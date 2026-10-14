// ============================================================================
// min_hamming_hls.h - version 1 (brute force) as a Vitis HLS accelerator.
// ============================================================================

#ifndef MIN_HAMMING_HLS_H
#define MIN_HAMMING_HLS_H

// Largest array the accelerator accepts. The words are copied into on-chip
// memory (BRAM) first: 8192 words x 4 bytes = 32 KB.
// (The m_axi depth and LOOP_TRIPCOUNT pragmas in min_hamming_hls.cpp use
// this value as a literal: change them too if you change it.)
#define HLS_MAX_N 8192

// Number of words compared with tab[i] in the same clock cycle (a power of
// two). 1 would follow the software loop exactly, one pair per cycle.
#define HLS_LANES 16

// Same contract as min_Hamming() in min_hamming_v1.c:
//   >= 0 : smallest Hamming distance between two words of tab[0..tab_size-1]
//   -1   : tab_size < 2, there is no pair
//   -2   : tab_size > HLS_MAX_N, the words do not fit in on-chip memory
int min_hamming_hls(const unsigned int *tab, unsigned int tab_size);

#endif
