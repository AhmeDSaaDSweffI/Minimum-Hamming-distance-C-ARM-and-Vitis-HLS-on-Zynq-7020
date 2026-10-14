// ============================================================================
// Version 2 - Time-optimized approach (pure C)
//
// Three ideas, applied from the cheapest check to the most expensive one:
//
//   Step 1 - Distance 0 (duplicates): sort a copy of the array. Equal words
//            end up next to each other, so ONE pass finds them.
//            Cost: O(N log N) instead of O(N^2).
//
//   Step 2 - Distance 1: two words are at distance 1 if one is the other with
//            exactly ONE bit flipped. For each word we build its 32 "one-bit
//            neighbours" and look for them in the sorted copy with binary
//            search. Cost: O(32 * N log N) instead of O(N^2).
//
//   Step 3 - Distance >= 2: fall back to comparing all pairs, but count bits
//            with ONE hardware instruction (POPCNT) instead of a 32-step loop,
//            and stop as soon as we find distance 2 (the smallest value still
//            possible after steps 1 and 2).
//
// Time  : O(N log N) when the answer is 0 or 1,
//         O(N^2) worst case, but each pair costs ~8 instructions instead of
//         ~267 in version 1 (measured with Callgrind and objdump)
// Memory: O(N) -> one sorted copy of the input, 4*N bytes (we must not modify
//         tab[]). glibc's qsort also borrows another 4*N bytes while it sorts,
//         so the peak is +8*N bytes (measured with Valgrind's Massif).
//
// Compile with -mpopcnt (or -march=native) so that the bit count becomes the
// single POPCNT CPU instruction.
// ============================================================================

#include <stdlib.h>  // malloc, free, qsort
#include <string.h>  // memcpy

// POPCOUNT32(x) = number of 1-bits in x.
// GCC and Clang have a built-in for it (one POPCNT instruction with -mpopcnt).
// Any other C compiler gets a portable version that adds the bits in parallel.
#ifndef POPCOUNT32
#if defined(__GNUC__) || defined(__clang__)
#define POPCOUNT32(x) __builtin_popcount(x)
#else
static int popcount32_portable(unsigned int x)
{
    x = x - ((x >> 1) & 0x55555555u);                 // 16 sums of 2 bits
    x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u); // 8 sums of 4 bits
    x = (x + (x >> 4)) & 0x0F0F0F0Fu;                 // 4 sums of 8 bits
    return (int)((x * 0x01010101u) >> 24);            // add the 4 bytes
}
#define POPCOUNT32(x) popcount32_portable(x)
#endif
#endif

// Comparison function for qsort: negative, zero or positive, like strcmp.
// We do not return a - b: with unsigned values that difference can overflow.
static int compare_words(const void* pa, const void* pb)
{
    unsigned int a = *(const unsigned int*)pa;
    unsigned int b = *(const unsigned int*)pb;
    return (a > b) - (a < b);
}

int min_Hamming(unsigned int tab[], unsigned int tab_size)
{
    // Fewer than 2 words: no pair exists, the answer is undefined.
    if (tab_size < 2)
        return -1;

    // The smallest answer still possible. Steps 1 and 2 raise it to 2;
    // step 3 stops as soon as it finds a pair at this distance.
    int lowest = 0;

    // ---------------------------------------------------------------- Step 1
    // Copy the input into a new array. This is the extra O(N) memory we pay to
    // go faster. We copy instead of sorting tab[] directly because the caller
    // does not expect its array to be reordered.
    unsigned int* sorted = malloc((size_t)tab_size * sizeof(unsigned int));

    // If there is no memory for the copy, skip steps 1 and 2: step 3 alone
    // still gives the right answer, only slower.
    if (sorted != NULL)
    {
        memcpy(sorted, tab, (size_t)tab_size * sizeof(unsigned int));

        // Sort the copy: O(N log N).
        qsort(sorted, tab_size, sizeof(unsigned int), compare_words);

        // After sorting, identical words are neighbours. If two neighbours are
        // equal, their distance is 0, which is the smallest possible answer.
        for (unsigned int i = 0; i + 1 < tab_size; i++)
        {
            if (sorted[i] == sorted[i + 1])
            {
                free(sorted);
                return 0;
            }
        }

        // ------------------------------------------------------------ Step 2
        // No duplicates. Now check whether some pair differs in exactly 1 bit.
        for (unsigned int i = 0; i < tab_size; i++)
        {
            for (int bit = 0; bit < 32; bit++)
            {
                // (1u << bit) is a mask with a single 1 at position 'bit'.
                // XOR with that mask flips exactly that one bit of the word.
                unsigned int neighbour = sorted[i] ^ (1u << bit);

                // Binary search for 'neighbour' in sorted[]: O(log N).
                // Each round halves the range [lo, hi) that can still hold it.
                // (Written by hand: the C library's bsearch would call
                // compare_words through a pointer at every round, 32*N times.)
                unsigned int lo = 0, hi = tab_size;
                while (lo < hi)
                {
                    unsigned int mid = lo + (hi - lo) / 2;
                    if (sorted[mid] < neighbour)
                        lo = mid + 1;
                    else
                        hi = mid;
                }

                // lo is now the first position whose word is >= neighbour.
                // If the neighbour exists in the array, the answer is 1.
                if (lo < tab_size && sorted[lo] == neighbour)
                {
                    free(sorted);
                    return 1;
                }
            }
        }

        free(sorted);
        lowest = 2;  // no pair at distance 0 or 1
    }

    // ---------------------------------------------------------------- Step 3
    // The answer is at least 'lowest'. Compare all pairs, like version 1, but fast.
    int best = 32;

    for (unsigned int i = 0; i < tab_size; i++)
    {
        for (unsigned int j = i + 1; j < tab_size; j++)
        {
            // XOR marks the differing bits; POPCOUNT32 counts the 1-bits in a
            // single CPU instruction (POPCNT).
            int distance = POPCOUNT32(tab[i] ^ tab[j]);

            if (distance < best)
            {
                best = distance;

                // Nothing smaller than 'lowest' is possible: stop immediately
                // (early exit). After steps 1 and 2 that happens at 2.
                if (best == lowest)
                    return best;
            }
        }
    }

    return best;
}
