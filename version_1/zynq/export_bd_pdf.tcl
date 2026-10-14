# ============================================================================
# export_bd_pdf.tcl : save the block design diagram as system_bd.pdf
# ----------------------------------------------------------------------------
# write_bd_layout only works with the GUI, so this opens Vivado briefly:
#   vivado -mode gui -nojournal -nolog -source export_bd_pdf.tcl
# Input : build/vivado/ham_v1_zynq.xpr from build_hw.tcl (nothing in it is saved)
# Output: system_bd.pdf (cropped into ../../report/figures/bd_v1.pdf)
# ============================================================================

set here [file dirname [file normalize [info script]]]
open_project [file join $here build vivado ham_v1_zynq.xpr]
open_bd_design [get_files system.bd]
# Default (portrait) orientation: the diagram is still drawn landscape, but without a
# rotated page ('-orientation landscape' only adds a 270 degree page rotation)
write_bd_layout -force -format pdf [file join $here system_bd.pdf]
exit
