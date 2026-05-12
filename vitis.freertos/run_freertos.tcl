# run_freertos.tcl — load and run freertos_hw on the KR260 over JTAG.
#
# Usage:
#   xsct run_freertos.tcl
#
# Prerequisites:
#   1. Platform + FreeRTOS domain built: xsct vitis/create_freertos_app.tcl
#   2. JTAG cable attached and hw_server reachable on localhost:3121

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/.."]

set xsa_file  "$repo_root/vivado/kr260_hw.xsa"
set fsbl_elf  "$script_dir/plat/export/plat/sw/plat/boot/fsbl.elf"
set app_elf   "$script_dir/freertos_hw/Debug/freertos_hw.elf"

# The FreeRTOS app runs on the same PL bitstream as the bare-metal app.
# Prefer the FreeRTOS app's own extracted copy; fall back to win_hw's.
set bit_file ""
foreach candidate [concat \
        [glob -nocomplain "$script_dir/freertos_hw/_ide/bitstream/*.bit"] \
        [glob -nocomplain "$script_dir/win_hw/_ide/bitstream/*.bit"]] {
    set bit_file $candidate; break
}

foreach f [list $xsa_file $fsbl_elf $app_elf] {
    if {![file exists $f]} { error "Required file not found:\n  $f" }
}
if {$bit_file eq ""} {
    error "No bitstream found. Build win_hw or freertos_hw in Vitis first."
}

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

targets -set -nocase -filter {name =~ "PS TAP"}
fpga -file $bit_file

targets -set -nocase -filter {name =~ "APU*"}
loadhw -hw $xsa_file \
    -mem-ranges [list {0x80000000 0xbfffffff} \
                      {0x400000000 0x5ffffffff} \
                      {0x1000000000 0x7fffffffff}] \
    -regs
configparams force-mem-access 1

targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $fsbl_elf
set fsbl_bp [bpadd -addr &XFsbl_Exit]
con -block -timeout 60
bpremove $fsbl_bp

targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $app_elf
configparams force-mem-access 0
con

# Capture UART output directly (avoids the PowerShell/COM7 dance that upsets the FT4232H).
# The KR260's UART0 appears as the second FT4232H channel; COM port set by Windows driver.
set uart_port ""
foreach candidate {COM7 COM8 COM9 COM6 COM5} {
    if {[catch {set fd [open "$candidate:" r+]} err] == 0} {
        set uart_port $candidate
        break
    }
}
if {$uart_port eq ""} {
    puts "freertos_hw running — could not auto-open UART. Connect a terminal to UART0 (115200 8N1)."
} else {
    fconfigure $fd -mode "115200,n,8,1" -translation binary -blocking 0 -buffersize 8192
    puts "freertos_hw running — capturing UART0 ($uart_port) for 20s..."
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
