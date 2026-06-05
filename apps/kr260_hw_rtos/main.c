/*
 * kr260_hw_rtos — FreeRTOS test for the kr260_hw bitstream.
 *
 * Two parallel implementations of the same three exercises, both wrapped
 * in a single FreeRTOS task:
 *   - main.c     (this file) uses Xilinx BSP drivers — XGpio for the
 *                accumulator GPIOs, XAxiDma for the loopback DMA.
 *   - memory.c   keeps the original direct-MMIO implementation, with
 *                test_* renamed to mem_test_*.
 *
 * The custom simple_fifo IP has no matching Xilinx driver (XLlFifo targets
 * axi_fifo_mm_s, which has a different register layout), so test_fifo()
 * here still goes through direct MMIO via local helpers. The other two
 * tests use the BSP drivers.
 *
 * Swap test_* → mem_test_* in test_task() to run the MMIO path instead.
 *
 * Hardware (matches kr260_hw.tcl + extend_design.tcl):
 *   axi_gpio_control  @ 0x8000_0000  2-bit opcode out -> my_state.control
 *   axi_gpio_value    @ 0x8001_0000  dual-channel in  <- my_state.{sum,carry}
 *   axi_gpio_addend   @ 0x8002_0000  32-bit out       -> my_state.value
 *   axi_fifo_0        @ 0x8003_0000  custom simple_fifo (push/pop @ 0x00)
 *   axi_dma_0         @ 0x8004_0000  AXI DMA, MM2S->axis_data_fifo->S2MM
 */

#include <stdint.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xgpio.h"
#include "xaxidma.h"

#include "FreeRTOS.h"
#include "task.h"

#include "memory.h"

/* simple_fifo register layout (no Xilinx driver) */
#define ADDR_AXI_FIFO       0x80030000UL
#define FIFO_DATA           0x00
#define FIFO_COUNT          0x04
#define FIFO_STATUS         0x08
#define FIFO_RESET          0x0C
#define FIFO_STATUS_EMPTY   0x1u
#define FIFO_STATUS_FULL    0x2u

static XGpio   gpio_control;
static XGpio   gpio_value;
static XGpio   gpio_addend;
static XAxiDma axi_dma;

static void print_u64(const char *prefix, uint64_t v) {
    xil_printf("%s0x%08x_%08x", prefix,
               (uint32_t)(v >> 32), (uint32_t)(v & 0xFFFFFFFFu));
}

/* ========================================================================= */

static int init_devices(void)
{
    int s;

    s = XGpio_Initialize(&gpio_control, XPAR_AXI_GPIO_CONTROL_DEVICE_ID);
    if (s != XST_SUCCESS) { xil_printf("XGpio_Initialize(control) -> %d\r\n", s); return -1; }
    XGpio_SetDataDirection(&gpio_control, 1, 0x0);

    s = XGpio_Initialize(&gpio_value, XPAR_AXI_GPIO_VALUE_DEVICE_ID);
    if (s != XST_SUCCESS) { xil_printf("XGpio_Initialize(value) -> %d\r\n", s); return -1; }
    XGpio_SetDataDirection(&gpio_value, 1, 0xFFFFFFFFu);
    XGpio_SetDataDirection(&gpio_value, 2, 0xFFFFFFFFu);

    s = XGpio_Initialize(&gpio_addend, XPAR_AXI_GPIO_ADDEND_DEVICE_ID);
    if (s != XST_SUCCESS) { xil_printf("XGpio_Initialize(addend) -> %d\r\n", s); return -1; }
    XGpio_SetDataDirection(&gpio_addend, 1, 0x0);

    XAxiDma_Config *cfg = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_DEVICE_ID);
    if (!cfg) { xil_printf("XAxiDma_LookupConfig failed\r\n"); return -1; }
    s = XAxiDma_CfgInitialize(&axi_dma, cfg);
    if (s != XST_SUCCESS) { xil_printf("XAxiDma_CfgInitialize -> %d\r\n", s); return -1; }
    if (XAxiDma_HasSg(&axi_dma)) {
        xil_printf("AXI DMA built with SG — this test expects simple mode\r\n");
        return -1;
    }
    XAxiDma_IntrDisable(&axi_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&axi_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    return 0;
}

/* ---- 1. accumulator via XGpio ---- */
static int test_gpio(void)
{
    xil_printf("\r\n===== [XGpio] Accumulator (control + addend + value) =====\r\n");
    int fails = 0;

    #define ACC_PULSE(op) do {                                  \
        XGpio_DiscreteWrite(&gpio_control, 1, 0);               \
        XGpio_DiscreteWrite(&gpio_control, 1, (op));            \
        XGpio_DiscreteWrite(&gpio_control, 1, 0);               \
    } while (0)

    #define ACC_READ()                                          \
        ( ((uint64_t)XGpio_DiscreteRead(&gpio_value, 2) << 32)  \
        |  (uint64_t)XGpio_DiscreteRead(&gpio_value, 1) )

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

    ACC_PULSE(2);                                                              ACC_CHECK("reset",                 0, 0);
    XGpio_DiscreteWrite(&gpio_addend, 1, 5);           ACC_PULSE(1);           ACC_CHECK("+5",                    0, 5);
    ACC_PULSE(1);                                                              ACC_CHECK("+5 again",              0, 10);
    XGpio_DiscreteWrite(&gpio_addend, 1, 100);         ACC_PULSE(1);           ACC_CHECK("+100",                  0, 110);
    XGpio_DiscreteWrite(&gpio_addend, 1, 0xFFFFFFFFu); ACC_PULSE(1);           ACC_CHECK("+0xFFFFFFFF (cross)",   1, 109);
    ACC_PULSE(2);                                                              ACC_CHECK("reset to 0",            0, 0);
    XGpio_DiscreteWrite(&gpio_addend, 1, 0xDEADBEEFu); ACC_PULSE(1);           ACC_CHECK("+0xDEADBEEF",           0, 0xDEADBEEF);
    ACC_PULSE(2); XGpio_DiscreteWrite(&gpio_addend, 1, 0);                     ACC_CHECK("final reset",           0, 0);

    #undef ACC_PULSE
    #undef ACC_READ
    #undef ACC_CHECK
    return fails;
}

/* ---- 2. simple_fifo via direct MMIO (no Xilinx driver) ---- */
static inline void  fifo_w(uint32_t off, uint32_t v) { Xil_Out32(ADDR_AXI_FIFO + off, v); }
static inline uint32_t fifo_r(uint32_t off)          { return Xil_In32(ADDR_AXI_FIFO + off); }

static int test_fifo(void)
{
    xil_printf("\r\n===== [MMIO] simple_fifo push/pop (no Xilinx driver matches) =====\r\n");
    int fails = 0;

    fifo_w(FIFO_RESET, 1);

    uint32_t status = fifo_r(FIFO_STATUS);
    uint32_t count  = fifo_r(FIFO_COUNT);
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
        fifo_w(FIFO_DATA, (uint32_t)(tx[i] & 0xFFFFFFFFu));
        fifo_w(FIFO_DATA, (uint32_t)(tx[i] >> 32));
    }

    count = fifo_r(FIFO_COUNT);
    xil_printf("  after %d pushes: COUNT=%d (expected %d)\r\n",
               N_WORDS, (unsigned)count, N_WORDS * 2);
    if (count != N_WORDS * 2) { xil_printf("  COUNT mismatch\r\n"); return 1; }

    for (int i = 0; i < N_WORDS; i++) {
        uint32_t lo = fifo_r(FIFO_DATA);
        uint32_t hi = fifo_r(FIFO_DATA);
        rx[i] = ((uint64_t)hi << 32) | lo;
    }

    count  = fifo_r(FIFO_COUNT);
    status = fifo_r(FIFO_STATUS);
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

/* ---- 3. AXI DMA echo via XAxiDma (simple mode) ---- */
static int test_dma_fifo(void)
{
    xil_printf("\r\n===== [XAxiDma] DMA echo (mem -> MM2S -> AXIS FIFO -> S2MM -> mem) =====\r\n");
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

    XAxiDma_Reset(&axi_dma);
    int spin = 0;
    while (!XAxiDma_ResetIsDone(&axi_dma) && spin < 10000) spin++;
    if (!XAxiDma_ResetIsDone(&axi_dma)) {
        xil_printf("  XAxiDma_Reset did not complete\r\n");
        return 1;
    }

    int s = XAxiDma_SimpleTransfer(&axi_dma, (UINTPTR)rx_buf, buf_sz,
                                   XAXIDMA_DEVICE_TO_DMA);
    if (s != XST_SUCCESS) { xil_printf("  S2MM submit -> %d\r\n", s); return 1; }
    s = XAxiDma_SimpleTransfer(&axi_dma, (UINTPTR)tx_buf, buf_sz,
                                XAXIDMA_DMA_TO_DEVICE);
    if (s != XST_SUCCESS) { xil_printf("  MM2S submit -> %d\r\n", s); return 1; }

    int polls = 0;
    while ((XAxiDma_Busy(&axi_dma, XAXIDMA_DEVICE_TO_DMA) ||
            XAxiDma_Busy(&axi_dma, XAXIDMA_DMA_TO_DEVICE)) && polls < 10000000) {
        polls++;
    }
    if (XAxiDma_Busy(&axi_dma, XAXIDMA_DEVICE_TO_DMA) ||
        XAxiDma_Busy(&axi_dma, XAXIDMA_DMA_TO_DEVICE)) {
        xil_printf("  DMA timeout after %d polls\r\n", polls);
        return 1;
    }
    xil_printf("  DMA done after %d polls\r\n", polls);

    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, buf_sz);

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

    return fails;
}

/* ========================================================================= */

static void test_task(void *pvParameters)
{
    (void)pvParameters;

    xil_printf("\r\n=========================================\r\n");
    xil_printf("kr260_hw_rtos FreeRTOS test (Xilinx drivers, Cortex-A53 #0)\r\n");
    xil_printf("=========================================\r\n");

    if (init_devices() != 0) {
        xil_printf("Device initialization failed — idling\r\n");
        for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
    }

    int fails = 0;
    fails += test_gpio();
    fails += test_fifo();
    fails += test_dma_fifo();

    xil_printf("\r\n=========================================\r\n");
    xil_printf("RESULT: %s — %d failures\r\n",
               fails == 0 ? "ALL PASS" : "FAIL", fails);
    xil_printf("=========================================\r\n");

    for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
}

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xTaskCreate(test_task, "test",
                configMINIMAL_STACK_SIZE * 8,
                NULL,
                tskIDLE_PRIORITY + 1,
                NULL);

    vTaskStartScheduler();

    for (;;);
    return 0;
}
