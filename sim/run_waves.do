# ============================================================================
# run_waves.do - QuestaSim (optional): RTL simulation of the two Vitis HLS
# cores on main.c's benchmark array (N = 5,000, MT19937 seed 42), with
# waveform screenshots. The report itself uses the Icarus Verilog figures made
# by run_icarus.bat; to show these screenshots instead, change wave_v1/wave_v2
# to questa_v1/questa_v2 in min_hamming_report.tex and the simulator name in
# its text.
#
#   run_waves.bat              double-click (runs the line below in this folder)
#   vsim -do run_waves.do      GUI: simulate and save the screenshots
#   vsim -c -do run_waves.do   batch: simulate and print the results only
#
# Output
#   ../report/figures/questa_v1.png     version 1 core, whole call
#   ../report/figures/questa_v2.png     version 2 core, whole call
#   ../report/figures/questa_start.png  version 2 core, start of the call
#   ../report/figures/questa_end.png    version 2 core, end of the call
#   results.txt                         answer, latency and rows of each core
#
# AUTO_SNAP 1 : the screenshots are taken automatically (snap.py: Python+Pillow)
# AUTO_SNAP 0 : the GUI stays open; type  view_v1, view_v2, view_start  or
#               view_end  in the transcript and take the screenshots yourself
# ============================================================================

# $finish stops the simulation (-onfinish stop): carry on with this script
onbreak {resume}

quietly set AUTO_SNAP 1
quietly set WIN_GEOMETRY 1000x620+10+10
quietly set RTL(1) rtl/v1
quietly set RTL(2) rtl/v2
quietly set FIG    ../report/figures
quietly set GUI    [expr {![batch_mode]}]
quietly set LOADED 0

# ---------------------------------------------------------------- compile
foreach v {1 2} {
    if {![file exists work_v$v]} {
        vlib work_v$v
    }
    vmap work_v$v work_v$v
    vlog -quiet -work work_v$v +define+CORE_V$v {*}[lsort [glob $RTL($v)/*.v]] tb_min_hamming.v
}
if {[file exists results.txt]} {
    file delete results.txt
}

# ---------------------------------------------------------------- helpers
proc sig_int {sig} {
    set value [examine -radix decimal $sig]
    regsub -all {[^0-9-]} $value {} value
    return $value
}

proc wave_setup {} {
    configure wave -namecolwidth 100
    configure wave -valuecolwidth 80
    configure wave -justifyvalue left
    configure wave -signalnamewidth 1
    configure wave -timelineunits us
}

# Whole call: control, phase and result (no clock: it would be a solid band).
proc waves_whole {v} {
    set tb /tb_min_hamming
    catch {delete wave *}
    add wave -noupdate -divider "Version $v core"
    add wave -noupdate -label ap_start                 $tb/dut/ap_start
    add wave -noupdate -label ap_done                  $tb/dut/ap_done
    add wave -noupdate -label phase   -radix ascii     $tb/phase
    add wave -noupdate -label rows    -radix unsigned  $tb/rows
    add wave -noupdate -label ARVALID                  $tb/m_axi_gmem_ARVALID
    add wave -noupdate -label RVALID                   $tb/m_axi_gmem_RVALID
    add wave -noupdate -divider "Result"
    add wave -noupdate -label result  -radix unsigned  $tb/result
    if {$v == 2} {
        add wave -noupdate -label stage -radix unsigned $tb/stage
    }
    add wave -noupdate -label latency -radix unsigned  $tb/latency
    wave_setup
}

# Start of the call: AXI4-Lite writes (0x18, 0x20, 0x00) and the first burst.
proc waves_start {} {
    set tb /tb_min_hamming
    catch {delete wave *}
    add wave -noupdate -divider "AXI4-Lite"
    add wave -noupdate -label clk                      $tb/ap_clk
    add wave -noupdate -label AWVALID                  $tb/s_axi_control_AWVALID
    add wave -noupdate -label AWADDR  -radix hex       $tb/s_axi_control_AWADDR
    add wave -noupdate -label WDATA   -radix hex       $tb/s_axi_control_WDATA
    add wave -noupdate -label ap_start                 $tb/dut/ap_start
    add wave -noupdate -label phase   -radix ascii     $tb/phase
    add wave -noupdate -divider "AXI4 m_axi_gmem"
    add wave -noupdate -label ARVALID                  $tb/m_axi_gmem_ARVALID
    add wave -noupdate -label ARADDR  -radix hex       $tb/m_axi_gmem_ARADDR
    add wave -noupdate -label ARLEN   -radix unsigned  $tb/m_axi_gmem_ARLEN
    add wave -noupdate -label RVALID                   $tb/m_axi_gmem_RVALID
    add wave -noupdate -label RDATA   -radix hex       $tb/m_axi_gmem_RDATA
    add wave -noupdate -label RLAST                    $tb/m_axi_gmem_RLAST
    wave_setup
}

# End of the call: ap_done, then the ARM-side reads of 0x00, 0x10 and 0x28.
proc waves_end {} {
    set tb /tb_min_hamming
    catch {delete wave *}
    add wave -noupdate -divider "Core"
    add wave -noupdate -label clk                      $tb/ap_clk
    add wave -noupdate -label ap_done                  $tb/dut/ap_done
    add wave -noupdate -label phase   -radix ascii     $tb/phase
    add wave -noupdate -label ap_return -radix unsigned $tb/dut/ap_return
    add wave -noupdate -divider "AXI4-Lite reads"
    add wave -noupdate -label ARVALID                  $tb/s_axi_control_ARVALID
    add wave -noupdate -label ARADDR  -radix hex       $tb/s_axi_control_ARADDR
    add wave -noupdate -label RVALID                   $tb/s_axi_control_RVALID
    add wave -noupdate -label RDATA   -radix hex       $tb/s_axi_control_RDATA
    add wave -noupdate -label result  -radix unsigned  $tb/result
    add wave -noupdate -label stage   -radix unsigned  $tb/stage
    add wave -noupdate -label latency -radix unsigned  $tb/latency
    wave_setup
}

# Let the GUI redraw for about a second.
proc settle {} {
    for {set i 0} {$i < 12} {incr i} {
        update
        after 100
    }
}

# Screenshot of the wave window (snap.py converts Tk to screen pixels).
proc snap {png} {
    global FIG AUTO_SNAP
    if {!$AUTO_SNAP} {
        return
    }
    set w ""
    if {[catch {view wave} w] || ![winfo exists $w]} {
        set w ""
        foreach candidate {.main_pane.wave .wave} {
            if {[winfo exists $candidate]} {
                set w $candidate
                break
            }
        }
    }
    if {$w eq ""} {
        set w .
    }
    raise .
    settle
    set cmd [list python snap.py [winfo rootx $w] [winfo rooty $w] \
                 [winfo width $w] [winfo height $w] \
                 [winfo screenwidth .] [winfo screenheight .] [file join $FIG $png]]
    if {[catch {exec {*}$cmd 2>@1} msg]} {
        echo "snap: screenshot $png failed: $msg"
    } else {
        echo "snap: $msg"
    }
}

# Simulate one core (if it is not already loaded) and log its results.
proc load_core {v} {
    global GUI LOADED
    if {$LOADED == $v} {
        return
    }
    catch {quit -sim}
    vsim -quiet -onfinish stop -voptargs=+acc work_v$v.tb_min_hamming
    if {$GUI} {
        # Record every signal that one of the views shows: only signals logged
        # during the run have a waveform afterwards.
        set tb /tb_min_hamming
        log $tb/ap_clk $tb/phase $tb/rows $tb/latency $tb/result $tb/stage \
            $tb/s_axi_control_AWVALID $tb/s_axi_control_AWADDR $tb/s_axi_control_WDATA \
            $tb/s_axi_control_ARVALID $tb/s_axi_control_ARADDR \
            $tb/s_axi_control_RVALID $tb/s_axi_control_RDATA \
            $tb/m_axi_gmem_ARVALID $tb/m_axi_gmem_ARADDR $tb/m_axi_gmem_ARLEN \
            $tb/m_axi_gmem_RVALID $tb/m_axi_gmem_RDATA $tb/m_axi_gmem_RLAST \
            $tb/dut/ap_start $tb/dut/ap_done $tb/dut/ap_return
        waves_whole $v
    }
    run -all
    set LOADED $v
    set line "v$v distance=[sig_int /tb_min_hamming/result]"
    if {$v == 2} {
        append line " stage=[sig_int /tb_min_hamming/stage]"
    }
    append line " latency=[sig_int /tb_min_hamming/latency]"
    append line " rows=[sig_int /tb_min_hamming/rows]"
    append line " t_start=[sig_int /tb_min_hamming/t_start_ns]ns"
    append line " t_done=[sig_int /tb_min_hamming/t_done_ns]ns"
    echo "RESULTS $line"
    set fh [open results.txt a]
    puts $fh $line
    close $fh
}

proc zoom {from_ns to_ns cursor_ns} {
    WaveRestoreCursors [list {Cursor 1} "$cursor_ns ns" 0]
    WaveRestoreZoom "$from_ns ns" "$to_ns ns"
}

# The four views (also usable by hand: type the name in the transcript).
proc view_whole_call {v} {
    load_core $v
    waves_whole $v
    set t_end [sig_int /tb_min_hamming/t_end_ns]
    zoom 0 $t_end [expr {$t_end - 30}]
}
proc view_v1 {} { view_whole_call 1 }
proc view_v2 {} { view_whole_call 2 }
proc view_start {} {
    load_core 2
    waves_start
    set t0 [sig_int /tb_min_hamming/t_start_ns]
    zoom [expr {$t0 - 250}] [expr {$t0 + 800}] [expr {$t0 + 150}]
}
proc view_end {} {
    load_core 2
    waves_end
    set t1 [sig_int /tb_min_hamming/t_done_ns]
    set t_end [sig_int /tb_min_hamming/t_end_ns]
    zoom [expr {$t1 - 150}] $t_end [expr {$t_end - 30}]
}

# ---------------------------------------------------------------- run
if {$GUI} {
    foreach pane {library structure sim objects processes locals} {
        catch {noview $pane}
    }
    catch {wm geometry . $WIN_GEOMETRY}
}

load_core 1
if {$GUI} {
    view_v1
    snap questa_v1.png
}
load_core 2
if {$GUI} {
    view_v2
    snap questa_v2.png
    view_start
    snap questa_start.png
    view_end
    snap questa_end.png
}

if {!$GUI || $AUTO_SNAP} {
    quit -f
}
