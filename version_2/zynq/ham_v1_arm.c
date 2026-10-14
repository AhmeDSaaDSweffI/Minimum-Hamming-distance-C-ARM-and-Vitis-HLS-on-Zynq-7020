/*
 * ham_v1_arm.c : version 1 built into the board program under another name,
 * so main.c can time version 1 and version 2 on the same ARM core.
 *
 * run_sw.tcl adds ../../version_1 to the include path; the file is used as is.
 */

#define min_Hamming min_Hamming_v1
#include "min_hamming_v1.c"
