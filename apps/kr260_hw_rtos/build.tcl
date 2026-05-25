# build.tcl — build the FreeRTOS app via xsct (Vitis Classic command line).
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct build.tcl
#
# Outputs:
#   vitis_ws/                                Vitis workspace
#   vitis_ws/kr260_hw_rtos/Debug/kr260_hw_rtos.elf
#
# After build, load to the board via load.tcl (separate JTAG flow).
#
# Differs from apps/kr260_hw_bm/build.tcl only in -os freertos10_xilinx
# (kr260_hw_bm uses standalone). The XSA, address map, and load.tcl flow
# are identical — FreeRTOS on ZU+ is just a richer BSP layered on bare-metal.

set this_dir [file dirname [file normalize [info script]]]
set xsa_path [file normalize "$this_dir/../../vivado/kr260_hw.xsa"]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform kr260_hw
set app      kr260_hw_rtos
# KR260 = ZynqMP ZU5EV: quad Cortex-A53 APU + dual Cortex-R5F RPU. No A72.
set cpu      psu_cortexa53_0
set domain   freertos_psu_cortexa53_0

puts "build.tcl: workspace = $ws_path"
puts "build.tcl: XSA       = $xsa_path"

if {![file exists $xsa_path]} {
    error "XSA not found at $xsa_path — run 'make' in ../../vivado first"
}

file mkdir $ws_path
setws $ws_path

# Create platform + FreeRTOS domain if not already present.
# Wrap in catch: xsct throws "No platform exist" on an empty workspace
# instead of returning an empty list.
if {[catch {platform list} existing] || [lsearch $existing $platform] < 0} {
    puts "build.tcl: creating platform $platform with FreeRTOS domain"
    platform create -name $platform -hw $xsa_path
    domain create -name $domain -proc $cpu -os freertos10_xilinx
    platform write
    platform generate
} else {
    puts "build.tcl: platform $platform already exists, skipping create"
    platform active $platform
}

# Create application if not already present.
# Same catch: xsct throws "No application exist" on an empty workspace.
if {[catch {app list} existing] || [lsearch $existing $app] < 0} {
    puts "build.tcl: creating app $app"
    app create -name $app -platform $platform -domain $domain \
               -template "Empty Application(C)" -lang C
}

# Always re-import main.c so edits to apps/kr260_hw_rtos/main.c flow through.
# (kr260_hw_bm/build.tcl has this inside the create-only guard, which is a
# footgun — edits on disk silently don't rebuild.)
puts "build.tcl: importing main.c"
importsources -name $app -path $this_dir/main.c

puts "build.tcl: building $app"
app build -name $app

set elf $ws_path/$app/Debug/$app.elf
if {[file exists $elf]} {
    puts "build.tcl: built $elf"
} else {
    error "build failed — no $elf"
}
