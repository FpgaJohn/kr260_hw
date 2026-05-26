# load.tcl — program the FPGA via JTAG, run psu_init, download + run the ELF.
#
# Prereq: a JTAG cable (Xilinx Platform Cable USB II or compatible) attached to
# the KR260's J7 / FTDI USB. The KR260 must be powered on.
#
# Two modes of operation:
#   1. Hot takeover (default) — Linux is running, we stop the kernel, reprogram
#      PL, enable AFI fabric interfaces, and run our ELF. Skips full psu_init
#      (MIO/DDR/PLL/SerDes already done by Linux).
#   2. Cold JTAG boot — board booted with DIPs in JTAG mode, PS needs full init.
#      Set env COLD_BOOT=1 before running to use this mode.
#
# Handles multiple JTAG cables: filters for the KR260 (Xilinx SCK-KR) so it
# works even with other boards (e.g. Arty Z7) connected simultaneously.
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

set bit      [file normalize "$this_dir/vitis_ws/$platform/hw/kr260_hw.bit"]
set psu_init_file [file normalize "$this_dir/vitis_ws/$platform/hw/psu_init.tcl"]

foreach f [list $elf $bit $psu_init_file] {
    if {![file exists $f]} { error "missing: $f" }
}

set cold_boot [expr {[info exists ::env(COLD_BOOT)] && $::env(COLD_BOOT)}]

# KR260 cable filter — distinguishes from other boards (Arty, etc.)
set kr260_cable {jtag_cable_name =~ "Xilinx*"}

connect

if {$cold_boot} {
    puts "load.tcl: cold JTAG boot — full psu_init"
    targets -set -filter "name =~ \"PSU\" && $kr260_cable"
    rst -system
    after 1000
    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    source $psu_init_file
    psu_init
    puts "load.tcl: psu_init complete"
} else {
    puts "load.tcl: hot takeover from Linux"
    # Stop A53 #0 (running Linux kernel, or already stopped from prior run)
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    catch {stop}
    after 500

    # Program PL — PS stays alive, DDR contents preserved
    # Target the PS TAP (xck26 JTAG device) so fpga knows which FPGA to program
    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    after 500

    # Source psu_init.tcl for its helper procs and data variables
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    source $psu_init_file

    # Run only the subset of psu_init needed for PL access:
    #   1. PS-PL isolation removal (power up PL domain)
    #   2. AFI config (deassert AFI resets, set fabric widths)
    #   3. PS-PL reset release (deassert FCLKRESETN via EMIO)
    configparams force-mem-accesses 1
    psu_ps_pl_isolation_removal
    puts "load.tcl: PS-PL isolation removed"

    # AFI: deassert FPD AFI resets (FM0-FM5)
    mask_write 0XFD1A0100 0x00001F80 0x00000000
    # AFI: deassert LPD AFI reset (FM6)
    mask_write 0XFF5E023C 0x00080000 0x00000000
    # LPD_SLCR AFI_FS: 32-bit data width for slave 2 (HPM0_LPD)
    mask_write 0XFF419000 0x00000300 0x00000000
    # AFIFM0 RDCTRL: 128-bit fabric width
    mask_write 0XFD360000 0x00000003 0x00000000
    # AFIFM0 WRCTRL: 128-bit fabric width
    mask_write 0XFD360014 0x00000003 0x00000000
    puts "load.tcl: AFI configured"

    psu_ps_pl_reset_config
    puts "load.tcl: PS-PL resets released"
    configparams force-mem-accesses 0
}

targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
rst -processor
after 200

dow $elf
con

puts "load.tcl: ELF running. UART output on ttyUSB at 115200 8N1."
