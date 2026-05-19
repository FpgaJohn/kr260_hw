#!/bin/sh
# gpio.sh — drive the my_state accumulator using devmem only.
#
# Run on the KR260 (needs /dev/mem, so root). The kr260_hw app must
# already be loaded (xmutil loadapp kr260_hw) so the AXI GPIOs exist
# at the addresses below.
#
# Usage:  sudo ./gpio.sh [ADDEND]      (default ADDEND = 5)
#
# axi_gpio_control @ 0x80000000:
#   0x00  DATA  -- 2-bit opcode: 0=noop, 1=add (edge-triggered), 2=reset
# axi_gpio_addend  @ 0x80020000:
#   0x00  DATA  -- 32-bit addend (separate IP to dodge dual-channel synth bug)
# axi_gpio_value   @ 0x80010000:
#   0x00  ch1 DATA  -- accumulator[31:0]
#   0x08  ch2 DATA  -- accumulator[63:32]

set -eu

ADDEND=${1:-5}

CTRL_OP=0x80000000      # control: 2-bit opcode
CTRL_VAL=0x80020000     # addend: 32-bit value (separate IP)
VAL_LO=0x80010000       # value ch1: accumulator[31:0]
VAL_HI=0x80010008       # value ch2: accumulator[63:32]

read_accum() {
    LO=$(devmem $VAL_LO 32)
    HI=$(devmem $VAL_HI 32)
    printf "  accum = 0x%08x_%08x  (hi=%s lo=%s)\n" "$HI" "$LO" "$HI" "$LO"
}

pulse() {                       # $1 = opcode (1=add, 2=reset)
    devmem $CTRL_OP 32 0x0
    devmem $CTRL_OP 32 "$1"
    devmem $CTRL_OP 32 0x0
}

echo "Before:"
read_accum

echo "Reset accumulator:"
pulse 0x2
read_accum

printf "Set addend = %s and pulse ADD:\n" "$ADDEND"
devmem $CTRL_VAL 32 "$ADDEND"
pulse 0x1
read_accum

echo "Pulse ADD again (should be addend * 2):"
pulse 0x1
read_accum
