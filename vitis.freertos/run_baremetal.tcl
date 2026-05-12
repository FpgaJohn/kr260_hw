# run_baremetal.tcl — load and run win_hw on the KR260 over JTAG.
#
# Usage:
#   xsct run_baremetal.tcl
#
# Prerequisites:
#   1. Platform generated : xsct vitis/plat/platform.tcl
#   2. win_hw built       : build in Vitis IDE (Debug configuration)
#   3. JTAG cable attached and hw_server reachable on localhost:3121
#      (hw_server starts automatically when xsct calls connect)

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/.."]

set xsa_file  "$repo_root/vivado/kr260_hw.xsa"
set fsbl_elf  "$script_dir/plat/export/plat/sw/plat/boot/fsbl.elf"
set app_elf   "$script_dir/win_hw/Debug/win_hw.elf"
set bit_file ""
foreach candidate [glob -nocomplain "$script_dir/win_hw/_ide/bitstream/*.bit"] {
    set bit_file $candidate; break
}

foreach f [list $xsa_file $fsbl_elf $app_elf] {
    if {![file exists $f]} { error "Required file not found:\n  $f" }
}
if {$bit_file eq ""} { error "No bitstream found in win_hw/_ide/bitstream/ — build win_hw first." }

# Switch the PSU to JTAG boot mode and reset.
# Safe to call whether the board is running Linux or already in JTAG mode.
proc boot_jtag {} {
    targets -set -nocase -filter {name =~ "PSU"}
    mwr 0xffca0010 0x0       ;# clear multiboot address
    mwr 0xff5e0200 0x0100    ;# set boot mode to JTAG
    rst -system
}

connect
# Give hw_server time to enumerate targets after fresh connect
after 2000
boot_jtag
after 3000

# Program PL.  KR260 exposes a built-in "Xilinx SCK-KR" FTDI JTAG cable;
# the filter omits the board serial number so any KR260 unit works.
targets -set -nocase -filter {name =~ "PS TAP"}
fpga -file $bit_file

# Load the hardware description so the debugger knows the memory map.
targets -set -nocase -filter {name =~ "APU*"}
loadhw -hw $xsa_file \
    -mem-ranges [list {0x80000000 0xbfffffff} \
                      {0x400000000 0x5ffffffff} \
                      {0x1000000000 0x7fffffffff}] \
    -regs
configparams force-mem-access 1

# Run FSBL.  It initialises DDR, PS clocks, and MIO, then calls XFsbl_Exit.
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $fsbl_elf
set fsbl_bp [bpadd -addr &XFsbl_Exit]
con -block -timeout 60
bpremove $fsbl_bp

# Download application and release the core.
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $app_elf
configparams force-mem-access 0
con

# Capture UART output directly (avoids the PowerShell/COM7 dance that upsets the FT4232H).
set uart_port ""
foreach candidate {COM7 COM8 COM9 COM6 COM5} {
    if {[catch {set fd [open "$candidate:" r+]} err] == 0} {
        set uart_port $candidate
        break
    }
}
if {$uart_port eq ""} {
    puts "win_hw running — could not auto-open UART. Connect a terminal to UART0 (115200 8N1)."
} else {
    fconfigure $fd -mode "115200,n,8,1" -translation binary -blocking 0 -buffersize 8192
    puts "win_hw running — capturing UART0 ($uart_port) for 20s..."
    set buf ""
    set start [clock seconds]
    while {[expr {[clock seconds] - $start}] < 20} {
        after 200
        append buf [read $fd]
    }
    close $fd
    puts "=== UART OUTPUT ==="
    puts $buf
}
