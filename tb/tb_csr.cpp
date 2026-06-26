// tb_csr.cpp — unit test for kv32_csr
// Verifies: reset values, CSR read/write/set/clear, read-before-write,
//           read-only CSRs, mtvec MODE masking, mepc bit0 masking,
//           trap updates, MRET restore, counter increment/writes,
//           priority chain (trap > mret > csr_wen).

#include "Vkv32_csr.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

static void tick(Vkv32_csr* d) {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
}

static void idle(Vkv32_csr* d) {
    d->csr_addr = 0;
    d->csr_wdata = 0;
    d->csr_op = 0;       // CSR_OP_NONE
    d->csr_wen = 0;
    d->is_csr = 0;
    d->irq_external = 0;
    d->irq_timer = 0;
    d->irq_software = 0;
    d->trap_taken = 0;
    d->trap_pc = 0;
    d->trap_cause = 0;
    d->trap_val = 0;
    d->mret_taken = 0;
    d->instr_retired = 0;
}

static uint32_t read_csr(Vkv32_csr* d, uint16_t addr) {
    idle(d);
    d->csr_addr = addr;
    d->eval();
    return d->csr_rdata;
}

static uint32_t write_csr(Vkv32_csr* d, uint16_t addr, uint32_t wdata) {
    idle(d);
    d->csr_addr = addr;
    d->csr_wdata = wdata;
    d->csr_op = 1;       // CSR_OP_WRITE
    d->csr_wen = 1;
    d->eval();
    uint32_t old = d->csr_rdata;  // read-before-write
    tick(d);
    idle(d);
    return old;
}

static void expect_eq(const char* name, uint32_t got, uint32_t want) {
    tests++;
    if (got != want) {
        fprintf(stderr, "FAIL  %-30s got=0x%08X want=0x%08X\n", name, got, want);
        failures++;
    }
}

// CSR addresses
static const uint16_t CsrMstatus=0x300, CsrMisa=0x301, CsrMie=0x304,
    CsrMtvec=0x305, CsrMstatush=0x310, CsrMscratch=0x340,
    CsrMepc=0x341, CsrMcause=0x342, CsrMtval=0x343, CsrMip=0x344,
    CsrMvendorid=0xF11, CsrMarchid=0xF12, CsrMimpid=0xF13,
    CsrMhartid=0xF14, CsrMconfigptr=0xF15,
    CsrMcycle=0xB00, CsrMcycleh=0xB80,
    CsrMinstret=0xB02, CsrMinstreth=0xB82;

int main() {
    Verilated::traceEverOn(false);
    Vkv32_csr* d = new Vkv32_csr;

    // Reset
    d->clk = 0;
    d->rst_n = 0;
    idle(d);
    d->eval();
    tick(d);
    d->rst_n = 1;
    d->eval();

    // ---- Reset values ----
    expect_eq("reset mstatus", read_csr(d, CsrMstatus), 0x00001800); // mpp=11
    expect_eq("reset misa", read_csr(d, CsrMisa), 0x40001105);       // I+M+C+A
    expect_eq("reset mie", read_csr(d, CsrMie), 0);
    expect_eq("reset mtvec", read_csr(d, CsrMtvec), 0);
    expect_eq("reset mscratch", read_csr(d, CsrMscratch), 0);
    expect_eq("reset mepc", read_csr(d, CsrMepc), 0);
    expect_eq("reset mcause", read_csr(d, CsrMcause), 0);
    expect_eq("reset mtval", read_csr(d, CsrMtval), 0);
    expect_eq("reset mcycle", read_csr(d, CsrMcycle), 0);
    expect_eq("reset minstret", read_csr(d, CsrMinstret), 0);

    // ---- Identity CSRs (read-only, return 0) ----
    expect_eq("mvendorid", read_csr(d, CsrMvendorid), 0);
    expect_eq("marchid", read_csr(d, CsrMarchid), 0);
    expect_eq("mimpid", read_csr(d, CsrMimpid), 0);
    expect_eq("mhartid", read_csr(d, CsrMhartid), 0);
    expect_eq("mconfigptr", read_csr(d, CsrMconfigptr), 0);
    expect_eq("mstatush", read_csr(d, CsrMstatush), 0);

    // ---- CSRRW mscratch: read-before-write returns old, then new value ----
    expect_eq("mscratch old (RBW)", write_csr(d, CsrMscratch, 0xDEADBEEF), 0);
    expect_eq("mscratch after write", read_csr(d, CsrMscratch), 0xDEADBEEF);

    // ---- CSRRS mscratch: set bits ----
    idle(d);
    d->csr_addr = CsrMscratch;
    d->csr_wdata = 0x0000FF00;
    d->csr_op = 2; // CSR_OP_SET
    d->csr_wen = 1;
    d->eval();
    tick(d);
    expect_eq("mscratch after SET", read_csr(d, CsrMscratch), 0xDEADFFEF);

    // ---- CSRRC mscratch: clear bits ----
    idle(d);
    d->csr_addr = CsrMscratch;
    d->csr_wdata = 0x00FF0000;
    d->csr_op = 3; // CSR_OP_CLEAR
    d->csr_wen = 1;
    d->eval();
    tick(d);
    expect_eq("mscratch after CLEAR", read_csr(d, CsrMscratch), 0xDE00FFEF);

    // ---- mtvec MODE masking: write with MODE=3, read back MODE=0 ----
    write_csr(d, CsrMtvec, 0x80001203);
    expect_eq("mtvec MODE masked", read_csr(d, CsrMtvec), 0x80001200);

    // ---- mepc bit0 masking: write odd address, bit0 cleared ----
    write_csr(d, CsrMepc, 0x80000101);
    expect_eq("mepc bit0 cleared", read_csr(d, CsrMepc), 0x80000100);

    // ---- Read-only CSRs ignore writes ----
    write_csr(d, CsrMisa, 0xFFFFFFFF);
    expect_eq("misa write ignored", read_csr(d, CsrMisa), 0x40001105);
    write_csr(d, CsrMvendorid, 0xFFFFFFFF);
    expect_eq("mvendorid write ignored", read_csr(d, CsrMvendorid), 0);
    write_csr(d, CsrMstatush, 0xFFFFFFFF);
    expect_eq("mstatush write ignored", read_csr(d, CsrMstatush), 0);

    // ---- mstatus write: set MIE (bit 3) ----
    // Note: writing 0x08 sets MIE=1 but clears MPP to 00 (U-mode) because
    // MPP bits [12:11] are not in the write value. This is correct CSR
    // behavior — software must read-modify-write to preserve MPP.
    write_csr(d, CsrMstatus, 0x00000008); // MIE=1
    expect_eq("mstatus MIE=1 (MPP cleared)", read_csr(d, CsrMstatus), 0x00000008);

    // ---- Trap: check mepc, mcause, mtval, mstatus.mpie/mie/mpp ----
    idle(d);
    d->trap_taken = 1;
    d->trap_pc = 0x80000100;
    d->trap_cause = 0xB;      // Machine ECALL
    d->trap_val = 0;
    d->eval();
    tick(d);
    expect_eq("trap mepc", read_csr(d, CsrMepc), 0x80000100);
    expect_eq("trap mcause", read_csr(d, CsrMcause), 0xB);
    expect_eq("trap mtval", read_csr(d, CsrMtval), 0);
    // After trap: mpie=1 (saved mie), mie=0, mpp=11
    expect_eq("trap mstatus", read_csr(d, CsrMstatus), 0x00001880); // mpie=1, mie=0, mpp=11

    // ---- MRET: restore mstatus ----
    idle(d);
    d->mret_taken = 1;
    d->eval();
    tick(d);
    // After MRET: mie=mpie=1, mpie=1, mpp=11
    expect_eq("mret mstatus", read_csr(d, CsrMstatus), 0x00001888); // mpie=1, mie=1, mpp=11

    // ---- Counter: mcycle increments each cycle ----
    uint32_t cyc_before = read_csr(d, CsrMcycle);
    tick(d); // one idle cycle
    uint32_t cyc_after = read_csr(d, CsrMcycle);
    expect_eq("mcycle incremented", cyc_after, cyc_before + 1);

    // ---- Counter: minstret increments on instr_retired ----
    uint32_t inst_before = read_csr(d, CsrMinstret);
    idle(d);
    d->instr_retired = 1;
    d->eval();
    tick(d);
    uint32_t inst_after = read_csr(d, CsrMinstret);
    expect_eq("minstret incremented", inst_after, inst_before + 1);

    // ---- Counter writes: mcycle low/high ----
    write_csr(d, CsrMcycle, 0x12345678);
    write_csr(d, CsrMcycleh, 0x0000ABCD);
    expect_eq("mcycle low after write", read_csr(d, CsrMcycle), 0x12345678);
    // mcycle keeps incrementing after write, so read +1
    // (the write happens on the tick inside write_csr, then read_csr is
    //  combinational in the same cycle before the next tick)
    // Actually: write_csr ticks once (mcycle becomes 0x12345678+1 due to
    // the increment on the same clock edge), then read_csr is
    // combinational. So we read 0x12345679. Let me just check the high
    // word which is less affected by single-cycle increments.
    expect_eq("mcycleh after write", read_csr(d, CsrMcycleh), 0x0000ABCD);

    // ---- minstret write ----
    write_csr(d, CsrMinstret, 0xCAFEBABE);
    expect_eq("minstret after write", read_csr(d, CsrMinstret), 0xCAFEBABE);

    // ---- Priority: trap_taken > csr_wen ----
    // Set mscratch to a known value, then try CSRRW + trap simultaneously
    write_csr(d, CsrMscratch, 0x11111111);
    idle(d);
    d->csr_addr = CsrMscratch;
    d->csr_wdata = 0x22222222;
    d->csr_op = 1; // CSR_OP_WRITE
    d->csr_wen = 1;
    d->trap_taken = 1;
    d->trap_pc = 0x00000040;
    d->trap_cause = 0x2;
    d->trap_val = 0;
    d->eval();
    tick(d);
    // Trap should win: mscratch NOT written, mepc updated
    expect_eq("priority: mscratch unchanged", read_csr(d, CsrMscratch), 0x11111111);
    expect_eq("priority: mepc updated", read_csr(d, CsrMepc), 0x00000040);

    // ---- Priority: mret_taken > csr_wen ----
    // Set mstatus.MIE=0 first, then try CSRRW + MRET simultaneously
    write_csr(d, CsrMstatus, 0x00001800); // mie=0, mpie=0
    idle(d);
    d->csr_addr = CsrMstatus;
    d->csr_wdata = 0x00000008; // try to set MIE=1
    d->csr_op = 1; // CSR_OP_WRITE
    d->csr_wen = 1;
    d->mret_taken = 1;
    d->eval();
    tick(d);
    // MRET should win: mstatus NOT written by CSRRW, mpie set to 1 by MRET
    // After MRET with mpie=0: mie=mpie=0, mpie=1, mpp=11
    expect_eq("priority: mret over csr", read_csr(d, CsrMstatus), 0x00001880);

    // ---- MIP reads hardware-driven interrupt bits ----
    idle(d);
    d->irq_external = 1;
    d->irq_timer = 1;
    d->irq_software = 1;
    d->csr_addr = CsrMip;
    d->eval();
    // MEIP=bit11, MTIP=bit7, MSIP=bit3
    expect_eq("mip all irqs", d->csr_rdata, 0x00000888);
    d->irq_external = 0;
    d->irq_timer = 0;
    d->irq_software = 0;
    d->eval();
    expect_eq("mip no irqs", d->csr_rdata, 0);

    // ---- MIP writes ignored ----
    write_csr(d, CsrMip, 0xFFFFFFFF);
    expect_eq("mip write ignored", read_csr(d, CsrMip), 0);

    // ---- csr_illegal: unimplemented CSR (any access) ----
    // satp (0x180) and cycle (0xC00) are not implemented → illegal on read.
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0x180; // satp
    d->eval();
    expect_eq("satp read illegal", d->csr_illegal, 1);
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0xC00; // cycle (U-mode counter, unimplemented)
    d->eval();
    expect_eq("cycle read illegal", d->csr_illegal, 1);

    // ---- csr_illegal: implemented RW CSR (read and write legal) ----
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMscratch;
    d->eval();
    expect_eq("mscratch read legal", d->csr_illegal, 0);
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMscratch;
    d->csr_wdata = 0xAAAAAAAA;
    d->csr_op = 1; // CSR_OP_WRITE
    d->csr_wen = 1;
    d->eval();
    expect_eq("mscratch write legal", d->csr_illegal, 0);

    // ---- csr_illegal: read-only CSR write is illegal, read is legal ----
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMvendorid;
    d->eval();
    expect_eq("mvendorid read legal", d->csr_illegal, 0);
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMvendorid;
    d->csr_wdata = 0xFFFFFFFF;
    d->csr_op = 1; // CSR_OP_WRITE
    d->csr_wen = 1;
    d->eval();
    expect_eq("mvendorid write illegal", d->csr_illegal, 1);
    // CSRRS with rs1=x0 (csr_wen=0) reading a read-only CSR is legal.
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMvendorid;
    d->csr_op = 2; // CSR_OP_SET
    d->csr_wen = 0;
    d->eval();
    expect_eq("mvendorid CSRRS x0 legal", d->csr_illegal, 0);

    // ---- csr_illegal: non-CSR instruction never reports illegal ----
    idle(d);
    d->is_csr = 0;
    d->csr_addr = 0x180; // would be illegal if accessed
    d->eval();
    expect_eq("non-csr not illegal", d->csr_illegal, 0);

    delete d;
    printf("\n=== tb_csr: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
