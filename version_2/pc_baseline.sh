#!/usr/bin/env bash
# ============================================================================
# pc_baseline.sh : PC measurements of software version 2, and version 1 vs 2
# ----------------------------------------------------------------------------
# Usage (from version_2/):  ./pc_baseline.sh
#
# Writes, next to this script:
#   time.v2.log         scalar build (the build line in main.c): /usr/bin/time -v
#                       on the first run, then 14 more runs of the N = 5000 benchmark
#   time.v2.native.log  the same with -O3 -march=native (the build of time.v1.native.log)
#   compare_v1_v2.log   version 1 and version 2 built the same way (-O3 -march=native
#                       -mno-avx512f: Valgrind cannot run AVX-512 code) for several N:
#                       answer, median time of 5 runs and Massif peak heap
#
# The binaries are built in a temporary folder, so ham_v2 (the build profiled in
# callgrind.v2.out and massif.v2.out) is not touched. Takes about a minute.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1="$HERE/../version_1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCALAR="gcc -O2 -g -mpopcnt -Wall -std=c11"
NATIVE="gcc -O3 -march=native -g -std=c11"
SWEEP="gcc -O3 -march=native -mno-avx512f -g -std=c11"
RUNS=15
SIZES="1000 2000 5000 10000 20000"

# time_log <log> <binary> <build line> <note>
time_log() {
    {
        echo "# build: $3   ($4)"
        /usr/bin/time -v "$2" 5000 2>&1
        for ((i = 1; i < RUNS; i++)); do
            "$2" 5000 | tail -n 1
        done
    } > "$1"
    echo "wrote $1"
}

# median_ms <binary> <n>: median of 5 runs of the benchmark time printed by main.c
median_ms() {
    for i in 1 2 3 4 5; do "$1" "$2" | grep -o '([0-9.]* ms)' | tr -d '(ms)'; done | sort -n | sed -n 3p | tr -d ' '
}

# peak_heap <binary> <n>: Massif peak heap in bytes (stdout to /dev/null: printf buffer is 4,096 B)
peak_heap() {
    valgrind --tool=massif --stacks=no --peak-inaccuracy=0.0 --massif-out-file="$TMP/massif.out" \
        "$1" "$2" > /dev/null 2>&1
    grep -B3 'heap_tree=peak' "$TMP/massif.out" | sed -n 's/^mem_heap_B=//p' || true
}

cd "$HERE"
$SCALAR main.c min_hamming_v2.c -o "$TMP/ham_v2_scalar"
$NATIVE main.c min_hamming_v2.c -o "$TMP/ham_v2_native"
$SWEEP main.c min_hamming_v2.c -o "$TMP/ham_v2_sweep"
(cd "$V1" && $SWEEP main.c min_hamming_v1.c -o "$TMP/ham_v1_sweep")

time_log time.v2.log "$TMP/ham_v2_scalar" "$SCALAR main.c min_hamming_v2.c -o ham_v2" \
    "scalar build, the build line in main.c"
time_log time.v2.native.log "$TMP/ham_v2_native" "$NATIVE main.c min_hamming_v2.c -o ham_v2" \
    "Tiger Lake, -O3 -march=native"

{
    echo "# version 1 and version 2, both built with: $SWEEP main.c min_hamming_vN.c"
    echo "# time: median of 5 runs of the min_Hamming call (main.c's clock_gettime), ms"
    echo "# heap: Massif peak heap, bytes (includes the 4,096 B stdout buffer of printf)"
    printf "%6s %6s %10s %10s %8s %10s %10s\n" N answer v1_ms v2_ms v1/v2 v1_heap v2_heap
    for n in $SIZES; do
        ans=$("$TMP/ham_v2_sweep" "$n" | grep -o 'distance = [-0-9]*' | cut -d' ' -f3)
        t1=$(median_ms "$TMP/ham_v1_sweep" "$n")
        t2=$(median_ms "$TMP/ham_v2_sweep" "$n")
        h1=$(peak_heap "$TMP/ham_v1_sweep" "$n")
        h2=$(peak_heap "$TMP/ham_v2_sweep" "$n")
        [[ -n "$h1" && -n "$h2" ]] || { echo "Massif failed for N = $n" >&2; exit 1; }
        printf "%6s %6s %10s %10s %7.1fx %10s %10s\n" "$n" "$ans" "$t1" "$t2" "$(echo "$t1 / $t2" | bc -l)" "$h1" "$h2"
    done
} > compare_v1_v2.log
echo "wrote compare_v1_v2.log"
cat compare_v1_v2.log
