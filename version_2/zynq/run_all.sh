#!/usr/bin/env bash
# ============================================================================
# run_all.sh : push-button flow for the version 2 HLS core on the ZC702
# ----------------------------------------------------------------------------
# Usage: ./run_all.sh [stage]
#   all   (default) hls -> hw -> sw -> run
#   build hls -> hw -> sw (everything that does not need the board)
#   hls   C model regression (420 cases, native g++), then Vitis HLS:
#         C sim, synthesis, C/RTL co-sim, IP export             (../hls/run_hls.tcl)
#   hw    Vivado: block design, bitstream, XSA                  (build_hw.tcl)
#   sw    Vitis: platform, BSP, application ELF                  (run_sw.tcl build)
#   run   JTAG: program PL, ps7_init, smoke test, run ELF, capture UART (run_sw.tcl run)
#
# Environment overrides:
#   XILINX_ROOT  install root            (default /tools/Xilinx)
#   XILINX_VER   tool version            (default 2021.1)
#   JOBS         Vivado parallel jobs    (default: nproc)
#   UART_DEV     board serial port       (default: the ZC702's CP2103 USB-UART,
#                                         else the only USB serial port present)
#   UART_WAIT    seconds to wait for the test result on the UART (default 120;
#                the board test takes about 20 s, version 1 on the ARM most of it)
#
# Results: every run (passed or failed) is saved to
#   results/<date>_<time>_<stage>/   summary.txt + logs/reports of the stages run
#   results/history.log              one line per run
#   results/latest                   link to the newest run folder
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HLS="$(cd "$HERE/../hls" && pwd)"
BUILD="$HERE/build"
HLS_BUILD="$HLS/build"
HLS_SOL="$HLS_BUILD/min_hamming_hls/sol"
STAGE="${1:-all}"
XILINX_ROOT="${XILINX_ROOT:-/tools/Xilinx}"
XILINX_VER="${XILINX_VER:-2021.1}"
UART_WAIT="${UART_WAIT:-120}"
UART_LOG="$BUILD/uart.log"
CAP_PID=""

START_TIME=$EPOCHSECONDS
printf -v RUN_DATE  '%(%Y-%m-%d %H:%M:%S)T' "$START_TIME"
printf -v RUN_STAMP '%(%Y-%m-%d_%H-%M-%S)T' "$START_TIME"
RESULTS="$HERE/results/${RUN_STAMP}_${STAGE}"
STAGES_PASSED=()
CUR_STAGE=""
LAST_ERROR=""

log()  { printf '\n\033[1m[run_all] %s\033[0m\n' "$*"; }
die()  { LAST_ERROR="$*"; printf '\n\033[31m[run_all] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

case "$STAGE" in
    all|build|hls|hw|sw|run) ;;
    *) echo "usage: $0 [all|build|hls|hw|sw|run]"; exit 2 ;;
esac

# ---------------------------------------------------------------- tools
# The Xilinx settings scripts are not 'set -u' clean
set +u
for s in "$XILINX_ROOT/Vitis/$XILINX_VER/settings64.sh" "$XILINX_ROOT/Vivado/$XILINX_VER/settings64.sh" \
         "$XILINX_ROOT/Vitis_HLS/$XILINX_VER/settings64.sh"; do
    if [[ -f "$s" ]]; then
        # shellcheck disable=SC1090
        source "$s"
    fi
done
set -u
for t in vitis_hls vivado xsct; do
    command -v "$t" >/dev/null || die "$t not found; check XILINX_ROOT/XILINX_VER ($XILINX_ROOT, $XILINX_VER)"
done
mkdir -p "$BUILD" "$HLS_BUILD"

# ---------------------------------------------------------------- stages
run_hls() {
    # The full testbench (420 cases) built with the system g++ -O2 and the HLS
    # headers: about a minute, where Vitis HLS's -O1 C simulation needs over an hour
    local hls_inc="${XILINX_HLS:-$XILINX_ROOT/Vitis_HLS/$XILINX_VER}/include"
    log "C model regression: full testbench, native g++ (log in $HLS_BUILD/tb_full.log)"
    (
        cd "$HLS_BUILD"
        gcc -O2 -std=gnu99 -c "$HLS/../min_hamming_v2.c" -o tb_v2.o
        g++ -O2 -std=c++11 -Wno-unknown-pragmas -I"$hls_inc" -I"$HLS" \
            "$HLS/min_hamming_hls.cpp" "$HLS/tb_min_hamming_hls.cpp" tb_v2.o -o tb_native
        ./tb_native full > "$HLS_BUILD/tb_full.log"
    ) || die "C model regression failed (see $HLS_BUILD/tb_full.log)"
    grep -E "cases, " "$HLS_BUILD/tb_full.log" || true

    log "Vitis HLS: C sim, synthesis, C/RTL co-sim, export (log in $HLS_BUILD/vitis_hls.log)"
    (
        cd "$HLS_BUILD"
        vitis_hls -f "$HLS/run_hls.tcl" > "$HLS_BUILD/run_hls_console.log" 2>&1
    ) || die "Vitis HLS failed (see $HLS_BUILD/vitis_hls.log)"
    grep -E "^  .* (OK|FAIL)$|cases, |ALL TESTS|TESTS FAILED" "$HLS_SOL/csim/report/min_hamming_hls_csim.log" \
        | grep -v "random case" || true
    grep -q "ALL TESTS PASSED" "$HLS_SOL/csim/report/min_hamming_hls_csim.log" || die "C simulation failed"
    grep -qE "^\| *Verilog *\| *Pass" "$HLS_SOL/sim/report/min_hamming_hls_cosim.rpt" \
        || die "C/RTL co-simulation failed (see $HLS_SOL/sim/report/min_hamming_hls_cosim.rpt)"
    [[ -f "$HLS_SOL/impl/ip/component.xml" ]] || die "IP not exported"
    log "HLS passed: C sim, co-sim, IP in $HLS_SOL/impl/ip"
}

run_hw() {
    log "Building hardware (Vivado batch, full log in $BUILD/vivado_hw.log)"
    rm -f "$BUILD/timing_summary.rpt" "$BUILD/utilization.rpt" "$BUILD/utilization_hier.rpt" "$BUILD/power.rpt"
    (
        cd "$BUILD"
        vivado -mode batch -nojournal -log "$BUILD/vivado_hw.log" -source "$HERE/build_hw.tcl" \
            | { grep --line-buffered -E '^(==== |ERROR|Timing:|HAM |XSA|Bitstream|BUILD_HW)' || true; }
    ) || die "hardware build failed (see $BUILD/vivado_hw.log)"
    [[ -f "$BUILD/ham_v2_zynq.xsa" ]] || die "XSA not produced"
}

run_sw_build() {
    log "Building software (XSCT, full log in $BUILD/xsct_build.log)"
    (
        cd "$BUILD"
        xsct "$HERE/run_sw.tcl" build 2>&1 | tee "$BUILD/xsct_build.log" \
            | { grep --line-buffered -E '^(==== |ERROR|ELF|RUN_SW)|error:|warning:' || true; }
    ) || die "software build failed (see $BUILD/xsct_build.log)"
}

# ---------------------------------------------------------------- UART
find_uart() {
    if [[ -n "${UART_DEV:-}" ]]; then echo "$UART_DEV"; return; fi
    # ZC702: Silicon Labs CP2103 USB-UART on PS UART1
    local d all=()
    for d in /dev/serial/by-id/*CP2103*-port0; do
        [[ -e "$d" ]] && { echo "$d"; return; }
    done
    # Otherwise the only USB serial port present
    for d in /dev/serial/by-id/*; do
        [[ -e "$d" ]] && all+=("$d")
    done
    if (( ${#all[@]} == 1 )); then echo "${all[0]}"; fi
    return 0
}

start_uart_capture() {
    local dev
    dev="$(find_uart)"
    : > "$UART_LOG"
    if [[ -z "$dev" ]]; then
        log "Board UART not found (none or several serial ports); set UART_DEV=/dev/ttyUSBx to capture output"
        return
    fi
    if [[ ! -r "$dev" || ! -w "$dev" ]]; then
        log "No permission on $dev (add yourself to the 'dialout' group); UART not captured"
        return
    fi
    log "Capturing UART from $dev"
    # Re-open the port if it drops out; timeout kills the whole capture when stopped
    timeout 3600 bash -c '
        while :; do
            if stty -F "$1" 115200 cs8 -cstopb -parenb -crtscts -ixon raw -echo 2>/dev/null; then
                cat "$1" >> "$2" 2>/dev/null
            fi
            sleep 0.2
        done' _ "$dev" "$UART_LOG" &
    CAP_PID=$!
}

stop_uart_capture() {
    if [[ -n "$CAP_PID" ]]; then
        kill "$CAP_PID" 2>/dev/null || true
        wait "$CAP_PID" 2>/dev/null || true
        CAP_PID=""
    fi
}

# ---------------------------------------------------------------- results
save() {  # save <source file> <name in the results folder>
    if [[ -f "$1" ]]; then cp "$1" "$RESULTS/$2"; fi
}

save_stage_files() {
    case "$1" in
        hls) save "$HLS_BUILD/tb_full.log" hls_tb_full.log
             save "$HLS_BUILD/vitis_hls.log" hls_vitis_hls.log
             save "$HLS_SOL/csim/report/min_hamming_hls_csim.log" hls_csim.log
             save "$HLS_SOL/syn/report/min_hamming_hls_csynth.rpt" hls_csynth.rpt
             save "$HLS_SOL/sim/report/min_hamming_hls_cosim.rpt" hls_cosim.rpt ;;
        hw)  save "$BUILD/vivado_hw.log" hw_vivado.log
             save "$BUILD/timing_summary.rpt" hw_timing_summary.rpt
             save "$BUILD/utilization.rpt" hw_utilization.rpt
             save "$BUILD/utilization_hier.rpt" hw_utilization_hier.rpt
             save "$BUILD/power.rpt" hw_power.rpt ;;
        sw)  save "$BUILD/xsct_build.log" sw_xsct_build.log ;;
        run) save "$BUILD/xsct_run.log" board_xsct_run.log
             if [[ -s "$UART_LOG" ]]; then
                 tr -cd '\11\12\40-\176' < "$UART_LOG" > "$RESULTS/board_uart.log"
             fi ;;
    esac
}

# One-line key numbers for a passed stage
stage_details() {
    local lut ff bram dsp
    case "$1" in
        hls) echo "native $(grep -m1 'cases, ' "$HLS_BUILD/tb_full.log" | cut -d';' -f1); csim $(grep -m1 'cases, ' "$HLS_SOL/csim/report/min_hamming_hls_csim.log" | cut -d';' -f1); cosim latency $(awk -F'|' '/^\| *Verilog *\| *Pass/ {gsub(/ /, ""); print "min " $4 ", avg " $5 ", max " $6 " cycles"; exit}' "$HLS_SOL/sim/report/min_hamming_hls_cosim.rpt")" ;;
        hw)  lut=$(awk -F'|'  '/^\| Slice LUTs /      {gsub(/ /, "", $3); print $3; exit}' "$BUILD/utilization.rpt")
             ff=$(awk -F'|'   '/^\| Slice Registers / {gsub(/ /, "", $3); print $3; exit}' "$BUILD/utilization.rpt")
             bram=$(awk -F'|' '/^\| Block RAM Tile /  {gsub(/ /, "", $3); print $3; exit}' "$BUILD/utilization.rpt")
             dsp=$(awk -F'|'  '/^\| DSPs /            {gsub(/ /, "", $3); print $3; exit}' "$BUILD/utilization.rpt")
             echo "$(grep -m1 '^Timing:' "$BUILD/vivado_hw.log" | cut -d' ' -f2-); $lut LUTs, $ff FFs, $bram BRAM tiles, $dsp DSPs" ;;
        sw)  awk '$NF == "ham_app.elf" && $1 ~ /^[0-9]+$/ {s = "ELF text " $1 ", data " $2 ", bss " $3 " bytes"}
                  END {print s}' "$BUILD/xsct_build.log" ;;
        run) if [[ -s "$RESULTS/board_uart.log" ]]; then
                 grep -E 'ARM version|PL core  |mismatches' "$RESULTS/board_uart.log" | grep -vE '^ *--' \
                     | sed -E 's/^ +//; s/ +: /: /' | paste -sd '|' | sed 's/|/; /g'
             else
                 echo "UART not captured; $(grep -m1 'JTAG smoke test' "$BUILD/xsct_run.log")"
             fi ;;
    esac 2>/dev/null
}

# EXIT trap: stop the UART capture, then save the results of the stages that ran
finish() {
    local rc=$? s result=PASSED summary
    set +e
    stop_uart_capture
    if (( ${#STAGES_PASSED[@]} == 0 )) && [[ -z "$CUR_STAGE" ]]; then
        exit "$rc"
    fi
    if (( rc != 0 )) || [[ -n "$CUR_STAGE" ]]; then result=FAILED; fi

    mkdir -p "$RESULTS"
    summary="$RESULTS/summary.txt"
    {
        echo "min_Hamming version 2 HLS core - run results"
        echo "date     : $RUN_DATE"
        echo "command  : ./run_all.sh $STAGE"
        echo "duration : $(( EPOCHSECONDS - START_TIME )) s"
        echo "target   : ZC702 (xc7z020clg484-1), Vitis HLS/Vivado/Vitis $XILINX_VER"
        echo
    } > "$summary"
    for s in "${STAGES_PASSED[@]}"; do
        save_stage_files "$s"
        printf '%-4s  PASSED  %s\n' "$s" "$(stage_details "$s")" >> "$summary"
    done
    if [[ -n "$CUR_STAGE" ]]; then
        save_stage_files "$CUR_STAGE"
        printf '%-4s  FAILED  %s\n' "$CUR_STAGE" "${LAST_ERROR:-exit code $rc}" >> "$summary"
    fi
    printf '\nRESULT: %s\n' "$result" >> "$summary"

    printf '%s  %-5s  %-6s  %s\n' "$RUN_DATE" "$STAGE" "$result" "$(basename "$RESULTS")" \
        >> "$HERE/results/history.log"
    ln -sfn "$(basename "$RESULTS")" "$HERE/results/latest"
    log "Results saved in results/$(basename "$RESULTS")"
    exit "$rc"
}
trap finish EXIT

run_board() {
    start_uart_capture
    log "Programming and running the board over JTAG (log in $BUILD/xsct_run.log)"
    (
        cd "$BUILD"
        xsct "$HERE/run_sw.tcl" run 2>&1 | tee "$BUILD/xsct_run.log" \
            | { grep --line-buffered -vE '^\s*$|^\s*[0-9]+%' || true; }
    ) || die "JTAG run failed (see $BUILD/xsct_run.log)"

    [[ -n "$CAP_PID" ]] || { log "Done (UART output not captured)"; return; }

    local i
    for ((i = 0; i < UART_WAIT * 5; i++)); do
        grep -qE "ALL TESTS PASSED|TESTS FAILED" "$UART_LOG" && break
        sleep 0.2
    done
    sleep 0.5
    stop_uart_capture

    log "UART output"
    tr -cd '\11\12\40-\176' < "$UART_LOG"
    echo
    if grep -q "ALL TESTS PASSED" "$UART_LOG"; then
        log "Board test PASSED"
    elif grep -q "TESTS FAILED" "$UART_LOG"; then
        die "Board test FAILED"
    else
        die "No test result on the UART within ${UART_WAIT}s (see $UART_LOG)"
    fi
}

# ---------------------------------------------------------------- main
stage() {  # stage <name> <function>: run it and record the outcome for finish()
    CUR_STAGE="$1"
    "$2"
    STAGES_PASSED+=("$1")
    CUR_STAGE=""
}

case "$STAGE" in
    hls) stage hls run_hls ;;
    hw)  stage hw  run_hw ;;
    sw)  stage sw  run_sw_build ;;
    run) stage run run_board ;;
    build) stage hls run_hls; stage hw run_hw; stage sw run_sw_build ;;
    all) stage hls run_hls; stage hw run_hw; stage sw run_sw_build; stage run run_board ;;
esac
