# ============================================================================
# run_hls.tcl : Vitis HLS 2021.1 flow for the version 2 core (min_hamming_hls)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   vitis_hls -f run_hls.tcl                              csim csynth cosim export
#   vitis_hls -f run_hls.tcl -tclargs csim                C simulation only
#   vitis_hls -f run_hls.tcl -tclargs csim csynth         any subset, in this order
#   vitis_hls -f run_hls.tcl -tclargs impl                IP export + out-of-context implementation
#
# Stages:
#   csim    C simulation: testbench vs the software version 2 (all cases)
#   csynth  C synthesis: report in build/min_hamming_hls/sol/syn/report/
#   cosim   C/RTL co-simulation of the Verilog, testbench argument "quick"
#   export  IP for Vivado: build/min_hamming_hls/sol/impl/ip
#           (xilinx.com:hls:min_hamming_hls:1.0, used by ../zynq/build_hw.tcl)
#   impl    (optional, not in the default list) the same export with -flow impl:
#           Vivado synthesis and place & route of the IP alone (out of context),
#           report in build/min_hamming_hls/sol/impl/report/verilog/ (~10 min)
#
# Target: xc7z020clg484-1 (ZC702), 10 ns clock (FCLK_CLK0 = 100 MHz).
# ============================================================================

set here   [file dirname [file normalize [info script]]]
set build  [file join $here build]

# vitis_hls puts "-f run_hls.tcl" in argv ahead of the -tclargs values
set args $argv
set k [lsearch -exact $args -f]
if {$k >= 0} { set args [lrange $args [expr {$k + 2}] end] }
set stages [expr {[llength $args] > 0 ? $args : {csim csynth cosim export}}]

foreach s $stages {
    if {$s ni {csim csynth cosim export impl}} {
        puts "usage: vitis_hls -f run_hls.tcl \[-tclargs csim csynth cosim export impl\]"
        exit 2
    }
}

proc banner {msg} { puts "\n==== $msg ====" }

# Linking the C simulation with Vitis HLS's bundled GCC 6.2 on this machine
# (Ubuntu 24.04, install on an NTFS partition):
#  - the liblto_plugin.so symlinks of the install cannot be read, so link
#    without the LTO plugin (nothing uses LTO);
#  - the bundled binutils 2.26 cannot read glibc 2.39's libm (.relr.dyn), so
#    -B/usr/bin/ makes GCC use the system linker;
#  - GCC 6.2 does not search Ubuntu's multiarch directory for crt1.o and libc.
# All three are harmless on a normal install.
set link_flags "-fno-use-linker-plugin -B/usr/bin/"
if {[file isdirectory /usr/lib/x86_64-linux-gnu]} {
    set lp [expr {[info exists ::env(LIBRARY_PATH)] ? ":$::env(LIBRARY_PATH)" : ""}]
    set ::env(LIBRARY_PATH) "/usr/lib/x86_64-linux-gnu$lp"
}

file mkdir $build
cd $build

# Re-create the project only when C simulation starts the flow, so that
# "-tclargs cosim export" can reuse an existing synthesis.
if {[lindex $stages 0] in {csim csynth}} {
    open_project -reset min_hamming_hls
} else {
    open_project min_hamming_hls
}
set_top min_hamming_hls
add_files [file join $here min_hamming_hls.cpp] -cflags "-I$here"
add_files -tb [file join $here tb_min_hamming_hls.cpp] -cflags "-I$here"
# The software version 2 is the reference; HLS compiles .c files as C89 by default
add_files -tb [file join $here .. min_hamming_v2.c] -cflags "-std=gnu99"

if {[lindex $stages 0] in {csim csynth}} {
    open_solution -reset sol -flow_target vivado
} else {
    open_solution sol -flow_target vivado
}
set_part xc7z020clg484-1
create_clock -period 10 -name default
# 32-bit AXI addresses, as on the Zynq-7000 (one tab register instead of two)
config_interface -m_axi_addr64=false

if {"csim" in $stages} {
    banner "C simulation"
    csim_design -O -ldflags $link_flags
}
if {"csynth" in $stages} {
    banner "C synthesis"
    csynth_design
}
if {"cosim" in $stages} {
    banner "C/RTL co-simulation (testbench argument: quick)"
    cosim_design -rtl verilog -argv quick -ldflags $link_flags
}
if {"export" in $stages} {
    banner "Exporting IP"
    export_design -format ip_catalog -rtl verilog \
        -display_name "min_Hamming version 2 (HLS)" \
        -description "Smallest Hamming distance between 32-bit words: radix sort, search tree, LANES-way pair compare"
    puts "IP: [file join $build min_hamming_hls sol impl ip]"
}
if {"impl" in $stages} {
    banner "Exporting IP with out-of-context Vivado implementation"
    export_design -flow impl -format ip_catalog -rtl verilog \
        -display_name "min_Hamming version 2 (HLS)" \
        -description "Smallest Hamming distance between 32-bit words: radix sort, search tree, LANES-way pair compare"
    puts "Report: [file join $build min_hamming_hls sol impl report verilog]"
}

puts "\nRUN_HLS OK"
exit
