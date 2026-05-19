# kr260_hw_bm — bare-metal test

Single-file bare-metal app to exercise the kr260_hw bitstream:

1. **GPIO accumulator** — `axi_gpio_control` / `axi_gpio_addend` / `axi_gpio_value` driving `my_state`.
2. **simple_fifo** — push/pop the custom Verilog FIFO at `0xA0050000`.
3. **AXI DMA echo** — mem → `axi_dma_0/MM2S` → `axis_data_fifo` → `axi_dma_0/S2MM` → mem.

Target: KR260 SOM, ZynqMP ZU5EV, Cortex-A53 #0 (psu_cortexa53_0).

## Build

```bash
source /tools/Xilinx/Vitis/2024.1/settings64.sh
cd apps/kr260_hw_bm
xsct build.tcl
```

Produces `vitis_ws/kr260_hw_bm/Debug/kr260_hw_bm.elf` plus the platform and
FSBL Vitis needs at JTAG-load time.

Prerequisite: `vivado/kr260_hw.xsa` must exist — run `make` in `vivado/` first.

## Run via JTAG

```bash
xsct load.tcl
```

`load.tcl` does:

1. `connect` to the JTAG cable
2. `rst -system` (clean slate)
3. `fpga <bit>` (program the PL — fresh, not what dfx-mgr loaded)
4. `source psu_init.tcl; psu_init` (configure PS DDR, MIO, AFI, clocks —
   this is what dfx-mgr does NOT do at runtime, and is the prime suspect
   for the HP0 hang seen under Linux)
5. `rst -processor` on Cortex-A53 #0
6. `dow <elf>; con` — download and run

UART output: 115200 8N1 on whichever `/dev/ttyUSB*` the FTDI on the
KR260's J7 enumerated as.

Boot mode: leave QSPI as default — the JTAG load overrides what's running.
If you want the board to come up empty (no Ubuntu running), switch the
boot-mode DIP switches to all-off (JTAG mode).

## What we're hoping to learn

The exact same bitstream that hangs under Linux/dfx-mgr should run fine
here. If DMA passes bare-metal:

- **The bitstream is fine.** The DMA hang under Linux is caused by something
  dfx-mgr (or the running Ubuntu kernel) doesn't set up that bare-metal does
  — almost certainly the FPD AFI registers / HP0 fabric-port enable in
  `psu_init`.

If DMA fails bare-metal too:

- The issue is in the bitstream/IP. Next step would be ChipScope ILA on the
  DMA's M_AXI port to see whether transactions even leave the IP.

Either outcome dramatically narrows the search.
