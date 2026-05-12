# create_freertos_app.tcl — add a FreeRTOS domain to the existing plat platform,
# create the freertos_hw application, copy in source, and build it.
#
# Usage:
#   xsct create_freertos_app.tcl
#
# Run this AFTER the platform has been created:
#   xsct vitis.freertos/create_platform.tcl
#
# Output:
#   vitis.freertos/freertos_hw/Debug/freertos_hw.elf

set script_dir [file normalize [file dirname [info script]]]
set src_file   "$script_dir/src/freertos_main.c"

if {![file exists $src_file]} {
    error "Source not found: $src_file"
}

setws $script_dir
repo -add "$script_dir/plat/export"
platform read "$script_dir/plat/platform.spr"
platform active {plat}

if {[catch {domain create \
    -name         {freertos_domain} \
    -display-name {FreeRTOS A53} \
    -os           {freertos10_xilinx} \
    -proc         {psu_cortexa53_0}} err]} {
    puts "Note: domain create skipped ($err)"
} else {
    platform write
    platform generate -domains
    platform generate
}

if {[catch {app create \
    -name     {freertos_hw} \
    -platform {plat} \
    -domain   {freertos_domain} \
    -template {Empty Application(C)}} err]} {
    puts "Note: app create skipped ($err)"
}

# Replace the template stub with the real implementation.
file copy -force $src_file "$script_dir/freertos_hw/src/main.c"

app build -name {freertos_hw}

puts ""
puts "Build complete: $script_dir/freertos_hw/Debug/freertos_hw.elf"
puts "To run on hardware:  xsct $script_dir/run_freertos.tcl"
