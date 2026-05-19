# build.tcl — build the bare-metal app via xsct (Vitis Classic command line).
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct build.tcl
#
# Outputs:
#   vitis_ws/                      Vitis workspace
#   vitis_ws/kr260_hw_bm/Debug/kr260_hw_bm.elf
#
# After build, load to the board via load.tcl (separate JTAG flow).

set this_dir [file dirname [file normalize [info script]]]
set xsa_path [file normalize "$this_dir/../../vivado/kr260_hw.xsa"]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform kr260_hw
set app      kr260_hw_bm
# KR260 = ZynqMP ZU5EV: quad Cortex-A53 APU + dual Cortex-R5F RPU. No A72.
set domain   standalone_psu_cortexa53_0
set cpu      psu_cortexa53_0

puts "build.tcl: workspace = $ws_path"
puts "build.tcl: XSA       = $xsa_path"

if {![file exists $xsa_path]} {
    error "XSA not found at $xsa_path — run 'make' in ../../vivado first"
}

file mkdir $ws_path
setws $ws_path

# Create platform if not already present
if {[lsearch [platform list] $platform] < 0} {
    puts "build.tcl: creating platform $platform"
    platform create -name $platform -hw $xsa_path -proc $cpu \
                    -os standalone -fsbl-target $cpu
    platform write
    platform generate
} else {
    puts "build.tcl: platform $platform already exists, skipping create"
    platform active $platform
}

# Create application if not already present
if {[lsearch [app list] $app] < 0} {
    puts "build.tcl: creating app $app"
    app create -name $app -platform $platform -domain $domain \
               -template "Empty Application(C)" -lang C
    # Import main.c into the app's src/
    importsources -name $app -path $this_dir/main.c
} else {
    puts "build.tcl: app $app already exists, skipping create"
}

puts "build.tcl: building $app"
app build -name $app

set elf $ws_path/$app/Debug/$app.elf
if {[file exists $elf]} {
    puts "build.tcl: built $elf"
} else {
    error "build failed — no $elf"
}
