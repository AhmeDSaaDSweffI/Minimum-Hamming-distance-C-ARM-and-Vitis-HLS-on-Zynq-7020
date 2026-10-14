# ============================================================================
# build_hw.tcl : batch Vivado flow for the min_hamming_hls accelerator (Zybo Z7-20)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   vivado -mode batch -nojournal -log build/vivado_hw.log -source build_hw.tcl
#   JOBS=4 vivado -mode batch -source build_hw.tcl      # limit parallel jobs
#
# Input: the IP exported by ../hls/run_hls.tcl
#        (../hls/proj_min_hamming/solution1/impl/ip, user.org:hls:min_hamming_hls:1.0)
#
# Steps:
#   1. Block design: Zynq PS7 (Zybo Z7-20 board preset) + min_hamming_hls
#        s_axi_control <- M_AXI_GP0   registers (tab, tab_size, start/done,
#                                     return) at 0x43C0_0000
#        m_axi_gmem    -> S_AXI_HP0   the accelerator reads the words from DDR
#      Clocks, resets and interconnects come from connection automation.
#   2. HDL wrapper, synthesis, implementation, bitstream, timing check
#   3. Export build/ham_v1_zynq.xsa (bitstream included) and build/ham_v1_zynq.bit
# ============================================================================

set here      [file dirname [file normalize [info script]]]
set ip_repo   [file normalize [file join $here .. hls proj_min_hamming solution1 impl ip]]
set build     [file join $here build]
set proj_dir  [file join $build vivado]
set xsa_file  [file join $build ham_v1_zynq.xsa]
set bit_file  [file join $build ham_v1_zynq.bit]

set part       xc7z020clg400-1
set board_part digilentinc.com:zybo-z7-20:part0:1.2
set ham_vlnv   user.org:hls:min_hamming_hls:1.0
set ham_base   0x43C00000

if {[info exists ::env(JOBS)]} {
    set jobs $::env(JOBS)
} elseif {[catch {exec nproc} jobs]} {
    set jobs 4
}

proc banner {msg} { puts "\n==== $msg ====" }

proc check_run {run} {
    if {[get_property PROGRESS [get_runs $run]] ne "100%"} {
        error "$run failed: [get_property STATUS [get_runs $run]]\
               (see [get_property DIRECTORY [get_runs $run]]/runme.log)"
    }
}

file mkdir $build
if {![file exists [file join $ip_repo component.xml]]} {
    error "HLS IP not found in $ip_repo, run ../hls/run_hls.tcl first"
}
set_param board.repoPaths [list [file join $here board_files]]
if {[get_board_parts -quiet $board_part] eq ""} {
    error "Board part $board_part not found in [file join $here board_files]"
}

# ----------------------------------------------------------------------------
# 1. Project and block design
# ----------------------------------------------------------------------------
banner "Creating block design"
file delete -force $proj_dir
create_project -force ham_v1_zynq $proj_dir -part $part
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild

create_bd_design system

# Zynq PS: DDR, MIO, PS clock and UART1 (MIO 48/49) come from the board preset.
# M_AXI_GP0 drives the registers, S_AXI_HP0 gives the accelerator access to DDR.
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    $ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0            {1} \
    CONFIG.PCW_USE_S_AXI_HP0            {1} \
    CONFIG.PCW_EN_CLK0_PORT             {1} \
    CONFIG.PCW_EN_RST0_PORT             {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] $ps7

create_bd_cell -type ip -vlnv $ham_vlnv ham

# Control path: PS M_AXI_GP0 -> s_axi_control
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} \
             Slave {/ham/s_axi_control} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins ham/s_axi_control]

# Data path: m_axi_gmem -> PS S_AXI_HP0 (DDR)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ham/m_axi_gmem} \
             Slave {/ps7/S_AXI_HP0} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins ps7/S_AXI_HP0]

# Fixed register address so main.c and run_sw.tcl can use a known base address
assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*ham*"}]
if {[llength $seg] != 1} { error "Expected one address segment for ham, got '$seg'" }
set_property offset $ham_base $seg
puts "HAM address segment: $seg  offset=[get_property OFFSET $seg]  range=[get_property RANGE $seg]"
set ham_space [get_bd_addr_spaces -quiet ham/Data_m_axi_gmem]
if {$ham_space ne ""} {
    foreach s [get_bd_addr_segs -quiet -of_objects $ham_space] {
        puts "HAM DDR window: $s  offset=[get_property OFFSET $s]  range=[get_property RANGE $s]"
    }
}

validate_bd_design
save_bd_design

set bd_file [get_files system.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ----------------------------------------------------------------------------
# 2. Synthesis, implementation, bitstream
# ----------------------------------------------------------------------------
banner "Synthesis ($jobs jobs)"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
check_run synth_1

banner "Implementation and bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
check_run impl_1

open_run impl_1
report_timing_summary -file [file join $build timing_summary.rpt]
report_utilization    -file [file join $build utilization.rpt]
report_utilization    -hierarchical -file [file join $build utilization_hier.rpt]
report_power          -file [file join $build power.rpt]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1]]
puts "Timing: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    error "Timing not met (see [file join $build timing_summary.rpt])"
}

# ----------------------------------------------------------------------------
# 3. Export hardware
# ----------------------------------------------------------------------------
banner "Exporting hardware"
write_hw_platform -fixed -include_bit -force -file $xsa_file
file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] system_wrapper.bit] $bit_file

puts "\nXSA       : $xsa_file"
puts "Bitstream : $bit_file"
puts "BUILD_HW OK"
