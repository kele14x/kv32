// tb_regfile.cpp — unit test for kv32_regfile
// Verifies: x0 hardwire, write/read, write-during-read (old value),
//           write enable gating, dual-port reads.

#include "Vkv32_regfile.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void tick(Vkv32_regfile* d) {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
}

static void expect_eq(const char* name, uint32_t got, uint32_t want) {
    tests++;
    if (got != want) {
        fprintf(stderr, "FAIL  %-25s got=0x%08X want=0x%08X\n", name, got, want);
        failures++;
    }
}

int main() {
    Verilated::traceEverOn(false);
    Vkv32_regfile* d = new Vkv32_regfile;
    d->clk = 0;
    d->we = 0;
    d->rd_addr = 0; d->rd_data = 0;
    d->rs1_addr = 0; d->rs2_addr = 0;
    d->eval();

    // x0 always reads as 0, even after attempted write
    d->we = 1; d->rd_addr = 0; d->rd_data = 0xDEADBEEF;
    tick(d);
    d->we = 0;
    d->rs1_addr = 0; d->rs2_addr = 0; d->eval();
    expect_eq("x0 after write (rs1)", d->rs1_data, 0);
    expect_eq("x0 after write (rs2)", d->rs2_data, 0);

    // Write x1, read back
    d->we = 1; d->rd_addr = 1; d->rd_data = 0x12345678;
    tick(d);
    d->we = 0;
    d->rs1_addr = 1; d->eval();
    expect_eq("write x1, read rs1", d->rs1_data, 0x12345678);

    // Write x5, read on rs2
    d->we = 1; d->rd_addr = 5; d->rd_data = 0xAABBCCDD;
    tick(d);
    d->we = 0;
    d->rs2_addr = 5; d->eval();
    expect_eq("write x5, read rs2", d->rs2_data, 0xAABBCCDD);

    // Dual-port read of two different registers
    d->rs1_addr = 1; d->rs2_addr = 5; d->eval();
    expect_eq("dual-port rs1=x1", d->rs1_data, 0x12345678);
    expect_eq("dual-port rs2=x5", d->rs2_data, 0xAABBCCDD);

    // Write-during-read: writing x10 while reading x10 same cycle
    // should return the OLD value (write happens on clock edge)
    d->we = 1; d->rd_addr = 10; d->rd_data = 0xCAFEBABE;
    d->rs1_addr = 10; d->eval();
    expect_eq("write-during-read (old val)", d->rs1_data, 0);
    tick(d);  // write commits
    d->we = 0;
    d->rs1_addr = 10; d->eval();
    expect_eq("write-during-read (new val)", d->rs1_data, 0xCAFEBABE);

    // we=0 must not write
    d->we = 0; d->rd_addr = 10; d->rd_data = 0x11111111;
    tick(d);
    d->rs1_addr = 10; d->eval();
    expect_eq("we=0 no write", d->rs1_data, 0xCAFEBABE);

    // Write all 31 registers, read back a few
    for (int i = 1; i <= 31; i++) {
        d->we = 1; d->rd_addr = i; d->rd_data = i * 0x10 + i;
        tick(d);
    }
    d->we = 0;
    d->rs1_addr = 1; d->eval();  expect_eq("scan x1",  d->rs1_data, 0x11);
    d->rs1_addr = 15; d->eval(); expect_eq("scan x15", d->rs1_data, 0xFF);
    d->rs1_addr = 31; d->eval(); expect_eq("scan x31", d->rs1_data, 0x20F);

    delete d;
    printf("\n=== tb_regfile: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
