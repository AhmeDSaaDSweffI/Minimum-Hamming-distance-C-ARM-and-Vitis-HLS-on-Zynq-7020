// ============================================================================
// Version 2 - FPGA core (Vitis HLS 2021.1, Zynq-7020 at 100 MHz)
//
// The same three steps as min_hamming_v2.c. qsort, malloc and one binary
// search after another do not turn into good hardware, so each step is
// rebuilt from parts that do:
//
//   Load   - read tab[] from DDR once (AXI burst) into on-chip memories.
//
//   Step 1 - Distance 0 (duplicates): sort the words with a radix sort, which
//            needs no comparisons and no recursion: 4 passes, one per byte,
//            each touching one word per clock. Equal words end up next to
//            each other, so ONE pass finds them.
//
//   Step 2 - Distance 1: look up the 32 one-bit neighbours of every word in a
//            search tree built from the sorted words. The software runs one
//            binary search after another; here every tree level sits in its
//            own memory, so a new lookup starts every clock and LOOKUPS of
//            them run side by side.
//
//   Step 3 - Distance >= 2: compare all pairs like version 1, but LANES pairs
//            per clock, each pair one XOR and a small adder tree that counts
//            the 1-bits. The rows go in the same order as the software and
//            stop at the end of the first row that reaches distance 2 (the
//            software stops at that pair; the answer is the same).
//
// Clock cycles, n words: about 9n (load + sort) + n (step 1) + 8n (step 2)
// + n(n-1)/2 / LANES at most (step 3). N = 5000 benchmark: about 0.1 M
// cycles, because step 3 stops after 264 rows.
//
// Interface (AXI4-Lite registers; Vitis HLS generates the C driver):
//   tab       address of the words in DDR, read through AXI master m_axi_gmem
//   tab_size  number of words, 0 .. MAX_N
//   return    smallest distance, -1 if tab_size < 2, TOO_BIG if > MAX_N
//   stage     which step decided the answer (see min_hamming_hls.h)
// ============================================================================

#include <ap_int.h>
#include "min_hamming_hls.h"

#if (1 << TREE_LEVELS) != MAX_N
#error "TREE_LEVELS must be log2(MAX_N): the tree holds MAX_N - 1 words"
#endif
#if (1 << LOG2_LANES) != LANES
#error "LOG2_LANES must be log2(LANES)"
#endif

typedef ap_uint<32> word_t;
typedef ap_uint<14> idx_t;    // 0 .. MAX_N (MAX_N itself is a valid tab_size)
typedef ap_uint<13> node_t;   // position inside one tree level
typedef ap_uint<6>  dist_t;   // 0 .. 33 (33 = "this lane holds no pair")

// Lets the tree macros below carry HLS pragmas
#define PRAGMA_SUB(x) _Pragma(#x)
#define PRAGMA(x)     PRAGMA_SUB(x)

// Hamming distance of a and b = number of 1-bits of a ^ b, as an adder tree:
// 16 sums of 2 bits, 8 of 4, 4 of 8, 2 of 16, 1 of 32 (the same idea as
// popcount32_portable in min_hamming_v2.c, but wires instead of instructions).
// The XOR is taken bit by bit: written as a 32-bit a ^ b, HLS would split it
// into one narrowed XOR per bit and over-count the logic.
static dist_t hamming32(word_t a, word_t b)
{
#pragma HLS INLINE
    ap_uint<2> s2[16];
    ap_uint<3> s4[8];
    ap_uint<4> s8[4];
    ap_uint<5> s16[2];
#pragma HLS ARRAY_PARTITION variable=s2 complete
#pragma HLS ARRAY_PARTITION variable=s4 complete
#pragma HLS ARRAY_PARTITION variable=s8 complete
#pragma HLS ARRAY_PARTITION variable=s16 complete

    for (int k = 0; k < 16; k++) {
#pragma HLS UNROLL
        s2[k] = ap_uint<2>(a[2 * k] ^ b[2 * k]) + ap_uint<2>(a[2 * k + 1] ^ b[2 * k + 1]);
    }
    for (int k = 0; k < 8; k++) {
#pragma HLS UNROLL
        s4[k] = ap_uint<3>(s2[2 * k]) + ap_uint<3>(s2[2 * k + 1]);
    }
    for (int k = 0; k < 4; k++) {
#pragma HLS UNROLL
        s8[k] = ap_uint<4>(s4[2 * k]) + ap_uint<4>(s4[2 * k + 1]);
    }
    for (int k = 0; k < 2; k++) {
#pragma HLS UNROLL
        s16[k] = ap_uint<5>(s8[2 * k]) + ap_uint<5>(s8[2 * k + 1]);
    }
    return dist_t(s16[0]) + dist_t(s16[1]);
}

// Number of trailing zero bits of v (v > 0): a small priority encoder.
static int trailing_zeros(idx_t v)
{
#pragma HLS INLINE
    int tz = 0;
    for (int b = TREE_LEVELS; b >= 0; b--) {
#pragma HLS UNROLL
        if (v[b]) {
            tz = b;
        }
    }
    return tz;
}

// ---------------------------------------------------------------- Step 1
// LSD radix sort of a[0..n-1], one byte per pass, with t[] as the second
// buffer: a -> t -> a -> t -> a, so after 4 passes the result is in a[].
// Each pass counts how many words have each byte value (HIST), turns the
// counts into start positions (PREFIX), then copies every word to its
// position (SCATTER).
//
// The 256 counters sit in a block RAM: a counter is read, incremented and
// written back a few clocks later, while the next words already read theirs.
// When a word has the same byte as one of the last 3 words, the RAM may still
// hold the old count, so the count is taken from those words (forwarding).
// In C the RAM is always up to date and the forwarded value is the same.
static void radix_sort(word_t a[MAX_N], word_t t[MAX_N], idx_t n)
{
    idx_t pos[256];
#pragma HLS BIND_STORAGE variable=pos type=ram_2p impl=bram

PASS:
    for (int pass = 0; pass < 4; pass++) {
        const int  shift  = 8 * pass;
        const bool from_a = (pass % 2) == 0;

    CLEAR:
        for (int d = 0; d < 256; d++) {
#pragma HLS PIPELINE II=1
            pos[d] = 0;
        }

        ap_uint<9> d1 = 256, d2 = 256, d3 = 256;   // bytes of the last 3 words (256 = none)
        idx_t      c1 = 0, c2 = 0, c3 = 0;        // their counts after the update
    HIST:
        for (idx_t i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=2 max=8192
#pragma HLS DEPENDENCE variable=pos inter false
            word_t w = from_a ? a[i] : t[i];
            ap_uint<8> d = w >> shift;
            idx_t c = pos[d];
            if (d == d1) {
                c = c1;
            } else if (d == d2) {
                c = c2;
            } else if (d == d3) {
                c = c3;
            }
            c++;
            pos[d] = c;
            d3 = d2; c3 = c2;
            d2 = d1; c2 = c1;
            d1 = d;  c1 = c;
        }

        idx_t sum = 0;
    PREFIX:
        for (int d = 0; d < 256; d++) {
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=pos inter false
            idx_t count = pos[d];
            pos[d] = sum;
            sum += count;
        }

        d1 = 256; d2 = 256; d3 = 256;
    SCATTER:
        for (idx_t i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=2 max=8192
#pragma HLS DEPENDENCE variable=pos inter false
            // A pass reads one buffer and writes the other, never the same one
#pragma HLS DEPENDENCE variable=a inter false
#pragma HLS DEPENDENCE variable=t inter false
            word_t w = from_a ? a[i] : t[i];
            ap_uint<8> d = w >> shift;
            idx_t p = pos[d];
            if (d == d1) {
                p = c1;
            } else if (d == d2) {
                p = c2;
            } else if (d == d3) {
                p = c3;
            }
            if (from_a) {
                t[p] = w;
            } else {
                a[p] = w;
            }
            pos[d] = p + 1;
            d3 = d2; c3 = c2;
            d2 = d1; c2 = c1;
            d1 = d;  c1 = p + 1;
        }
    }
}

// ---------------------------------------------------------------- Step 2 tree
// The sorted words, stored as a perfectly balanced binary search tree with
// one memory per level: level k holds 2^k words. Sorted position i goes to
//     level = 12 - tz,  slot = (i + 1) >> (tz + 1),  tz = trailing zeros of i+1
// e.g. position 4095 (the middle) is the root, 2047 and 6143 are level 1, and
// every even position is a leaf on level 12. Position 8191 (only used when
// tab_size = MAX_N) has no slot in 13 levels, and needs none: a one-bit pair
// is looked up from both of its words, and at most one of them sits there.
//
// A lookup walks down one level per step: equal -> found, smaller -> left
// child (2*slot), larger -> right child (2*slot + 1). Slots whose sorted
// position is >= n hold old data from an earlier call: they count as "larger
// than everything", so the walk turns left there and never matches them.

#define TREE_LEVEL(k)                                                   \
    word_t lvl##k[TREE_COPIES][1 << (k)];                               \
    PRAGMA(HLS ARRAY_PARTITION variable=lvl##k complete dim=1)          \
    PRAGMA(HLS BIND_STORAGE variable=lvl##k type=ram_2p)

#define TREE_WRITE(k)                                                   \
    case (k):                                                           \
        for (int c = 0; c < TREE_COPIES; c++) {                         \
            lvl##k[c][slot] = w;                                        \
        }                                                               \
        break;

#define TREE_STEP(k, c)                                                 \
    {                                                                   \
        word_t   v    = lvl##k[c][node];                                \
        unsigned spos = ((2u * (unsigned)node + 1u) << (TREE_LEVELS - 1 - (k))) - 1u; \
        bool     real = spos < (unsigned)n;                             \
        if (real && v == q) {                                           \
            hit = true;                                                 \
        }                                                               \
        node = node * 2 + ((real && q > v) ? 1 : 0);                    \
    }

#define TREE_LOOKUP(c)                                                  \
    {                                                                   \
        node_t node = 0;                                                \
        TREE_STEP(0, c)  TREE_STEP(1, c)  TREE_STEP(2, c)               \
        TREE_STEP(3, c)  TREE_STEP(4, c)  TREE_STEP(5, c)               \
        TREE_STEP(6, c)  TREE_STEP(7, c)  TREE_STEP(8, c)               \
        TREE_STEP(9, c)  TREE_STEP(10, c) TREE_STEP(11, c)              \
        TREE_STEP(12, c)                                                \
    }

// ---------------------------------------------------------------- top level
int min_hamming_hls(const unsigned int *tab, unsigned int tab_size, unsigned int *stage)
{
#pragma HLS INTERFACE m_axi port=tab offset=slave bundle=gmem depth=8192 max_read_burst_length=256 max_write_burst_length=2 num_write_outstanding=1
#pragma HLS INTERFACE s_axilite port=tab
#pragma HLS INTERFACE s_axilite port=tab_size
#pragma HLS INTERFACE s_axilite port=stage
#pragma HLS INTERFACE s_axilite port=return

    // Fewer than 2 words: no pair exists (same answer as the software).
    if (tab_size < 2) {
        *stage = 0;
        return -1;
    }
    // More words than the on-chip copies can hold.
    if (tab_size > MAX_N) {
        *stage = 0;
        return TOO_BIG;
    }
    const idx_t n = tab_size;

    // On-chip copies of the input
    word_t sorted[MAX_N];              // steps 1 and 2: sorted copy
    word_t tmp[MAX_N];                 // second buffer of the radix sort
    word_t orig[MAX_N];                // step 3: the words in their original order...
    word_t col[LANES][MAX_N / LANES];  // ...and spread over LANES memories (word j in col[j % LANES])
#pragma HLS BIND_STORAGE variable=sorted type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=tmp type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=orig type=ram_1p impl=bram
#pragma HLS ARRAY_PARTITION variable=col complete dim=1
#pragma HLS BIND_STORAGE variable=col type=ram_1p impl=lutram

    TREE_LEVEL(0)  TREE_LEVEL(1)  TREE_LEVEL(2)  TREE_LEVEL(3)
    TREE_LEVEL(4)  TREE_LEVEL(5)  TREE_LEVEL(6)  TREE_LEVEL(7)
    TREE_LEVEL(8)  TREE_LEVEL(9)  TREE_LEVEL(10) TREE_LEVEL(11)
    TREE_LEVEL(12)

    // ---------------------------------------------------------------- Load
LOAD:
    for (idx_t i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=2 max=8192
        word_t w = tab[i];
        sorted[i] = w;
        orig[i] = w;
        col[i % LANES][i / LANES] = w;
    }

    // ---------------------------------------------------------------- Step 1
    radix_sort(sorted, tmp, n);

    // One pass over the sorted words: equal neighbours mean distance 0.
    // The same pass fills the step 2 search tree.
    bool   duplicate = false;
    word_t prev = 0;
BUILD:
    for (idx_t i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=2 max=8192
        word_t w = sorted[i];
        if (i != 0 && w == prev) {
            duplicate = true;
        }
        prev = w;

        idx_t  p    = i + 1;
        int    tz   = trailing_zeros(p);
        node_t slot = p >> (tz + 1);
        if (tz < TREE_LEVELS) {             // tz == TREE_LEVELS: position 8191
            switch (TREE_LEVELS - 1 - tz) {
                TREE_WRITE(0)  TREE_WRITE(1)  TREE_WRITE(2)  TREE_WRITE(3)
                TREE_WRITE(4)  TREE_WRITE(5)  TREE_WRITE(6)  TREE_WRITE(7)
                TREE_WRITE(8)  TREE_WRITE(9)  TREE_WRITE(10) TREE_WRITE(11)
                TREE_WRITE(12)
                default: break;
            }
        }
    }
    if (duplicate) {
        *stage = 1;
        return 0;
    }

    // ---------------------------------------------------------------- Step 2
    // Word i of the sorted copy takes 32 / LOOKUPS clocks; lookup l of group g
    // flips bit g * LOOKUPS + l and searches tree copy l / 2.
    bool one_bit = false;
    const unsigned steps2 = (unsigned)n * (32 / LOOKUPS);
STEP2:
    for (unsigned t = 0; t < steps2; t++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=16 max=65536
        idx_t  i = t / (32 / LOOKUPS);
        int    g = t % (32 / LOOKUPS);
        word_t x = sorted[i];
        for (int l = 0; l < LOOKUPS; l++) {
#pragma HLS UNROLL
            word_t q   = x ^ (word_t(1) << (g * LOOKUPS + l));
            bool   hit = false;
            TREE_LOOKUP(l / 2)
            if (hit) {
                one_bit = true;
            }
        }
    }
    if (one_bit) {
        *stage = 2;
        return 1;
    }

    // ---------------------------------------------------------------- Step 3
    // Row i compares word i with every later word, LANES at a time: block jb
    // holds words jb*LANES .. jb*LANES + LANES-1, one in each col[] memory.
    // Lanes outside i < j < n hold no pair. After steps 1 and 2 the answer is
    // at least 2, so a row that reaches 2 ends the search.
    int best = 32;
ROWS:
    for (idx_t i = 0; i + 1 < n; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=8191
        const word_t xi          = orig[i];
        const idx_t  first_block = (i + 1) / LANES;
        const idx_t  last_block  = (n - 1) / LANES;
        // Only the first and the last block of a row are partial: lanes below
        // lo hold j <= i, lanes from hi on hold j >= n
        const ap_uint<7> lo = (i + 1) % LANES;
        const ap_uint<7> hi = n - last_block * LANES;
    BLOCKS:
        for (idx_t jb = first_block; jb <= last_block; jb++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=1 max=128
            dist_t d[LANES];
#pragma HLS ARRAY_PARTITION variable=d complete
        LANE:
            for (int k = 0; k < LANES; k++) {
#pragma HLS UNROLL
                const bool pair = (jb != first_block || k >= lo) && (jb != last_block || k < hi);
                d[k] = pair ? hamming32(xi, col[k][jb]) : dist_t(33);
            }
            // Smallest of the LANES distances: a tree of LOG2_LANES levels
        MIN_TREE:
            for (int s = 0; s < LOG2_LANES; s++) {
#pragma HLS UNROLL
                const int width = LANES >> (s + 1);
                for (int k = 0; k < LANES / 2; k++) {
#pragma HLS UNROLL
                    if (k < width && d[k + width] < d[k]) {
                        d[k] = d[k + width];
                    }
                }
            }
            if (d[0] < best) {
                best = d[0];
            }
        }
        if (best <= 2) {
            break;
        }
    }

    *stage = 3;
    return best;
}
