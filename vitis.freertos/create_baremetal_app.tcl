# create_baremetal_app.tcl — create the win_hw bare-metal application in the
# existing plat platform and build it.
#
# Usage:
#   xsct create_baremetal_app.tcl
#
# Run this AFTER the platform has been created:
#   xsct vitis.freertos/create_platform.tcl
#
# Output:
#   vitis.freertos/win_hw/Debug/win_hw.elf

set script_dir [file normalize [file dirname [info script]]]
set src_file   "$script_dir/src/baremetal_main.c"

if {![file exists $src_file]} {
    error "Source not found: $src_file"
}

setws $script_dir
repo -add "$script_dir/plat/export"

if {[catch {app create \
    -name     {win_hw} \
    -platform {plat} \
    -domain   {standalone_domain} \
    -template {Hello World}} err]} {
    puts "Note: app create skipped ($err)"
}

file copy -force $src_file "$script_dir/win_hw/src/helloworld.c"

app build -name {win_hw}

puts ""
puts "Build complete: $script_dir/win_hw/Debug/win_hw.elf"
puts "To run on hardware:  xsct $script_dir/run_baremetal.tcl"
