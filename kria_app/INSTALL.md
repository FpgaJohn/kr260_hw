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

The Makefile pulls `design_1_wrapper.bit` out of `../design_1_wrapper.xsa`,
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

# 4c. gpiochips for the LEDs?
gpiodetect                                       # libgpiod
# or, sysfs-style:
ls /sys/class/gpio/
ls /sys/bus/platform/devices/ | grep a00
```

Two new `gpiochip` entries should appear — one for `axi_gpio_0` (dual-bank,
2 + 3 lines) and one for `axi_gpio_1` (3 lines). Drive a line with libgpiod:

```bash
gpioinfo                                         # find the right chip + line
sudo gpioset --mode=time --sec=1 gpiochipN 0=1   # blink line 0 for 1 s
```

## 5. Unload when done

```bash
sudo xmutil unloadapp kr260_hw
```

This removes the overlay nodes and clears the FPGA. You can now `loadapp`
something else (e.g. the factory app) without rebooting.

## What's in the overlay

| Node | Address | Width | Direction | Drives |
|---|---|---|---|---|
| `gpio@a0000000` ch1 | `0xA000_0000` | 2 | out | `som240_1_connector_User_led` |
| `gpio@a0000000` ch2 | `0xA000_0000` | 3 | out | `som240_1_connector_gem2_led` |
| `gpio@a0010000` ch1 | `0xA001_0000` | 3 | out | `som240_2_connector_gem3_led` |

The fan-enable signal (`fan_en_b`, pin A12) is driven by `xlslice_0` from
PS-side `emio_ttc0_wave_o[2]` — it has no AXI mapping and is not represented
in the overlay. Toggle it from the PS by configuring TTC0.

To switch a peripheral between gpiolib and userspace UIO, change its
`compatible` to `"generic-uio"` in `kr260_hw.dtso`, run `make`, reinstall.

## Address conflict (read this if `loadapp` fails)

The factory KR260 base device tree contains stub nodes at the lowest PL
addresses — typically `gpio@a0000000`, `i2c@a0010000`, `dma@a0020000`,
`ethernet@a0030000` under `/amba_pl@0/`. Our overlay places GPIOs at
`0xA000_0000` and `0xA001_0000`, which **collides** with the first two.

The likely failure mode is `xmutil loadapp` rolling back with a kernel
message like `sysfs: cannot create duplicate filename '…/a0000000.gpio'`
visible in `dmesg`. The `0xA001_0000` entry is less likely to collide
because the factory unit-name is `i2c`, not `gpio`, but the address-region
request can still fail depending on factory bindings.

If you hit this, options in increasing order of effort:

1. **Confirm what's actually claiming the address:**
   ```bash
   cat /proc/iomem | grep -iE 'a000|a001'
   ls /sys/bus/platform/devices/ | grep -E 'a000|a001'
   ```
   If nothing is bound, the conflict is purely sysfs-name; rename the
   unit-name in the dtso (e.g. `gpio@a0000000` → `myled@a0000000`) and
   rebuild. The `compatible` still drives binding.

2. **Switch the conflicting node to `compatible = "generic-uio"`** — UIO
   binds by `of_id` rather than the Xilinx in-tree GPIO driver, which
   sometimes sidesteps the duplicate-platform-device path. You then drive
   the registers from userspace via `/dev/uioN` + `mmap`.

3. **Move the addresses in the Vivado BD** — open `design_1`, change the
   `assign_bd_address` offsets in `axi_gpio_0` / `axi_gpio_1` to something
   above `0xA004_0000` (the factory stubs cover `A000`–`A003`), regenerate
   the wrapper, re-export the XSA, then re-`make` here. This is the
   cleanest fix and matches how the prior `kr260_petalinux` design avoided
   the conflict — see `~/work/kr260_petalinux/kria_app/kr260_petalinux.dtso`
   for an example layout starting at `0xA004_0000`.

## Troubleshooting

- **`loadapp` fails with `firmware not found`**: the app directory wasn't
  placed under `/lib/firmware/xilinx/`, or the `.bit.bin` filename inside
  `kr260_hw.dtbo` doesn't match `firmware-name` in the dtso (must be
  `kr260_hw/kr260_hw.bit.bin`).
- **`fpga0/state` stays `unknown`**: bootgen produced the wrong bitstream
  variant. The Makefile passes `-process_bitstream bin`, which is correct;
  verify `file build/kr260_hw.bit.bin` reports a raw binary of roughly the
  same size as `design_1_wrapper.bit` extracted from the XSA (~2.2 MB for
  this minimal design).
- **Overlay applies but no new gpiochips**: check
  `dmesg | grep -iE "gpio|fpga|overlay"` for probe errors. Most often a
  clock or interrupt phandle that doesn't exist in the running kernel's
  base DT — overlays can only reference labels (`&zynqmp_clk`, `&gic`,
  `&fpga_full`) that are already exported.
