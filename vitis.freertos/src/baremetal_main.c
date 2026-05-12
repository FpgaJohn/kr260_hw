#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xil_cache.h"
#include "sleep.h"

/*
 * axi_gpio_control @ 0xA000_0000  ch1=control (2-bit out, single-channel)
 * axi_gpio_addend  @ 0xA004_0000  ch1=addend  (32-bit out, single-channel)
 * axi_gpio_value   @ 0xA001_0000  ch1=sum     (32-bit in)  ch2=carry (32-bit in)
 * axi_fifo_mm_s_0  @ 0xA002_0000  AXI4-Stream FIFO (32-bit, loopback)
 * axi_dma_0        @ 0xA005_0000  AXI DMA (no SG, 64-bit, loopback via axis_data_fifo)
 */
#define GPIO_CTRL_BASE    0xA0000000UL
#define GPIO_ADDEND_BASE  0xA0040000UL
#define GPIO_VAL_BASE     0xA0010000UL
#define FIFO_BASE         0xA0020000UL
#define DMA_BASE          0xA0050000UL

/* GPIO register offsets */
#define GPIO_DATA    0x00
#define GPIO_TRI     0x04
#define GPIO2_DATA   0x08
#define GPIO2_TRI    0x0C

/* AXI4-Stream FIFO (axi_fifo_mm_s) register offsets — from xaxififo.h */
#define FIFO_ISR      0x00  /* Interrupt Status */
#define FIFO_TDFR     0x08  /* TX FIFO Reset (write 0xA5) */
#define FIFO_TDFV     0x0C  /* TX FIFO Vacancy (32-bit words) */
#define FIFO_TDFD     0x10  /* TX FIFO Data */
#define FIFO_TLR      0x14  /* TX Length Register — write byte count to trigger TX */
#define FIFO_RDFR     0x18  /* RX FIFO Reset (write 0xA5) */
#define FIFO_RDFO     0x1C  /* RX FIFO Occupancy (32-bit words) */
#define FIFO_RDFD     0x20  /* RX FIFO Data */
#define FIFO_RLR      0x24  /* RX packet length (bytes) */
#define FIFO_RESET_KEY 0xA5u

/* AXI DMA register offsets */
#define DMA_MM2S_DMACR  0x00
#define DMA_MM2S_DMASR  0x04
#define DMA_MM2S_SA     0x18  /* Source Address lower 32 bits */
#define DMA_MM2S_SA_MSB 0x1C  /* Source Address upper 32 bits */
#define DMA_MM2S_LENGTH 0x28  /* Transfer length (bytes) — triggers MM2S */
#define DMA_S2MM_DMACR  0x30
#define DMA_S2MM_DMASR  0x34
#define DMA_S2MM_DA     0x48  /* Destination Address lower 32 bits */
#define DMA_S2MM_DA_MSB 0x4C  /* Destination Address upper 32 bits */
#define DMA_S2MM_LENGTH 0x58  /* Transfer length (bytes) — triggers S2MM */

#define DMA_DMACR_RS    0x00000001u  /* Run/Stop */
#define DMA_DMACR_RESET 0x00000004u  /* Software reset (self-clearing) */
#define DMA_DMASR_HALTED 0x00000001u
#define DMA_DMASR_IDLE  0x00000002u  /* Transfer complete */
#define DMA_DMASR_ERR   0x00000070u  /* IntErr | SlvErr | DecErr */

#define CTRL_NOOP    0u
#define CTRL_ADD     1u
#define CTRL_RESET   2u

/* ---- GPIO helpers ---- */
static inline void ctrl_w(u32 off, u32 v)   { Xil_Out32(GPIO_CTRL_BASE   + off, v); }
static inline u32  ctrl_r(u32 off)           { return Xil_In32(GPIO_CTRL_BASE   + off); }
static inline void addend_w(u32 v)           { Xil_Out32(GPIO_ADDEND_BASE + GPIO_DATA, v); }
static inline u32  addend_r(void)            { return Xil_In32(GPIO_ADDEND_BASE + GPIO_DATA); }
static inline u32  val_r(u32 off)            { return Xil_In32(GPIO_VAL_BASE    + off); }

/* ---- FIFO helpers ---- */
static inline void fifo_w(u32 off, u32 v) { Xil_Out32(FIFO_BASE + off, v); }
static inline u32  fifo_r(u32 off)        { return Xil_In32(FIFO_BASE + off); }

/* ---- DMA helpers ---- */
static inline void dma_w(u32 off, u32 v) { Xil_Out32(DMA_BASE + off, v); }
static inline u32  dma_r(u32 off)        { return Xil_In32(DMA_BASE + off); }

/* DMA transfer buffers — cache-line aligned (64 bytes on Cortex-A53) */
static u8 dma_src[64] __attribute__((aligned(64)));
static u8 dma_dst[64] __attribute__((aligned(64)));

/* ---- GPIO / my_state functions ---- */
static void pulse_control(u32 opcode)
{
    ctrl_w(GPIO_DATA, CTRL_NOOP);
    ctrl_w(GPIO_DATA, opcode);
    ctrl_w(GPIO_DATA, CTRL_NOOP);
}

static void reset_accumulator(void)
{
    pulse_control(CTRL_RESET);
}

static void add_value(u32 value)
{
    addend_w(value);
    pulse_control(CTRL_ADD);
}

static u64 read_accumulator(void)
{
    u32 lo = val_r(GPIO_DATA);
    u32 hi = val_r(GPIO2_DATA);
    return ((u64)hi << 32) | lo;
}

static void print_u64(const char *label, u64 v)
{
    xil_printf("%s0x%08x%08x", label, (u32)(v >> 32), (u32)v);
}

static int check(const char *label, u64 got, u64 expected)
{
    int ok = (got == expected);
    xil_printf("  %-30s ", label);
    print_u64("got=",  got);
    print_u64("  exp=", expected);
    xil_printf("  %s\r\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

/* ---- AXI4-Stream FIFO loopback test ---- */
static int fifo_test(void)
{
    int failures = 0;
    u32 rlr;
    const u32 w0 = 0x12345678u;
    const u32 w1 = 0xCAFEBABEu;

    xil_printf("\r\n=== AXI Stream FIFO loopback test ===\r\n");
    xil_printf("axi_fifo_mm_s_0 @ 0x%08x  (32-bit stream, TX->RX loopback)\r\n",
               (u32)FIFO_BASE);

    xil_printf("  ISR=0x%08x  TDFV=0x%08x\r\n",
               fifo_r(FIFO_ISR), fifo_r(FIFO_TDFV));

    fifo_w(FIFO_TDFR, FIFO_RESET_KEY);
    fifo_w(FIFO_RDFR, FIFO_RESET_KEY);

    /* Two 32-bit stream words: one TDFD write each */
    fifo_w(FIFO_TDFD, w0);
    fifo_w(FIFO_TDFD, w1);

    /* Trigger TX: 2 words × 4 bytes = 8 bytes */
    fifo_w(FIFO_TLR, 8);

    /* Wait for RX data */
    int timeout = 1000000;
    while (fifo_r(FIFO_RDFO) == 0 && --timeout > 0);
    if (timeout == 0) {
        xil_printf("  RX timeout — FAIL (RDFO never non-zero)\r\n");
        return 2;
    }

    {
        u32 got = fifo_r(FIFO_RDFD);
        int ok = (got == w0);
        xil_printf("  word0: got 0x%08x  exp 0x%08x  %s\r\n", got, w0, ok ? "PASS" : "FAIL");
        if (!ok) failures++;
    }
    {
        u32 got = fifo_r(FIFO_RDFD);
        int ok = (got == w1);
        xil_printf("  word1: got 0x%08x  exp 0x%08x  %s\r\n", got, w1, ok ? "PASS" : "FAIL");
        if (!ok) failures++;
    }

    rlr = fifo_r(FIFO_RLR);
    xil_printf("  RLR=%u bytes (expect 8)  %s\r\n",
               (unsigned)rlr, (rlr == 8) ? "PASS" : "note");

    xil_printf("=== FIFO: %s : %d failure(s) ===\r\n",
               failures == 0 ? "ALL PASS" : "FAIL", failures);
    return failures;
}

/* ---- AXI DMA loopback test ---- */
static int dma_test(void)
{
    int failures = 0;
    const u32 len = sizeof(dma_src);
    u32 sr;
    int timeout;

    xil_printf("\r\n=== AXI DMA loopback test (%u bytes) ===\r\n", (unsigned)len);
    xil_printf("axi_dma_0 @ 0x%08x  (MM2S→HP0, S2MM←HP1, axis_data_fifo loopback)\r\n",
               (u32)DMA_BASE);

    /* Fill src with test pattern, clear dst */
    for (u32 i = 0; i < len; i++) {
        dma_src[i] = (u8)(i ^ 0xA5u);
        dma_dst[i] = 0;
    }

    /* Flush src to DDR before DMA reads; invalidate dst so CPU re-fetches after DMA writes */
    Xil_DCacheFlushRange((UINTPTR)dma_src, len);
    Xil_DCacheInvalidateRange((UINTPTR)dma_dst, len);

    /* Soft-reset both channels */
    dma_w(DMA_MM2S_DMACR, DMA_DMACR_RESET);
    dma_w(DMA_S2MM_DMACR, DMA_DMACR_RESET);
    timeout = 100000;
    while ((dma_r(DMA_MM2S_DMACR) & DMA_DMACR_RESET) && --timeout > 0);
    timeout = 100000;
    while ((dma_r(DMA_S2MM_DMACR) & DMA_DMACR_RESET) && --timeout > 0);

    /* Start S2MM first (so it's ready when MM2S sends data) */
    dma_w(DMA_S2MM_DMACR,  DMA_DMACR_RS);
    dma_w(DMA_S2MM_DA,     (u32)(UINTPTR)dma_dst);
    dma_w(DMA_S2MM_DA_MSB, 0);
    dma_w(DMA_S2MM_LENGTH, len);  /* triggers S2MM */

    /* Start MM2S */
    dma_w(DMA_MM2S_DMACR,  DMA_DMACR_RS);
    dma_w(DMA_MM2S_SA,     (u32)(UINTPTR)dma_src);
    dma_w(DMA_MM2S_SA_MSB, 0);
    dma_w(DMA_MM2S_LENGTH, len);  /* triggers MM2S */

    /* Poll MM2S for Idle or error */
    timeout = 1000000;
    do { sr = dma_r(DMA_MM2S_DMASR); } while (!(sr & (DMA_DMASR_IDLE | DMA_DMASR_ERR)) && --timeout > 0);
    if (sr & DMA_DMASR_ERR) {
        xil_printf("  MM2S error DMASR=0x%08x  FAIL\r\n", sr);
        failures++;
    } else if (timeout == 0) {
        xil_printf("  MM2S timeout  FAIL\r\n");
        failures++;
    } else {
        xil_printf("  MM2S idle  PASS\r\n");
    }

    /* Poll S2MM for Idle or error */
    timeout = 1000000;
    do { sr = dma_r(DMA_S2MM_DMASR); } while (!(sr & (DMA_DMASR_IDLE | DMA_DMASR_ERR)) && --timeout > 0);
    if (sr & DMA_DMASR_ERR) {
        xil_printf("  S2MM error DMASR=0x%08x  FAIL\r\n", sr);
        failures++;
    } else if (timeout == 0) {
        xil_printf("  S2MM timeout  FAIL\r\n");
        failures++;
    } else {
        xil_printf("  S2MM idle  PASS\r\n");
    }

    /* Invalidate dst before CPU reads (DMA may have written behind the cache) */
    Xil_DCacheInvalidateRange((UINTPTR)dma_dst, len);

    /* Compare buffers */
    int mismatch = 0;
    for (u32 i = 0; i < len; i++) {
        if (dma_dst[i] != dma_src[i]) {
            xil_printf("  mismatch at byte %u: got 0x%02x exp 0x%02x\r\n",
                       (unsigned)i, dma_dst[i], dma_src[i]);
            mismatch++;
            if (mismatch >= 4) break;
        }
    }
    if (mismatch == 0)
        xil_printf("  data compare (%u bytes)  PASS\r\n", (unsigned)len);
    else
        failures += mismatch;

    xil_printf("=== DMA: %s : %d failure(s) ===\r\n",
               failures == 0 ? "ALL PASS" : "FAIL", failures);
    return failures;
}

/* ---- GPIO / my_state test ---- */
static int gpio_test(void)
{
    int failures = 0;

    xil_printf("\r\n=== bare-metal GPIO + my_state test ===\r\n");
    xil_printf("axi_gpio_control @ 0x%08x   (ch1=control, single-channel out)\r\n",
               (u32)GPIO_CTRL_BASE);
    xil_printf("axi_gpio_addend  @ 0x%08x   (ch1=addend,  single-channel out)\r\n",
               (u32)GPIO_ADDEND_BASE);
    xil_printf("axi_gpio_value   @ 0x%08x   (ch1=sum,     ch2=carry)\r\n",
               (u32)GPIO_VAL_BASE);

    xil_printf("\r\n--- TRI sanity (expect 0 for all-output channels) ---\r\n");
    xil_printf("  ctrl   GPIO_TRI   = 0x%08x\r\n", ctrl_r(GPIO_TRI));
    xil_printf("  addend GPIO_TRI   = 0x%08x\r\n", Xil_In32(GPIO_ADDEND_BASE + GPIO_TRI));

    xil_printf("\r\n--- addend write-readback ---\r\n");
    addend_w(0xCAFEBABEu);
    u32 rb = addend_r();
    xil_printf("  wrote 0xCAFEBABE, read 0x%08x  %s\r\n",
               rb, (rb == 0xCAFEBABEu) ? "PASS" : "FAIL  <-- bitstream bug");
    if (rb != 0xCAFEBABEu) failures++;
    addend_w(0);

    xil_printf("\r\n--- functional test ---\r\n");

    reset_accumulator();
    failures += check("after reset",             read_accumulator(), 0ULL);

    add_value(5);
    failures += check("after +5",                read_accumulator(), 5ULL);

    add_value(5);
    failures += check("after +5 again",          read_accumulator(), 10ULL);

    add_value(0x100);
    failures += check("after +0x100",            read_accumulator(), 10ULL + 0x100ULL);

    reset_accumulator();
    failures += check("after reset (round 2)",   read_accumulator(), 0ULL);

    add_value(0xFFFFFFFFu);
    failures += check("after +0xFFFFFFFF",       read_accumulator(), 0xFFFFFFFFULL);

    add_value(0xFFFFFFFFu);
    failures += check("after +0xFFFFFFFF again", read_accumulator(),
                      2ULL * 0xFFFFFFFFULL);

    reset_accumulator();
    failures += check("after final reset",       read_accumulator(), 0ULL);

    add_value(0xDEADBEEFu);
    u64 before_noop = read_accumulator();
    pulse_control(CTRL_NOOP);
    failures += check("noop leaves accum",       read_accumulator(), before_noop);

    reset_accumulator();

    xil_printf("\r\n=== GPIO: %s : %d failure(s) ===\r\n",
               failures == 0 ? "ALL PASS" : "FAIL", failures);
    return failures;
}

int main(void)
{
    int total = 0;

    total += gpio_test();
    total += fifo_test();
    total += dma_test();

    ctrl_w(GPIO_DATA, 0);
    addend_w(0);

    xil_printf("\r\n========================================\r\n");
    xil_printf("TOTAL: %s : %d failure(s)\r\n",
               total == 0 ? "ALL PASS" : "FAIL", total);
    xil_printf("========================================\r\n");

    return total;
}
