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
    d->dmem_gnt = 0;
    d->dmem_ack = 0; d->dmem_gnt = 0;
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
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LW rdata_valid", d->rdata_valid, 1);
    check_eq("LW rdata", d->rdata, 0xDEADBEEF);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // LB sign-extend positive
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 0, 0, 0);  // LB, funct3=0
    d->dmem_rdata = 0x00000042;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LB@0 positive rdata", d->rdata, 0x00000042);

    // LB sign-extend negative
    reset(d);
    set_inputs(d, 1, 0x1001, 0, 0, 0, 0);  // LB@1
    d->dmem_rdata = 0x00008200;  // byte1 = 0x82 (negative)
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LB@1 negative rdata", d->rdata, 0xFFFFFF82);

    // LBU zero-extend
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 0, 0, 4);  // LBU, funct3=4
    d->dmem_rdata = 0x00820000;  // byte2 = 0x82
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LBU@2 rdata", d->rdata, 0x00000082);

    // LH sign-extend positive
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 1, 0, 1);  // LH, funct3=1
    d->dmem_rdata = 0x00001234;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LH@0 positive rdata", d->rdata, 0x00001234);

    // LH sign-extend negative
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 1, 0, 1);  // LH@2
    d->dmem_rdata = 0x82340000;  // half@2 = 0x8234 (negative)
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("LH@2 negative rdata", d->rdata, 0xFFFF8234);

    // LHU zero-extend
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 1, 0, 5);  // LHU, funct3=5
    d->dmem_rdata = 0x00008234;
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("zero-lat rdata_valid", d->rdata_valid, 1);
    check_eq("zero-lat rdata", d->rdata, 0xCAFEBABE);

    // Multi-cycle latency: req held, ack after 2 cycles
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW
    d->dmem_rdata = 0;
    d->dmem_ack = 0; d->dmem_gnt = 0;
    d->eval();
    check_eq("latency cycle0 rdata_valid", d->rdata_valid, 0);
    tick(d);
    check_eq("latency cycle1 rdata_valid", d->rdata_valid, 0);
    tick(d);
    d->dmem_rdata = 0x12345678;
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    // Cycle 0: IDLE drives the first beat immediately and waits for grant.
    check_eq("SH@11 cycle0 req", d->dmem_req, 1);
    check_eq("SH@11 cycle0 addr", d->dmem_addr, 0x1000);
    check_eq("SH@11 cycle0 be", d->dmem_be, 0x8);  // first byte in lane 3
    check_eq("SH@11 cycle0 wdata", d->dmem_wdata, 0xCD000000);  // low byte of halfword
    tick(d);

    // Cycle 1: MA_FIRST, req asserted, waiting for ack
    check_eq("SH@11 cycle1 req", d->dmem_req, 1);
    check_eq("SH@11 cycle1 addr", d->dmem_addr, 0x1000);
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Cycle 2: after the first ack, the second beat request is already on the bus.
    check_eq("SH@11 cycle2 req", d->dmem_req, 1);
    tick(d);

    // Cycle 3: MA_SECOND, req asserted, addr+4
    check_eq("SH@11 cycle3 req", d->dmem_req, 1);
    check_eq("SH@11 cycle3 addr", d->dmem_addr, 0x1004);
    check_eq("SH@11 cycle3 be", d->dmem_be, 0x1);  // high byte in lane 0
    check_eq("SH@11 cycle3 wdata", d->dmem_wdata, 0x000000AB);  // high byte of halfword
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    check_eq("SH@11 load cycle0 req", d->dmem_req, 1);
    tick(d);

    // MA_FIRST
    d->dmem_rdata = 0x12345678;  // first word
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // MA_BETWEEN
    tick(d);

    // MA_SECOND
    d->dmem_rdata = 0xAABBCCDD;  // second word
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    check_eq("SW@01 cycle0 req", d->dmem_req, 1);
    check_eq("SW@01 cycle0 be", d->dmem_be, 0xE);  // 3 bytes in high lanes
    check_eq("SW@01 cycle0 wdata", d->dmem_wdata, 0xADBEEF00);
    tick(d);

    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;
    tick(d);

    // MA_SECOND
    check_eq("SW@01 cycle3 addr", d->dmem_addr, 0x1004);
    check_eq("SW@01 cycle3 be", d->dmem_be, 0x1);  // 1 byte in lane 0
    check_eq("SW@01 cycle3 wdata", d->dmem_wdata, 0x000000DE);
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;
    tick(d);

    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1; d->dmem_gnt = 1;
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
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval(); tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0; tick(d);
    check_eq("SW@10 store cycle3 be", d->dmem_be, 0x3);
    check_eq("SW@10 store cycle3 wdata", d->dmem_wdata, 0x0000DEAD);
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval();
    check_eq("SW@10 store rdata_valid", d->rdata_valid, 1);

    // Load
    reset(d);
    set_inputs(d, 1, 0x1002, 0, 2, 0, 2);
    d->eval();
    tick(d);
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval(); tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0; tick(d);
    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval();
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
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval(); tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0; tick(d);
    check_eq("SW@11 store cycle3 be", d->dmem_be, 0x7);
    check_eq("SW@11 store cycle3 wdata", d->dmem_wdata, 0x00DEADBE);
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval();
    check_eq("SW@11 store rdata_valid", d->rdata_valid, 1);

    // Load
    reset(d);
    set_inputs(d, 1, 0x1003, 0, 2, 0, 2);
    d->eval();
    tick(d);
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval(); tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0; tick(d);
    d->dmem_rdata = 0x11223344;
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval();
    check_eq("SW@11 load rdata_valid", d->rdata_valid, 1);
    // Stitched: {second[23:0], first[31:24]} = {0x223344, 0xAA}
    check_eq("SW@11 load rdata", d->rdata, 0x223344AA);
}

// ---- Comprehensive load extraction (all offsets) ----
static void test_load_extraction_all_offsets(Vkv32_mem_fe* d) {
    printf("--- Load extraction (all offsets) ---\n");

    // LB sign-extend at all 4 offsets
    {
        uint32_t rdata = 0x7F80FF00;  // bytes: 00, FF, 80, 7F
        // LB@0 = 0x00000000, LB@1 = 0xFFFFFFFF, LB@2 = 0xFFFFFF80, LB@3 = 0x0000007F
        uint32_t want[4] = {0x00000000, 0xFFFFFFFF, 0xFFFFFF80, 0x0000007F};
        for (int off = 0; off < 4; off++) {
            reset(d);
            set_inputs(d, 1, 0x1000 + off, 0, 0, 0, 0);  // LB
            d->dmem_rdata = rdata;
            d->dmem_ack = 1; d->dmem_gnt = 1;
            d->eval();
            char label[64];
            snprintf(label, sizeof(label), "LB@%d sign-extend", off);
            check_eq(label, d->rdata, want[off]);
        }
    }

    // LBU zero-extend at all 4 offsets
    {
        uint32_t rdata = 0x7F80FF00;
        uint32_t want[4] = {0x00000000, 0x000000FF, 0x00000080, 0x0000007F};
        for (int off = 0; off < 4; off++) {
            reset(d);
            set_inputs(d, 1, 0x1000 + off, 0, 0, 0, 4);  // LBU
            d->dmem_rdata = rdata;
            d->dmem_ack = 1; d->dmem_gnt = 1;
            d->eval();
            char label[64];
            snprintf(label, sizeof(label), "LBU@%d zero-extend", off);
            check_eq(label, d->rdata, want[off]);
        }
    }

    // LH sign-extend at both halfword offsets
    {
        // LH@0: low half = 0x8000 (negative) → 0xFFFF8000
        // LH@2: high half = 0x7FFF (positive) → 0x00007FFF
        reset(d);
        set_inputs(d, 1, 0x1000, 0, 1, 0, 1);
        d->dmem_rdata = 0x7FFF8000;
        d->dmem_ack = 1; d->dmem_gnt = 1;
        d->eval();
        check_eq("LH@0 negative", d->rdata, 0xFFFF8000);

        reset(d);
        set_inputs(d, 1, 0x1002, 0, 1, 0, 1);
        d->dmem_rdata = 0x7FFF8000;
        d->dmem_ack = 1; d->dmem_gnt = 1;
        d->eval();
        check_eq("LH@2 positive", d->rdata, 0x00007FFF);
    }

    // LHU zero-extend at offset 2
    {
        reset(d);
        set_inputs(d, 1, 0x1002, 0, 1, 0, 5);  // LHU@2
        d->dmem_rdata = 0xABCD1234;
        d->dmem_ack = 1; d->dmem_gnt = 1;
        d->eval();
        check_eq("LHU@2 zero-extend", d->rdata, 0x0000ABCD);
    }
}

// ---- Back-to-back transactions (FSM returns to IDLE cleanly) ----
static void test_back_to_back(Vkv32_mem_fe* d) {
    printf("--- Back-to-back ---\n");
    reset(d);

    // Store then immediately load at the same address
    set_inputs(d, 1, 0x1000, 1, 2, 0xDEADBEEF, 0);  // SW
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("b2b store rdata_valid", d->rdata_valid, 1);
    check_eq("b2b store err", d->err, 0);
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Next cycle: load at same address, zero-latency
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW
    d->dmem_rdata = 0xCAFEBABE;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("b2b load rdata_valid", d->rdata_valid, 1);
    check_eq("b2b load rdata", d->rdata, 0xCAFEBABE);
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Crossing store then aligned load
    reset(d);
    set_inputs(d, 1, 0x1003, 1, 1, 0xABCD, 0);  // SH@11 crossing store
    d->eval();
    tick(d);  // → MA_FIRST
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval(); tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0; tick(d);  // → MA_BETWEEN → MA_SECOND
    d->dmem_ack = 1; d->dmem_gnt = 1; d->eval();
    check_eq("b2b crossing store rdata_valid", d->rdata_valid, 1);
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Immediately do an aligned load — FSM must be back in IDLE
    set_inputs(d, 1, 0x2000, 0, 2, 0, 2);
    d->dmem_rdata = 0x12345678;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("b2b post-crossing load rdata_valid", d->rdata_valid, 1);
    check_eq("b2b post-crossing load rdata", d->rdata, 0x12345678);
}

// ---- Error: single-beat (aligned) ----
static void test_err_single_beat(Vkv32_mem_fe* d) {
    printf("--- Error: single-beat ---\n");
    reset(d);

    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);  // LW aligned
    d->dmem_err = 1;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("single-beat err rdata_valid", d->rdata_valid, 1);
    check_eq("single-beat err err", d->err, 1);
    tick(d);
    d->dmem_err = 0;
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Verify err is NOT asserted when dmem_err=1 but no ack
    reset(d);
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);
    d->dmem_err = 1;
    d->dmem_ack = 0; d->dmem_gnt = 0;
    d->eval();
    check_eq("single-beat no-ack rdata_valid", d->rdata_valid, 0);
    check_eq("single-beat no-ack err", d->err, 0);
}

// ---- Error: first-beat abort on crossing (no second beat issued) ----
static void test_err_first_beat_abort(Vkv32_mem_fe* d) {
    printf("--- Error: first-beat abort ---\n");
    reset(d);

    set_inputs(d, 1, 0x1003, 0, 1, 0, 1);  // SH@11 crossing load
    d->eval();
    check_eq("abort cycle0 req", d->dmem_req, 1);
    check_eq("abort cycle0 rdata_valid", d->rdata_valid, 0);
    check_eq("abort cycle0 err", d->err, 0);
    tick(d);  // → MA_FIRST

    // MA_FIRST: drive err on ack
    d->dmem_rdata = 0xDEADBEEF;
    d->dmem_err = 1;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("abort cycle1 rdata_valid", d->rdata_valid, 1);
    check_eq("abort cycle1 err", d->err, 1);
    tick(d);  // → MA_IDLE (abort, not MA_BETWEEN)
    d->dmem_err = 0;
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Verify FSM is back in IDLE: a new aligned access should work immediately
    set_inputs(d, 1, 0x2000, 0, 2, 0, 2);  // LW
    d->dmem_rdata = 0xCAFEBABE;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("abort recovery rdata_valid", d->rdata_valid, 1);
    check_eq("abort recovery rdata", d->rdata, 0xCAFEBABE);
    check_eq("abort recovery err", d->err, 0);
}

// ---- Error: second-beat on crossing ----
static void test_err_second_beat(Vkv32_mem_fe* d) {
    printf("--- Error: second-beat ---\n");
    reset(d);

    set_inputs(d, 1, 0x1003, 0, 1, 0, 1);  // SH@11 crossing load
    d->eval();
    tick(d);  // → MA_FIRST

    // MA_FIRST: success
    d->dmem_rdata = 0x12345678;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("second-err cycle1 rdata_valid", d->rdata_valid, 0);  // not done yet
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // MA_BETWEEN
    tick(d);  // → MA_SECOND

    // MA_SECOND: err
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_err = 1;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("second-err rdata_valid", d->rdata_valid, 1);
    check_eq("second-err err", d->err, 1);
    tick(d);
    d->dmem_err = 0;
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // Verify recovery
    set_inputs(d, 1, 0x3000, 0, 2, 0, 2);
    d->dmem_rdata = 0xBEEF1234;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("second-err recovery rdata_valid", d->rdata_valid, 1);
    check_eq("second-err recovery err", d->err, 0);
}

// ---- Error: crossing overflow (aligned_base + 4 wraps past 0xFFFFFFFF) ----
static void test_err_overflow(Vkv32_mem_fe* d) {
    printf("--- Error: crossing overflow ---\n");
    reset(d);

    // SW@0xFFFFFFFD: addr[1:0]=01 (crossing), addr[31:2] all-ones (overflow)
    set_inputs(d, 1, 0xFFFFFFFD, 0, 2, 0, 2);
    d->eval();
    check_eq("overflow req", d->dmem_req, 0);  // no beat issued
    check_eq("overflow rdata_valid", d->rdata_valid, 1);  // immediate completion
    check_eq("overflow err", d->err, 1);
    check_eq("overflow addr", d->dmem_addr, 0xFFFFFFFC);  // aligned_base
    tick(d);  // FSM stays in IDLE (no MA_FIRST entry)

    // Verify recovery with a normal access
    d->req = 0;
    d->eval();
    set_inputs(d, 1, 0x1000, 0, 2, 0, 2);
    d->dmem_rdata = 0xCAFEBABE;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("overflow recovery rdata_valid", d->rdata_valid, 1);
    check_eq("overflow recovery rdata", d->rdata, 0xCAFEBABE);
    check_eq("overflow recovery err", d->err, 0);

    // Also test SH@0xFFFFFFFF (crossing + overflow)
    reset(d);
    set_inputs(d, 1, 0xFFFFFFFF, 1, 1, 0xABCD, 0);  // SH store
    d->eval();
    check_eq("overflow SH req", d->dmem_req, 0);
    check_eq("overflow SH rdata_valid", d->rdata_valid, 1);
    check_eq("overflow SH err", d->err, 1);
}

// ---- Crossing access with multi-cycle latency (FSM holds under wait) ----
static void test_crossing_with_latency(Vkv32_mem_fe* d) {
    printf("--- Crossing with latency ---\n");
    reset(d);

    set_inputs(d, 1, 0x1003, 0, 1, 0, 1);  // SH@11 crossing load
    d->eval();
    check_eq("lat-cross cycle0 req", d->dmem_req, 1);
    tick(d);  // → MA_FIRST

    // MA_FIRST: hold for 2 cycles with no ack
    check_eq("lat-cross cycle1 req", d->dmem_req, 1);
    check_eq("lat-cross cycle1 rdata_valid", d->rdata_valid, 0);
    d->dmem_ack = 0; d->dmem_gnt = 0;
    d->eval();
    tick(d);  // stay in MA_FIRST

    check_eq("lat-cross cycle2 req", d->dmem_req, 1);
    check_eq("lat-cross cycle2 rdata_valid", d->rdata_valid, 0);
    tick(d);  // stay in MA_FIRST

    // Now ack the first beat
    d->dmem_rdata = 0x12345678;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("lat-cross first-ack rdata_valid", d->rdata_valid, 0);  // FIRST→BETWEEN, not done
    tick(d);
    d->dmem_ack = 0; d->dmem_gnt = 0;

    // The second-beat request stays presented while waiting for the first ack.
    check_eq("lat-cross between req", d->dmem_req, 1);
    tick(d);  // → MA_SECOND

    // MA_SECOND: hold for 2 cycles
    check_eq("lat-cross cycle5 req", d->dmem_req, 1);
    check_eq("lat-cross cycle5 addr", d->dmem_addr, 0x1004);
    check_eq("lat-cross cycle5 rdata_valid", d->rdata_valid, 0);
    d->dmem_ack = 0; d->dmem_gnt = 0;
    d->eval();
    tick(d);

    check_eq("lat-cross cycle6 rdata_valid", d->rdata_valid, 0);
    tick(d);

    // Ack the second beat
    d->dmem_rdata = 0xAABBCCDD;
    d->dmem_ack = 1; d->dmem_gnt = 1;
    d->eval();
    check_eq("lat-cross second-ack rdata_valid", d->rdata_valid, 1);
    check_eq("lat-cross second-ack rdata", d->rdata, 0xFFFFDD12);
    tick(d);
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
    test_load_extraction_all_offsets(d);
    test_aligned_flow(d);
    test_non_crossing_sh01(d);
    test_crossing_sh11_store(d);
    test_crossing_sh11_load(d);
    test_crossing_sw01_store(d);
    test_crossing_sw01_load(d);
    test_crossing_sw10(d);
    test_crossing_sw11(d);
    test_back_to_back(d);
    test_err_single_beat(d);
    test_err_first_beat_abort(d);
    test_err_second_beat(d);
    test_err_overflow(d);
    test_crossing_with_latency(d);
    test_reset(d);

    delete d;
    printf("\n=== tb_mem_fe: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
