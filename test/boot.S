#include "common.h"

.section .text.init;
.align 4;
.globl _start;

_start:
    j reset_vector;

reset_vector:
    INIT_XREG;
