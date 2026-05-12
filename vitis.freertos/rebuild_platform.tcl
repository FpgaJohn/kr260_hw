# rebuild_platform.tcl — recompile all BSPs (standalone + FreeRTOS) so that
# exported bspinclude/include/ has the full set of headers the IDE needs.
#
# Usage (run from vitis.freertos/ dir):
#   xsct rebuild_platform.tcl

set script_dir [file normalize [file dirname [info script]]]

setws $script_dir
repo -add "$script_dir/plat/export"
platform read "$script_dir/plat/platform.spr"
platform active {plat}
platform generate

puts "Platform BSPs rebuilt."
