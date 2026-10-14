# ============================================================================
# run_hls.tcl : Vitis HLS 2021.1 flow for min_hamming_hls (Zybo Z7-20)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   vitis_hls -f run_hls.tcl              C simulation, synthesis, IP export
#   COSIM=1 vitis_hls -f run_hls.tcl      also RTL co-simulation (a few minutes)
#
# Steps:
#   1. csim   : tb_min_hamming_hls.cpp checks the C++ against min_hamming_v1.c
#   2. csynth : C++ -> RTL at 100 MHz for the xc7z020
#               (report: proj_min_hamming/solution1/syn/report/min_hamming_hls_csynth.rpt)
#   3. cosim  : optional, the same testbench drives the generated RTL
#   4. export : IP for Vivado in proj_min_hamming/solution1/impl/ip
#               (user.org:hls:min_hamming_hls:1.0, used by ../zynq/build_hw.tcl)
# ============================================================================

set here   [file dirname [file normalize [info script]]]
set v1_dir [file dirname $here]
cd $here

open_project -reset proj_min_hamming
set_top min_hamming_hls
add_files     min_hamming_hls.cpp
add_files -tb tb_min_hamming_hls.cpp -cflags "-I$v1_dir"

open_solution -reset solution1 -flow_target vivado
set_part xc7z020clg400-1
create_clock -period 10 -name default

# The Zynq-7000 HP ports use 32-bit addresses: one 32-bit register for 'tab'
config_interface -m_axi_addr64=false

# C simulation links with the GCC 6.2 bundled with Vitis HLS 2021.1. On this
# PC two of its pieces fail, so the link step avoids them:
#   -fno-use-linker-plugin : the liblto_plugin.so symlinks in the install are
#                            broken (the install is on an NTFS drive)
#   -B/usr/bin/            : use the system ld; the bundled ld 2.26 cannot read
#                            the libm.so.6 of Ubuntu 24.04 (.relr.dyn section)
set ldflags {-fno-use-linker-plugin -B/usr/bin/}

csim_design -ldflags $ldflags
csynth_design
if {[info exists ::env(COSIM)] && $::env(COSIM) eq "1"} {
    cosim_design -ldflags $ldflags
}
export_design -format ip_catalog -vendor user.org -library hls -version 1.0 \
    -display_name "min_Hamming v1 (brute force)" \
    -description "Smallest Hamming distance of an array, all pairs, 16 pairs per clock"

exit
