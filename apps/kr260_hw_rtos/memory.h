/*
 * memory.h — declarations for the direct-MMIO test path.
 *
 * memory.c holds the original implementation of the three kr260_hw tests,
 * programming every register via Xil_In32/Xil_Out32 against hardcoded
 * physical addresses. It's kept alongside main.c (which uses Xilinx BSP
 * drivers) as a reference and a sanity check.
 *
 * Swap the calls in test_task() from test_* to mem_test_* to exercise the
 * MMIO path instead.
 */

#ifndef MEMORY_H
#define MEMORY_H

#include <stdint.h>

/* Shared DMA buffers — 64-byte aligned for cacheline-clean DMA, defined in
 * memory.c. Both the BSP-driver path (main.c) and the MMIO path use them so
 * the two implementations exercise identical DDR addresses. */
#define DMA_BUF_SIZE 4096
extern uint8_t tx_buf[DMA_BUF_SIZE];
extern uint8_t rx_buf[DMA_BUF_SIZE];

int mem_test_gpio(void);
int mem_test_fifo(void);
int mem_test_dma_fifo(void);

#endif
