// ============================================================================
// tb_min_hamming_hls.cpp - testbench for the version 2 FPGA core
//
// Every case runs on the core (min_hamming_hls) and on the software version 2
// (min_Hamming in ../min_hamming_v2.c). The answers must match, and so must
// the step that decided it (0 -> step 1, 1 -> step 2, >= 2 -> step 3).
//
// Three sets of cases (argument 1):
//   quick     the 6 tests of main.c, the benchmark and a few small cases:
//             C/RTL co-simulation, since the RTL simulation is far slower
//   (none)    quick + MAX_N-sized cases + 200 small random arrays: C simulation
//             (Vitis HLS builds it at -O1, where ap_uint code runs slowly)
//   full      standard + slow MAX_N cases + 400 random arrays of every size:
//             run_all.sh builds it natively with g++ -O2 (about 1 minute)
//
// Exit code 0 = every case passed (Vitis HLS reports a failure otherwise).
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "min_hamming_hls.h"

// Software version 2, the reference (C code, compiled as C)
extern "C" int min_Hamming(unsigned int tab[], unsigned int tab_size);

// ---------------------------------------------------------------- random data
// MT19937, the same generator and seed as ../main.c, so the benchmark array
// is the one version 1 and version 2 were measured on.
static unsigned int mt[624];
static int mt_index;

static void mt_seed(unsigned int seed)
{
    mt[0] = seed;
    for (int i = 1; i < 624; i++)
        mt[i] = 1812433253u * (mt[i - 1] ^ (mt[i - 1] >> 30)) + (unsigned int)i;
    mt_index = 624;
}

static unsigned int mt_next(void)
{
    if (mt_index == 624)
    {
        for (int i = 0; i < 624; i++)
        {
            unsigned int y = (mt[i] & 0x80000000u) | (mt[(i + 1) % 624] & 0x7FFFFFFFu);
            mt[i] = mt[(i + 397) % 624] ^ (y >> 1) ^ ((y & 1u) ? 0x9908B0DFu : 0u);
        }
        mt_index = 0;
    }
    unsigned int y = mt[mt_index++];
    y ^= y >> 11;
    y ^= (y << 7) & 0x9D2C5680u;
    y ^= (y << 15) & 0xEFC60000u;
    y ^= y >> 18;
    return y;
}

// xorshift32 for the regression cases (any fixed generator would do)
static unsigned int rng_state = 0x2545F491u;

static unsigned int rng_next(void)
{
    unsigned int x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

// ---------------------------------------------------------------- one case
// The core reads MAX_N words through its AXI master in co-simulation, so its
// input buffer always has room for MAX_N + 1 words.
static unsigned int core_buf[MAX_N + 1];
static unsigned int ref_buf[MAX_N + 1];
static unsigned int data[MAX_N + 1];

static int cases = 0, failures = 0;
static int decided[4] = {0, 0, 0, 0};

static unsigned int expected_stage(int answer)
{
    if (answer < 0)  return 0;
    if (answer == 0) return 1;
    if (answer == 1) return 2;
    return 3;
}

// Runs data[0..n-1] on both versions. expected = -99 means "whatever the
// software says". Returns 1 if the case failed.
static int run_case(const char* name, unsigned int n, int expected, bool verbose)
{
    memcpy(core_buf, data, n * sizeof(unsigned int));
    memcpy(ref_buf, data, n * sizeof(unsigned int));

    unsigned int stage = 99;
    int got = min_hamming_hls(core_buf, n, &stage);
    int ref = (n <= MAX_N) ? min_Hamming(ref_buf, n) : TOO_BIG;
    if (expected == -99)
        expected = ref;

    bool ok = (got == expected) && (ref == expected) && (stage == expected_stage(expected))
              && memcmp(core_buf, data, n * sizeof(unsigned int)) == 0;   // tab[] unchanged
    cases++;
    if (ok && stage <= 3)
        decided[stage]++;
    if (!ok)
        failures++;
    if (verbose || !ok)
        printf("  %-38s n=%-5u expected %2d, core %2d (step %u), software %2d  %s\n",
               name, n, expected, got, stage, ref, ok ? "OK" : "FAIL");
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------- data shapes
static void fill_random(unsigned int n)
{
    for (unsigned int i = 0; i < n; i++)
        data[i] = rng_next();
}

// Only the low 'bits' bits random: duplicates when 2^bits is small next to n
static void fill_low_bits(unsigned int n, int bits)
{
    unsigned int mask = (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    for (unsigned int i = 0; i < n; i++)
        data[i] = rng_next() & mask;
}

// Makes data[b] = data[a] with 'flips' different bits flipped (a != b),
// so some pair is at distance <= flips.
static void plant_pair(unsigned int n, int flips)
{
    unsigned int a = rng_next() % n, b = rng_next() % n;
    if (a == b)
        b = (a + 1) % n;
    unsigned int w = data[a], used = 0;
    for (int f = 0; f < flips; f++)
    {
        unsigned int bit;
        do
            bit = rng_next() % 32;
        while (used & (1u << bit));
        used |= 1u << bit;
        w ^= 1u << bit;
    }
    data[b] = w;
}

// ---------------------------------------------------------------- tests
int main(int argc, char* argv[])
{
    const bool quick = (argc > 1 && strcmp(argv[1], "quick") == 0);
    const bool full  = (argc > 1 && strcmp(argv[1], "full") == 0);
    printf("min_hamming_hls testbench (%s): MAX_N=%d, LANES=%d, LOOKUPS=%d\n",
           quick ? "quick" : (full ? "full" : "standard"), MAX_N, LANES, LOOKUPS);

    // 1) The 6 correctness tests of main.c, with the hand-computed answers
    printf("Correctness tests (main.c):\n");
    {
        static const unsigned int t1[] = {0x0, 0xF, 0xFF};
        static const unsigned int t2[] = {7, 42, 7};
        static const unsigned int t3[] = {0xA, 0x8, 0xFF00};
        static const unsigned int t4[] = {0x0, 0x3, 0xF0};
        static const unsigned int t5[] = {0x0, 0xFFFFFFFF};
        static const unsigned int t6[] = {123};
        memcpy(data, t1, sizeof t1); run_case("general case {0x0, 0xF, 0xFF}", 3, 4, true);
        memcpy(data, t2, sizeof t2); run_case("duplicate {7, 42, 7}", 3, 0, true);
        memcpy(data, t3, sizeof t3); run_case("one bit {0xA, 0x8, 0xFF00}", 3, 1, true);
        memcpy(data, t4, sizeof t4); run_case("two bits {0x0, 0x3, 0xF0}", 3, 2, true);
        memcpy(data, t5, sizeof t5); run_case("max distance {0, 0xFFFFFFFF}", 2, 32, true);
        memcpy(data, t6, sizeof t6); run_case("single word {123}", 1, -1, true);
    }

    // 2) The benchmark array of main.c: N = 5000, MT19937 seed 42 -> 2
    printf("Benchmark array:\n");
    mt_seed(42);
    for (unsigned int i = 0; i < 5000; i++)
        data[i] = mt_next();
    run_case("N = 5000, MT19937 seed 42", 5000, 2, true);

    // 3) Edge cases
    printf("Edge cases:\n");
    run_case("empty array", 0, -1, true);
    fill_random(MAX_N + 1);
    run_case("MAX_N + 1 words (too big for the core)", MAX_N + 1, TOO_BIG, true);
    data[0] = 0x80000000u; data[1] = 0x0u;
    run_case("bit 31 only {0x80000000, 0}", 2, 1, true);
    for (unsigned int i = 0; i < 20; i++)
        data[i] = 1000u - i;
    run_case("descending 1000..981 (distance 1)", 20, 1, true);
    fill_random(40);
    run_case("40 random words", 40, -99, true);
    fill_random(40); data[39] = data[3];
    run_case("40 random words + duplicate", 40, 0, true);
    fill_random(100); plant_pair(100, 2);
    run_case("100 random words + 2-bit pair", 100, -99, true);

    if (!quick)
    {
        for (unsigned int i = 0; i < MAX_N; i++)
            data[i] = 7u;
        run_case("MAX_N equal words", MAX_N, 0, true);
        // Two multiples of 3 never differ in one bit (2^b is not a multiple
        // of 3), so step 2 finds nothing and step 3 stops at 0 vs 3 -> 2
        for (unsigned int i = 0; i < MAX_N; i++)
            data[i] = i * 3u;
        run_case("MAX_N multiples of 3", MAX_N, 2, true);
        fill_random(MAX_N); plant_pair(MAX_N, 1);
        run_case("MAX_N random + 1-bit pair", MAX_N, -99, true);
        // The largest word sits at sorted position MAX_N - 1, the register 'last'
        fill_random(MAX_N);
        data[MAX_N - 1] = 0xFFFFFFFFu; data[17] = 0xFFFFFFFEu;
        run_case("MAX_N, 1-bit pair at the largest word", MAX_N, -99, true);
        if (full)
        {
            // Step 3 runs for thousands of rows here: slow in C simulation
            fill_random(MAX_N); plant_pair(MAX_N, 2);
            run_case("MAX_N random + 2-bit pair", MAX_N, -99, true);
            mt_seed(42);
            for (unsigned int i = 0; i < 8000; i++)
                data[i] = mt_next();
            run_case("N = 8000, MT19937 seed 42", 8000, -99, true);
        }

        // 4) Random regression: sizes and shapes mixed so that all three
        //    steps decide some cases (small sizes only, unless full)
        printf("Random regression:\n");
        const int runs = full ? 400 : 200;
        for (int r = 0; r < runs; r++)
        {
            unsigned int n;
            switch (r % 8)
            {
                case 0:  n = 2 + rng_next() % 30; break;
                case 1:  n = 2 + rng_next() % 300; break;
                case 7:  n = 2 + rng_next() % (full ? MAX_N : 300); break;
                default: n = 2 + rng_next() % (full ? 2000 : 300); break;
            }
            switch ((r / 8) % 5)
            {
                case 0: fill_random(n); break;
                case 1: fill_low_bits(n, 6 + rng_next() % 14); break;
                case 2: fill_random(n); plant_pair(n, 1); break;
                case 3: fill_random(n); plant_pair(n, 2); break;
                default: fill_random(n); plant_pair(n, 3 + rng_next() % 4); break;
            }
            char name[64];
            snprintf(name, sizeof name, "random case %d", r);
            run_case(name, n, -99, false);
        }
        printf("  %d random cases run\n", runs);
    }

    printf("\n%d cases, %d failures; decided by step 1: %d, step 2: %d, step 3: %d\n",
           cases, failures, decided[1], decided[2], decided[3]);
    printf(failures == 0 ? "ALL TESTS PASSED\n" : "TESTS FAILED\n");
    return failures == 0 ? 0 : 1;
}
