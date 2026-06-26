// tb_m_unit.cpp — unit test for kv32_m_unit (M-extension multiply/divide)

#include "Vkv32_m_unit.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void tick(Vkv32_m_unit* d) {
    d->clk = 0;
    d->eval();
    d->clk = 1;
    d->eval();
}

static uint32_t run_op(Vkv32_m_unit* d, int is_mul, int funct3, uint32_t a, uint32_t b) {
    // Set inputs
    d->valid = 1;
    d->is_mul = is_mul;
    d->funct3 = funct3;
    d->op_a = a;
    d->op_b = b;
    d->eval();

    // Clock in the request
    tick(d);

    // Deassert valid
    d->valid = 0;
    d->eval();

    // Wait for completion
    int timeout = 100;
    while (!d->done && timeout > 0) {
        tick(d);
        timeout--;
    }

    if (timeout == 0) {
        fprintf(stderr, "TIMEOUT: is_mul=%d funct3=%d a=0x%08X b=0x%08X\n",
                is_mul, funct3, a, b);
        return 0xDEADBEEF;
    }

    uint32_t result = d->result;

    // Wait one more cycle to return to IDLE
    tick(d);

    return result;
}

int main() {
    Verilated::traceEverOn(false);
    auto d = new Vkv32_m_unit;

    // Reset
    d->clk = 0;
    d->rst_n = 0;
    d->valid = 0;
    d->is_mul = 0;
    d->funct3 = 0;
    d->op_a = 0;
    d->op_b = 0;
    d->eval();
    tick(d);
    d->rst_n = 1;
    d->eval();

    printf("=== MUL tests ===\n");

    // MUL (funct3=0): result = (a * b)[31:0]
    tests++;
    uint32_t r = run_op(d, 1, 0, 7, 6);
    if (r != 42) {
        printf("FAIL MUL 7*6: got 0x%08X, want 42\n", r);
        failures++;
    } else {
        printf("PASS MUL 7*6 = %d\n", r);
    }

    tests++;
    r = run_op(d, 1, 0, 0x10000, 0x10000);
    if (r != 0) {
        printf("FAIL MUL 0x10000*0x10000: got 0x%08X, want 0\n", r);
        failures++;
    } else {
        printf("PASS MUL 0x10000*0x10000 = 0 (lower 32 bits)\n");
    }

    // MULH (funct3=1): result = (signed(a) * signed(b))[63:32]
    tests++;
    r = run_op(d, 1, 1, 0x7FFFFFFF, 2);  // Max positive * 2
    if (r != 0) {
        printf("FAIL MULH 0x7FFFFFFF*2: got 0x%08X, want 0\n", r);
        failures++;
    } else {
        printf("PASS MULH 0x7FFFFFFF*2 = 0 (upper 32 bits)\n");
    }

    tests++;
    r = run_op(d, 1, 1, 0x80000000, 2);  // Min negative * 2 = overflow
    uint32_t expected = 0xFFFFFFFF;  // -2147483648 * 2 = -4294967296, upper 32 = all 1s
    if (r != expected) {
        printf("FAIL MULH 0x80000000*2: got 0x%08X, want 0x%08X\n", r, expected);
        failures++;
    } else {
        printf("PASS MULH 0x80000000*2 = 0x%08X (signed overflow)\n", r);
    }

    // MULHSU (funct3=2): result = (signed(a) * unsigned(b))[63:32]
    tests++;
    r = run_op(d, 1, 2, 0xFFFFFFFF, 2);  // -1 * 2 = -2, upper 32 = all 1s
    if (r != 0xFFFFFFFF) {
        printf("FAIL MULHSU -1*2: got 0x%08X, want 0xFFFFFFFF\n", r);
        failures++;
    } else {
        printf("PASS MULHSU -1*2 = 0xFFFFFFFF (upper 32 bits)\n");
    }

    // MULHU (funct3=3): result = (unsigned(a) * unsigned(b))[63:32]
    tests++;
    r = run_op(d, 1, 3, 0xFFFFFFFF, 2);  // Max unsigned * 2
    uint32_t expected_hu = 1;  // 4294967295 * 2 = 8589934590, upper 32 = 1
    if (r != expected_hu) {
        printf("FAIL MULHU 0xFFFFFFFF*2: got 0x%08X, want 0x%08X\n", r, expected_hu);
        failures++;
    } else {
        printf("PASS MULHU 0xFFFFFFFF*2 = 0x%08X (upper 32 bits)\n", r);
    }

    printf("\n=== DIV tests ===\n");

    // DIV (funct3=4): signed divide, quotient
    tests++;
    r = run_op(d, 0, 4, 100, 7);
    if (r != 14) {
        printf("FAIL DIV 100/7: got %d, want 14\n", r);
        failures++;
    } else {
        printf("PASS DIV 100/7 = %d\n", r);
    }

    tests++;
    r = run_op(d, 0, 4, -100, 7);  // Signed: -100 / 7 = -14
    if (r != (uint32_t)-14) {
        printf("FAIL DIV -100/7: got 0x%08X, want 0x%08X\n", r, (uint32_t)-14);
        failures++;
    } else {
        printf("PASS DIV -100/7 = %d\n", (int32_t)r);
    }

    // DIV by zero: result = -1 (all 1s)
    tests++;
    r = run_op(d, 0, 4, 42, 0);
    if (r != 0xFFFFFFFF) {
        printf("FAIL DIV by zero: got 0x%08X, want 0xFFFFFFFF\n", r);
        failures++;
    } else {
        printf("PASS DIV by zero = 0xFFFFFFFF\n");
    }

    // DIV overflow: INT_MIN / -1 = INT_MIN (overflow, return INT_MIN)
    tests++;
    r = run_op(d, 0, 4, 0x80000000, 0xFFFFFFFF);
    if (r != 0x80000000) {
        printf("FAIL DIV INT_MIN/-1: got 0x%08X, want 0x80000000\n", r);
        failures++;
    } else {
        printf("PASS DIV INT_MIN/-1 = 0x80000000 (overflow)\n");
    }

    // DIVU (funct3=5): unsigned divide, quotient
    tests++;
    r = run_op(d, 0, 5, 100, 7);
    if (r != 14) {
        printf("FAIL DIVU 100/7: got %d, want 14\n", r);
        failures++;
    } else {
        printf("PASS DIVU 100/7 = %d\n", r);
    }

    tests++;
    r = run_op(d, 0, 5, 0xFFFFFFFF, 2);  // Max unsigned / 2
    if (r != 0x7FFFFFFF) {
        printf("FAIL DIVU 0xFFFFFFFF/2: got 0x%08X, want 0x7FFFFFFF\n", r);
        failures++;
    } else {
        printf("PASS DIVU 0xFFFFFFFF/2 = 0x%08X\n", r);
    }

    // DIVU by zero: result = 0xFFFFFFFF (all 1s)
    tests++;
    r = run_op(d, 0, 5, 42, 0);
    if (r != 0xFFFFFFFF) {
        printf("FAIL DIVU by zero: got 0x%08X, want 0xFFFFFFFF\n", r);
        failures++;
    } else {
        printf("PASS DIVU by zero = 0xFFFFFFFF\n");
    }

    printf("\n=== REM tests ===\n");

    // REM (funct3=6): signed divide, remainder
    tests++;
    r = run_op(d, 0, 6, 100, 7);
    if (r != 2) {
        printf("FAIL REM 100%%7: got %d, want 2\n", r);
        failures++;
    } else {
        printf("PASS REM 100%%7 = %d\n", r);
    }

    tests++;
    r = run_op(d, 0, 6, -100, 7);  // Signed: -100 % 7 = -2
    if (r != (uint32_t)-2) {
        printf("FAIL REM -100%%7: got 0x%08X, want 0x%08X\n", r, (uint32_t)-2);
        failures++;
    } else {
        printf("PASS REM -100%%7 = %d\n", (int32_t)r);
    }

    // REM by zero: result = dividend
    tests++;
    r = run_op(d, 0, 6, 42, 0);
    if (r != 42) {
        printf("FAIL REM by zero: got %d, want 42\n", r);
        failures++;
    } else {
        printf("PASS REM by zero = %d (dividend)\n", r);
    }

    // REM overflow: INT_MIN % -1 = 0
    tests++;
    r = run_op(d, 0, 6, 0x80000000, 0xFFFFFFFF);
    if (r != 0) {
        printf("FAIL REM INT_MIN%%-1: got 0x%08X, want 0\n", r);
        failures++;
    } else {
        printf("PASS REM INT_MIN%%-1 = 0 (overflow)\n");
    }

    // REMU (funct3=7): unsigned divide, remainder
    tests++;
    r = run_op(d, 0, 7, 100, 7);
    if (r != 2) {
        printf("FAIL REMU 100%%7: got %d, want 2\n", r);
        failures++;
    } else {
        printf("PASS REMU 100%%7 = %d\n", r);
    }

    tests++;
    r = run_op(d, 0, 7, 0xFFFFFFFF, 2);  // Max unsigned % 2 = 1
    if (r != 1) {
        printf("FAIL REMU 0xFFFFFFFF%%2: got %d, want 1\n", r);
        failures++;
    } else {
        printf("PASS REMU 0xFFFFFFFF%%2 = %d\n", r);
    }

    // REMU by zero: result = dividend
    tests++;
    r = run_op(d, 0, 7, 42, 0);
    if (r != 42) {
        printf("FAIL REMU by zero: got %d, want 42\n", r);
        failures++;
    } else {
        printf("PASS REMU by zero = %d (dividend)\n", r);
    }

    delete d;

    printf("\n=== Results ===\n");
    printf("%d/%d tests passed\n", tests - failures, tests);

    return failures > 0 ? 1 : 0;
}
