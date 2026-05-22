# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Vivado 2024.1 hardware project** for the **Xilinx KR260 Robotics Starter Kit** (Zynq UltraScale+, part `xck26-sfvc784-2LV-c`, board `xilinx.com:kr260_som:part0:1.1`), packaged as a **Kria runtime app** so it loads on a running Ubuntu (or PetaLinux) board via `xmutil loadapp` — no SD reflash. The hardware deliverable is `vivado/kr260_hw.xsa`; the runtime deliverable is `kria_app/build/kr260_hw/`.

The design exposes three things to PS userspace via UIO at `0x8000_0000+`:
- A 64-bit `my_state` accumulator driven by 3× single-channel AXI GPIO.
- A 32-bit AXI-Lite FIFO (`simple_fifo`) with internal push/pop echo.
- An AXI DMA loopback (DDR → MM2S → AXIS FIFO → S2MM → DDR).

**Control plane** routes via `M_AXI_HPM0_LPD`. **Data plane** (DMA → DDR) routes via `S_AXI_HPC0_FPD` with `PSU__AFI0_COHERENCY=1` (snooped). This split is load-bearing — see "Critical gotcha" below.

This is a separate project from the `arty_*` and `fpganow` trees in `/home/john/work/`. Same toolchain (2024.1), but KR260 is `cortexa72` (UltraScale+, ARMv8), not the Zynq-7000 / `cortexa9` of the Arty boards — sysroots and bitstream formats are not interchangeable.

## Repo layout

```
vivado/kr260_hw.tcl         # Vivado project-recreation script — base BD (machine-generated)
vivado/extend_design.tcl    # hand-written delta: switches to HPM0_LPD, adds FIFO + DMA
vivado/build.tcl            # batch-mode driver: sources both above, runs synth/impl/XSA
vivado/Makefile             # invokes Vivado in batch mode
vivado/ip/my_state.v        # 64-bit accumulator (module-ref'd into the BD)
vivado/ip/simple_fifo.v     # custom Verilog AXI4-Lite FIFO (256×32, push@+0 W / pop@+0 R)
vivado/constraints/cons.xdc # fan-EN pin (A12)
vivado/kr260_hw.xsa         # exported hardware handoff (consumed by kria_app/)
vivado/kr260_starter_kit.tcl # reference design (Xilinx) — not built; used for comparison

kria_app/                   # packages vivado/kr260_hw.xsa as a Kria runtime app
kria_app/kr260_hw.dtso      # device-tree overlay — defines the UIO nodes at 0x8000_0000+

apps/kr260_hw_test/         # userspace UIO test (cross-compiled, runs under Ubuntu)
apps/kr260_hw_bm/           # bare-metal JTAG test (Vitis xsct, standalone BSP)
apps/kr260_hw_rtos/         # FreeRTOS JTAG test (Vitis xsct, freertos10_xilinx BSP)

vitis/boot_jtag.tcl         # xsct helper to flip the board into JTAG boot mode
scripts/                    # helper shell scripts that run on the KR260
Makefile                    # top-level: ships scripts/ to the board over ssh
README.md                   # step-by-step rebuild & deploy walkthrough (UI + CLI flows)
bug.txt                     # write-up of the AXI GPIO v2.0 dual-channel synth bug
```

There are no checked-in HDL sources for the BD itself and no `vivado/kr260_hw/` project directory in git — `kr260_hw.tcl` + `extend_design.tcl` regenerate everything.

## Two-stage Tcl: `kr260_hw.tcl` + `extend_design.tcl`

This is the most important workflow fact: the BD is produced by **two scripts in order**.

1. **`kr260_hw.tcl`** is the output of Vivado's `write_project_tcl` — it's **machine-generated** and builds the *base* BD (PS + 3× AXI GPIO + `my_state_0` + xlslice). Hand-edits survive but are easy to clobber on the next export.
2. **`extend_design.tcl`** is **hand-written**. It re-opens the saved BD and *mutates* it: switches the PS control master from `M_AXI_HPM0_FPD` to `M_AXI_HPM0_LPD`, enables `S_AXI_HPC0_FPD` with AFI coherency, grows the AXI interconnect (1 SI / 5 MI), adds `simple_fifo_0`, `axi_dma_0`, `axis_data_fifo`, and `axi_smc_dma`, reassigns every PL IP into the `0x8000_0000+` LPD aperture, validates, regenerates the wrapper.

**Both scripts are sourced in order** by `vivado/build.tcl`. If you do anything that re-runs `write_project_tcl`, don't let it eat `extend_design.tcl` — that's the file that captures every BD decision worth keeping.

Practical patterns:
- **Add/change something in the GUI** — re-export `kr260_hw.tcl` with `write_project_tcl -force ../kr260_hw.tcl` (run from the project dir). Then re-apply your change as Tcl in `extend_design.tcl` so it survives the next regen. Don't merge regenerated layout strings by hand.
- **Manual Tcl shell repro** — `cd vivado && vivado &`, then in the Tcl Console: `source kr260_hw.tcl; source extend_design.tcl`.

The constraint path embedded in `kr260_hw.tcl` is `$origin_dir/constraints/cons.xdc` — keep `cons.xdc` at `vivado/constraints/cons.xdc` or the script's `checkRequiredFiles` proc refuses to bootstrap.

## Block design summary (`design_1`)

PL clock is `pl_clk0` (~99.999 MHz). Reset is `rst_ps8_0_99M` driven by `pl_resetn0`.

| IP | Address | Role |
|---|---|---|
| `axi_gpio_control` | `0x8000_0000` | 2-bit output → `my_state_0/control` (1=add edge-trig, 2=reset) |
| `axi_gpio_value`   | `0x8001_0000` | 32-bit input ×2 ← accumulator (ch1=`[31:0]`, ch2=`[63:32]`) |
| `axi_gpio_addend`  | `0x8002_0000` | 32-bit output → `my_state_0/value` (the addend) |
| `axi_fifo_0`       | `0x8003_0000` | `simple_fifo` — push at +0 (W), pop at +0 (R) |
| `axi_dma_0`        | `0x8004_0000` | S_AXI_LITE control; M_AXI MM2S/S2MM → HPC0_FPD via `axi_smc_dma` |

- `my_state_0` (module-ref of `vivado/ip/my_state.v`): 64-bit accumulator. `control` opcode 1 (rising edge from 0) adds `value` once; opcode 2 resets to zero. Outputs split into `sum`/`carry` consumed by `axi_gpio_value` ch1/ch2.
- `axis_data_fifo` sits between `axi_dma_0/M_AXIS_MM2S` and `axi_dma_0/S_AXIS_S2MM` — PL-internal loopback for the DMA echo test.
- `axi_smc_dma` is an `axi_interconnect:2.1` (not smartconnect — see `extend_design.tcl` for why) routing both DMA M_AXI ports into `S_AXI_HPC0_FPD`.
- `xlslice_0` picks bit `[2]` of `emio_ttc0_wave_o` → `fan_en_b` (pin A12, see `cons.xdc`).

`scripts/gpio.sh` is a `devmem`-only smoke test for just the accumulator path; `apps/kr260_hw_test` is the full UIO-based test (GPIO + FIFO + DMA).

## Critical gotcha: AXI GPIO v2.0 dual-channel is broken

**Don't try to "consolidate" the three single-channel GPIOs into dual-channel.** `xilinx.com:ip:axi_gpio:2.0` with `C_IS_DUAL=1` + both channels `C_ALL_OUTPUTS{,_2}=1` silently drops AXI writes to the second channel's `GPIO2_DATA` register: `BRESP=OKAY`, readback `0x0`, outputs stay at the synth default. Channel 1 works under identical config. Synth log fingerprint is `WARNING: [Synth 8-6014] Unused sequential element Dual.ALLOUT1_ND_G2.READ_REG2_GEN[*].GPIO2_DBus_i_reg was removed` for every bit of the channel-2 width.

The workaround applied here is to use **three separate single-channel `axi_gpio:2.0` instances** (`axi_gpio_control`, `axi_gpio_addend`, `axi_gpio_value`). The single-channel path doesn't enter the `Dual.*` generate hierarchy, so the trimming heuristic never fires.

Full write-up with reproduction details: `bug.txt`. If anyone proposes going back to dual-channel, point them at it first.

## Critical gotcha: DMA hangs if control plane is on HPM0_FPD

This design **specifically routes PS-PL control via `M_AXI_HPM0_LPD`** (not the default HPM0_FPD), and DMA data via `S_AXI_HPC0_FPD`. If control regresses to FPD, `axi_dma` reads `SR=0` forever after the test asserts `RS=1` — fabric contention between control writes and data transactions deadlocks at the FPD switch. `extend_design.tcl` actively disconnects both `M_AXI_HPMx_FPD` nets, disables `PSU__USE__M_AXI_GP0/GP1`, enables `PSU__USE__M_AXI_GP2` (the LPD master), and reduces the interconnect to a single SI on HPM0_LPD.

If you regenerate the BD and DMA hangs, this is the first thing to re-check. `apps/kr260_hw_rtos/` (or `apps/kr260_hw_bm/` once its addresses are updated — see "Bare-metal alternative" below) is the diagnostic tool: if DMA passes there but hangs under Linux, the bitstream is fine and dfx-mgr's PS init is missing something (AFI / HP fabric-port enable).

## Building the XSA

```bash
cd vivado
make            # → ./kr260_hw.xsa, project at ./kr260_hw/  (~25–35 min)
make clean
```

`vivado/Makefile` sources `/tools/Xilinx/Vivado/2024.1/settings64.sh` (override with `VIVADO_SETTINGS=…`), runs `vivado -mode batch -source build.tcl`, and writes the XSA via `write_hw_platform -fixed -include_bit -force kr260_hw.xsa`. `build.tcl` stubs `APPDATA` (harmless on Linux), sources `kr260_hw.tcl` then `extend_design.tcl`, and forces `general.maxThreads 1` (Vivado's `parallel_synth_helper` deadlocks at 0% CPU on memory-constrained hosts; serialising costs a few minutes but is reliable).

`JOBS` defaults to 1 — running this design with `JOBS=4` triggers the OOM killer on a 16 GiB host with no swap. Bump only after watching `free -h` during a build.

## Packaging as a Kria runtime app (`kria_app/`)

Wraps `vivado/kr260_hw.xsa` so `dfx-mgr` / `xmutil` can program the PL at runtime — no SD-card rewrite. Works on stock Kria firmware.

```bash
cd kria_app
make            # → build/kr260_hw/{kr260_hw.bit.bin, kr260_hw.dtbo, shell.json}
make deploy     # package + scp build/kr260_hw to ubuntu@kr260u:~/
make clean
```

What the Makefile does:
1. `unzip -p ../vivado/kr260_hw.xsa kr260_hw.bit` → raw `.bit`.
2. `bootgen -arch zynqmp -process_bitstream bin` → `.bit.bin` (the format `fpga_manager` needs).
3. `dtc -@ kr260_hw.dtso` → `.dtbo`. The overlay declares each PL IP as `compatible = "generic-uio"`, and the DMA node has `dma-coherent` (required for `PSU__AFI0_COHERENCY=1`).

Both `bootgen` and `dtc` come from the PetaLinux toolchain. Override with `PETALINUX_SETTINGS=…` (default `/tools/Xilinx/PetaLinux/2024.1/settings.sh`).

The dtso is hand-edited to match the BD's address map. If you move any IP's address in `extend_design.tcl`, update `kria_app/kr260_hw.dtso` in lockstep — `xmutil loadapp` will succeed even when addresses mismatch, and you'll see `NO UIO at 0x800X_0000` style failures from `kr260_hw_test`.

Loading on the KR260 (after `make deploy`):
```bash
ssh ubuntu@kr260u
sudo rm -rf /lib/firmware/xilinx/kr260_hw
sudo mv ~/kr260_hw /lib/firmware/xilinx/
sudo xmutil unloadapp                           # drop whatever's active
sudo xmutil loadapp kr260_hw
cat /sys/class/fpga_manager/fpga0/state         # → "operating"
for u in /sys/class/uio/uio*; do echo "$(basename $u): $(cat $u/name) @ $(cat $u/maps/map0/addr)"; done
echo 8 | sudo tee /proc/sys/vm/nr_hugepages     # required before running the DMA test
```

Because the IPs now sit at `0x8000_0000+` (LPD aperture), the old `0xA000_0000` factory-stub address conflict (`gpio@a0000000`, `i2c@a0010000` under `/amba_pl@0/`) doesn't apply to this design. If you ever move IPs back into the FPD aperture, see `kria_app/INSTALL.md` "Address conflict".

## Userspace test (`apps/kr260_hw_test/`)

Single C source that exercises all three subsystems via `/dev/uio*` mmap. Uses only stdlib + standard Linux syscalls — no Xilinx sysroot needed. Default toolchain is Ubuntu's `gcc-aarch64-linux-gnu` package:

```bash
sudo apt install gcc-aarch64-linux-gnu         # one-time
cd apps/kr260_hw_test
make                                           # → kr260_hw_test (aarch64)
make deploy                                    # → ubuntu@kr260u:/tmp/
make run                                       # deploy + ssh + sudo run
```

The prebuilt `apps/kr260_hw_test/kr260_hw_test` is checked in and matches the in-tree `main.c`. Rebuild only when `main.c` changes. The binary needs `sudo` on the board (UIO mmap + hugepages).

To use a different toolchain (e.g. the PetaLinux SDK's `aarch64-xilinx-linux-gcc`), override `CC=…` on the make command line.

## JTAG alternatives (`apps/kr260_hw_bm/`, `apps/kr260_hw_rtos/`)

Two Vitis Classic apps that run the same three exercises directly on Cortex-A53 #0 via JTAG, bypassing Linux and `dfx-mgr` entirely. Used as a "is the bitstream good?" diagnostic when the userspace test hangs. Both follow the same xsct flow:

```bash
source /tools/Xilinx/Vitis/2024.1/settings64.sh
cd apps/kr260_hw_{bm,rtos}
xsct build.tcl                                 # builds ELF + FSBL + platform
xsct load.tcl                                  # connects JTAG, programs PL, runs ELF
```

UART: 115200 8N1 on the FTDI at J7. Requires `vivado/kr260_hw.xsa` to exist.

- **`kr260_hw_bm/`** — standalone BSP (`-os standalone`). **Note: its `main.c` still uses the pre-`extend_design.tcl` FPD addresses (`0xA000_0000+`) and will not work against the current XSA until updated to `0x8000_0000+`.** Also has an `importsources`-inside-create-guard footgun: edits to `main.c` silently don't rebuild on subsequent `xsct build.tcl` runs unless you nuke `vitis_ws/` first.
- **`kr260_hw_rtos/`** — FreeRTOS BSP (`-os freertos10_xilinx`). Same three exercises wrapped in one `xTaskCreate`'d task, then `vTaskStartScheduler()`. **Address map is up to date (`0x8000_0000+`)** and `build.tcl` re-imports `main.c` on every run. This is the working JTAG diagnostic until `kr260_hw_bm` is brought current.

### Boot-mode options and restoring Ubuntu

With Ubuntu installed on SD, three ways to enter JTAG mode:

1. **Hot takeover** — leave QSPI boot DIP, run `xsct load.tcl` while Ubuntu is running. `rst -system` yanks the kernel mid-execution and Vitis takes over. Easiest, but FreeRTOS can occasionally see flaky GIC state on first takeover (standalone is more forgiving).
2. **DIP-switch JTAG boot** — power off, flip boot-mode DIPs to all-off, power on. Board sits idle waiting for JTAG. Cleanest state; required for `psu_init` to run against a virgin PS.
3. **Software boot-mode override** — `xsct` then `source vitis/boot_jtag.tcl; boot_jtag` writes the boot-mode register so the next `rst -system` comes up in JTAG mode without touching DIPs.

To restore Ubuntu: **power-cycle the board**. The boot-mode register reloads from the DIPs at every cold reset; SD card is untouched. After Ubuntu boots back up, run `sudo xmutil unloadapp 2>/dev/null; sudo xmutil loadapp kr260_hw` to resync `dfx-mgr` with the PL state.

## Top-level `Makefile` and `scripts/`

The repo-root `Makefile` is for **interacting with the running board**, not building. It assumes ssh to `ubuntu@kr260u` is set up. Set up passwordless sudo on the board first (one-liner in `README.md` "One-time host setup").

- `make` (default `info`) — scps `list_uio.sh` to `~/` on the board and runs it. Prints SoC temps and the `/sys/class/uio/uio*` table.
- `make deploy` — scps all of `scripts/` to `~/` on the board.

`scripts/` contents:
- `list_uio.sh` — temps + UIO listing.
- `mod_probe.sh` — rebinds the generic UIO driver: `modprobe -r uio_pdrv_genirq; modprobe uio_pdrv_genirq of_id=generic-uio`. Run after a fresh `loadapp` if `/dev/uioN` doesn't appear.
- `load_app.sh`, `list_apps.sh` — thin wrappers around `xmutil`.
- `update_app.sh` — moves a freshly scp'd `~/kr260_hw` into `/lib/firmware/xilinx/`.
- `gpio.sh` — `devmem`-only smoke test for the accumulator path. Addresses are `0x8000_0000` (control), `0x8001_0000` (value readback), `0x8002_0000` (addend) — matches the current LPD-aperture map. The old `0xA000_0000`/`0xA001_0000` variant in git history is **not** valid against the current bitstream.
