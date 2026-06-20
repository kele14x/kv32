// tb_mem_arbiter.cpp — unit test for kv32_mem_arbiter
// Verifies: d-port priority, zero-latency response, multi-cycle latency,
//           one-cycle gnt pulse (granted flag), request field pass-through,
//           latched d-port fields during D_PORT_ACTIVE, arb_idle signal.

#include "Vkv32_mem_arbiter.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void tick(Vkv32_mem_arbiter* d) {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
}

static void idle_inputs(Vkv32_mem_arbiter* d) {
    d->i_req = 0; d->i_addr = 0;
    d->d_req = 0; d->d_addr = 0; d->d_we = 0; d->d_size = 0;
    d->d_wdata = 0; d->d_be = 0; d->d_excl = 0;
    d->mem_gnt = 0; d->mem_valid = 0; d->mem_rdata = 0; d->mem_err = 0;
}

static void expect_eq(const char* name, uint32_t got, uint32_t want) {
    tests++;
    if (got != want) {
        fprintf(stderr, "FAIL  %-35s got=0x%X want=0x%X\n", name, got, want);
        failures++;
    }
}

int main() {
    Verilated::traceEverOn(false);
    Vkv32_mem_arbiter* d = new Vkv32_mem_arbiter;

    // Reset
    d->clk = 0; d->rst_n = 0;
    idle_inputs(d);
    d->eval();
    tick(d);
    d->rst_n = 1;
    d->eval();

    expect_eq("reset arb_idle", d->arb_idle, 1);

    // ============================================================
    // 1. Zero-latency i-port fetch (mem_gnt + mem_valid same cycle)
    // ============================================================
    idle_inputs(d);
    d->i_req = 1; d->i_addr = 0x80000100;
    d->mem_gnt = 1; d->mem_valid = 1; d->mem_rdata = 0x12345678;
    d->eval();
    expect_eq("i-port zero-lat i_gnt", d->i_gnt, 1);
    expect_eq("i-port zero-lat i_valid", d->i_valid, 1);
    expect_eq("i-port zero-lat i_rdata", d->i_rdata, 0x12345678);
    expect_eq("i-port zero-lat d_gnt", d->d_gnt, 0);
    expect_eq("i-port zero-lat arb_idle", d->arb_idle, 1); // stays IDLE
    expect_eq("i-port mem_addr", d->mem_addr, 0x80000100);
    expect_eq("i-port mem_we", d->mem_we, 0);
    expect_eq("i-port mem_be", d->mem_be, 0xF);
    tick(d); // should stay IDLE

    // ============================================================
    // 2. Zero-latency d-port read
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80002000; d->d_size = 2; d->d_be = 0xF;
    d->mem_gnt = 1; d->mem_valid = 1; d->mem_rdata = 0xDEADBEEF;
    d->eval();
    expect_eq("d-port zero-lat d_gnt", d->d_gnt, 1);
    expect_eq("d-port zero-lat d_valid", d->d_valid, 1);
    expect_eq("d-port zero-lat d_rdata", d->d_rdata, 0xDEADBEEF);
    expect_eq("d-port zero-lat i_gnt", d->i_gnt, 0);
    expect_eq("d-port zero-lat arb_idle", d->arb_idle, 1);
    tick(d);

    // ============================================================
    // 3. d-port priority over i-port (both req, zero-latency)
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80002000;
    d->i_req = 1; d->i_addr = 0x80000100;
    d->mem_gnt = 1; d->mem_valid = 1; d->mem_rdata = 0xAAAAAAAA;
    d->eval();
    expect_eq("priority d_gnt", d->d_gnt, 1);
    expect_eq("priority i_gnt", d->i_gnt, 0);
    expect_eq("priority d_valid", d->d_valid, 1);
    expect_eq("priority i_valid", d->i_valid, 0);
    expect_eq("priority d_rdata", d->d_rdata, 0xAAAAAAAA);
    expect_eq("priority mem_addr (d)", d->mem_addr, 0x80002000);
    tick(d);

    // ============================================================
    // 4. Zero-latency d-port write (field pass-through)
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80003000; d->d_we = 1; d->d_size = 2;
    d->d_wdata = 0xCAFEBABE; d->d_be = 0xF; d->d_excl = 0;
    d->mem_gnt = 1; d->mem_valid = 1;
    d->eval();
    expect_eq("d-write d_gnt", d->d_gnt, 1);
    expect_eq("d-write d_valid", d->d_valid, 1);
    expect_eq("d-write mem_we", d->mem_we, 1);
    expect_eq("d-write mem_addr", d->mem_addr, 0x80003000);
    expect_eq("d-write mem_wdata", d->mem_wdata, 0xCAFEBABE);
    expect_eq("d-write mem_be", d->mem_be, 0xF);
    tick(d);

    // ============================================================
    // 5. Multi-cycle d-port: gnt cycle 1, valid cycle 2
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80004000; d->d_size = 2; d->d_be = 0xF;
    d->mem_gnt = 1; d->mem_valid = 0;  // grant but no response yet
    d->eval();
    expect_eq("multi d_gnt (cycle 1)", d->d_gnt, 1);
    expect_eq("multi d_valid (cycle 1)", d->d_valid, 0);
    expect_eq("multi arb_idle (cycle 1)", d->arb_idle, 1); // still IDLE this cycle
    tick(d); // transition to D_PORT_ACTIVE

    // Cycle 2: response arrives
    d->mem_gnt = 0; d->mem_valid = 1; d->mem_rdata = 0x11223344;
    d->eval();
    expect_eq("multi d_valid (cycle 2)", d->d_valid, 1);
    expect_eq("multi d_rdata (cycle 2)", d->d_rdata, 0x11223344);
    expect_eq("multi d_gnt (cycle 2, pulse)", d->d_gnt, 0); // one-cycle pulse
    expect_eq("multi arb_idle (cycle 2)", d->arb_idle, 0); // D_PORT_ACTIVE
    tick(d); // transition back to IDLE

    expect_eq("multi arb_idle (back to idle)", d->arb_idle, 1);

    // ============================================================
    // 6. Multi-cycle i-port: gnt cycle 1, valid cycle 2
    // ============================================================
    idle_inputs(d);
    d->i_req = 1; d->i_addr = 0x80000500;
    d->mem_gnt = 1; d->mem_valid = 0;
    d->eval();
    expect_eq("multi-i i_gnt (cycle 1)", d->i_gnt, 1);
    expect_eq("multi-i i_valid (cycle 1)", d->i_valid, 0);
    tick(d); // transition to I_PORT_ACTIVE

    d->mem_gnt = 0; d->mem_valid = 1; d->mem_rdata = 0x99887766;
    d->eval();
    expect_eq("multi-i i_valid (cycle 2)", d->i_valid, 1);
    expect_eq("multi-i i_rdata (cycle 2)", d->i_rdata, 0x99887766);
    expect_eq("multi-i i_gnt (cycle 2, pulse)", d->i_gnt, 0);
    expect_eq("multi-i arb_idle (cycle 2)", d->arb_idle, 0);
    tick(d);

    // ============================================================
    // 7. One-cycle gnt pulse: mem_gnt held high for 2 cycles
    //    during multi-cycle transaction. d_gnt should only pulse once.
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80006000; d->d_be = 0xF;
    d->mem_gnt = 1; d->mem_valid = 0; // grant, no response
    d->eval();
    expect_eq("pulse d_gnt (cycle 1)", d->d_gnt, 1);
    tick(d); // -> D_PORT_ACTIVE, granted=1

    // Cycle 2: mem_gnt still high, but granted=1 so d_gnt should be 0
    d->mem_gnt = 1; d->mem_valid = 0;
    d->eval();
    expect_eq("pulse d_gnt (cycle 2, suppressed)", d->d_gnt, 0);
    expect_eq("pulse mem_req (held)", d->mem_req, 1);
    tick(d);

    // Cycle 3: response arrives
    d->mem_gnt = 0; d->mem_valid = 1; d->mem_rdata = 0x55555555;
    d->eval();
    expect_eq("pulse d_valid (cycle 3)", d->d_valid, 1);
    expect_eq("pulse d_rdata (cycle 3)", d->d_rdata, 0x55555555);
    tick(d);

    // ============================================================
    // 8. Latched d-port fields: d_req drops but latched values
    //    hold mem_req stable during D_PORT_ACTIVE
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80007000; d->d_we = 1;
    d->d_wdata = 0xBBBB2222; d->d_be = 0xA; d->d_size = 1; d->d_excl = 1;
    d->mem_gnt = 1; d->mem_valid = 0;
    d->eval();
    tick(d); // -> D_PORT_ACTIVE, d-port fields latched

    // Now drop d_req — latched fields should hold
    d->d_req = 0; d->d_addr = 0; d->d_we = 0; d->d_wdata = 0;
    d->d_be = 0; d->d_size = 0; d->d_excl = 0;
    d->mem_gnt = 0; d->mem_valid = 0;
    d->eval();
    expect_eq("latch mem_req (held)", d->mem_req, 1);
    expect_eq("latch mem_addr", d->mem_addr, 0x80007000);
    expect_eq("latch mem_we", d->mem_we, 1);
    expect_eq("latch mem_wdata", d->mem_wdata, 0xBBBB2222);
    expect_eq("latch mem_be", d->mem_be, 0xA);
    expect_eq("latch mem_excl", d->mem_excl, 1);
    tick(d);

    // Complete the transaction
    d->mem_valid = 1; d->mem_rdata = 0;
    d->eval();
    expect_eq("latch d_valid (complete)", d->d_valid, 1);
    tick(d);

    // ============================================================
    // 9. No request → arb_idle, mem_req=0
    // ============================================================
    idle_inputs(d);
    d->eval();
    expect_eq("idle arb_idle", d->arb_idle, 1);
    expect_eq("idle mem_req", d->mem_req, 0);
    expect_eq("idle d_gnt", d->d_gnt, 0);
    expect_eq("idle i_gnt", d->i_gnt, 0);

    // ============================================================
    // 10. d_req without mem_gnt → stays IDLE, no gnt
    // ============================================================
    idle_inputs(d);
    d->d_req = 1; d->d_addr = 0x80008000;
    d->mem_gnt = 0; d->mem_valid = 0; // no grant
    d->eval();
    expect_eq("no-gnt d_gnt", d->d_gnt, 0);
    expect_eq("no-gnt mem_req", d->mem_req, 1); // requesting
    expect_eq("no-gnt arb_idle", d->arb_idle, 1); // still IDLE
    tick(d);
    expect_eq("no-gnt still IDLE", d->arb_idle, 1);

    delete d;
    printf("\n=== tb_mem_arbiter: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
