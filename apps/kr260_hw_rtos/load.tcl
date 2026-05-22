# load.tcl — program the FPGA via JTAG, run psu_init, download + run the ELF.
#
# Prereq: a JTAG cable on the KR260's J7 FTDI USB. Board powered on.
# To get back to Ubuntu after a session: power-cycle the board.
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct load.tcl
#
# UART comes out on the FTDI USB at 115200 8N1.

set this_dir [file dirname [file normalize [info script]]]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform kr260_hw
set app      kr260_hw_rtos
set elf      $ws_path/$app/Debug/$app.elf

set bit      [file normalize "$this_dir/vitis_ws/$platform/hw/kr260_hw_wrapper.bit"]
set psu_init [file normalize "$this_dir/vitis_ws/$platform/hw/psu_init.tcl"]

foreach f [list $elf $bit $psu_init] {
    if {![file exists $f]} { error "missing: $f" }
}

connect

# Reset the whole system to clear any leftover state (including a running
# Ubuntu kernel, if you're hot-taking-over from a board that was booted
# normally — see the README for boot-mode caveats).
targets -set -filter {name =~ "PSU"}
rst -system

# Program FPGA — drives a fresh bitstream, not whatever dfx-mgr loaded.
targets -set -filter {name =~ "PSU"}
fpga $bit

# Run psu_init — configures FPD AFI registers, MIO, DDR, clocks. Required
# whenever the PS hasn't already been initialized (DIP-switch JTAG boot)
# and harmless to re-run after a soft takeover from Linux.
targets -set -filter {name =~ "Cortex-A53 #0"}
source $psu_init
psu_init
puts "load.tcl: psu_init complete"

targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor

dow $elf
con

puts "load.tcl: ELF running. UART output on ttyUSB at 115200 8N1."
