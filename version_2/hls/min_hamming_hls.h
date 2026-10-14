// ============================================================================
// min_hamming_hls.h - version 2 as an FPGA core (Vitis HLS 2021.1, Zynq-7020)
//
// Shared by the core (min_hamming_hls.cpp), its testbench and the board
// program (../zynq/main.c), so all three agree on the limits below.
// ============================================================================

#ifndef MIN_HAMMING_HLS_H
#define MIN_HAMMING_HLS_H

// Largest tab_size the core accepts. The core keeps its own copies of the
// array in on-chip memory, so this size is fixed when the hardware is built.
#define MAX_N        8192

// Step 2 search tree: TREE_LEVELS levels hold 2^TREE_LEVELS - 1 = 8191 words
// (MAX_N = 2^TREE_LEVELS; why one slot fewer is enough: min_hamming_hls.cpp).
#define TREE_LEVELS  13

// Step 2 looks up LOOKUPS one-bit neighbours per clock cycle. Each copy of the
// search tree serves 2 of them (a block RAM has 2 ports).
#define TREE_COPIES  2
#define LOOKUPS      (2 * TREE_COPIES)

// Step 3 compares LANES pairs per clock cycle.
#define LANES        64
#define LOG2_LANES   6

// Returned when tab_size > MAX_N (the software version has no such limit).
#define TOO_BIG      (-2)

// Same contract as min_Hamming() in ../min_hamming_v2.c, plus:
//   stage  receives the step that decided the answer: 1 (duplicate, 0),
//          2 (one-bit neighbour, 1) or 3 (all pairs); 0 for -1 and TOO_BIG.
int min_hamming_hls(const unsigned int *tab, unsigned int tab_size, unsigned int *stage);

#endif
