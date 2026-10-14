// ============================================================================
// main.c - test + benchmark driver for version 1.
//
// Runs 6 small correctness tests on min_Hamming, then times it on N random
// words. version_2/main.c is the same program (same tests, same random
// data, same timing), so the two versions can be compared fairly later.
//
// Build: gcc -O2 -mpopcnt -Wall -std=c11 main.c min_hamming_v1.c -o ham_v1
// Usage: ./ham_v1 [N]      (N = number of random words, default 5000)
// ============================================================================

#define _POSIX_C_SOURCE 199309L  // for clock_gettime with -std=c11

#include <ctype.h>   // isdigit
#include <errno.h>   // errno
#include <limits.h>  // UINT_MAX
#include <stdio.h>   // printf
#include <stdlib.h>  // malloc, free, strtoul
#include <time.h>    // clock_gettime (wall-clock timing)

// Declaration of the function under test. Its body is in min_hamming_v1.c.
int min_Hamming(unsigned int tab[], unsigned int tab_size);

// ---------------------------------------------------------------- random data
// MT19937 (Mersenne Twister), the standard generator also used by C++'s
// std::mt19937: with the same seed it always produces the same numbers.
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
    if (mt_index == 624)  // all 624 numbers used: generate the next block
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
// Runs one small test whose answer was computed by hand.
// Returns 1 if the test failed, 0 if it passed (so we can add up failures).
static int check(const char* name, unsigned int tab[], unsigned int size, int expected)
{
    int got = min_Hamming(tab, size);
    printf("  %-34s expected %2d, got %2d  %s\n",
           name, expected, got, (got == expected) ? "OK" : "FAIL");
    return (got == expected) ? 0 : 1;
}

int main(int argc, char* argv[])
{
    // Read N from the command line, or use 5000 by default. Only plain
    // numbers are accepted ("-5" would otherwise become a huge unsigned value).
    unsigned long n = 5000;
    if (argc > 1)
    {
        char* end;
        errno = 0;
        n = strtoul(argv[1], &end, 10);
        if (!isdigit((unsigned char)argv[1][0]) || *end != '\0' || errno != 0 || n > UINT_MAX)
        {
            fprintf(stderr, "usage: %s [N]   (N = number of random words, 0 to %u)\n", argv[0], UINT_MAX);
            return 2;
        }
    }

    // ------------------------------------------------ 1) Correctness tests
    printf("Correctness tests:\n");

    unsigned int t1[] = {0x0, 0xF, 0xFF};    // 0 vs 0xF differ in 4 bits   -> 4
    unsigned int t2[] = {7, 42, 7};          // 7 appears twice             -> 0
    unsigned int t3[] = {0xA, 0x8, 0xFF00};  // 1010 vs 1000: 1 bit         -> 1
    unsigned int t4[] = {0x0, 0x3, 0xF0};    // 00 vs 11: 2 bits            -> 2
    unsigned int t5[] = {0x0, 0xFFFFFFFF};   // every bit differs           -> 32
    unsigned int t6[] = {123};               // a single word, no pair      -> -1

    int failures = 0;
    failures += check("general case {0x0, 0xF, 0xFF}", t1, 3, 4);
    failures += check("duplicate {7, 42, 7}", t2, 3, 0);
    failures += check("one bit {0xA, 0x8, 0xFF00}", t3, 3, 1);
    failures += check("two bits {0x0, 0x3, 0xF0}", t4, 3, 2);
    failures += check("max distance {0, 0xFFFFFFFF}", t5, 2, 32);
    failures += check("single word {123}", t6, 1, -1);

    // ------------------------------------------------ 2) Benchmark
    // Allocate the array on the heap so that Massif (memory profiler) sees it.
    unsigned int* tab = malloc(n * sizeof(unsigned int));
    if (tab == NULL && n > 0)
    {
        fprintf(stderr, "not enough memory for %lu words\n", n);
        return 2;
    }

    // Fill it with random 32-bit words. The fixed seed (42) gives the same
    // data on every run, so both versions are compared on identical input.
    mt_seed(42);
    for (unsigned long i = 0; i < n; i++)
        tab[i] = mt_next();

    // Measure only the call to min_Hamming.
    struct timespec start, stop;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int result = min_Hamming(tab, (unsigned int)n);
    clock_gettime(CLOCK_MONOTONIC, &stop);

    double ms = (stop.tv_sec - start.tv_sec) * 1e3 + (stop.tv_nsec - start.tv_nsec) / 1e6;
    printf("\nBenchmark: N = %lu random words -> min Hamming distance = %d (%.3f ms)\n",
           n, result, ms);

    free(tab);

    // Exit code 0 = all tests passed, 1 = at least one failed.
    return (failures == 0) ? 0 : 1;
}
