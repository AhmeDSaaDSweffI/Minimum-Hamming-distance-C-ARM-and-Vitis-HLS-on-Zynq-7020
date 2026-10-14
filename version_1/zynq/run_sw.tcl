# ============================================================================
# run_sw.tcl : XSCT flow for the min_hamming_hls accelerator (Vitis 2021.1, Zybo Z7-20)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   xsct run_sw.tcl          build the software, then program and run the board
#   xsct run_sw.tcl build    create workspace, platform and app, build the ELF
#   xsct run_sw.tcl run      program the bitstream and run the existing ELF
#
# Input : build/ham_v1_zynq.xsa from build_hw.tcl
# Output: build/vitis_ws/ham_app/Release/ham_app.elf
#
# The application is main.c plus the unchanged software version 1
# (../min_hamming_v1.c), so the board compares the PL accelerator with v1
# running on the ARM Cortex-A9.
#
# The run step needs the board powered, a JTAG cable connected (on-board
# Digilent USB or a Platform Cable USB II) and the boot-mode jumper (JP5) on
# JTAG. Program output goes to PS UART1 at 115200 8N1 (run_all.sh captures it).
# ============================================================================

set here      [file dirname [file normalize [info script]]]
set build     [file join $here build]
set xsa       [file join $build ham_v1_zynq.xsa]
set ws        [file join $build vitis_ws]
set platform  ham_platform
set domain    standalone_domain
set app       ham_app
set elf       [file join $ws $app Release $app.elf]
set hw_dir    [file join $ws $platform hw]

# Register map of min_hamming_hls (generated driver, see xmin_hamming_hls_hw.h in
# ../hls/proj_min_hamming/solution1/impl/ip/drivers/min_hamming_hls_v1_0/src)
set ham_base      0x43C00000
set reg_ctrl      0x00      ;# bit 0 ap_start, bit 1 ap_done, bit 2 ap_idle
set reg_return    0x10
set reg_tab_size  0x20

set mode [expr {$argc > 0 ? [lindex $argv 0] : "all"}]
if {$mode ni {all build run}} {
    puts "usage: xsct run_sw.tcl \[all|build|run\]"
    exit 2
}

proc banner {msg} { puts "\n==== $msg ====" }

# ----------------------------------------------------------------------------
# Software build
# ----------------------------------------------------------------------------
proc build_sw {} {
    global here xsa ws platform domain app elf

    if {![file exists $xsa]} { error "$xsa not found, run build_hw.tcl first" }

    banner "Creating Vitis workspace $ws"
    file delete -force $ws
    setws $ws

    # Standalone BSP on CPU0; no FSBL is needed for JTAG boot
    platform create -name $platform -hw $xsa -no-boot-bsp
    domain create -name $domain -os standalone -proc ps7_cortexa9_0
    bsp config stdin  ps7_uart_1
    bsp config stdout ps7_uart_1
    platform generate

    app create -name $app -platform $platform -domain $domain -template {Empty Application(C)}
    importsources -name $app -path [file join $here main.c]
    importsources -name $app -path [file normalize [file join $here .. min_hamming_v1.c]]
    app config -name $app build-config release

    banner "Building $app"
    app build -name $app
    if {![file exists $elf]} { error "Build failed, $elf not found" }
    puts "ELF: $elf"
}

# ----------------------------------------------------------------------------
# JTAG: program PL, initialise PS, check the core, download and run the ELF
# ----------------------------------------------------------------------------
proc select_target {filter what} {
    # The JTAG chain can take a moment to show up after hw_server starts
    for {set i 0} {$i < 20} {incr i} {
        if {![catch {targets -set -nocase -filter $filter}]} { return }
        after 250
    }
    error "No $what target found on JTAG. Check that the board is powered, the\
           JTAG cable is connected, JP5 is set to JTAG, and the cable drivers\
           are installed. Visible targets:\n[targets]"
}

proc reg_read {offset} {
    global ham_base
    return [expr {[mrd -value [expr {$ham_base + $offset}]] & 0xFFFFFFFF}]
}

proc reg_write {offset value} {
    global ham_base
    mwr [expr {$ham_base + $offset}] $value
}

# Register-level check over JTAG, independent of the UART and of DDR:
# with tab_size = 1 the core answers -1 without reading memory.
proc smoke_test {} {
    global reg_ctrl reg_return reg_tab_size

    set ctrl [reg_read $reg_ctrl]
    if {!($ctrl & 0x4)} {
        error [format "accelerator not idle after reset: CTRL=0x%X" $ctrl]
    }
    reg_write $reg_tab_size 1
    reg_write $reg_ctrl 1
    for {set i 0} {$i < 100} {incr i} {
        if {[reg_read $reg_ctrl] & 0x2} { break }
    }
    if {$i == 100} { error "smoke test failed: ap_done never set" }
    set ret [reg_read $reg_return]
    puts [format "JTAG smoke test: min_hamming_hls(tab_size = 1) returned 0x%08X" $ret]
    if {$ret != 0xFFFFFFFF} {
        error [format "smoke test failed: expected 0xFFFFFFFF (-1), got 0x%08X" $ret]
    }
}

proc run_hw {} {
    global elf hw_dir

    if {![file exists $elf]} { error "$elf not found, run 'xsct run_sw.tcl build' first" }
    # Use the hardware files the ELF was built against (copied into the platform)
    set bit      [lindex [glob -nocomplain [file join $hw_dir *.bit]] 0]
    set hw_xsa   [lindex [glob -nocomplain [file join $hw_dir *.xsa]] 0]
    set ps7_init [file join $hw_dir ps7_init.tcl]
    if {$bit eq "" || $hw_xsa eq "" || ![file exists $ps7_init]} {
        error "Bitstream, XSA or ps7_init.tcl missing in $hw_dir"
    }

    banner "Connecting to hw_server"
    connect                             ;# starts a local hw_server if needed

    select_target {name =~ "APU*"} "Zynq APU"
    rst -system
    after 3000

    banner "Programming PL: [file tail $bit]"
    select_target {name =~ "xc7z020*"} "xc7z020 FPGA"
    fpga -file $bit

    banner "Initialising PS (ps7_init)"
    select_target {name =~ "APU*"} "Zynq APU"
    loadhw -hw $hw_xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
    configparams force-mem-access 1
    uplevel #0 [list source $ps7_init]
    uplevel #0 ps7_init
    uplevel #0 ps7_post_config          ;# enables PS-PL level shifters, releases FCLK reset

    select_target {name =~ "*A9*#0"} "Cortex-A9 #0"
    catch {stop}
    smoke_test

    banner "Downloading and running [file tail $elf]"
    dow $elf
    configparams force-mem-access 0
    con
    puts "Program running on CPU0; output is on PS UART1 (115200 8N1)."
    disconnect
}

# ----------------------------------------------------------------------------
if {[catch {
    if {$mode in {all build}} { build_sw }
    if {$mode in {all run}}   { run_hw }
} err]} {
    puts "\nERROR: $err"
    exit 1
}
puts "\nRUN_SW OK"
exit 0
