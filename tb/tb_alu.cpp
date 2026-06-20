// tb_alu.cpp — unit test for kv32_alu
// Verifies all 10 ALU operations with edge cases.
// Combinational DUT: set inputs, eval, check output.

#include "Vkv32_alu.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void check(Vkv32_alu* d, const char* name,
                  uint32_t a, uint32_t b, uint8_t op, uint32_t expected) {
    d->a = a;
    d->b = b;
    d->op = op;
    d->eval();
    tests++;
    if (d->result != expected) {
        fprintf(stderr, "FAIL  %-7s a=0x%08X b=0x%08X op=%u  "
                "got=0x%08X want=0x%08X\n",
                name, a, b, op, d->result, expected);
        failures++;
    }
}

int main() {
    Verilated::traceEverOn(false);
    Vkv32_alu* d = new Vkv32_alu;

    // ADD
    check(d, "ADD", 5, 3, 0, 8);
    check(d, "ADD", 0, 0, 0, 0);
    check(d, "ADD", 0xFFFFFFFF, 1, 0, 0);           // wrap
    check(d, "ADD", 0x7FFFFFFF, 1, 0, 0x80000000);

    // SUB
    check(d, "SUB", 10, 3, 1, 7);
    check(d, "SUB", 0, 1, 1, 0xFFFFFFFF);           // underflow
    check(d, "SUB", 5, 5, 1, 0);

    // SLL (shift amount is b[4:0])
    check(d, "SLL", 1, 4, 2, 16);
    check(d, "SLL", 0xFF, 8, 2, 0xFF00);
    check(d, "SLL", 1, 31, 2, 0x80000000);
    check(d, "SLL", 1, 0, 2, 1);
    check(d, "SLL", 0x12345678, 4, 2, 0x23456780);  // shift masked to 5 bits

    // SLT (signed)
    check(d, "SLT", 5, 10, 3, 1);
    check(d, "SLT", 0xFFFFFFFF, 0, 3, 1);           // -1 < 0
    check(d, "SLT", 0, 0xFFFFFFFF, 3, 0);           // 0 < -1 is false
    check(d, "SLT", 10, 5, 3, 0);
    check(d, "SLT", 0xFFFFFFFB, 0xFFFFFFFD, 3, 1);  // -5 < -3

    // SLTU (unsigned)
    check(d, "SLTU", 5, 10, 4, 1);
    check(d, "SLTU", 0xFFFFFFFF, 1, 4, 0);
    check(d, "SLTU", 0, 1, 4, 1);
    check(d, "SLTU", 10, 5, 4, 0);

    // XOR
    check(d, "XOR", 0xFF, 0x0F, 5, 0xF0);
    check(d, "XOR", 0, 0, 5, 0);
    check(d, "XOR", 0xFFFFFFFF, 0xFFFFFFFF, 5, 0);

    // SRL (logical right shift)
    check(d, "SRL", 0x80000000, 4, 6, 0x08000000);
    check(d, "SRL", 0xFF, 0, 6, 0xFF);
    check(d, "SRL", 0x80000000, 31, 6, 1);

    // SRA (arithmetic right shift)
    check(d, "SRA", 0x80000000, 4, 7, 0xF8000000);  // sign-extends
    check(d, "SRA", 0x40000000, 4, 7, 0x04000000);  // no sign bit
    check(d, "SRA", 0x80000000, 31, 7, 0xFFFFFFFF);

    // OR
    check(d, "OR", 0xF0, 0x0F, 8, 0xFF);
    check(d, "OR", 0, 0, 8, 0);
    check(d, "OR", 0xFF, 0xFF, 8, 0xFF);

    // AND
    check(d, "AND", 0xFF, 0x0F, 9, 0x0F);
    check(d, "AND", 0, 0, 9, 0);
    check(d, "AND", 0xFF, 0xFF, 9, 0xFF);

    delete d;
    printf("\n=== tb_alu: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
