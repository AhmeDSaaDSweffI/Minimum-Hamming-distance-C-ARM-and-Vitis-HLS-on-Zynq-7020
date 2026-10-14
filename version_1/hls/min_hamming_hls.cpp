// ============================================================================
// min_hamming_hls.cpp - version 1 (brute force) as a Vitis HLS accelerator
//
// Same algorithm as min_hamming_v1.c: compare EVERY pair (i, j), XOR the two
// words and count the 1-bits one by one, keep the smallest count. Only the
// way the hardware runs it changes:
//
//   1. The array is copied from DDR into on-chip BRAM (one AXI burst), split
//      into HLS_LANES banks so that HLS_LANES words can be read per clock.
//   2. The 32-step bit loop is fully unrolled: in hardware it becomes an
//      adder tree that counts the 32 bits in a single clock.
//   3. tab[i] is compared with HLS_LANES words per clock (the inner loop is
//      pipelined with II = 1, i.e. it starts a new row every clock).
//
// Time  : about N^2 / (2 * HLS_LANES) clock cycles (no early exit, like v1)
// Memory: 4 * N bytes of BRAM for the copy, O(1) besides that
//
// Distances are 6-bit numbers (ap_uint<6>, 0..63): a distance is at most 32.
//
// Interfaces seen by the Zynq PS:
//   tab      : AXI4 master (m_axi, bundle gmem), reads the words from DDR
//   tab_size : AXI4-Lite register (s_axilite, bundle control)
//   return   : AXI4-Lite register, with the ap_start / ap_done handshake
// ============================================================================

#include <ap_int.h>

#include "min_hamming_hls.h"

// Rows of the on-chip copy: word k is in row k / HLS_LANES, bank k % HLS_LANES.
#define NUM_ROWS (HLS_MAX_N / HLS_LANES)

// A Hamming distance of two 32-bit words: 0..32 fits in 6 bits.
typedef ap_uint<6> dist_t;

// v1's bit counter: test the 32 bits one by one. HLS unrolls the loop, so
// the 32 tests and additions are done in parallel (an adder tree).
static dist_t count_bits(unsigned int diff)
{
#pragma HLS INLINE
    dist_t distance = 0;
    for (int bit = 0; bit < 32; bit++)
    {
#pragma HLS UNROLL
        if ((diff >> bit) & 1u)
            distance++;
    }
    return distance;
}

int min_hamming_hls(const unsigned int *tab, unsigned int tab_size)
{
#pragma HLS INTERFACE m_axi port=tab offset=slave bundle=gmem depth=8192 max_read_burst_length=256
#pragma HLS INTERFACE s_axilite port=tab bundle=control
#pragma HLS INTERFACE s_axilite port=tab_size bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    // With 0 or 1 word there is no pair: same answer as v1.
    if (tab_size < 2)
        return -1;

    // The copy has to fit in on-chip memory.
    if (tab_size > HLS_MAX_N)
        return -2;

    // On-chip copy of the words. Each of the HLS_LANES banks (dimension 2) is
    // a separate BRAM, so a whole row of HLS_LANES words is read in one clock.
    unsigned int buf[NUM_ROWS][HLS_LANES];
#pragma HLS ARRAY_PARTITION variable=buf complete dim=2

    // Read the words from DDR: one word per clock, as an AXI burst.
copy_loop:
    for (unsigned int k = 0; k < tab_size; k++)
    {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=2 max=8192 avg=5000
        buf[k / HLS_LANES][k % HLS_LANES] = tab[k];
    }

    // Two 32-bit words differ in at most 32 bits: safe starting value.
    dist_t best = 32;

    // Row and lane of the last word.
    const unsigned int last_row  = (tab_size - 1) / HLS_LANES;
    const unsigned int last_lane = (tab_size - 1) % HLS_LANES;

    // Outer loop: pick the first word of the pair, as in v1.
i_loop:
    for (unsigned int i = 0; i + 1 < tab_size; i++)
    {
#pragma HLS LOOP_TRIPCOUNT min=1 max=8191 avg=4999
        const unsigned int a = buf[i / HLS_LANES][i % HLS_LANES];

        // Row and lane of word i + 1, the first candidate for the second word.
        const unsigned int first_row  = (i + 1) / HLS_LANES;
        const unsigned int first_lane = (i + 1) % HLS_LANES;

        // Inner loop: the second word j > i, HLS_LANES candidates per clock.
        // In the first row the lanes before word i + 1 are switched off, and
        // in the last row the lanes after the last word: a switched-off lane
        // reports distance 32, which can never lower 'best'.
    j_loop:
        for (unsigned int row = first_row; row <= last_row; row++)
        {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=1 max=512 avg=157
            const unsigned int lo = (row == first_row) ? first_lane : 0;
            const unsigned int hi = (row == last_row) ? last_lane : HLS_LANES - 1;

            dist_t d[HLS_LANES];
#pragma HLS ARRAY_PARTITION variable=d complete

            // XOR + bit count for every lane at the same time.
            for (unsigned int lane = 0; lane < HLS_LANES; lane++)
            {
#pragma HLS UNROLL
                d[lane] = (lane >= lo && lane <= hi) ? count_bits(a ^ buf[row][lane]) : dist_t(32);
            }

            // Smallest of the lanes as a balanced tree of comparisons:
            // 16 -> 8 -> 4 -> 2 -> 1 values (log2(HLS_LANES) levels).
            for (unsigned int step = HLS_LANES / 2; step > 0; step /= 2)
            {
#pragma HLS UNROLL
                for (unsigned int lane = 0; lane < step; lane++)
                {
#pragma HLS UNROLL
                    if (d[lane + step] < d[lane])
                        d[lane] = d[lane + step];
                }
            }

            // Keep the smallest distance seen so far, as in v1.
            if (d[0] < best)
                best = d[0];
        }
    }

    return (int)best;
}
