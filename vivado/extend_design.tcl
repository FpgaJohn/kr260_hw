# extend_design.tcl — add a simple FIFO + AXI DMA to design_1.
#
# Sourced from build.tcl AFTER kr260_hw.tcl has created the BD and made the
# wrapper. We:
#   1. Reopen the saved BD (kr260_hw.tcl closes it).
#   2. Enable S_AXI_HPC0_FPD on the PS so the DMA can master into PS DDR.
#   3. Grow ps8_0_axi_periph from 3 MI to 5 MI.
#   4. Add simple_fifo_0 — a custom Verilog AXI4-Lite slave with built-in
#      256-deep 32-bit FIFO (push at 0x00 W, pop at 0x00 R). User-visible
#      "64-bit words" are pairs of 32-bit pushes/pops in the C app.
#   5. Add axi_dma_0 (no SG, 64-bit MM2S+S2MM, 49-bit address width to reach
#      DDR_HIGH) plus axis_data_fifo on the MM2S→S2MM stream.
#   6. Add axi_smc_dma (smartconnect) routing both DMA M_AXI ports into
#      S_AXI_HPC0_FPD with both DDR_LOW and DDR_HIGH visible.
#   7. Wire clocks/resets, assign addresses, validate, regen wrapper.
#
# Why a custom FIFO instead of axi_fifo_mm_s: the Xilinx IP's AXI4-Stream-based
# loopback (TXD→RXD or via an external axis_data_fifo) consistently fires TSE
# on TLR commit in this configuration; debugging the IP-side state machine isn't
# worth the effort when ~150 lines of Verilog gives us exactly the semantics
# the user asked for ("push, pop, get the same data back"). simple_fifo.v lives
# at vivado/ip/simple_fifo.v.

puts "extend_design: opening BD"
open_bd_design [get_files design_1.bd]

# ----- 1. PS: enable S_AXI_HP0_FPD (PSU__USE__S_AXI_GP2) -----
# HP0 (non-coherent) bypasses CCI/SMMU. Simpler than HPC0; no cache-attr
# tuning needed at the DMA. Userspace must do explicit cache management on
# DMA buffers (or use uncached memory). For our small test buffer this is
# acceptable.
puts "extend_design: enabling S_AXI_HP0_FPD on PS"
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# ----- 2. Grow ps8_0_axi_periph to 5 MI (M03=axi_fifo, M04=axi_dma_lite) -----
puts "extend_design: ps8_0_axi_periph NUM_MI 3 -> 5"
set_property -dict [list CONFIG.NUM_MI {5}] [get_bd_cells ps8_0_axi_periph]

# ----- 3. simple_fifo (custom Verilog AXI4-Lite slave with built-in FIFO) -----
puts "extend_design: importing simple_fifo.v"
import_files -quiet -fileset sources_1 [file normalize "[file dirname [info script]]/ip/simple_fifo.v"]
update_compile_order -fileset sources_1

puts "extend_design: creating axi_fifo_0 (module-reference simple_fifo)"
set axi_fifo_0 [create_bd_cell -type module -reference simple_fifo axi_fifo_0]

# ----- 4. AXI DMA (no SG, 64-bit MM2S+S2MM, no DRE) -----
puts "extend_design: creating axi_dma_0"
set axi_dma_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
# 32-bit data width experiment — matches the kr260_petalinux reference DMA
# config (xlnx,addrwidth = <0x20>) which apparently worked in its day. If
# 32-bit "just works" but 64-bit hangs, the smartconnect/interconnect path
# has a width-conversion bug for the 64→128 bridge to HP0.
# c_addr_width stays 49 so the DMA can still reach DDR_HIGH addresses.
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_addr_width {49} \
] $axi_dma_0

# ----- 5. AXIS data FIFO between MM2S→S2MM -----
# TDATA_NUM_BYTES matches the DMA stream width (32-bit = 4 bytes).
puts "extend_design: creating axis_data_fifo"
set axis_data_fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_data_fifo]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TKEEP {1} \
] $axis_data_fifo

connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                   [get_bd_intf_pins axis_data_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo/M_AXIS] \
                   [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# ----- 6. axi_interconnect (NOT smartconnect): DMA → S_AXI_HP0_FPD -----
# We tried smartconnect:1.0 first and the DMA stalled with SR=0 forever after
# triggering a transfer. axi_interconnect:2.1 is older but rock-solid for HP
# slave ports.
puts "extend_design: creating axi_smc_dma (axi_interconnect)"
set axi_smc_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_smc_dma]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $axi_smc_dma

connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
                   [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                   [get_bd_intf_pins axi_smc_dma/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] \
                   [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# ----- 7. AXI-Lite control wires from PS -----
puts "extend_design: connecting M03→axi_fifo_0/S_AXI, M04→axi_dma_0/S_AXI_LITE"
connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/M03_AXI] \
                   [get_bd_intf_pins axi_fifo_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/M04_AXI] \
                   [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# ----- 8. Clocks: pl_clk0 to all the new bits -----
puts "extend_design: connecting pl_clk0 to new IPs"
set clk [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
foreach pin [list \
    ps8_0_axi_periph/M03_ACLK \
    ps8_0_axi_periph/M04_ACLK \
    axi_fifo_0/s_axi_aclk \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_mm2s_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
    axis_data_fifo/s_axis_aclk \
    axi_smc_dma/ACLK \
    axi_smc_dma/S00_ACLK \
    axi_smc_dma/S01_ACLK \
    axi_smc_dma/M00_ACLK \
    zynq_ultra_ps_e_0/saxihp0_fpd_aclk \
] {
    connect_bd_net $clk [get_bd_pins $pin]
}

# ----- 9. Reset: peripheral_aresetn to all the new bits -----
puts "extend_design: connecting peripheral_aresetn to new IPs"
set rst [get_bd_pins rst_ps8_0_99M/peripheral_aresetn]
foreach pin [list \
    ps8_0_axi_periph/M03_ARESETN \
    ps8_0_axi_periph/M04_ARESETN \
    axi_fifo_0/s_axi_aresetn \
    axi_dma_0/axi_resetn \
    axis_data_fifo/s_axis_aresetn \
    axi_smc_dma/ARESETN \
    axi_smc_dma/S00_ARESETN \
    axi_smc_dma/S01_ARESETN \
    axi_smc_dma/M00_ARESETN \
] {
    connect_bd_net $rst [get_bd_pins $pin]
}

# ----- 10. Address assignments -----
puts "extend_design: assigning addresses"
# For module-reference cells the auto-generated address-segment name varies
# (Mem0, reg0, ...). Look it up by the interface pin instead of hard-coding.
set fifo_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_fifo_0/S_AXI]]
puts "extend_design: axi_fifo_0 segment = $fifo_seg"
assign_bd_address -offset 0xA0050000 -range 0x00010000 -with_name SEG_axi_fifo_0_Reg \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    $fifo_seg -force
assign_bd_address -offset 0xA0060000 -range 0x00010000 -with_name SEG_axi_dma_0_Reg \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force

# DMA needs to see PS DDR through HP0 — both LOW (0..2 GiB) and HIGH (0x8_0000_0000..)
# regions, since Linux allocations may land above 4 GB on a board with > 2 GB DDR.
# HP0 = SAXIGP2 in PSU naming.
foreach seg {HP0_DDR_LOW HP0_DDR_HIGH HP0_LPS_OCM HP0_QSPI} {
    catch {
        assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
            [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/$seg] -force
    }
    catch {
        assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
            [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/$seg] -force
    }
}

puts "extend_design: validating BD"
validate_bd_design
save_bd_design

# ----- 11. Regenerate the wrapper since we changed the BD -----
puts "extend_design: regenerating wrapper"
generate_target all [get_files design_1.bd]
set old_wrapper [get_files -quiet design_1_wrapper.v]
if { [llength $old_wrapper] > 0 } {
    remove_files -fileset sources_1 $old_wrapper
    file delete -force $old_wrapper
}
set wrapper_path [make_wrapper -files [get_files -norecurse design_1.bd] -top -force]
add_files -norecurse -fileset sources_1 $wrapper_path
update_compile_order -fileset sources_1

puts "extend_design: done"
