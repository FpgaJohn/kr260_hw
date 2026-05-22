# kr260_hw_rtos — FreeRTOS test

Same three exercises as `apps/kr260_hw_bm`, but the BSP is FreeRTOS
(`freertos10_xilinx`) rather than standalone. Single task wraps GPIO
accumulator + simple_fifo echo + AXI DMA echo, then idles.

Target: KR260 SOM, ZynqMP ZU5EV, Cortex-A53 #0 at EL3.

## Build

```bash
source /tools/Xilinx/Vitis/2024.1/settings64.sh
cd apps/kr260_hw_rtos
xsct build.tcl
```

Produces `vitis_ws/kr260_hw_rtos/Debug/kr260_hw_rtos.elf` plus the
FreeRTOS-flavored platform and FSBL Vitis needs at JTAG-load time.

Prerequisite: `vivado/kr260_hw.xsa` must exist — run `make` in `vivado/` first.

## Run via JTAG

```bash
xsct load.tcl
```

Identical to `apps/kr260_hw_bm/load.tcl` — `connect`, `rst -system`,
`fpga <bit>`, `psu_init`, `dow <elf>; con`. The JTAG flow doesn't care
that the ELF contains a FreeRTOS scheduler.

UART: 115200 8N1 on whichever `/dev/ttyUSB*` the FTDI at J7 enumerated as.

## Boot-mode caveats and restoring Ubuntu

Three ways to get into bare-metal/FreeRTOS with Ubuntu installed on SD:

1. **Hot takeover** (cable plugged in while Ubuntu is running):
   `xsct load.tcl` does `rst -system` which yanks Linux mid-execution. May
   leave the GIC in an odd state with FreeRTOS — if you see flaky IRQs,
   try option 2.
2. **DIP-switch JTAG boot**: power off, flip the boot-mode DIPs to all-off
   (JTAG), power on. Board sits idle waiting for JTAG, no PS init has
   happened yet, `psu_init` runs against a virgin PS. Cleanest state.
3. **Software boot-mode override**: `xsct` then `source ../../vitis/boot_jtag.tcl; boot_jtag`
   — writes the boot-mode register so the next reset comes up in JTAG mode
   without touching DIPs.

To return to Ubuntu: **power-cycle the board**. The boot-mode register is
re-read from the DIPs at every cold reset. SD card is untouched.

After Ubuntu boots back up, run `sudo xmutil unloadapp 2>/dev/null; sudo xmutil loadapp kr260_hw`
to resync `dfx-mgr` with the PL state.

## Differences vs. apps/kr260_hw_bm

- **BSP**: FreeRTOS (`freertos10_xilinx`) instead of standalone.
- **Address map**: this file targets the current LPD aperture
  (`0x8000_0000+`); `kr260_hw_bm/main.c` still uses the pre-extend_design
  FPD addresses (`0xA000_0000+`) and will not work against the current
  XSA without an update.
- **build.tcl** always re-imports `main.c` (no create-only guard footgun).
- **main.c** wraps the test sequence in an `xTaskCreate`'d task and
  starts the scheduler. DMA buffers stay in `.bss` so they don't blow
  the task stack.
