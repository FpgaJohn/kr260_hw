# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Vivado 2024.1 hardware project** for the **Xilinx KR260 Robotics Starter Kit** (Zynq UltraScale+, part `xck26-sfvc784-2LV-c`, board `xilinx.com:kr260_som:part0:1.1`). The project produces a single deliverable — `design_1_wrapper.xsa` — which is intended to be consumed by a downstream PetaLinux / Vitis flow (not present in this repo).

This is a **separate project from the `arty_*` and `fpganow` trees** in `/home/john/work/`. The workspace-level `/home/john/work/CLAUDE.md` predates this repo and does not list it; do **not** assume cross-references with those projects. Same toolchain version (2024.1), but the KR260 is `cortexa72` (UltraScale+, ARMv8), not the Zynq-7000 / `cortexa9` of the Arty boards.

## Repo layout

```
kr260_hw.tcl              # project-recreation script — the source of truth
vivado/constraints/cons.xdc
design_1_wrapper.xsa      # exported hardware handoff
vivado/                   # generated project lives here after running the .tcl
```

There are **no checked-in HDL sources** and no `vivado/kr260_hw/` project directory in git. The Tcl script generates everything from scratch; the block design lives inline inside `kr260_hw.tcl` (proc `cr_bd_design_1`, around line 225+).

## Recreating the project in Vivado

```bash
# In the Vivado 2024.1 Tcl shell, from this directory:
source kr260_hw.tcl
```

The script will:
1. Create `vivado/kr260_hw/kr260_hw.xpr`
2. Build block design `design_1` (PS + 2× AXI GPIO + xlslice for fan EN)
3. Generate `design_1_wrapper.v`, add `vivado/constraints/cons.xdc`
4. Define `synth_1` and `impl_1` runs (Vivado defaults). It does **not** auto-launch them.

Re-export the XSA with `write_hw_platform -fixed -include_bit -force design_1_wrapper.xsa` after `impl_1` + `write_bitstream`.

## Block design summary (`design_1`)

A minimal "hello PS+PL" design — useful to know before editing `kr260_hw.tcl`:

- **`zynq_ultra_ps_e_0`** — Zynq UltraScale+ PS (v3.5). Exposes `M_AXI_HPM0_FPD` and `M_AXI_HPM1_FPD`. `pl_clk0` clocks the AXI fabric; `emio_ttc0_wave_o[2]` drives the fan.
- **`ps8_0_axi_periph`** — `axi_interconnect` (2 SI, 2 MI). Both PS HPM masters fan into the two AXI GPIO blocks.
- **`axi_gpio_0`** @ `0xA000_0000` — drives `som240_1_connector_User_led` (GPIO) and `som240_1_connector_gem2_led` (GPIO2).
- **`axi_gpio_1`** @ `0xA001_0000` — drives `som240_2_connector_gem3_led`.
- **`xlslice_0`** — picks bit `[2]` of `emio_ttc0_wave_o` → `fan_en_b` (pin A12, see `cons.xdc`).
- **`rst_ps8_0_99M`** — `proc_sys_reset` driven by `pl_resetn0`.

If you change the BD, regenerate the XSA and re-export the script with `write_project_tcl -force kr260_hw.tcl` so the repo stays self-bootstrapping.

## Editing `kr260_hw.tcl` directly

The Tcl is **machine-generated** by `write_project_tcl`. Hand-edits survive but are easy to clobber on the next export. Two practical patterns:

- **Tweak a parameter** (e.g., GPIO width, slice range) — fine to edit in place, but re-run `source kr260_hw.tcl` in a fresh project to confirm it still bootstraps cleanly.
- **Add IP / nets** — prefer doing it in the Vivado GUI, then re-run `write_project_tcl -force kr260_hw.tcl` and commit the diff. Don't merge the regenerated layout-string section by hand.

The constraint file path embedded in the script is `$origin_dir/vivado/constraints/cons.xdc` — keep `cons.xdc` at that location or the script's `checkRequiredFiles` proc will refuse to bootstrap.
