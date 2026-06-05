/*
 * memory.c — direct-MMIO test path, kept alongside the BSP-driver path in
 * main.c. This is the original kr260_hw_bm implementation, verbatim except
 * for the test_* → mem_test_* rename and the move of tx_buf/rx_buf to
 * file scope (so main.c shares the same DMA buffers via memory.h).
 *
 * Address map (LPD aperture; matches extend_design.tcl):
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

#include "memory.h"

/* ---- Address map (LPD aperture) ---- */
#define ADDR_GPIO_CONTROL  0x80000000UL
#define ADDR_GPIO_VALUE    0x80010000UL
#define ADDR_GPIO_ADDEND   0x80020000UL
#define ADDR_AXI_FIFO      0x80030000UL
#define ADDR_AXI_DMA       0x80040000UL

/* ---- AXI GPIO (PG144) — single-channel layout ---- */
#define GPIO_DATA  0x00
#define GPIO2_DATA 0x08

/* ---- simple_fifo register offsets (custom Verilog, vivado/ip/simple_fifo.v) ---- */
#define FIFO_DATA   0x00
#define FIFO_COUNT  0x04
#define FIFO_STATUS 0x08
#define FIFO_RESET  0x0C
#define FIFO_STATUS_EMPTY 0x1u
#define FIFO_STATUS_FULL  0x2u

/* ---- AXI DMA (PG021), no-SG, simple register mode ---- */
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

static inline void w32(uintptr_t base, uint32_t off, uint32_t v) {
    Xil_Out32(base + off, v);
}
static inline uint32_t r32(uintptr_t base, uint32_t off) {
    return Xil_In32(base + off);
}

static void print_u64(const char *prefix, uint64_t v) {
    xil_printf("%s0x%08x_%08x", prefix,
               (uint32_t)(v >> 32), (uint32_t)(v & 0xFFFFFFFFu));
}

/* Shared DMA buffers — declared extern in memory.h so main.c can also use
 * them with the XAxiDma path. */
uint8_t tx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));
uint8_t rx_buf[DMA_BUF_SIZE] __attribute__((aligned(64)));

/* ========================================================================= */

int mem_test_gpio(void)
{
    xil_printf("\r\n===== [MMIO] Accumulator (axi_gpio_control + addend + value) =====\r\n");
    int fails = 0;

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

    ACC_PULSE(2);                                                       ACC_CHECK("reset",                 0, 0);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 5);          ACC_PULSE(1);         ACC_CHECK("+5",                    0, 5);
    ACC_PULSE(1);                                                       ACC_CHECK("+5 again",              0, 10);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 100);        ACC_PULSE(1);         ACC_CHECK("+100",                  0, 110);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0xFFFFFFFFu); ACC_PULSE(1);        ACC_CHECK("+0xFFFFFFFF (cross)",   1, 109);
    ACC_PULSE(2);                                                       ACC_CHECK("reset to 0",            0, 0);
    w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0xDEADBEEFu); ACC_PULSE(1);        ACC_CHECK("+0xDEADBEEF",           0, 0xDEADBEEF);
    ACC_PULSE(2); w32(ADDR_GPIO_ADDEND, GPIO_DATA, 0);                  ACC_CHECK("final reset",           0, 0);

    #undef ACC_PULSE
    #undef ACC_READ
    #undef ACC_CHECK
    return fails;
}

/* ========================================================================= */

int mem_test_fifo(void)
{
    xil_printf("\r\n===== [MMIO] simple_fifo push/pop (64-bit-word echo) =====\r\n");
    int fails = 0;

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

/* ========================================================================= */

static int dma_wait_idle(uint32_t sr_off, const char *name)
{
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

int mem_test_dma_fifo(void)
{
    xil_printf("\r\n===== [MMIO] AXI DMA echo (mem -> MM2S -> AXIS FIFO -> S2MM -> mem) =====\r\n");
    int fails = 0;
    const uint32_t buf_sz = DMA_BUF_SIZE;

    uint64_t tx_pa = (uint64_t)(uintptr_t)tx_buf;
    uint64_t rx_pa = (uint64_t)(uintptr_t)rx_buf;

    uint64_t *tx64 = (uint64_t *)tx_buf;
    uint64_t *rx64 = (uint64_t *)rx_buf;
    for (uint32_t i = 0; i < buf_sz / 8; i++)
        tx64[i] = 0xA5A5000000000000ULL ^ (uint64_t)i;
    memset(rx_buf, 0, buf_sz);

    xil_printf("  tx PA=0x%08x_%08x  rx PA=0x%08x_%08x  size=%d B\r\n",
               (uint32_t)(tx_pa >> 32), (uint32_t)(tx_pa & 0xFFFFFFFFu),
               (uint32_t)(rx_pa >> 32), (uint32_t)(rx_pa & 0xFFFFFFFFu),
               (int)buf_sz);

    Xil_DCacheFlushRange((UINTPTR)tx_buf, buf_sz);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

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

    w32(ADDR_AXI_DMA, DMA_S2MM_DMACR, DMA_DMACR_RS);
    w32(ADDR_AXI_DMA, DMA_MM2S_DMACR, DMA_DMACR_RS);
    xil_printf("  after RS=1:   MM2S CR=0x%08x SR=0x%08x  S2MM CR=0x%08x SR=0x%08x\r\n",
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_MM2S_DMASR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMACR),
               (unsigned)r32(ADDR_AXI_DMA, DMA_S2MM_DMASR));

    w32(ADDR_AXI_DMA, DMA_S2MM_DA,     (uint32_t)(rx_pa & 0xFFFFFFFFu));
    w32(ADDR_AXI_DMA, DMA_S2MM_DA_MSB, (uint32_t)(rx_pa >> 32));
    w32(ADDR_AXI_DMA, DMA_S2MM_LENGTH, buf_sz);

    w32(ADDR_AXI_DMA, DMA_MM2S_SA,     (uint32_t)(tx_pa & 0xFFFFFFFFu));
    w32(ADDR_AXI_DMA, DMA_MM2S_SA_MSB, (uint32_t)(tx_pa >> 32));
    w32(ADDR_AXI_DMA, DMA_MM2S_LENGTH, buf_sz);

    fails += dma_wait_idle(DMA_MM2S_DMASR, "MM2S");
    fails += dma_wait_idle(DMA_S2MM_DMASR, "S2MM");

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
