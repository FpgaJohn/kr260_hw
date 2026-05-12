# create_platform.tcl — create and generate the Vitis platform (plat) for the
# KR260 bare-metal / FreeRTOS workspace.
#
# Usage:
#   xsct create_platform.tcl
#
# Prerequisites:
#   vivado/kr260_hw.xsa must exist (run the Vivado build first).
#
# Output:
#   vitis.freertos/plat/   (generated — not in source control)
#
# Run this once before create_baremetal_app.tcl or create_freertos_app.tcl.

set script_dir [file normalize [file dirname [info script]]]
set xsa_file   [file normalize "$script_dir/../vivado/kr260_hw.xsa"]

if {![file exists $xsa_file]} {
    error "XSA not found: $xsa_file\nBuild the Vivado project first."
}

setws $script_dir

platform create -name {plat} \
    -hw           $xsa_file \
    -proc         {psu_cortexa53_0} \
    -os           {standalone} \
    -arch         {64-bit} \
    -fsbl-target  {psu_cortexa53_0} \
    -out          $script_dir

platform write
platform generate -domains
platform active {plat}
platform generate

puts ""
puts "Platform ready: $script_dir/plat/"
puts "Next steps:"
puts "  xsct $script_dir/create_baremetal_app.tcl"
puts "  xsct $script_dir/create_freertos_app.tcl"
