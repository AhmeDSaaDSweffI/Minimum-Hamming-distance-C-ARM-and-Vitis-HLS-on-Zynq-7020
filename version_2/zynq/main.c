/*
 * main.c : bare-metal test of the version 2 HLS core (min_hamming_hls) on the ZC702
 *
 * Runs on ps7_cortexa9_0 (standalone BSP). Output goes to stdout, which is
 * PS UART1 (MIO 48/49, the board's CP2103 USB-UART), 115200 8N1.
 *
 *   1. The 6 correctness tests of ../main.c, on the core
 *   2. Edge cases: 0 and 1 words, MAX_N + 1 words (too big for the core)
 *   3. Benchmark: N = 5000 MT19937 words (seed 42, the array of ../main.c),
 *      on the ARM (version 1 and version 2, the same C code as on the PC)
 *      and on the PL core: answer and time of each
 *   4. Random regression: core vs ARM version 2, answer and deciding step
 *
 * The core reads the words from DDR through S_AXI_HP0, which does not see the
 * ARM data cache, so every call flushes the array from the cache first.
 *
 * The last line is "ALL TESTS PASSED" or "TESTS FAILED" (run_all.sh looks for
 * these).
 */

#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xstatus.h"
#include "xtime_l.h"
#include "xmin_hamming_hls.h"
#include "min_hamming_hls.h"          /* MAX_N, TOO_BIG (../hls) */

/* AXI base address of the core's registers; fixed by build_hw.tcl (ham_base) */
#define HAM_BASEADDR    0x43C00000U

/* The slowest call (MAX_N words, all pairs) takes about 6 ms; give up after 1 s */
#define HAM_TIMEOUT_S   1U

#define BENCH_N         5000U
#define BENCH_HW_RUNS   10U
#define BENCH_V2_RUNS   5U
#define NUM_RANDOM      300U

/* Software versions, the same C files as on the PC */
int min_Hamming(unsigned int tab[], unsigned int tab_size);      /* ../min_hamming_v2.c */
int min_Hamming_v1(unsigned int tab[], unsigned int tab_size);   /* ham_v1_arm.c */

static XMin_hamming_hls ham;

/* Input arrays in DDR, cache-line aligned so a flush covers exactly them.
 * unsigned int, not u32 (unsigned long in this BSP), to match min_Hamming(). */
static unsigned int bench[MAX_N + 1] __attribute__((aligned(32)));
static unsigned int buf[MAX_N + 1] __attribute__((aligned(32)));

/* ---------------------------------------------------------------- core */

/*
 * Runs the core on tab[0..n-1]. ns (optional) receives the time from START to
 * DONE, register writes included, cache flush excluded.
 * Returns XST_SUCCESS, or XST_FAILURE if DONE never comes.
 */
static int ham_hw(const unsigned int *tab, u32 n, int *result, u32 *stage, u64 *ns)
{
    XTime t0, t1, deadline;

    Xil_DCacheFlushRange((INTPTR)tab, (n + 1U) * sizeof(u32));

    XTime_GetTime(&t0);
    deadline = t0 + (XTime)HAM_TIMEOUT_S * COUNTS_PER_SECOND;
    XMin_hamming_hls_Set_tab(&ham, (u32)(UINTPTR)tab);
    XMin_hamming_hls_Set_tab_size(&ham, n);
    XMin_hamming_hls_Start(&ham);
    while (XMin_hamming_hls_IsDone(&ham) == 0U) {
        XTime_GetTime(&t1);
        if (t1 > deadline) {
            *result = -99;
            *stage = 99U;
            return XST_FAILURE;
        }
    }
    XTime_GetTime(&t1);

    *result = (int)XMin_hamming_hls_Get_return(&ham);
    *stage = XMin_hamming_hls_Get_stage(&ham);
    if (ns != NULL) {
        *ns = ((t1 - t0) * 1000000000ULL) / COUNTS_PER_SECOND;
    }
    return XST_SUCCESS;
}

/* Step that decides answer a in version 2: 0 -> 1, 1 -> 2, >= 2 -> 3 */
static u32 expected_stage(int a)
{
    if (a < 0) {
        return 0U;
    }
    return (a == 0) ? 1U : ((a == 1) ? 2U : 3U);
}

/* ---------------------------------------------------------------- printing */

/* xil_printf has no floating point: prints ns as "m.uuu ms" */
static void print_ms(u64 ns)
{
    u64 us = ns / 1000U;
    xil_printf("%u.%03u ms", (u32)(us / 1000U), (u32)(us % 1000U));
}

/* Prints a / b with one decimal ("12.3x") */
static void print_ratio(u64 a, u64 b)
{
    u64 r = (b == 0U) ? 0U : (a * 10U + b / 2U) / b;
    xil_printf("%u.%ux", (u32)(r / 10U), (u32)(r % 10U));
}

static u64 sw_ns(XTime t0, XTime t1)
{
    return ((t1 - t0) * 1000000000ULL) / COUNTS_PER_SECOND;
}

/* ---------------------------------------------------------------- data */

/* MT19937, as in ../main.c (same seed -> same benchmark array) */
static u32 mt[624];
static int mt_index;

static void mt_seed(u32 seed)
{
    int i;

    mt[0] = seed;
    for (i = 1; i < 624; i++) {
        mt[i] = 1812433253U * (mt[i - 1] ^ (mt[i - 1] >> 30)) + (u32)i;
    }
    mt_index = 624;
}

static u32 mt_next(void)
{
    int i;
    u32 y;

    if (mt_index == 624) {
        for (i = 0; i < 624; i++) {
            y = (mt[i] & 0x80000000U) | (mt[(i + 1) % 624] & 0x7FFFFFFFU);
            mt[i] = mt[(i + 397) % 624] ^ (y >> 1) ^ (((y & 1U) != 0U) ? 0x9908B0DFU : 0U);
        }
        mt_index = 0;
    }
    y = mt[mt_index++];
    y ^= y >> 11;
    y ^= (y << 7) & 0x9D2C5680U;
    y ^= (y << 15) & 0xEFC60000U;
    y ^= y >> 18;
    return y;
}

/* xorshift32 for the regression arrays (same generator as the HLS testbench) */
static u32 rng_state = 0x2545F491U;

static u32 rng_next(void)
{
    u32 x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/* buf[b] = buf[a] with 'flips' different bits flipped: some pair at distance <= flips */
static void plant_pair(u32 n, u32 flips)
{
    u32 a = rng_next() % n, b = rng_next() % n, w, used = 0U, f, bit;

    if (a == b) {
        b = (a + 1U) % n;
    }
    w = buf[a];
    for (f = 0U; f < flips; f++) {
        do {
            bit = rng_next() % 32U;
        } while ((used & (1U << bit)) != 0U);
        used |= 1U << bit;
        w ^= 1U << bit;
    }
    buf[b] = w;
}

/* Mix of sizes and shapes, so that all three steps decide some arrays */
static u32 random_array(u32 r)
{
    u32 n, i, mask;

    switch (r % 8U) {
    case 0U:  n = 2U + rng_next() % 30U;   break;
    case 1U:  n = 2U + rng_next() % 300U;  break;
    case 7U:  n = 2U + rng_next() % MAX_N; break;
    default:  n = 2U + rng_next() % 2000U; break;
    }
    mask = 0xFFFFFFFFU;
    if ((r / 8U) % 5U == 1U) {
        mask = (1U << (6U + rng_next() % 14U)) - 1U;    /* few bits: duplicates */
    }
    for (i = 0U; i < n; i++) {
        buf[i] = rng_next() & mask;
    }
    switch ((r / 8U) % 5U) {
    case 2U:  plant_pair(n, 1U); break;
    case 3U:  plant_pair(n, 2U); break;
    case 4U:  plant_pair(n, 3U + rng_next() % 4U); break;
    default:  break;
    }
    return n;
}

/* ---------------------------------------------------------------- tests */

typedef struct {
    const char *name;
    u32 n;
    u32 words[3];
    int expected;
} small_test;

/* The 6 tests of ../main.c, with their hand-computed answers */
static const small_test small_tests[] = {
    {"general case {0x0, 0xF, 0xFF}", 3U, {0x0U, 0xFU, 0xFFU},   4},
    {"duplicate {7, 42, 7}",          3U, {7U, 42U, 7U},         0},
    {"one bit {0xA, 0x8, 0xFF00}",    3U, {0xAU, 0x8U, 0xFF00U}, 1},
    {"two bits {0x0, 0x3, 0xF0}",     3U, {0x0U, 0x3U, 0xF0U},   2},
    {"max distance {0, 0xFFFFFFFF}",  2U, {0x0U, 0xFFFFFFFFU},   32},
    {"single word {123}",             1U, {123U},                -1},
};

/* One core call checked against an expected answer; returns 1 on failure */
static u32 check_core(const char *name, const unsigned int *tab, u32 n, int expected)
{
    int got;
    u32 stage;
    int ok;

    ok = (ham_hw(tab, n, &got, &stage, NULL) == XST_SUCCESS)
         && (got == expected) && (stage == expected_stage(expected));
    xil_printf("  %-34s expected %2d, got %2d (step %u)  %s\r\n",
               name, expected, got, stage, ok ? "OK" : "FAIL");
    return ok ? 0U : 1U;
}

int main(void)
{
    XMin_hamming_hls_Config cfg;
    u32 failures = 0U, i, r, n, stage, mismatches = 0U;
    u32 decided[4] = {0U, 0U, 0U, 0U};
    int hw, sw, v1, v2;
    XTime t0, t1;
    u64 ns, hw_min = ~0ULL, hw_max = 0U, v1_ns, v2_ns = ~0ULL;

    xil_printf("\r\n==== min_Hamming version 2 on the ZC702: ARM vs PL (HLS core) ====\r\n");
    cfg.DeviceId = 0U;
    cfg.Control_BaseAddress = HAM_BASEADDR;
    if (XMin_hamming_hls_CfgInitialize(&ham, &cfg) != XST_SUCCESS) {
        xil_printf("core driver init failed\r\nTESTS FAILED\r\n");
        return 1;
    }
    xil_printf("HLS core at 0x%08x, MAX_N = %u words, %s\r\n", HAM_BASEADDR, (u32)MAX_N,
               XMin_hamming_hls_IsIdle(&ham) ? "idle" : "NOT IDLE");

    /* 1) The 6 tests of main.c */
    xil_printf("\r\n-- Correctness tests (main.c), PL core --\r\n");
    for (i = 0U; i < sizeof(small_tests) / sizeof(small_tests[0]); i++) {
        for (n = 0U; n < small_tests[i].n; n++) {
            buf[n] = small_tests[i].words[n];
        }
        failures += check_core(small_tests[i].name, buf, small_tests[i].n, small_tests[i].expected);
    }

    /* 2) Edge cases */
    xil_printf("\r\n-- Edge cases, PL core --\r\n");
    failures += check_core("empty array", buf, 0U, -1);
    for (i = 0U; i <= MAX_N; i++) {
        buf[i] = rng_next();
    }
    failures += check_core("MAX_N + 1 words (too big)", buf, MAX_N + 1U, TOO_BIG);

    /* 3) Benchmark: the array of main.c */
    xil_printf("\r\n-- Benchmark: N = %u random words (MT19937, seed 42) --\r\n", BENCH_N);
    mt_seed(42U);
    for (i = 0U; i < BENCH_N; i++) {
        bench[i] = mt_next();
    }

    XTime_GetTime(&t0);
    v1 = min_Hamming_v1(bench, BENCH_N);
    XTime_GetTime(&t1);
    v1_ns = sw_ns(t0, t1);

    for (r = 0U; r < BENCH_V2_RUNS; r++) {
        XTime_GetTime(&t0);
        v2 = min_Hamming(bench, BENCH_N);
        XTime_GetTime(&t1);
        ns = sw_ns(t0, t1);
        v2_ns = (ns < v2_ns) ? ns : v2_ns;
    }

    hw = -99;
    stage = 99U;
    for (r = 0U; r < BENCH_HW_RUNS; r++) {
        if (ham_hw(bench, BENCH_N, &hw, &stage, &ns) != XST_SUCCESS) {
            break;
        }
        hw_min = (ns < hw_min) ? ns : hw_min;
        hw_max = (ns > hw_max) ? ns : hw_max;
    }

    xil_printf("  ARM version 1 : distance %d, ", v1);  print_ms(v1_ns);  xil_printf("\r\n");
    xil_printf("  ARM version 2 : distance %d, ", v2);  print_ms(v2_ns);
    xil_printf("  (fastest of %u)\r\n", BENCH_V2_RUNS);
    xil_printf("  PL core       : distance %d, ", hw);  print_ms(hw_min);
    xil_printf(" .. ");  print_ms(hw_max);
    xil_printf("  (%u runs, decided in step %u)\r\n", BENCH_HW_RUNS, stage);
    xil_printf("  speed-up      : PL vs ARM v2 ");  print_ratio(v2_ns, hw_min);
    xil_printf(", PL vs ARM v1 ");  print_ratio(v1_ns, hw_min);  xil_printf("\r\n");
    if (v1 != 2 || v2 != 2 || hw != 2 || stage != 3U) {
        xil_printf("  benchmark FAIL: expected distance 2 (step 3) everywhere\r\n");
        failures++;
    }

    /* 4) Random regression against ARM version 2 */
    xil_printf("\r\n-- Random regression: %u arrays, PL core vs ARM version 2 --\r\n", NUM_RANDOM);
    for (r = 0U; r < NUM_RANDOM; r++) {
        n = random_array(r);
        sw = min_Hamming(buf, n);
        if (ham_hw(buf, n, &hw, &stage, NULL) != XST_SUCCESS || hw != sw
            || stage != expected_stage(sw)) {
            if (mismatches < 10U) {
                xil_printf("  array %u (n = %u): core %d (step %u), ARM %d  FAIL\r\n",
                           r, n, hw, stage, sw);
            }
            mismatches++;
        } else {
            decided[stage]++;
        }
    }
    xil_printf("  %u mismatches; decided by step 1: %u, step 2: %u, step 3: %u\r\n",
               mismatches, decided[1], decided[2], decided[3]);
    failures += mismatches;

    xil_printf("\r\n%u failures\r\n", failures);
    xil_printf(failures == 0U ? "ALL TESTS PASSED\r\n" : "TESTS FAILED\r\n");
    return 0;
}
