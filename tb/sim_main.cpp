#include "Vkv32_core.h"
#include "Vkv32_core___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

// ============================================================================
// BRAM Memory Model (64 KiB, word-addressed, byte-enable writes)
// ============================================================================
static const int BRAM_WORDS = 16384; // 64 KiB / 4
static uint32_t bram[BRAM_WORDS];

static void bram_write(uint32_t addr, uint32_t wdata, uint8_t be) {
    int idx = (addr >> 2) & 0x3FFF;
    if (be & 1) bram[idx] = (bram[idx] & 0xFFFFFF00) | (wdata & 0x000000FF);
    if (be & 2) bram[idx] = (bram[idx] & 0xFFFF00FF) | (wdata & 0x0000FF00);
    if (be & 4) bram[idx] = (bram[idx] & 0xFF00FFFF) | (wdata & 0x00FF0000);
    if (be & 8) bram[idx] = (bram[idx] & 0x00FFFFFF) | (wdata & 0xFF000000);
}

static uint32_t bram_read(uint32_t addr) {
    return bram[(addr >> 2) & 0x3FFF];
}

// ============================================================================
// Test Program Loader
// ============================================================================
struct TestWord {
    int addr_word;  // word index into bram
    uint32_t data;
};

// Test 1: Basic ALU — ADDI x1, x0, 5; ADDI x2, x0, 10; ADD x3, x1, x2
static const TestWord prog_alu[] = {
    {0, 0x00500093}, // ADDI x1, x0, 5
    {1, 0x00A00113}, // ADDI x2, x0, 10
    {2, 0x002081B3}, // ADD  x3, x1, x2
    {3, 0x00000013}, // NOP
};

// Test 2: Sub-word memory access
static const TestWord prog_subword[] = {
    {0,  0x05500093}, // ADDI x1, x0, 0x55
    {1,  0x05500113}, // ADDI x2, x0, 0x55
    {2,  0x00102023}, // SW   x1, 0(x0)
    {3,  0x00202223}, // SW   x2, 4(x0)
    {4,  0x00000183}, // LB   x3, 0(x0)
    {5,  0x00100203}, // LB   x4, 1(x0)
    {6,  0x00004283}, // LBU  x5, 0(x0)
    {7,  0x00401303}, // LH   x6, 4(x0)
    {8,  0x00405383}, // LHU  x7, 4(x0)
    {9,  0x0FF00413}, // ADDI x8, x0, 0xFF
    {10, 0x00800123}, // SB   x8, 2(x0)
    {11, 0x00204483}, // LBU  x9, 2(x0)
    {12, 0x23400513}, // ADDI x10, x0, 0x234
    {13, 0x00A01323}, // SH   x10, 6(x0)
    {14, 0x00605583}, // LHU  x11, 6(x0)
    {15, 0x00000013}, // NOP
};

struct RegCheck {
    int   reg;
    uint32_t expected;
    const char *label;
};

// Test 1 expected results
static const RegCheck check_alu[] = {
    {1,  0x00000005, "x1 (ADDI 5)"},
    {2,  0x0000000A, "x2 (ADDI 10)"},
    {3,  0x0000000F, "x3 (ADD x1+x2)"},
    {0,  0, nullptr} // sentinel
};

// Test 2 expected results
static const RegCheck check_subword[] = {
    {1,  0x00000055, "x1  (0x55)"},
    {2,  0x00000055, "x2  (0x55)"},
    {3,  0x00000055, "x3  (LB 0x55)"},
    {4,  0x00000000, "x4  (LB 0x00)"},
    {5,  0x00000055, "x5  (LBU 0x55)"},
    {6,  0x00000055, "x6  (LH 0x55)"},
    {7,  0x00000055, "x7  (LHU 0x55)"},
    {8,  0x000000FF, "x8  (0xFF)"},
    {9,  0x000000FF, "x9  (LBU 0xFF)"},
    {10, 0x00000234, "x10 (0x234)"},
    {11, 0x00000234, "x11 (LHU 0x234)"},
    {0,  0, nullptr}
};

// ============================================================================
// Test framework
// ============================================================================
static vluint64_t sim_time = 0;
static int fail_count = 0;

static void tick(Vkv32_core* top, VerilatedVcdC* tfp) {
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(sim_time++);
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(sim_time++);
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(sim_time++);
}

// Reset: hold rst_n low for 2 cycles
static void reset(Vkv32_core* top, VerilatedVcdC* tfp) {
    top->rst_n = 0;
    tick(top, tfp);
    tick(top, tfp);
    top->rst_n = 1;
}

// Memory responder: implements the simple req/gnt/valid protocol
// Same timing as the SV testbench: gnt arrives 1 cycle after req,
// valid arrives 1 cycle after gnt (2 cycles after initial req).
static struct MemState {
    uint32_t rdata;
    bool     gnt_reg;
    bool     valid_reg;
} mem;

static void mem_responder(Vkv32_core* top) {
    // gnt follows req with 1-cycle delay
    mem.gnt_reg = top->mem_req;

    if (top->mem_req && mem.gnt_reg) {
        if (top->mem_we) {
            bram_write(top->mem_addr, top->mem_wdata, top->mem_be);
        } else {
            mem.rdata = bram_read(top->mem_addr);
        }
    }

    // valid = req & gnt (both registered, so 2-cycle latency from first req)
    mem.valid_reg = top->mem_req && mem.gnt_reg;

    top->mem_gnt   = mem.gnt_reg;
    top->mem_valid = mem.valid_reg;
    top->mem_rdata = mem.rdata;
    top->mem_err   = 0;
}

static void load_program(const TestWord* prog, int count) {
    memset(bram, 0, sizeof(bram));
    for (int i = 0; i < count; i++) {
        bram[prog[i].addr_word] = prog[i].data;
    }
}

static uint32_t read_reg(Vkv32_core* top, int reg) {
    // Access the register file via the DUT's internal signal through rootp
    return top->rootp->kv32_core__DOT__u_regfile__DOT__regs[reg];
}

static void run_and_check(Vkv32_core* top, VerilatedVcdC* tfp,
                          const RegCheck* checks, int max_cycles) {
    for (int i = 0; i < max_cycles; i++) {
        mem_responder(top);
        tick(top, tfp);
    }

    printf("\n=== Test Results ===\n");
    int pass = 0, total = 0;
    for (const RegCheck* c = checks; c->label != nullptr; c++) {
        total++;
        uint32_t val = read_reg(top, c->reg);
        bool ok = (val == c->expected);
        if (ok) {
            pass++;
            printf("  PASS: %s = 0x%08X\n", c->label, val);
        } else {
            fail_count++;
            printf("  FAIL: %s = 0x%08X (expected 0x%08X)\n", c->label, val, c->expected);
        }
    }
    printf("  %d/%d checks passed\n", pass, total);
    printf("====================\n");
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    bool trace = true;
    int test_id = 0; // 0=alu, 1=subword

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--notrace") == 0) trace = false;
        if (strcmp(argv[i], "--test") == 0 && i + 1 < argc) test_id = atoi(argv[++i]);
    }

    Vkv32_core* top = new Vkv32_core;
    VerilatedVcdC* tfp = nullptr;
    if (trace) {
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("kv32_core_tb.vcd");
    }

    // Initialize inputs
    top->clk = 0;
    top->rst_n = 0;
    top->irq_external_i = 0;
    top->mem_gnt = 0;
    top->mem_valid = 0;
    top->mem_rdata = 0;
    top->mem_err = 0;
    mem = {0, false, false};

    if (test_id == 0) {
        printf("Running ALU test (test 0)...\n");
        load_program(prog_alu, sizeof(prog_alu) / sizeof(prog_alu[0]));
        reset(top, tfp);
        run_and_check(top, tfp, check_alu, 200);
    } else if (test_id == 1) {
        printf("Running sub-word memory test (test 1)...\n");
        load_program(prog_subword, sizeof(prog_subword) / sizeof(prog_subword[0]));
        reset(top, tfp);
        run_and_check(top, tfp, check_subword, 400);
    } else {
        printf("Unknown test id: %d\n", test_id);
        printf("Usage: %s [--notrace] [--test <0|1>]\n", argv[0]);
        printf("  0 = ALU test (default)\n");
        printf("  1 = Sub-word memory test\n");
    }

    if (tfp) {
        tfp->close();
        delete tfp;
    }
    top->final();
    delete top;

    return fail_count ? EXIT_FAILURE : EXIT_SUCCESS;
}
