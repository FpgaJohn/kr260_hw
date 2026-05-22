# Kr260 HW

A Vivado 2024.1 block design for the Xilinx KR260 Robotics Starter Kit
(Zynq UltraScale+, `xck26-sfvc784-2LV-c`) plus a Kria runtime app that
deploys it to a running Ubuntu (or PetaLinux) board via `xmutil loadapp` —
no reflash required.

The design exposes three things to PS userspace via UIO:
- A 64-bit `my_state` accumulator driven by 3× AXI GPIO
- A 32-bit AXI-Lite FIFO with internal push/pop echo
- An AXI DMA loopback (mem → MM2S → AXIS FIFO → S2MM → mem)

Control plane routes via `M_AXI_HPM0_LPD`; data plane via
`S_AXI_HPC0_FPD`. PL IPs live in the LPD aperture (`0x80000000+`).

## One-time host setup

Make passwordless `sudo` available on the board so the deploy step can
write `/lib/firmware/xilinx/`:

```sh
ssh -t ubuntu@kr260u '
    echo "ubuntu ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-ubuntu-nopasswd > /dev/null
    sudo chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd
    sudo visudo -cf /etc/sudoers.d/90-ubuntu-nopasswd && echo OK || sudo rm -f /etc/sudoers.d/90-ubuntu-nopasswd
  '
```

You also need:
- Vivado 2024.1 at `/tools/Xilinx/Vivado/2024.1/`
- PetaLinux 2024.1 at `/tools/Xilinx/PetaLinux/2024.1/` (for `bootgen` + `dtc -@`)
- An aarch64 cross-compiler for rebuilding the userspace test binary. Ubuntu's `gcc-aarch64-linux-gnu` package (`sudo apt install gcc-aarch64-linux-gnu`) is the default and is all you need — `apps/kr260_hw_test/main.c` uses only stdlib + standard Linux syscalls, no Xilinx sysroot. The PetaLinux SDK works too if you already have one; pass `CC=aarch64-xilinx-linux-gcc` to make. The prebuilt binary at `apps/kr260_hw_test/kr260_hw_test` is already aarch64 and works as-is.

---

# Rebuilding the design (Vivado UI workflow)

Follow these steps when you want to inspect, modify, or re-export the
block design through the Vivado GUI.

## 1. Launch Vivado and recreate the project

```sh
source /tools/Xilinx/Vivado/2024.1/settings64.sh
cd /home/john/work/kr260_hw/vivado
vivado &
```

In Vivado's **Tcl Console** at the bottom of the window:

```tcl
cd /home/john/work/kr260_hw/vivado
source kr260_hw.tcl
source extend_design.tcl
```

`kr260_hw.tcl` creates the project at `vivado/kr260_hw/kr260_hw.xpr`,
imports `my_state.v`, builds the base block design (PS + 3× AXI GPIO +
`my_state_0`), and adds `constraints/cons.xdc`.

`extend_design.tcl` then:
- Switches the PS control master from HPM0_FPD to **HPM0_LPD**
- Enables S_AXI_HPC0_FPD on the PS with `PSU__AFI0_COHERENCY=1`
- Adds `simple_fifo_0`, `axi_dma_0`, and `axis_data_fifo`
- Routes DMA M_AXI through `axi_smc_dma` (`axi_interconnect:2.1`) into HPC0_FPD
- Reassigns every PL IP into the LPD aperture (`0x80000000`–`0x80040000`)
- Validates the BD and regenerates the wrapper

Watch the Tcl Console for `extend_design: done` and no `CRITICAL WARNING`
or `ERROR` lines.

## 2. Inspect the block design (optional)

In the **Flow Navigator** (left pane):
**IP INTEGRATOR → Open Block Design**

Confirm visually that:
- `zynq_ultra_ps_e_0/M_AXI_HPM0_LPD` is wired into `ps8_0_axi_periph/S00_AXI`
- `axi_dma_0/M_AXI_MM2S` and `M_AXI_S2MM` enter `axi_smc_dma`, whose `M00_AXI` lands on `zynq_ultra_ps_e_0/S_AXI_HPC0_FPD`
- `axis_data_fifo` sits between the DMA's `M_AXIS_MM2S` and `S_AXIS_S2MM`
- The Address Editor shows all 5 PL IPs at `0x80000000–0x80040000`

## 3. Run synth + impl + bitstream

**Flow Navigator → Synthesis → Run Synthesis**, accept the default run
options.

> On a memory-constrained host, set `Number of jobs = 1` in the Launch
> Runs dialog. The Tcl console should also report
> `set_param general.maxThreads 1` was applied by `build.tcl`; if you're
> running from the GUI, paste that line into the Tcl Console once before
> launching synth.

When synthesis completes (status `synth_design Complete`), Vivado prompts
to run implementation. Click **Run Implementation**.

After implementation completes, Vivado prompts to generate bitstream.
Click **Generate Bitstream**. Job count of 1 is again safer on a
memory-constrained host.

## 4. Export the XSA

**File → Export → Export Hardware…**

- Output: **Include bitstream** (radio button)
- Files: navigate to `/home/john/work/kr260_hw/vivado`
- XSA file name: `kr260_hw`
- Click **OK**

You should now have `vivado/kr260_hw.xsa` with the bitstream included.

---

# Packaging and running on the KR260

## 5. Build the Kria runtime app

```sh
cd /home/john/work/kr260_hw/kria_app
make clean
make
```

The Makefile sources `/tools/Xilinx/PetaLinux/2024.1/settings.sh`, then:
1. Extracts the bitstream from `../vivado/kr260_hw.xsa` (`unzip`)
2. Runs `bootgen -process_bitstream bin` to produce `kr260_hw.bit.bin`
   (the format `fpga_manager` accepts)
3. Compiles `kr260_hw.dtso` to `kr260_hw.dtbo` (`dtc -@`)
4. Copies `bit.bin`, `dtbo`, `shell.json` into `build/kr260_hw/`

Verify the package:

```sh
ls -la build/kr260_hw/
# kr260_hw.bit.bin   ~3.4 MB
# kr260_hw.dtbo      ~1.7 KB
# shell.json         55 B
```

## 6. Build the userspace test binary (optional)

The prebuilt binary at `apps/kr260_hw_test/kr260_hw_test` already
matches the in-tree source and is aarch64, so you only need to rebuild
this if you edited `main.c`:

```sh
sudo apt install gcc-aarch64-linux-gnu       # one-time, host side
cd /home/john/work/kr260_hw/apps/kr260_hw_test
make clean
make
file kr260_hw_test    # → ELF 64-bit LSB pie executable, ARM aarch64
```

To build with the PetaLinux SDK instead, pass `CC` on the make line:
`make CC=aarch64-xilinx-linux-gcc` (after sourcing the SDK env).

## 7. Deploy to the KR260

From the host:

```sh
cd /home/john/work/kr260_hw/kria_app
make deploy                                # scp build/kr260_hw to ~ on the board

scp /home/john/work/kr260_hw/apps/kr260_hw_test/kr260_hw_test \
    ubuntu@kr260u:/tmp/                    # the test binary
```

## 8. Install the app, load it, run the test

ssh into the board:

```sh
ssh ubuntu@kr260u
```

On the board:

```sh
# Install the firmware so dfx-mgr can find it
sudo rm -rf /lib/firmware/xilinx/kr260_hw
sudo mv ~/kr260_hw /lib/firmware/xilinx/

# Drop whatever is currently loaded, then load ours
sudo xmutil unloadapp                      # or: sudo xmutil unloadapp <name>
sudo xmutil loadapp kr260_hw

# Confirm the PL is configured
cat /sys/class/fpga_manager/fpga0/state    # → "operating"

# Confirm the 5 PL UIOs appeared at 0x80000000+
for u in /sys/class/uio/uio*; do
    echo "$(basename $u): $(cat $u/name) @ $(cat $u/maps/map0/addr)"
done

# Reserve one 2 MiB hugepage for the DMA test buffer
echo 8 | sudo tee /proc/sys/vm/nr_hugepages

# Run all three tests
sudo /tmp/kr260_hw_test
```

Expected output ends with:

```
  DMA echo: PASS (4096 bytes round-tripped)

=========================================
Accumulator + FIFO + DMA: PASS
=========================================
```

If `xmutil unloadapp` returns `-1`, retry with the explicit slot name:
`sudo xmutil unloadapp kr260_hw` (or whatever name `xmutil listapps`
shows as currently loaded).

## Troubleshooting

- **`loadapp` error `-22` / `overlay changeset pre-apply notifier error`** — the previous overlay didn't actually unload. Run `sudo xmutil unloadapp <name>` with the explicit name from `xmutil listapps`.
- **`NO UIO at 0x800X_0000`** — the loaded firmware is the previous build. Re-check that `/lib/firmware/xilinx/kr260_hw/kr260_hw.dtbo` was actually replaced; `xmutil` will silently use the old one if the move failed.
- **DMA `SR=0` forever** — control plane regressed to FPD. Verify in the BD that `M_AXI_HPM0_LPD` is wired (not HPM0_FPD), and that PL IPs are at `0x80000000+`. See the "slay the DMA dragon" pattern under `vivado/extend_design.tcl`.

---

# CLI-only workflow (alternative)

For unattended rebuilds — same outcome as the UI flow above.

## Rebuild the XSA

```sh
source /tools/Xilinx/Vivado/2024.1/settings64.sh

cd /home/john/work/kr260_hw/vivado
make clean
JOBS=1 make                                # → vivado/kr260_hw.xsa  (~25-35 min)
```

`vivado/Makefile` invokes `vivado -mode batch -source build.tcl`, which
sources `kr260_hw.tcl`, then `extend_design.tcl`, sets
`general.maxThreads 1`, runs `synth_1`, runs `impl_1` through
`write_bitstream`, and finally `write_hw_platform -fixed -include_bit
-force kr260_hw.xsa`.

Override the Vivado install path if needed:
`VIVADO_SETTINGS=/tools/Xilinx/Vivado/2024.1/settings64.sh make`.

## Rebuild and deploy the Kria app

```sh
cd /home/john/work/kr260_hw/kria_app
make clean
make
make deploy                                # → ubuntu@kr260u:~/kr260_hw
```

## Rebuild and deploy the test binary

```sh
cd /home/john/work/kr260_hw/apps/kr260_hw_test
make clean
make                                       # uses aarch64-linux-gnu-gcc by default
make deploy                                # → ubuntu@kr260u:/tmp/kr260_hw_test
```

## Load and run, one-shot from the host

```sh
ssh ubuntu@kr260u '
    sudo rm -rf /lib/firmware/xilinx/kr260_hw
    sudo mv ~/kr260_hw /lib/firmware/xilinx/
    sudo xmutil unloadapp 2>/dev/null || true
    sudo xmutil loadapp kr260_hw
    cat /sys/class/fpga_manager/fpga0/state
    echo 8 | sudo tee /proc/sys/vm/nr_hugepages > /dev/null
    sudo /tmp/kr260_hw_test
'
```
