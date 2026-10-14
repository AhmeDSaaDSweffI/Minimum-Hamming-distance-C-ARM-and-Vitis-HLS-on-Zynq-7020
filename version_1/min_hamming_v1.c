// ============================================================================
// Version 1 - Intuitive / memory-optimized approach (brute force)
//
// Idea: compare EVERY pair of words. For each pair, XOR the two words: the
// result has a 1 exactly where the two words differ. Counting those 1-bits
// gives the Hamming distance of the pair. Keep the smallest one.
//
// Time  : O(N^2 * 32)  -> N*(N-1)/2 pairs, 32 bit-checks per pair
// Memory: O(1)         -> only a few local variables, no extra array
// ============================================================================

int min_Hamming(unsigned int tab[], unsigned int tab_size)
{
    // With 0 or 1 word there is no pair to compare, so the minimum distance
    // is undefined. We return -1 to signal "no valid answer".
    if (tab_size < 2)
        return -1;

    // Two 32-bit words can differ in at most 32 bits, so 32 is a safe
    // starting value: any real distance will be <= 32.
    int best = 32;

    // Outer loop: pick the first word of the pair.
    for (unsigned int i = 0; i < tab_size; i++)
    {
        // Inner loop: pick the second word. Starting at i + 1 means we never
        // compare a word with itself and never compare the same pair twice
        // (pair (2,5) is the same as pair (5,2)).
        for (unsigned int j = i + 1; j < tab_size; j++)
        {
            // XOR: a bit of 'diff' is 1 only where tab[i] and tab[j] differ.
            // Example: 1010 ^ 1001 = 0011  -> they differ in 2 bits.
            unsigned int diff = tab[i] ^ tab[j];

            // Count the 1-bits of 'diff' one by one.
            int distance = 0;
            for (int bit = 0; bit < 32; bit++)
            {
                // Shift the bit we want to test down to position 0, then
                // keep only that bit with "& 1". If it is 1, count it.
                if ((diff >> bit) & 1u)
                    distance++;
            }

            // Keep the smallest distance seen so far.
            if (distance < best)
                best = distance;
        }
    }

    return best;
}
