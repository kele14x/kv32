// tb_mem_fe.cpp — unit test for kv32_mem_fe
// Tests: sub-word store positioning, load extraction, aligned access flow,
//        non-crossing misaligned SH@01, crossing accesses (SH@11, SW@01/10/11),
//        FSM state transitions, reset, rdata_valid timing.

#include "Vkv32_mem_fe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void tick(Vkv32_mem_fe* d) {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
}

static void reset(Vkv32_mem_fe* d) {
    d->clk = 0;
    d->rst_n = 0;
    d->req = 0;
    d->addr = 0;
    d->we = 0;
    d->size = 0;
    d->wdata = 0;
    d->funct3 = 0;
    d->dmem_ack = 0;
    d->dmem_rdata = 0;
    d->dmem_err = 0;
    d->eval();
    tick(d);
    d->rst_n = 1;
    d->eval();
}

static void set_inputs(Vkv32_mem_fe* d, bool req, uint32_t addr, bool we,
                       uint8_t size, uint32_t wdata, uint8_t funct3) {
    d->req = req;
    d->addr = addr;
    d->we = we;
    d->size = size;
    d->wdata = wdata;
    d->funct3 = funct3;
    d->eval();
}

static void check_eq(const char* name, uint32_t got, uint32_t want) {
    tests++;
    if (got != want) {
        fprintf(stderr, "FAIL  %-40s got=0x%08X want=0x%08X\n", name, got, want);
        failures++;
    }
}

// ---- Sub-word store positioning (combinational) ----
static void test_store_positioning(Vkv32_mem_fe* d) {
    printf("--- Store positioning ---\n");

    // SB at all offsets
    for (int off = 0; off < 4; off++) {
        set_inputs(d, 1, 0x1000 + off, 1, 0, 0xAB, 0);  // SB, funct3=0
        char label[64];
        snprintf(label, sizeof(label), "SB@%d be", off);
        check_eq(label, d->dmem_be, 1 << off);
        snprintf(label, sizeof(label), "SB@%d wdata", off);
        check_eq(label, d->dmem_wdata, 0xAB << (off * 8));
        check_eq("SB req passthrough", d->dmem_req, 1);
        check_eq("SB addr passthrough", d->dmem_addr, 0x1000 + off);
    }

    // SH aligned (offset 0 and 2)
    set_inputs(d, 1, 0x1000, 1, 1, 0xABCD, 0);  // SH@0
    check_eq("SH@0 be", d->dmem_be, 0x3);
    check_eq("SH@0 wdata", d->dmem_wdata, 0x0000ABCD);

    set_inputs(d, 1, 0x1002, 1, 1, 0xABCD, 0);  // SH@2
    check_eq("SH@2 be", d->dmem_be, 0xC);
    check_eq("SH@2 wdata", d->dmem_wdata, 0xABCD0000);

    // SW aligned
    set_inputs(d, 1, 0x1000, 1, 2, 0xDEADBEEF, 0);  // SW@0
    check_eq("SW@0 be", d->dmem_be, 0xF);
    check_eq("SW@0 wdata", d->dmem_wdata, 0xDEADBEEF);
}

// ---- Load extraction (combinational, needs dmem_ack) ----
static void test_load_extraction(Vkv32_mem_fe* d) {
    printf("--- Load extraction ---\n");
    reset(d);

    // LW aligned
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW, funct3=2
    d->dmem_rdata = 0xDEADBEEF;
    d->dmem_ack = 1;
    d->eval();
    check_eq("LW rdata_valid", d->rdata_valid, 1);
    check_eq("LW rdata", d->rdata, 0xDEADBEEF);
    d->dmem_ack = 0;

    // LB sign-extend positive
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 0, 0, 0);  // LB, funct3=0
    d->dmem_rdata = 0x00000042;
    d->dmem_ack = 1;
    d->eval();
    check_eq("LB@0 positive rdata", d->rdata, 0x00000042);

    // LB sign-extend negative
    reset(d);
    set_inputs(d, 1, 0x1001, 0, 0, 0, 0);  // LB@1
    d->dmem_rdata = 0x00008200;  // byte1 = 0x82 (negative)
    d->dmem_ack = 1;
    d->eval();
    check_eq("LB@1 negative rdata", d->rdata, 0xFFFFFF82);

    // LBU zero-extend
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 0, 0, 4);  // LBU, funct3=4
    d->dmem_rdata = 0x00820000;  // byte2 = 0x82
    d->dmem_ack = 1;
    d->eval();
    check_eq("LBU@2 rdata", d->rdata, 0x00000082);

    // LH sign-extend positive
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 1, 0, 1);  // LH, funct3=1
    d->dmem_rdata = 0x00001234;
    d->dmem_ack = 1;
    d->eval();
    check_eq("LH@0 positive rdata", d->rdata, 0x00001234);

    // LH sign-extend negative
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 1, 0, 1);  // LH@2
    d->dmem_rdata = 0x82340000;  // half@2 = 0x8234 (negative)
    d->dmem_ack = 1;
    d->eval();
    check_eq("LH@2 negative rdata", d->rdata, 0xFFFF8234);

    // LHU zero-extend
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 1, 0, 5);  // LHU, funct3=5
    d->dmem_rdata = 0x00008234;
    d->dmem_ack = 1;
    d->eval();
    check_eq("LHU@0 rdata", d->rdata, 0x00008234);
}

// ---- Aligned access flow (sequential) ----
static void test_aligned_flow(Vkv32_mem_fe* d) {
    printf("--- Aligned flow ---\n");
    reset(d);

    // Zero-latency: req and ack in same cycle
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW
    d->dmem_rdata = 0xCAFEBABE;
    d->dmem_ack = 1;
    d->eval();
    check_eq("zero-lat rdata_valid", d->rdata_valid, 1);
    check_eq("zero-lat rdata", d->rdata, 0xCAFEBABE);

    // Multi-cycle latency: req held, ack after 2 cycles
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW
    d->dmem_rdata = 0;
    d->dmem_ack = 0;
    d->eval();
    check_eq("latency cycle0 rdata_valid", d->rdata_valid, 0);
    tick(d);
    check_eq("latency cycle1 rdata_valid", d->rdata_valid, 0);
    tick(d);
    d->dmem_rdata = 0x12345678;
    d->dmem_ack = 1;
    d->eval();
    check_eq("latency cycle2 rdata_valid", d->rdata_valid, 1);
    check_eq("latency cycle2 rdata", d->rdata, 0x12345678);
}

// ---- Non-crossing misaligned SH@01 ----
static void test_non_crossing_sh01(Vkv32_mem_fe* d) {
    printf("--- Non-crossing SH@01 ---\n");
    reset(d);

    // Store: addr=0x1001, size=SH, should align to 0x1000, BE=0110
    set_inputs(d, 1, 0x1001, 1, 1, 0xABCD, 0);  // SH store
    d->eval();
    check_eq("SH@01 store addr", d->dmem_addr, 0x1000);
    check_eq("SH@01 store be", d->dmem_be, 0x6);
    check_eq("SH@01 store wdata", d->dmem_wdata, 0x00ABCD00);
    check_eq("SH@01 store req", d->dmem_req, 1);

    // Load: addr=0x1001, size=SH, should shift rdata right by 8
    reset(d);
    set_inputs(d, 1, 0x1001, 0, 1, 0, 1);  // LH load
    d->dmem_rdata = 0x12AB3400;  // word containing halfword at bytes 1-2
    d->dmem_ack = 1;
    d->eval();
    check_eq("SH@01 load addr", d->dmem_addr, 0x1000);
    check_eq("SH@01 load be", d->dmem_be, 0x6);
    check_eq("SH@01 load rdata_valid", d->rdata_valid, 1);
    // Shifted right by 8: 0x0012AB34, then LH extracts low half: 0xFFFFAB34
    // (0xAB34 has bit 15 set, so sign-extended)
    check_eq("SH@01 load rdata", d->rdata, 0xFFFFAB34);
}

// ---- Crossing SH@addr[1:0]=11 (store) ----
static void test_crossing_sh11_store(Vkv32_mem_fe* d) {
    printf("--- Crossing SH@11 store ---\n");
    reset(d);

    set_inputs(d, 1, 0x1003, 1, 1, 0xABCD, 0);  // SH store at offset 3
    d->eval();
    // Cycle 0: IDLE detects crossing, suppresses req, transitions to MA_FIRST
    check_eq("SH@11 cycle0 req", d->dmem_req, 0);
    check_eq("SH@11 cycle0 addr", d->dmem_addr, 0x1000);
    check_eq("SH@11 cycle0 be", d->dmem_be, 0x8);  // first byte in lane 3
    check_eq("SH@11 cycle0 wdata", d->dmem_wdata, 0xCD000000);  // low byte of halfword
    tick(d);

    // Cycle 1: MA_FIRST, req asserted, waiting for ack
    check_eq("SH@11 cycle1 req", d->dmem_req, 1);
    check_eq("SH@11 cycle1 addr", d->dmem_addr, 0x1000);
    d->dmem_ack = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0;

    // Cycle 2: MA_BETWEEN, req deasserted
    check_eq("SH@11 cycle2 req", d->dmem_req, 0);
    tick(d);

    // Cycle 3: MA_SECOND, req asserted, addr+4
    check_eq("SH@11 cycle3 req", d->dmem_req, 1);
    check_eq("SH@11 cycle3 addr", d->dmem_addr, 0x1004);
    check_eq("SH@11 cycle3 be", d->dmem_be, 0x1);  // high byte in lane 0
    check_eq("SH@11 cycle3 wdata", d->dmem_wdata, 0x000000AB);  // high byte of halfword
    d->dmem_ack = 1;
    d->eval();
    check_eq("SH@11 rdata_valid", d->rdata_valid, 1);
    tick(d);
}

// ---- Crossing SH@11 (load) ----
static void test_crossing_sh11_load(Vkv32_mem_fe* d) {
    printf("--- Crossing SH@11 load ---\n");
    reset(d);

    set_inputs(d, 1, 0x1003, 0, 1, 0, 1);  // LH load at offset 3
    d->eval();
    check_eq("SH@11 load cycle0 req", d->dmem_req, 0);
    tick(d);

    // MA_FIRST
    d->dmem_rdata = 0x12345678;  // first word
    d->dmem_ack = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0;

    // MA_BETWEEN
    tick(d);

    // MA_SECOND
    d->dmem_rdata = 0xAABBCCDD;  // second word
    d->dmem_ack = 1;
    d->eval();
    check_eq("SH@11 load rdata_valid", d->rdata_valid, 1);
    // Stitched: {second[7:0], first[31:24], 16'h0} = {0xDD, 0x12, 0x0000}
    // Then LH extracts: addr[1]=1 (from 0x1003), so high half: 0xFFFFDD12
    // (0xDD12 has bit 15 set, so sign-extended)
    check_eq("SH@11 load rdata", d->rdata, 0xFFFFDD12);
    tick(d);
}

// ---- Crossing SW@addr[1:0]=01 (store) ----
static void test_crossing_sw01_store(Vkv32_mem_fe* d) {
    printf("--- Crossing SW@01 store ---\n");
    reset(d);

    set_inputs(d, 1, 0x1001, 1, 2, 0xDEADBEEF, 0);  // SW store at offset 1
    d->eval();
    check_eq("SW@01 cycle0 req", d->dmem_req, 0);
    check_eq("SW@01 cycle0 be", d->dmem_be, 0xE);  // 3 bytes in high lanes
    check_eq("SW@01 cycle0 wdata", d->dmem_wdata, 0xADBEEF00);
    tick(d);

    d->dmem_ack = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0;
    tick(d);

    // MA_SECOND
    check_eq("SW@01 cycle3 addr", d->dmem_addr, 0x1004);
    check_eq("SW@01 cycle3 be", d->dmem_be, 0x1);  // 1 byte in lane 0
    check_eq("SW@01 cycle3 wdata", d->dmem_wdata, 0x000000DE);
    d->dmem_ack = 1;
    d->eval();
    check_eq("SW@01 rdata_valid", d->rdata_valid, 1);
    tick(d);
}

// ---- Crossing SW@01 (load) ----
static void test_crossing_sw01_load(Vkv32_mem_fe* d) {
    printf("--- Crossing SW@01 load ---\n");
    reset(d);

    set_inputs(d, 1, 0x1001, 0, 2, 0, 2);  // LW load at offset 1
    d->eval();
    tick(d);

    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0;
    tick(d);

    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1;
    d->eval();
    check_eq("SW@01 load rdata_valid", d->rdata_valid, 1);
    // Stitched: {second[7:0], first[31:8]} = {0x44, 0xAABBCC}
    check_eq("SW@01 load rdata", d->rdata, 0x44AABBCC);
    tick(d);
}

// ---- Crossing SW@10 (store + load) ----
static void test_crossing_sw10(Vkv32_mem_fe* d) {
    printf("--- Crossing SW@10 ---\n");

    // Store
    reset(d);
    set_inputs(d, 1, 0x1002, 1, 2, 0xDEADBEEF, 0);
    d->eval();
    check_eq("SW@10 store cycle0 be", d->dmem_be, 0xC);
    check_eq("SW@10 store cycle0 wdata", d->dmem_wdata, 0xBEEF0000);
    tick(d);
    d->dmem_ack = 1; d->eval(); tick(d);
    d->dmem_ack = 0; tick(d);
    check_eq("SW@10 store cycle3 be", d->dmem_be, 0x3);
    check_eq("SW@10 store cycle3 wdata", d->dmem_wdata, 0x0000DEAD);
    d->dmem_ack = 1; d->eval();
    check_eq("SW@10 store rdata_valid", d->rdata_valid, 1);

    // Load
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 2, 0, 2);
    d->eval();
    tick(d);
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1; d->eval(); tick(d);
    d->dmem_ack = 0; tick(d);
    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1; d->eval();
    check_eq("SW@10 load rdata_valid", d->rdata_valid, 1);
    // Stitched: {second[15:0], first[31:16]} = {0x3344, 0xAABB}
    check_eq("SW@10 load rdata", d->rdata, 0x3344AABB);
}

// ---- Crossing SW@11 (store + load) ----
static void test_crossing_sw11(Vkv32_mem_fe* d) {
    printf("--- Crossing SW@11 ---\n");

    // Store
    reset(d);
    set_inputs(d, 1, 0x1003, 1, 2, 0xDEADBEEF, 0);
    d->eval();
    check_eq("SW@11 store cycle0 be", d->dmem_be, 0x8);
    check_eq("SW@11 store cycle0 wdata", d->dmem_wdata, 0xEF000000);
    tick(d);
    d->dmem_ack = 1; d->eval(); tick(d);
    d->dmem_ack = 0; tick(d);
    check_eq("SW@11 store cycle3 be", d->dmem_be, 0x7);
    check_eq("SW@11 store cycle3 wdata", d->dmem_wdata, 0x00DEADBE);
    d->dmem_ack = 1; d->eval();
    check_eq("SW@11 store rdata_valid", d->rdata_valid, 1);

    // Load
    reset(d);
    set_inputs(d, 1, 0x1003, 0, 2, 0, 2);
    d->eval();
    tick(d);
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1; d->eval(); tick(d);
    d->dmem_ack = 0; tick(d);
    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1; d->eval();
    check_eq("SW@11 load rdata_valid", d->rdata_valid, 1);
    // Stitched: {second[23:0], first[31:24]} = {0x223344, 0xAA}
    check_eq("SW@11 load rdata", d->rdata, 0x223344AA);
}

// ---- Reset behavior ----
static void test_reset(Vkv32_mem_fe* d) {
    printf("--- Reset ---\n");
    reset(d);
    set_inputs(d, 1, 0x1003, 1, 2, 0xDEADBEEF, 0);  // Start crossing access
    d->eval();
    tick(d);  // Transitions to MA_FIRST
    reset(d);  // Reset mid-transaction
    check_eq("reset req", d->dmem_req, 0);
    check_eq("reset rdata_valid", d->rdata_valid, 0);
}

int main() {
    Verilated::traceEverOn(false);
    Vkv32_mem_fe* d = new Vkv32_mem_fe;

    test_store_positioning(d);
    test_load_extraction(d);
    test_aligned_flow(d);
    test_non_crossing_sh01(d);
    test_crossing_sh11_store(d);
    test_crossing_sh11_load(d);
    test_crossing_sw01_store(d);
    test_crossing_sw01_load(d);
    test_crossing_sw10(d);
    test_crossing_sw11(d);
    test_reset(d);

    delete d;
    printf("\n=== tb_mem_fe: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
