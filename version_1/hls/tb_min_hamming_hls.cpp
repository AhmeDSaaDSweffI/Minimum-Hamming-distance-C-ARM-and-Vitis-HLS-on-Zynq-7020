// ============================================================================
// tb_min_hamming_hls.cpp - testbench for C simulation and RTL co-simulation
//
// Compares min_hamming_hls() with the unchanged software version 1
// (min_hamming_v1.c, compiled into this testbench) on:
//   1. the 6 hand-computed tests of main.c, plus the error cases
//   2. sizes around the lane width (2, 15, 16, 17, 33, ...) with random words,
//      and pairs placed on the row boundaries of the on-chip copy
//   3. the benchmark input of main.c: N = 5000 MT19937 words, seed 42
//
// Returns 0 when everything matches (Vitis HLS then reports a PASS).
// ============================================================================

#include <cstdio>
#include <cstring>

#include "min_hamming_hls.h"

// Golden reference: the software version 1, unchanged.
#include "min_hamming_v1.c"

// ---------------------------------------------------------------- random data
// MT19937, identical to main.c, so the benchmark uses the same words.
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

// ---------------------------------------------------------------- tests
// The m_axi port has depth HLS_MAX_N, so co-simulation transfers HLS_MAX_N
// words: every test passes this full-size buffer to the accelerator.
static unsigned int words[HLS_MAX_N];

// Copies 'n' test words into the buffer (if not already there), runs the
// accelerator and compares with 'expected'. Returns 1 on failure.
static int check(const char* name, const unsigned int* tab, unsigned int n, int expected)
{
    if (tab != words)
        memcpy(words, tab, n * sizeof(unsigned int));
    int got = min_hamming_hls(words, n);
    printf("  %-40s expected %2d, got %2d  %s\n",
           name, expected, got, (got == expected) ? "OK" : "FAIL");
    return (got == expected) ? 0 : 1;
}

// Fills the buffer with 'n' random words and checks the accelerator against
// the software version 1.
static int check_random(const char* name, unsigned int n)
{
    for (unsigned int k = 0; k < n; k++)
        words[k] = mt_next();
    return check(name, words, n, min_Hamming(words, n));
}

int main()
{
    int failures = 0;
    char name[64];

    // ------------------------------------------------ 1) Hand-computed tests
    printf("1) Hand-computed tests (same as main.c)\n");

    unsigned int t1[] = {0x0, 0xF, 0xFF};
    unsigned int t2[] = {7, 42, 7};
    unsigned int t3[] = {0xA, 0x8, 0xFF00};
    unsigned int t4[] = {0x0, 0x3, 0xF0};
    unsigned int t5[] = {0x0, 0xFFFFFFFF};
    unsigned int t6[] = {123};

    failures += check("general case {0x0, 0xF, 0xFF}", t1, 3, 4);
    failures += check("duplicate {7, 42, 7}", t2, 3, 0);
    failures += check("one bit {0xA, 0x8, 0xFF00}", t3, 3, 1);
    failures += check("two bits {0x0, 0x3, 0xF0}", t4, 3, 2);
    failures += check("max distance {0, 0xFFFFFFFF}", t5, 2, 32);
    failures += check("single word {123}", t6, 1, -1);
    failures += check("no word (tab_size = 0)", t6, 0, -1);
    failures += check("too many words (HLS_MAX_N + 1)", words, HLS_MAX_N + 1, -2);

    // ------------------------------------------------ 2) Lane / row edges
    printf("\n2) Sizes around the lane width (%d), random words vs software v1\n", HLS_LANES);
    mt_seed(1);
    const unsigned int sizes[] = {2, 3, 15, 16, 17, 31, 32, 33, 100, 1000, HLS_MAX_N};
    for (unsigned int s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++)
    {
        snprintf(name, sizeof(name), "random, N = %u", sizes[s]);
        failures += check_random(name, sizes[s]);
    }

    // The closest pair sits on row boundaries of the on-chip copy: the first
    // and the last word, then the last word of row 0 and the first of row 1.
    // (Random words are almost never closer than 5 bits, so these pairs are
    // the minimum; the expected value comes from software v1 anyway.)
    for (unsigned int k = 0; k < 33; k++)
        words[k] = mt_next();
    words[32] = words[0];                              // distance 0
    failures += check("pair (0, 32), N = 33", words, 33, min_Hamming(words, 33));

    for (unsigned int k = 0; k < 40; k++)
        words[k] = mt_next();
    words[HLS_LANES] = words[HLS_LANES - 1] ^ 0x1u;    // distance 1
    failures += check("pair across rows 0 and 1, N = 40", words, 40, min_Hamming(words, 40));

    // ------------------------------------------------ 3) Benchmark input
    printf("\n3) Benchmark input of main.c\n");
    mt_seed(42);
    failures += check_random("N = 5000 random words, seed 42", 5000);

    printf("\n%s\n", (failures == 0) ? "ALL TESTS PASSED" : "TESTS FAILED");
    return (failures == 0) ? 0 : 1;
}
