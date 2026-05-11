# build.tcl — drive a full Vivado run from kr260_hw.tcl.
#
# Invoked by the Makefile in this directory:
#   vivado -mode batch -source build.tcl
#
# Assumes CWD is ./vivado/ relative to the repo root, so the project lands
# in ./vivado/kr260_hw/ and source paths still resolve via origin_dir.

set origin_dir_loc "."

# kr260_hw.tcl was exported on a host that had APPDATA set; on Linux it is
# unset and trips the board_part_repo_paths line. Stub it to a harmless path.
if { ![info exists ::env(APPDATA)] } { set ::env(APPDATA) [file normalize ~/.Xilinx] }

source kr260_hw.tcl
source extend_design.tcl

# Force single-threaded synthesis. On memory-constrained boxes the
# parallel_synth_helper can deadlock at 0% CPU after "Initializing timing
# engine"; serialising avoids that and trades a few minutes of wall time.
set_param general.maxThreads 1

set jobs 4
if { [info exists ::env(JOBS)] } { set jobs $::env(JOBS) }

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } {
    error "synth_1 did not complete: status=[get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } {
    error "impl_1 did not complete: status=[get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
write_hw_platform -fixed -include_bit -force kr260_hw.xsa

puts "----"
puts "Wrote XSA: [file normalize kr260_hw.xsa]"
