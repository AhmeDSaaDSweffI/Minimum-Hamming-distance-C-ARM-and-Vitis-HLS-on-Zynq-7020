# ============================================================================
# run_sw.tcl : XSCT flow for the version 2 HLS core on the ZC702 (Vitis 2021.1)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   xsct run_sw.tcl          build the software, then program and run the board
#   xsct run_sw.tcl build    create workspace, platform and app, build the ELF
#   xsct run_sw.tcl run      program the bitstream and run the existing ELF
#
# Input : build/ham_v2_zynq.xsa from build_hw.tcl
# Output: build/vitis_ws/ham_app/Release/ham_app.elf
#
# The program is main.c plus the software versions it is timed against:
# ../min_hamming_v2.c and ../../version_1/min_hamming_v1.c (via ham_v1_arm.c).
#
# The run step needs the ZC702 powered, a JTAG cable connected (Platform
# Cable USB II on the JTAG header, or the on-board Digilent USB-JTAG) and the
# boot-mode switches on JTAG. Program output goes to PS UART1, the board's
# CP2103 USB-UART, at 115200 8N1 (run_all.sh captures it).
# ============================================================================

set here      [file dirname [file normalize [info script]]]
set build     [file join $here build]
set xsa       [file join $build ham_v2_zynq.xsa]
set ws        [file join $build vitis_ws]
set platform  ham_platform
set domain    standalone_domain
set app       ham_app
set elf       [file join $ws $app Release $app.elf]
set hw_dir    [file join $ws $platform hw]
set hls_dir   [file normalize [file join $here .. hls]]
set v1_dir    [file normalize [file join $here .. .. version_1]]
set drv_hdr   [file join $hls_dir build min_hamming_hls sol impl ip drivers min_hamming_hls_v1_0 src xmin_hamming_hls_hw.h]

set ham_base  0x43C00000
set smoke_buf 0x01000000            ;# DDR address for the JTAG smoke test words
set heap_size 0x100000              ;# version 2 mallocs 4 * n bytes (32 KB at MAX_N)

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
    global here xsa ws platform domain app elf hls_dir v1_dir heap_size

    if {![file exists $xsa]} { error "$xsa not found, run build_hw.tcl first" }
    if {![file exists [file join $v1_dir min_hamming_v1.c]]} {
        error "[file join $v1_dir min_hamming_v1.c] not found (version 1 is timed on the ARM too)"
    }

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
    importsources -name $app -path [file join $here ham_v1_arm.c]
    importsources -name $app -path [file normalize [file join $here .. min_hamming_v2.c]]
    app config -name $app build-config release
    app config -name $app -add include-path $hls_dir
    app config -name $app -add include-path $v1_dir
    app config -name $app -add linker-misc "-Wl,--defsym=_HEAP_SIZE=$heap_size"

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
           JTAG cable is connected, the boot mode is JTAG, and the cable drivers\
           are installed. Visible targets:\n[targets]"
}

# Register offsets of the core, from the header Vitis HLS generated with it
proc reg_offsets {} {
    global drv_hdr
    if {![file exists $drv_hdr]} { error "$drv_hdr not found (export the HLS IP first)" }
    set f [open $drv_hdr r]
    set text [read $f]
    close $f
    set offs [dict create]
    foreach {name key} {AP_CTRL ctrl AP_RETURN ret TAB_DATA tab TAB_SIZE_DATA size STAGE_DATA stage} {
        if {![regexp "#define XMIN_HAMMING_HLS_CONTROL_ADDR_${name}\\s+(0x\[0-9a-fA-F\]+)" $text -> off]} {
            error "XMIN_HAMMING_HLS_CONTROL_ADDR_$name not found in $drv_hdr"
        }
        dict set offs $key $off
    }
    return $offs
}

# Runs the core on {0x0, 0xF, 0xFF} over JTAG, independent of the UART and the
# ELF: the answer must be 4 (decided in step 3)
proc smoke_test {} {
    global ham_base smoke_buf
    set off [reg_offsets]

    set ctrl [mrd -value [expr {$ham_base + [dict get $off ctrl]}]]
    if {!($ctrl & 0x4)} {
        error [format "core not idle: AP_CTRL = 0x%X (is the bitstream loaded?)" $ctrl]
    }
    mwr $smoke_buf [list 0x0 0xF 0xFF]
    mwr [expr {$ham_base + [dict get $off tab]}]  $smoke_buf
    mwr [expr {$ham_base + [dict get $off size]}] 3
    mwr [expr {$ham_base + [dict get $off ctrl]}] 1
    set done 0
    for {set i 0} {$i < 100 && !$done} {incr i} {
        set done [expr {[mrd -value [expr {$ham_base + [dict get $off ctrl]}]] & 0x2}]
    }
    set result [mrd -value [expr {$ham_base + [dict get $off ret]}]]
    set stage  [mrd -value [expr {$ham_base + [dict get $off stage]}]]
    puts [format "JTAG smoke test: min_Hamming({0x0, 0xF, 0xFF}) = %d  (step %d)" $result $stage]
    if {!$done || $result != 4 || $stage != 3} {
        error [format "smoke test failed: done=%d result=%d step=%d (expected 4, step 3)" \
               $done $result $stage]
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
