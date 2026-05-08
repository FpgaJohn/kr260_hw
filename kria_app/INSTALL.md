# Installing and loading the `kr260_hw` app

This packages the Vivado design as a Kria App (XRT_FLAT shell) that can be
loaded at runtime on the booted KR260 — no reflash required. It works on the
factory Kria firmware as long as `dfx-mgr` / `xmutil` are present (default).

## 1. Build the package on the dev machine

```bash
cd kria_app
make
```

Produces `build/kr260_hw/` containing:
- `kr260_hw.bit.bin` — raw bitstream for `fpga_manager`
- `kr260_hw.dtbo`    — device-tree overlay
- `shell.json`       — Kria manifest

The Makefile pulls `kr260_hw.bit` out of `../kr260_hw.xsa`,
runs `bootgen -process_bitstream bin` to convert to the raw format
`fpga_manager` needs, and `dtc` to compile the overlay.

## 2. Copy to the KR260

```bash
scp -r build/kr260_hw/ ubuntu@<kr260_ip>:/tmp/
```

## 3. Install into the firmware library and load

On the KR260:

```bash
# Place the app where dfx-mgr looks for it
sudo mv /tmp/kr260_hw /lib/firmware/xilinx/

# Verify it shows up
sudo xmutil listapps
# you should see "kr260_hw" in the list with status: Inactive

# Unload whatever is currently active (the factory design)
sudo xmutil unloadapp

# Load ours
sudo xmutil loadapp kr260_hw
```

## 4. Verify it took effect

```bash
# 4a. FPGA programmed?
cat /sys/class/fpga_manager/fpga0/state          # → "operating"

# 4b. Our PL nodes are live?
ls /proc/device-tree/fpga-full/                  # lists overlay-added nodes

# 4c. /dev/uio* entries for the AXI GPIOs?
for i in /sys/class/uio/uio*; do
    name=$(cat $i/name 2>/dev/null)
    addr=$(cat $i/maps/map0/addr 2>/dev/null)
    echo "$(basename $i): $name @ $addr"
done
```

Two new UIO entries should appear — one mapped at `0xa0000000`
(`axi_gpio_control`) and one at `0xa0010000` (`axi_gpio_value`). Smoke-test
the my_state accumulator from userspace:

```bash
sudo devmem 0xa0000000 32 0x2          # ch1 opcode = 2 → reset
sudo devmem 0xa0000000 32 0x0          # back to noop (edge-trigger)
sudo devmem 0xa0000008 32 5            # ch2 addend = 5
sudo devmem 0xa0000000 32 0x1          # ch1 opcode = 1 → add
sudo devmem 0xa0000000 32 0x0
sudo devmem 0xa0010000 32              # → 0x00000005   (sum = accumulator[31:0])
sudo devmem 0xa0010008 32              # → 0x00000000   (carry = accumulator[63:32])
```

Note that `scripts/gpio.sh` in the repo root targets a different design
(`kr260_petalinux`, addresses `0xA004_0000` / `0xA00C_0000`) — its base
addresses are wrong for `kr260_hw`. Use the inline `devmem` commands above
or copy `gpio.sh` and rewrite the four address constants to `0xA000_0000`
(control) / `0xA001_0000` (value).

## 5. Unload when done

```bash
sudo xmutil unloadapp kr260_hw
```

This removes the overlay nodes and clears the FPGA. You can now `loadapp`
something else (e.g. the factory app) without rebooting.

## What's in the overlay

| Node | Address | Channels | Direction | Drives |
|---|---|---|---|---|
| `axi_gpio_control@a0000000` | `0xA000_0000` | ch1 (2-bit), ch2 (32-bit) | out | `my_state.control`, `my_state.value` |
| `axi_gpio_value@a0010000` | `0xA001_0000` | ch1 (32-bit), ch2 (32-bit) | in | `accumulator[31:0]`, `accumulator[63:32]` |

Both nodes use `compatible = "generic-uio"` — the registers are driven from
userspace via `mmap` on `/dev/uioN`. Channel 1 DATA lives at register `+0x00`
and channel 2 DATA at `+0x08`. See `~/work/kr260_hw/CLAUDE.md` "Block design
summary" for the full BD picture and the `my_state` accumulator semantics
(opcode 1 = add on rising edge, opcode 2 = reset on rising edge).

The fan-enable signal (`fan_en_b`, pin A12) is driven by `xlslice_0` from
PS-side `emio_ttc0_wave_o[2]` — it has no AXI mapping and is not represented
in the overlay. Toggle it from the PS by configuring TTC0.

To switch either peripheral back to a Xilinx in-tree driver (e.g. gpiolib
via `xlnx,axi-gpio-2.0`), change its `compatible` in `kr260_hw.dtso`, run
`make`, and reinstall.

## Address conflict (read this if `loadapp` fails)

The factory KR260 base device tree contains stub nodes at the lowest PL
addresses — typically `gpio@a0000000`, `i2c@a0010000`, `dma@a0020000`,
`ethernet@a0030000` under `/amba_pl@0/`. Our overlay places nodes at
`0xA000_0000` and `0xA001_0000` — the same addresses, but with distinct
unit-names (`axi_gpio_control@…`, `axi_gpio_value@…`) and `compatible =
"generic-uio"`. The unit-name divergence is what lets the overlay coexist
with the factory stubs; if you rename them back to `gpio@…`, the sysfs
duplicate-name path will trip.

The likely failure mode if it does collide is `xmutil loadapp` rolling
back with a kernel message like `sysfs: cannot create duplicate filename
'…/a0000000.gpio'` visible in `dmesg`. If you see that, options in
increasing order of effort:

1. **Confirm what's actually claiming the address:**
   ```bash
   cat /proc/iomem | grep -iE 'a000|a001'
   ls /sys/bus/platform/devices/ | grep -E 'a000|a001'
   ```
   If nothing is bound there, the conflict is purely sysfs-name. Pick a
   different unit-name in the dtso (the `compatible` still drives binding).

2. **Switch the conflicting node to `compatible = "generic-uio"`** if it
   isn't already — UIO binds by `of_id`, which sometimes sidesteps the
   duplicate-platform-device path entirely.

3. **Move the addresses in the Vivado BD** — open `design_1`, change the
   `assign_bd_address` offsets for `axi_gpio_control` / `axi_gpio_value`
   to something above `0xA004_0000` (the factory stubs cover `A000`–`A003`),
   regenerate the wrapper, re-export the XSA via `vivado/Makefile`, then
   re-`make` here. This is the cleanest fix and mirrors how the sibling
   `kria_app_eth/` design lays out its peripherals.

## Troubleshooting

- **`loadapp` fails with `firmware not found`**: the app directory wasn't
  placed under `/lib/firmware/xilinx/`, or the `.bit.bin` filename inside
  `kr260_hw.dtbo` doesn't match `firmware-name` in the dtso (must be
  `kr260_hw/kr260_hw.bit.bin`).
- **`fpga0/state` stays `unknown`**: bootgen produced the wrong bitstream
  variant. The Makefile passes `-process_bitstream bin`, which is correct;
  verify `file build/kr260_hw.bit.bin` reports a raw binary of roughly the
  same size as `kr260_hw.bit` extracted from the XSA (~2.4 MB).
- **Overlay applies but no new `/dev/uio*` for our nodes**: check
  `dmesg | grep -iE "uio|generic-uio|fpga|overlay"` for probe errors. Most
  often a clock phandle that doesn't exist in the running kernel's base DT
  — overlays can only reference labels (`&zynqmp_clk`, `&gic`, `&fpga_full`)
  that are already exported. If `/proc/device-tree/fpga-full/` lists the
  nodes but `/dev/uio*` doesn't show them, the `uio_pdrv_genirq` module
  may not have rebound to the new of_compatible — try
  `sudo modprobe -r uio_pdrv_genirq && sudo modprobe uio_pdrv_genirq of_id=generic-uio`
  (the same dance `scripts/mod_probe.sh` does).
