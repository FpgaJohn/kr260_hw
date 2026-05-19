# load.tcl — program the FPGA via JTAG, run psu_init, download + run the ELF.
#
# Prereq: a JTAG cable (Xilinx Platform Cable USB II or compatible) attached to
# the KR260's J7 / FTDI USB. The KR260 must be powered on; switch the boot
# mode to JTAG if you want to skip the QSPI boot.
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct load.tcl
#
# UART comes out on the FTDI USB at 115200 8N1 (one of ttyUSB0..ttyUSB3 on
# the host).

set this_dir [file dirname [file normalize [info script]]]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform kr260_hw
set app      kr260_hw_bm
set elf      $ws_path/$app/Debug/$app.elf

set bit      [file normalize "$this_dir/vitis_ws/$platform/hw/kr260_hw_wrapper.bit"]
# psu_init.tcl comes from the platform's hw directory
set psu_init [file normalize "$this_dir/vitis_ws/$platform/hw/psu_init.tcl"]

foreach f [list $elf $bit $psu_init] {
    if {![file exists $f]} { error "missing: $f" }
}

connect

# Reset the whole system to clear any leftover state
targets -set -filter {name =~ "PSU"}
rst -system

# Program FPGA — this drives a fresh bitstream, not the one dfx-mgr loaded
targets -set -filter {name =~ "PSU"}
fpga $bit

# Run psu_init — this is what dfx-mgr DOESN'T do at runtime. It configures
# the FPD AFI registers, MIO, DDR, clocks etc., so HP0/HPC0 ports actually
# accept transactions.
targets -set -filter {name =~ "Cortex-A53 #0"}
source $psu_init
psu_init
puts "load.tcl: psu_init complete"

targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor

dow $elf
con

puts "load.tcl: ELF running. UART output on ttyUSB at 115200 8N1."
