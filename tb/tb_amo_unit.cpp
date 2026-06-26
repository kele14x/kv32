// tb_amo_unit.cpp — unit test for kv32_amo_unit
// Verifies all 9 AMO operations with various operand combinations.

#include "Vkv32_amo_unit.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void test_amo(Vkv32_amo_unit* d, uint32_t old_val, uint32_t rs2_val,
                     uint8_t funct5, uint32_t expected, const char* name) {
    d->old_val = old_val;
    d->rs2_val = rs2_val;
    d->funct5  = funct5;
    d->eval();

    tests++;
    if (d->result != expected) {
        fprintf(stderr, "FAIL  %-40s got=0x%08X want=0x%08X\n", name, d->result, expected);
        failures++;
    }
}

// AMO funct5 encoding
static const uint8_t AMOADD  = 0b00000;
static const uint8_t AMOSWAP = 0b00001;
static const uint8_t AMOXOR  = 0b00100;
static const uint8_t AMOAND  = 0b01100;
static const uint8_t AMOOR   = 0b01000;
static const uint8_t AMOMIN  = 0b10000;
static const uint8_t AMOMAX  = 0b10100;
static const uint8_t AMOMINU = 0b11000;
static const uint8_t AMOMAXU = 0b11100;

int main() {
    Verilated::traceEverOn(false);
    Vkv32_amo_unit* d = new Vkv32_amo_unit;

    // ---- AMOSWAP: result = rs2 ----
    test_amo(d, 0x12345678, 0xDEADBEEF, AMOSWAP, 0xDEADBEEF, "amoswap basic");
    test_amo(d, 0xFFFFFFFF, 0x00000000, AMOSWAP, 0x00000000, "amoswap to zero");
    test_amo(d, 0x00000000, 0xFFFFFFFF, AMOSWAP, 0xFFFFFFFF, "amoswap to max");

    // ---- AMOADD: result = old + rs2 ----
    test_amo(d, 0x12345678, 0x00000001, AMOADD, 0x12345679, "amoadd basic");
    test_amo(d, 0xFFFFFFFF, 0x00000001, AMOADD, 0x00000000, "amoadd overflow");
    test_amo(d, 0x80000000, 0x80000000, AMOADD, 0x00000000, "amoadd neg+neg");
    test_amo(d, 0x00000000, 0x00000000, AMOADD, 0x00000000, "amoadd zeros");

    // ---- AMOAND: result = old & rs2 ----
    test_amo(d, 0xFF00FF00, 0x0F0F0F0F, AMOAND, 0x0F000F00, "amoand basic");
    test_amo(d, 0xFFFFFFFF, 0x12345678, AMOAND, 0x12345678, "amoand mask all");
    test_amo(d, 0x12345678, 0x00000000, AMOAND, 0x00000000, "amoand mask zero");

    // ---- AMOOR: result = old | rs2 ----
    test_amo(d, 0xFF00FF00, 0x0F0F0F0F, AMOOR, 0xFF0FFF0F, "amoor basic");
    test_amo(d, 0x00000000, 0x12345678, AMOOR, 0x12345678, "amoor with zero");
    test_amo(d, 0xFFFFFFFF, 0x00000000, AMOOR, 0xFFFFFFFF, "amoor with max");

    // ---- AMOXOR: result = old ^ rs2 ----
    test_amo(d, 0xFF00FF00, 0x0F0F0F0F, AMOXOR, 0xF00FF00F, "amoxor basic");
    test_amo(d, 0x12345678, 0x12345678, AMOXOR, 0x00000000, "amoxor same val");
    test_amo(d, 0x00000000, 0xFFFFFFFF, AMOXOR, 0xFFFFFFFF, "amoxor invert");

    // ---- AMOMIN (signed): result = smin(old, rs2) ----
    test_amo(d, 0x00000005, 0x00000003, AMOMIN, 0x00000003, "amomin pos/pos");
    test_amo(d, 0x00000003, 0x00000005, AMOMIN, 0x00000003, "amomin pos/pos swap");
    test_amo(d, 0x80000000, 0x7FFFFFFF, AMOMIN, 0x80000000, "amomin neg/pos");
    test_amo(d, 0x7FFFFFFF, 0x80000000, AMOMIN, 0x80000000, "amomin pos/neg");
    test_amo(d, 0xFFFFFFFE, 0xFFFFFFFF, AMOMIN, 0xFFFFFFFE, "amomin neg/neg");
    test_amo(d, 0xFFFFFFFF, 0xFFFFFFFE, AMOMIN, 0xFFFFFFFE, "amomin neg/neg swap");

    // ---- AMOMAX (signed): result = smax(old, rs2) ----
    test_amo(d, 0x00000005, 0x00000003, AMOMAX, 0x00000005, "amomax pos/pos");
    test_amo(d, 0x00000003, 0x00000005, AMOMAX, 0x00000005, "amomax pos/pos swap");
    test_amo(d, 0x80000000, 0x7FFFFFFF, AMOMAX, 0x7FFFFFFF, "amomax neg/pos");
    test_amo(d, 0x7FFFFFFF, 0x80000000, AMOMAX, 0x7FFFFFFF, "amomax pos/neg");
    test_amo(d, 0xFFFFFFFE, 0xFFFFFFFF, AMOMAX, 0xFFFFFFFF, "amomax neg/neg");
    test_amo(d, 0xFFFFFFFF, 0xFFFFFFFE, AMOMAX, 0xFFFFFFFF, "amomax neg/neg swap");

    // ---- AMOMINU (unsigned): result = umin(old, rs2) ----
    test_amo(d, 0x00000005, 0x00000003, AMOMINU, 0x00000003, "amominu small/large");
    test_amo(d, 0x00000003, 0x00000005, AMOMINU, 0x00000003, "amominu large/small");
    test_amo(d, 0x80000000, 0x7FFFFFFF, AMOMINU, 0x7FFFFFFF, "amominu high bit");
    test_amo(d, 0xFFFFFFFF, 0x00000000, AMOMINU, 0x00000000, "amominu max/zero");

    // ---- AMOMAXU (unsigned): result = umax(old, rs2) ----
    test_amo(d, 0x00000005, 0x00000003, AMOMAXU, 0x00000005, "amomaxu small/large");
    test_amo(d, 0x00000003, 0x00000005, AMOMAXU, 0x00000005, "amomaxu large/small");
    test_amo(d, 0x80000000, 0x7FFFFFFF, AMOMAXU, 0x80000000, "amomaxu high bit");
    test_amo(d, 0xFFFFFFFF, 0x00000000, AMOMAXU, 0xFFFFFFFF, "amomaxu max/zero");

    delete d;
    printf("\n=== tb_amo_unit: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
