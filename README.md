# KR260 Hardware Project

Vivado 2024.1 block design for the Xilinx KR260 Robotics Starter Kit, plus bare-metal and FreeRTOS test apps that exercise the PL peripherals over JTAG, and a Kria runtime app package for loading the bitstream via `xmutil` without reflashing.

See `CLAUDE.md` for a full description of the block design, address map, and repo layout.

---

## Prerequisites

### Hardware

- KR260 Robotics Starter Kit with a 12 V power supply
- USB-A to micro-USB cable — connects to the KR260's JTAG/UART port (single cable, FT4232H provides both JTAG and UART0)
- Ethernet cable — board must be reachable at hostname `kr260u` for SSH and deployment

### Software (Windows)

| Tool | Version | Notes |
|---|---|---|
| Vivado (with Vitis/XSCT) | 2024.1 | AMD unified installer; default path `C:\Xilinx\Vivado\2024.1\` and `C:\Xilinx\Vitis\2024.1\` |
| WSL2 + Ubuntu 22.04 | any | Required only for Kria app packaging (step 4) |
| PetaLinux | 2024.1 | In WSL2 at `/tools/Xilinx/PetaLinux/2024.1/`; required only for step 4 |

`build_all.bat` hard-codes `C:\Xilinx\Vitis\2024.1\bin\xsct.bat`. If Vitis is installed elsewhere, edit the `XSCT=` line at the top of that file before running.

---

## One-time board setup

### Add `kr260u` to your hosts file

If `kr260u` doesn't resolve via DNS, add it to `C:\Windows\System32\drivers\etc\hosts` (run Notepad as Administrator):

```
192.168.x.x   kr260u
```

Replace `192.168.x.x` with the board's actual IP address.

### Configure SSH key auth

From a Windows terminal (PowerShell or Command Prompt):

```powershell
ssh-keygen -t ed25519          # accept defaults; skip if you already have a key
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh ubuntu@kr260u "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Verify: `ssh ubuntu@kr260u` should log in without a password prompt.

### Enable passwordless sudo on the board

```powershell
ssh -t ubuntu@kr260u "echo 'ubuntu ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-ubuntu-nopasswd > /dev/null && sudo chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd"
```

---

## Step 1 — Build the hardware (Vivado XSA)

The output of this step is `vivado/kr260_hw.xsa`, which feeds both the Vitis software build and the Kria app package.

### Option A — Vivado Tcl console (GUI, Windows native)

1. Open **Vivado 2024.1**.
2. Open the **Tcl Console** (View → Tcl Console).
3. Navigate to the `vivado/` directory (adjust path):
   ```tcl
   cd {C:/work/kr260/kr260_hw/vivado}
   ```
4. Run the full build (creates project, runs synthesis + implementation + bitstream, writes XSA):
   ```tcl
   source build.tcl
   ```
   This takes 20–40 minutes depending on your machine. Progress appears in the log. On machines with less than 16 GB RAM, add `set ::env(JOBS) 1` before sourcing if you see OOM errors.

### Option B — Windows Command Prompt (batch mode)

```batch
cd C:\work\kr260\kr260_hw\vivado
set JOBS=1
"C:\Xilinx\Vivado\2024.1\bin\vivado.bat" -mode batch -nojournal -log build.log -source build.tcl
```

`JOBS=1` serialises synthesis threads. Safe to omit on machines with ≥ 16 GB RAM and a swap file, but if you see `parallel_synth_helper` stalling at 0% CPU, drop to 1.

**Output:** `vivado/kr260_hw.xsa`

---

## Step 2 — Build the software (Vitis ELFs)

Run from a **Windows Command Prompt** (not PowerShell, not WSL):

```batch
cd C:\work\kr260\kr260_hw\vitis.freertos
build_all.bat
```

This runs three `xsct.bat` steps in sequence:

1. **`create_platform.tcl`** — creates `plat/` from `vivado/kr260_hw.xsa` (standalone domain, A53 core 0). Run once per XSA.
2. **`create_baremetal_app.tcl`** — creates and builds the bare-metal app.
3. **`create_freertos_app.tcl`** — adds a FreeRTOS domain, creates and builds the FreeRTOS app.

**Outputs:**
- `vitis.freertos/win_hw/Debug/win_hw.elf` — bare-metal
- `vitis.freertos/freertos_hw/Debug/freertos_hw.elf` — FreeRTOS

If you change only the C source (`src/baremetal_main.c` or `src/freertos_main.c`) without changing the XSA, you can rebuild just one app:

```batch
"C:\Xilinx\Vitis\2024.1\bin\xsct.bat" vitis.freertos\create_baremetal_app.tcl
"C:\Xilinx\Vitis\2024.1\bin\xsct.bat" vitis.freertos\create_freertos_app.tcl
```

---

## Step 3 — Run tests on hardware (JTAG)

### Physical setup

1. Connect the micro-USB cable from the KR260's JTAG/UART port to your PC.
2. Power on the board. The KR260's FT4232H will enumerate as four COM ports in Device Manager — the UART0 port is typically the second one (Channel B). The run scripts auto-probe COM5–COM9; if your port falls outside that range, note the COM number and use a terminal instead (see below).
3. The board can be running the factory Linux image — the run scripts switch it to JTAG boot mode automatically.

### Run bare-metal test

```batch
"C:\Xilinx\Vitis\2024.1\bin\xsct.bat" vitis.freertos\run_baremetal.tcl
```

### Run FreeRTOS test

```batch
"C:\Xilinx\Vitis\2024.1\bin\xsct.bat" vitis.freertos\run_freertos.tcl
```

Each script:
1. Connects to `hw_server` (starts automatically on localhost:3121).
2. Switches the PSU to JTAG boot mode and resets the board.
3. Programs the PL with the bitstream extracted from the XSA.
4. Runs FSBL on A53 core 0 to initialise DDR and PS clocks.
5. Downloads and runs the ELF.
6. Captures UART0 output for 20 seconds and prints it to the xsct console.

### Expected output (all tests pass)

```
=== bare-metal GPIO + my_state test ===
...
=== GPIO:  ALL PASS : 0 failure(s) ===

=== AXI Stream FIFO loopback test ===
  word0: got 0x12345678  exp 0x12345678  PASS
  word1: got 0xCAFEBABE  exp 0xCAFEBABE  PASS
=== FIFO: ALL PASS : 0 failure(s) ===

=== AXI DMA loopback test (64 bytes) ===
  MM2S idle  PASS
  S2MM idle  PASS
  data compare (64 bytes)  PASS
=== DMA: ALL PASS : 0 failure(s) ===

========================================
TOTAL: ALL PASS : 0 failure(s)
========================================
```

### If UART is not auto-captured

If the script prints `could not auto-open UART`, open **PuTTY** (or any terminal) and connect to the KR260's UART COM port at **115200 baud, 8N1** before running the script. Output will appear there instead.

---

## Step 4 — Package and deploy the Kria runtime app (WSL2, optional)

This step is not required for the JTAG tests above. It packages the bitstream as a `xmutil`-loadable app so you can load it on the board's running Linux without a JTAG cable or Vitis.

### Build the package (WSL2)

```bash
cd /mnt/c/work/kr260/kr260_hw/kria_app
make        # produces build/kr260_hw/{kr260_hw.bit.bin, kr260_hw.dtbo, shell.json}
```

Requires PetaLinux 2024.1 sourced at `/tools/Xilinx/PetaLinux/2024.1/settings.sh` (provides `bootgen` and `dtc`). Override with `PETALINUX_SETTINGS=…` if installed elsewhere.

### Deploy to the board (WSL2 or Windows)

```bash
# From WSL2:
cd /mnt/c/work/kr260/kr260_hw/kria_app
make deploy    # scp build/kr260_hw to ubuntu@kr260u:~/
```

Or from Windows PowerShell:
```powershell
scp -r kria_app\build\kr260_hw ubuntu@kr260u:~/
```

### Install and load on the board

SSH into the board and run:

```bash
# If updating an existing install, use the helper script:
bash ~/update_app.sh   # removes old /lib/firmware/xilinx/kr260_hw, installs new one

# Otherwise, first install:
sudo mv ~/kr260_hw /lib/firmware/xilinx/

# Load:
sudo xmutil unloadapp
sudo xmutil loadapp kr260_hw
cat /sys/class/fpga_manager/fpga0/state   # → operating
```

### Smoke-test with gpio.sh

```bash
sudo bash ~/gpio.sh        # defaults to addend=5; resets, adds twice, prints accumulator
sudo bash ~/gpio.sh 100    # custom addend
```

See `kria_app/INSTALL.md` for the full overlay structure, address conflict workaround, and detailed troubleshooting.

---

## Troubleshooting

**`build_all.bat` fails with "xsct.bat not found"**
Vitis is not installed at `C:\Xilinx\Vitis\2024.1\`. Edit the `XSCT=` line at the top of `vitis.freertos\build_all.bat` to point to your actual install path.

**`create_platform.tcl` fails with "XSA not found"**
Run the Vivado build (Step 1) first. The platform script requires `vivado/kr260_hw.xsa`.

**`create_freertos_app.tcl` fails with "domain already exists"**
The workspace was partially created from a previous run. Safe to rerun — the script catches and skips already-created domains and apps.

**JTAG script fails with "no targets found" or hangs at `connect`**
- Confirm the micro-USB cable is connected and the board is powered.
- Check Device Manager for the FT4232H device. If it shows as unrecognised, install the [FTDI combined driver](https://ftdichip.com/drivers/d2xx-drivers/) and the Xilinx USB cable driver (included with Vivado: run `C:\Xilinx\Vivado\2024.1\data\xicom\cable_drivers\nt64\installdriver.cmd` as Administrator).
- Vivado's `hw_server` may be running and holding the cable. Close any open Vivado Hardware Manager sessions before running `xsct`.

**Synthesis stalls at 0% CPU ("parallel_synth_helper")**
Set `JOBS=1` (Option B) or add `set ::env(JOBS) 1` before `source build.tcl` (Option A). This is a known Vivado behaviour on memory-constrained machines.

**`xmutil loadapp` rolls back with "duplicate filename" in dmesg**
Factory base-DT stub nodes conflict with the overlay. See `kria_app/INSTALL.md` § "Address conflict" for diagnosis and fixes.
