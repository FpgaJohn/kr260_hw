# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Vivado 2024.1 hardware project** for the **Xilinx KR260 Robotics Starter Kit** (Zynq UltraScale+, part `xck26-sfvc784-2LV-c`, board `xilinx.com:kr260_som:part0:1.1`), plus the packaging and deploy glue to load it on the running board as a **Kria runtime app** (no reflash). The hardware deliverable is `design_1_wrapper.xsa`; the runtime deliverable is the `kria_app/build/kr260_hw/` package consumed by `xmutil loadapp`.

This is a separate project from the `arty_*` and `fpganow` trees in `/home/john/work/`. Same toolchain version (2024.1), but the KR260 is `cortexa72` (UltraScale+, ARMv8), not the Zynq-7000 / `cortexa9` of the Arty boards — sysroots and bitstream formats are not interchangeable.

## Repo layout

```
vivado/kr260_hw.tcl       # Vivado project-recreation script — source of truth for the BD
vivado/kr260_hw.xsa       # exported hardware handoff (consumed by kria_app/)
vivado/constraints/cons.xdc
kria_app/                 # packages vivado/kr260_hw.xsa as a Kria runtime app
scripts/                  # helper shell scripts that run on the KR260
Makefile                  # top-level: ships scripts/ to the board over ssh
vitis.freertos/           # Vitis XSCT workspace — bare-metal and FreeRTOS apps
kria_app_eth/             # OUT OF SCOPE here — separate, larger design (its own XSA, FIFOs/DMAs/my_state)
```

There are no checked-in HDL sources and no `vivado/kr260_hw/` project directory in git — `vivado/kr260_hw.tcl` regenerates everything. The block design lives inline in the script (proc `cr_bd_design_1`, around line 225+).

`kria_app_eth/` is unrelated to the BD in `vivado/kr260_hw.tcl`; do **not** mix its address map, dtso, or `gpio.sh`-style scripts into work on `kr260_hw`.

## Recreating the Vivado project

```bash
# In the Vivado 2024.1 Tcl shell, from the vivado/ directory:
source kr260_hw.tcl
```

The script will:
1. Create `vivado/kr260_hw/kr260_hw.xpr`
2. Build block design `design_1` (PS + 3× AXI GPIO + AXI Stream FIFO + AXI DMA + xlslice for fan EN)
3. Generate `design_1_wrapper.v`, add `vivado/constraints/cons.xdc`
4. Define `synth_1` and `impl_1` runs (Vivado defaults). It does **not** auto-launch them.

Re-export the XSA with `write_hw_platform -fixed -include_bit -force kr260_hw.xsa` after `impl_1` + `write_bitstream` (output lands in `vivado/`).

## Block design summary (`design_1`)

A PS + my_state accumulator + AXI Stream FIFO loopback + AXI DMA loopback design:

- **`zynq_ultra_ps_e_0`** — Zynq UltraScale+ PS (v3.5). Masters: `M_AXI_HPM0_FPD`, `M_AXI_HPM1_FPD`. Slaves: `S_AXI_HP0_FPD` (DMA MM2S), `S_AXI_HP1_FPD` (DMA S2MM). `pl_clk0` clocks the AXI fabric; `emio_ttc0_wave_o[2]` drives the fan.
- **`ps8_0_axi_periph`** — `axi_interconnect` (2 SI, 5 MI). Both PS HPM masters fan into the five peripheral slaves.
- **`axi_gpio_control`** @ `0xA000_0000` — single-channel, output only. 2-bit `gpio_io_o` drives `my_state_0/control` (opcode: 0=noop, 1=add, 2=reset).
- **`axi_gpio_value`** @ `0xA001_0000` — dual-channel, both input. ch1 (32-bit) reads `my_state_0/sum`; ch2 (32-bit) reads `my_state_0/carry`.
- **`axi_fifo_mm_s_0`** @ `0xA002_0000` — `axi_fifo_mm_s` v4.2 (AXI4-Stream FIFO). 64-bit stream, store-and-forward, no TX control signals. TX stream (`AXI_STR_TXD`) wired directly to RX stream (`AXI_STR_RXD`) for loopback. Software writes data via AXI4-Lite registers, reads it back from the RX FIFO.
- **`axi_gpio_addend`** @ `0xA004_0000` — single-channel, output only. 32-bit `gpio_io_o` drives `my_state_0/value` (the addend). Split out from `axi_gpio_control` to avoid the dual-channel write-latch synthesis bug.
- **`axi_dma_0`** @ `0xA005_0000` — `axi_dma` v7.1. No scatter-gather, 64-bit. MM2S sends DDR→stream via `M_AXI_MM2S`/`HP0_FPD`; S2MM receives stream→DDR via `M_AXI_S2MM`/`HP1_FPD`. DMA address spaces mapped to DDR_LOW (0x0000_0000, 2 GB).
- **`axis_data_fifo_0`** — `axis_data_fifo` v2.0. 64-bit, bridges `axi_dma_0/M_AXIS_MM2S` → `axi_dma_0/S_AXIS_S2MM` (stream loopback for DMA).
- **`my_state_0`** — module-reference of `vivado/ip/my_state.v`. 64-bit accumulator: opcode 1 (edge) adds `value`; opcode 2 resets. Outputs split into `sum`/`carry`.
- **`xlslice_0`** — picks bit `[2]` of `emio_ttc0_wave_o` → `fan_en_b` (pin A12, see `cons.xdc`).
- **`rst_ps8_0_99M`** — `proc_sys_reset` driven by `pl_resetn0`.

Address map:

| Block | Address | Width | Direction |
|---|---|---|---|
| `axi_gpio_control` | `0xA000_0000` | 16 KB | out — 2-bit opcode |
| `axi_gpio_value` | `0xA001_0000` | 16 KB | in — sum (ch1) + carry (ch2) |
| `axi_fifo_mm_s_0` | `0xA002_0000` | 16 KB | RW — AXI4-Stream FIFO control/data |
| `axi_gpio_addend` | `0xA004_0000` | 16 KB | out — 32-bit addend |
| `axi_dma_0` | `0xA005_0000` | 16 KB | RW — DMA control registers |

A known-good runtime smoke test for the GPIO/my_state part lives at `scripts/gpio.sh`. **Note:** `gpio.sh` currently uses the old address layout (addend at `0xA000_0008`); needs updating to write the addend to `0xA004_0000` instead. The FIFO and DMA tests are exercised by the Vitis bare-metal and FreeRTOS apps.

If you change the BD, regenerate the XSA (see "Building the XSA" below) and re-export the script with `write_project_tcl -force ../kr260_hw.tcl` (run from the project dir) so the repo stays self-bootstrapping.

## Building the XSA

```bash
cd vivado
make SHELL=/bin/bash JOBS=1   # → ./kr260_hw.xsa, project at ./kr260_hw/
make clean
```

**Linux / WSL2 note:** `make` defaults to `/bin/sh`, but `settings64.sh` uses the `source` builtin (bash-only). Without `SHELL=/bin/bash` you get `/bin/sh: source: not found` and the build aborts immediately. Always pass `SHELL=/bin/bash` on Linux or WSL2.

The Makefile sources `/tools/Xilinx/Vivado/2024.1/settings64.sh` (override with `VIVADO_SETTINGS=…`), runs `vivado -mode batch -source build.tcl`, and writes the XSA via `write_hw_platform -fixed -include_bit -force kr260_hw.xsa`. `build.tcl` stubs `APPDATA` (the script tries to use it, harmless on Linux) and forces `general.maxThreads 1` (Vivado's `parallel_synth_helper` deadlocks at 0% CPU on memory-constrained boxes; serialising costs a few minutes but is reliable).

`JOBS` defaults to 1 — running this design with `JOBS=4` triggers the OOM killer on a 16 GiB host with no swap. Bump only after watching `free -h` during a build.

`kria_app/Makefile` extracts the bitstream from `../vivado/kr260_hw.xsa`.

## Editing `vivado/kr260_hw.tcl` directly

The Tcl is **machine-generated** by `write_project_tcl`. Hand-edits survive but are easy to clobber on the next export. Two practical patterns:

- **Tweak a parameter** (e.g., GPIO width, slice range) — fine to edit in place, but re-run `source kr260_hw.tcl` (from `vivado/`) in a fresh project to confirm it still bootstraps cleanly.
- **Add IP / nets** — prefer doing it in the Vivado GUI, then re-run `write_project_tcl -force ../kr260_hw.tcl` (from the project dir) and commit the diff. Don't merge the regenerated layout-string section by hand.

The constraint file path embedded in the script is `$origin_dir/constraints/cons.xdc` — keep `cons.xdc` at `vivado/constraints/cons.xdc` or the script's `checkRequiredFiles` proc will refuse to bootstrap.

## Packaging as a Kria runtime app (`kria_app/`)

Wraps `vivado/kr260_hw.xsa` so `dfx-mgr` / `xmutil` can program the PL at runtime — no SD-card rewrite. Works on stock Kria firmware.

```bash
cd kria_app
make            # → build/kr260_hw/{kr260_hw.bit.bin, kr260_hw.dtbo, shell.json}
make deploy     # package + scp build/kr260_hw to ubuntu@kr260u:~/
make clean
```

What the Makefile does:
1. `unzip -p ../vivado/kr260_hw.xsa kr260_hw.bit` → raw `.bit`
2. `bootgen -arch zynqmp -process_bitstream bin` → `.bit.bin` (the format `fpga_manager` needs)
3. `dtc -@` → `.dtbo` from `kr260_hw.dtso`

Both `bootgen` and `dtc` come from the PetaLinux toolchain. Override the path via `PETALINUX_SETTINGS=…` (default `/tools/Xilinx/PetaLinux/2024.1/settings.sh`).

Loading on the KR260:
```bash
sudo mv ~/kr260_hw /lib/firmware/xilinx/        # where dfx-mgr looks
sudo xmutil listapps                            # confirm "kr260_hw" appears (Inactive)
sudo xmutil unloadapp                           # drop whatever's active (factory app)
sudo xmutil loadapp kr260_hw
cat /sys/class/fpga_manager/fpga0/state         # → "operating"
gpiodetect                                      # two new gpiochips appear
```

### Known address conflict

The overlay places GPIOs at `0xA000_0000`, `0xA001_0000`, and `0xA004_0000`. The first two collide with factory base-DT stub nodes (`gpio@a0000000`, `i2c@a0010000` under `/amba_pl@0/`). If `xmutil loadapp` rolls back with `sysfs: cannot create duplicate filename …a0000000.gpio` in `dmesg`, see `kria_app/INSTALL.md` "Address conflict" — two escalating fixes:

1. Rename the unit-name in the dtso (cheap, sometimes enough — `compatible` still drives binding).
2. Switch the conflicting node to `compatible = "generic-uio"` and drive registers from userspace.

## Vitis XSCT workspace (`vitis.freertos/`)

Contains source-controllable scripts to regenerate the Vitis platform and build both a bare-metal and a FreeRTOS application targeting A53 core 0. Generated directories (`plat/`, `win_hw/`, `freertos_hw/`) are gitignored.

**Build order (Windows Command Prompt or WSL via `cmd.exe /C`):**
```bat
:: Build everything in one shot:
vitis.freertos\build_all.bat

:: Or step by step:
xsct.bat vitis.freertos\create_platform.tcl       :: one-time; creates plat/
xsct.bat vitis.freertos\create_baremetal_app.tcl  :: builds win_hw/Debug/win_hw.elf
xsct.bat vitis.freertos\create_freertos_app.tcl   :: builds freertos_hw/Debug/freertos_hw.elf
xsct.bat vitis.freertos\rebuild_platform.tcl      :: recompile all BSPs (needed after create_freertos_app to install FreeRTOS headers for the IDE)
```

**Run on hardware (JTAG cable required):**
```bat
xsct.bat vitis.freertos\run_baremetal.tcl
xsct.bat vitis.freertos\run_freertos.tcl
```

Both run scripts boot JTAG mode, program the PL, run FSBL, then load and run the ELF on A53 core 0. Test output goes to UART0 at 115200 8N1.

**Source files** (tracked in git, copied into the app during build):
- `vitis.freertos/src/baremetal_main.c` — bare-metal GPIO + my_state test, AXI Stream FIFO loopback test, AXI DMA loopback test
- `vitis.freertos/src/freertos_main.c` — same three tests under FreeRTOS (single task with `vTaskDelay` between poll loops)

**AXI Stream FIFO test** (`axi_fifo_mm_s_0` @ `0xA002_0000`): writes two 64-bit words via TDFD/TDFD_U registers, triggers TX with TLR, polls RDFO for RX data, reads back and compares via RDFD/RDFD_U. Verifies store-and-forward loopback at register level.

**AXI DMA test** (`axi_dma_0` @ `0xA005_0000`): fills a 64-byte src buffer, flushes data cache, starts S2MM then MM2S, polls DMASR for Idle, invalidates dst cache, compares dst to src. Exercises the full DDR→stream→DDR path via HP0/HP1 ports.

**Known XSCT quirk:** each `xsct` invocation is a fresh process. App-create scripts call `repo -add "$script_dir/plat/export"` so the platform is findable by name — do not remove this line.

## Top-level `Makefile` and `scripts/`

The repo-root `Makefile` is for **interacting with the running board**, not for building. It assumes ssh to `ubuntu@kr260u` is set up.

- `make` (default `info`) — scp's `list_uio.sh` to `~/` on the board and runs it. Prints SoC temperatures and the `/sys/class/uio/uio*` table (UIO index → name → AXI address).
- `make deploy` — scp's all of `scripts/` to `~/` on the board.

`scripts/` contents:
- `list_uio.sh` — temps + UIO listing (read-only inspection).
- `mod_probe.sh` — rebinds the generic UIO driver: `modprobe -r uio_pdrv_genirq; modprobe uio_pdrv_genirq of_id=generic-uio`. Run after a fresh `loadapp` if your nodes set `compatible = "generic-uio"` but `/dev/uioN` doesn't appear.
- `load_app.sh` — wrapper around `xmutil listapps`.
- `gpio.sh` — drives the `my_state` accumulator from the PS via `devmem`. Run `sudo ./gpio.sh [ADDEND]` after `xmutil loadapp kr260_hw`. **Stale:** currently writes the addend to `0xA000_0008` (old dual-channel layout); needs updating to use `0xA004_0000` (`axi_gpio_addend`). **Not** valid against the `kria_app_eth` (`kr260_petalinux`) bitstream.
