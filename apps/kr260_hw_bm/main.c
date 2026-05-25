/*
 * kr260_hw_bm — bare-metal test for the kr260_hw bitstream.
 *
 * Drop into a Vitis "Standalone Empty Application" project targeting the
 * kr260_hw.xsa platform (psu_cortexa53_0). Single source file with main()
 * plus three helpers (test_gpio, test_fifo, test_dma_fifo) — no BSP-specific
 * dependencies beyond the standard Xilinx standalone library (xil_io,
 * xil_cache, xil_printf, sleep).
 *
 * Compared to the Linux userspace version this is much simpler:
 *   - No /dev/uio enumeration, just hardcoded physical addresses (the BD's
 *     address map is fixed and the standalone aarch64 boot maps DDR 1:1).
 *   - No mlock / pagemap / dmabuf gymnastics — DMA buffers are .bss arrays
 *     in DDR_LOW that the AXI DMA can access directly.
 *   - No SMMU / HP0 fabric oddities to worry about; bare-metal runs at EL3
 *     and the AXI bus is wide-open.
 *
 * Hardware (matches kr260_hw.tcl + extend_design.tcl, LPD aperture):
 *   axi_gpio_control  @ 0x8000_0000  2-bit opcode out → my_state.control
 *   axi_gpio_value    @ 0x8001_0000  dual-channel in  ← my_state.{sum,carry}
 *   axi_gpio_addend   @ 0x8002_0000  32-bit out       → my_state.value
 *   axi_fifo_0        @ 0x8003_0000  custom simple_fifo (push/pop @ 0x00)
 *   axi_dma_0         @ 0x8004_0000  AXI DMA, MM2S→axis_data_fifo→S2MM
 */

#include <stdint.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"

/* ---- Address map (LPD aperture; matches extend_design.tcl) ---- */
#define ADDR_GPIO_CONTROL  0x80000000UL
#define ADDR_GPIO_VALUE    0x80010000UL
#define ADDR_GPIO_ADDEND   0x80020000UL
#define ADDR_AXI_FIFO      0x80030000UL
#define ADDR_AXI_DMA       0x80040000UL

/* ---- AXI GPIO (Xilinx PG144) — single-channel layout ---- */
#define GPIO_DATA  0x00
#define GPIO2_DATA 0x08

/* ---- simple_fifo register offsets (custom Verilog, see vivado/ip/simple_fifo.v) ---- */
#define FIFO_DATA   0x00  /* W: push 32-bit value; R: pop 32-bit value */
#define FIFO_COUNT  0x04
#define FIFO_STATUS 0x08
#define FIFO_RESET  0x0C
#define FIFO_STATUS_EMPTY 0x1u
#define FIFO_STATUS_FULL  0x2u

/* ---- AXI DMA (Xilinx PG021), no-SG, simple register mode ---- */
#define DMA_MM2S_DMACR     0x00
#define DMA_MM2S_DMASR     0x04
#define DMA_MM2S_SA        0x18
#define DMA_MM2S_SA_MSB    0x1C
#define DMA_MM2S_LENGTH    0x28

#define DMA_S2MM_DMACR     0x30
#define DMA_S2MM_DMASR     0x34
#define DMA_S2MM_DA        0x48
#define DMA_S2MM_DA_MSB    0x4C
#define DMA_S2MM_LENGTH    0x58

#define DMA_DMACR_RS       (1u << 0)
#define DMA_DMACR_RESET    (1u << 2)
#define DMA_DMASR_HALTED   (1u << 0)
#define DMA_DMASR_IDLE     (1u << 1)
#define DMA_DMASR_ERR_MASK (0x70u)

/* ---- Helpers ---- */

static inline void w32(uintptr_t base, uint32_t off, uint32_t v) {
    Xil_Out32(base + off, v);
}
static inline uint32_t r32(uintptr_t base, uint32_t off) {
    return Xil_In32(base + off);
}

/* xil_printf doesn't support %llx — print 64-bit values as two 32-bit halves. */
static void print_u64(const char *prefix, uint64_t v) {
    xil_printf("%s0x%08x_%08x", prefix,
               (uint32_t)(v >> 32), (uint32_t)(v & 0xFFFFFFFFu));
}

/* ---- DMA buffers in DDR (.bss). 64-byte aligned for cacheline-clean DMA. ---- */
#define DMA_BUF_SIZE 4096
static uint8_t tx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));
static uint8_t rx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));

/* =========================================================================
 * Helper 1: GPIO accumulator test
 * ========================================================================= */
static int test_gpio(void)
{
    xil_printf("\n===== Accumulator (axi_gpio_control + addend + value) =====\r\n");
    int fails = 0;

    /* pulse(opcode): 0 -> opcode -> 0 on the 2-bit control bus.
     * my_state captures the rising edge from 0. */
    #define ACC_PULSE(op) do {                                 \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, 0);                  \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, (op));               \
        w32(ADDR_GPIO_CONTROL, GPIO_DATA, 0);                  \
    } while (0)

    #define ACC_READ()                                                          \
        ( ((uint64_t)r32(ADDR_GPIO_VALUE, GPIO2_DATA) << 32)                    \
        |  (uint64_t)r32(ADDR_GPIO_VALUE, GPIO_DATA) )

    #define ACC_CHECK(label, exp_hi, exp_lo) do {                               \
        uint64_t got = ACC_READ();                                              \
        uint64_t exp = ((uint64_t)(exp_hi) << 32) | (uint64_t)(exp_lo);         \
        int ok = (got == exp);                                                  \
        xil_printf("  %-26s  ", (label));                                       \
        print_u64("got=", got);                                                 \
        print_u64("  exp=", exp);                                               \
        xil_printf("  %s\r\n", ok ? "PASS" : "FAIL");                           \
        if (!ok) fails++;                                                       \
    } while (0)

    /* opcode 2 = reset, opcode 1 = add (both edge-triggered) */
    ACC_PULSE(2);                                                       ACC_CHECK("reset",                 0, 0);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 5);          ACC_PULSE(1);         ACC_CHECK("+5",                    0, 5);
    ACC_PULSE(1);                                                       ACC_CHECK("+5 again",              0, 10);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 100);        ACC_PULSE(1);         ACC_CHECK("+100",                  0, 110);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0xFFFFFFFFu); ACC_PULSE(1);        ACC_CHECK("+0xFFFFFFFF (cross)",   1, 109);
    ACC_PULSE(2);                                                       ACC_CHECK("reset to 0",            0, 0);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0xDEADBEEFu); ACC_PULSE(1);        ACC_CHECK("+0xDEADBEEF",           0, 0xDEADBEEF);
    ACC_PULSE(2); w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0);                  ACC_CHECK("final reset",           0, 0);

    return fails;
}

/* =========================================================================
 * Helper 2: simple_fifo push/pop test
 * ========================================================================= */
static int test_fifo(void)
{
    xil_printf("\n===== simple_fifo push/pop (64-bit-word echo) =====\r\n");
    int fails = 0;

    /* Reset the FIFO (any write to FIFO_RESET clears wp = rp). */
    w32(ADDR_AXI_FIFO, FIFO_RESET, 1);

    uint32_t status = r32(ADDR_AXI_FIFO, FIFO_STATUS);
    uint32_t count  = r32(ADDR_AXI_FIFO, FIFO_COUNT);
    xil_printf("  post-reset: STATUS=0x%x (empty=%d full=%d) COUNT=%d\r\n",
               (unsigned)status,
               !!(status & FIFO_STATUS_EMPTY), !!(status & FIFO_STATUS_FULL),
               (unsigned)count);
    if (!(status & FIFO_STATUS_EMPTY) || count != 0) {
        xil_printf("  FIFO not empty after reset\r\n");
        return 1;
    }

    /* Push 16 64-bit words (32 × 32-bit pushes, LSB then MSB). */
    enum { N_WORDS = 16 };
    uint64_t tx[N_WORDS], rx[N_WORDS];
    for (int i = 0; i < N_WORDS; i++)
        tx[i] = 0xCAFE000000000001ULL + (uint64_t)i * 0x100000010ULL;

    for (int i = 0; i < N_WORDS; i++) {
        w32(ADDR_AXI_FIFO, FIFO_DATA, (uint32_t)(tx[i] & 0xFFFFFFFFu));
        w32(ADDR_AXI_FIFO, FIFO_DATA, (uint32_t)(tx[i] >> 32));
    }

    count = r32(ADDR_AXI_FIFO, FIFO_COUNT);
    xil_printf("  after %d pushes: COUNT=%d (expected %d)\r\n",
               N_WORDS, (unsigned)count, N_WORDS * 2);
    if (count != N_WORDS * 2) { xil_printf("  COUNT mismatch\r\n"); return 1; }

    /* Pop them back. */
    for (int i = 0; i < N_WORDS; i++) {
        uint32_t lo = r32(ADDR_AXI_FIFO, FIFO_DATA);
        uint32_t hi = r32(ADDR_AXI_FIFO, FIFO_DATA);
        rx[i] = ((uint64_t)hi << 32) | lo;
    }

    count  = r32(ADDR_AXI_FIFO, FIFO_COUNT);
    status = r32(ADDR_AXI_FIFO, FIFO_STATUS);
    xil_printf("  after %d pops: COUNT=%d  STATUS=0x%x\r\n",
               N_WORDS, (unsigned)count, (unsigned)status);

    int ok = (memcmp(tx, rx, sizeof(tx)) == 0) && (count == 0) &&
             (status & FIFO_STATUS_EMPTY);
    if (!ok) {
        for (int i = 0; i < N_WORDS; i++) {
            if (tx[i] != rx[i]) {
                xil_printf("    [%2d] ", i);
                print_u64("tx=", tx[i]);
                print_u64("  rx=", rx[i]);
                xil_printf("  MISMATCH\r\n");
            }
        }
        fails++;
    }
    xil_printf("  echo of %d 64-bit words: %s\r\n", N_WORDS, ok ? "PASS" : "FAIL");
    return fails;
}

/* =========================================================================
 * Helper 3: AXI DMA echo test (mem→MM2S→axis_data_fifo→S2MM→mem)
 * ========================================================================= */
static int dma_wait_idle(uint32_t sr_off, const char *name)
{
    /* Generous timeout — bare-metal usually completes a 4-KiB transfer in
     * well under 100 µs, but we count loop iterations rather than time so
     * this works regardless of CPU frequency. */
    for (int i = 0; i < 10000000; i++) {
        uint32_t sr = r32(ADDR_AXI_DMA, sr_off);
        if (sr & DMA_DMASR_ERR_MASK) {
            xil_printf("  %s SR=0x%08x ERR\r\n", name, (unsigned)sr);
            return 1;
        }
        if (sr & DMA_DMASR_IDLE) {
            xil_printf("  %s done after %d polls, SR=0x%08x\r\n",
                       name, i, (unsigned)sr);
            return 0;
        }
    }
    xil_printf("  %s timeout, SR=0x%08x\r\n",
               name, (unsigned)r32(ADDR_AXI_DMA, sr_off));
    return 1;
}

static int test_dma_fifo(void)
{
    xil_printf("\n===== AXI DMA echo (mem -> MM2S -> AXIS FIFO -> S2MM -> mem) =====\r\n");
    int fails = 0;
    const uint32_t buf_sz = DMA_BUF_SIZE;

    /* Bare-metal: tx_buf and rx_buf are .bss arrays at fixed DDR_LOW addresses.
     * No MMU, so VA == PA. (uintptr_t cast OK on aarch64.) */
    uint64_t tx_pa = (uint64_t)(uintptr_t)tx_buf;
    uint64_t rx_pa = (uint64_t)(uintptr_t)rx_buf;

    /* Fill TX with a recognizable pattern as 64-bit words. */
    uint64_t *tx64 = (uint64_t *)tx_buf;
    uint64_t *rx64 = (uint64_t *)rx_buf;
    for (uint32_t i = 0; i < buf_sz / 8; i++)
        tx64[i] = 0xA5A5000000000000ULL ^ (uint64_t)i;
    memset(rx_buf, 0, buf_sz);

    xil_printf("  tx PA=0x%08x_%08x  rx PA=0x%08x_%08x  size=%d B\r\n",
               (uint32_t)(tx_pa >> 32), (uint32_t)(tx_pa & 0xFFFFFFFFu),
               (uint32_t)(rx_pa >> 32), (uint32_t)(rx_pa & 0xFFFFFFFFu),
               (int)buf_sz);

    /* Cache management: flush TX so DDR sees the data the DMA will read,
     * and invalidate RX so any stale dirty cache lines don't overwrite the
     * DMA-written data when they get evicted later. */
    Xil_DCacheFlushRange((UINTPTR)tx_buf, buf_sz);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

    /* Reset both DMA channels and wait for the bit to self-clear. */
    w32(ADDR_AXI_DMA, DMA_MM2S_DMACR, DMA_DMACR_RESET);
    w32(ADDR_AXI_DMA, DMA_S2MM_DMACR, DMA_DMACR_RESET);
    int sp = 0;
    while ((r32(ADDR_AXI_DMA, DMA_MM2S_DMACR) & DMA_DMACR_RESET) && sp < 10000) sp++;
    while ((r32(ADDR_AXI_DMA, DMA_S2MM_DMACR) & DMA_DMACR_RESET) && sp < 10000) sp++;
    xil_printf("  after reset:  MM2S CR=0x%08x SR=0x%08x  S2MM CR=0x%08x SR=0x%08x\r\n",
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMASR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMASR));

    /* RS=1 on both halves. */
    w32(ADDR_AXI_DMA, DMA_S2MM_DMACR, DMA_DMACR_RS);
    w32(ADDR_AXI_DMA, DMA_MM2S_DMACR, DMA_DMACR_RS);
    xil_printf("  after RS=1:   MM2S CR=0x%08x SR=0x%08x  S2MM CR=0x%08x SR=0x%08x\r\n",
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMASR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMASR));

    /* Program S2MM (receiver) first so the AXIS FIFO has a sink ready. */
    w32(ADDR_AXI_DMA, DMA_S2MM_DA,     (uint32_t)(rx_pa & 0xFFFFFFFFu));
    w32(ADDR_AXI_DMA, DMA_S2MM_DA_MSB, (uint32_t)(rx_pa >> 32));
    w32(ADDR_AXI_DMA, DMA_S2MM_LENGTH, buf_sz);

    /* Program MM2S — LENGTH write triggers the transfer. */
    w32(ADDR_AXI_DMA, DMA_MM2S_SA,     (uint32_t)(tx_pa & 0xFFFFFFFFu));
    w32(ADDR_AXI_DMA, DMA_MM2S_SA_MSB, (uint32_t)(tx_pa >> 32));
    w32(ADDR_AXI_DMA, DMA_MM2S_LENGTH, buf_sz);

    fails += dma_wait_idle(DMA_MM2S_DMASR, "MM2S");
    fails += dma_wait_idle(DMA_S2MM_DMASR, "S2MM");

    /* Invalidate RX once more so the cache view matches what DMA wrote. */
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

    if (!fails) {
        if (memcmp(tx_buf, rx_buf, buf_sz) != 0) {
            int diffs = 0;
            for (uint32_t i = 0; i < buf_sz / 8 && diffs < 4; i++) {
                if (tx64[i] != rx64[i]) {
                    xil_printf("    [%4d] ", (int)i);
                    print_u64("tx=", tx64[i]);
                    print_u64("  rx=", rx64[i]);
                    xil_printf("\r\n");
                    diffs++;
                }
            }
            fails++;
            xil_printf("  DMA echo: FAIL (data mismatch)\r\n");
        } else {
            xil_printf("  DMA echo: PASS (%d bytes round-tripped)\r\n", (int)buf_sz);
        }
    }

    return fails;
}

/* ========================================================================= */

int main(void)
{
    /* Vitis Standalone normally calls init_platform()/cleanup_platform() that
     * wraps these. Doing it inline keeps this file self-contained. */
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n=========================================\r\n");
    xil_printf("kr260_hw_bm bare-metal test\r\n");
    xil_printf("=========================================\r\n");

    int fails = 0;
    fails += test_gpio();
    fails += test_fifo();
    fails += test_dma_fifo();

    xil_printf("\r\n=========================================\r\n");
    xil_printf("RESULT: %s — %d failures\r\n",
               fails == 0 ? "ALL PASS" : "FAIL", fails);
    xil_printf("=========================================\r\n");

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    return 0;
}
