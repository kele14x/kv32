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
    d->priv_mode = 3;    // PRIV_M (2'b11)
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
    d->trap_to_smode = 0;
    d->mret_taken = 0;
    d->sret_taken = 0;
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

// Helper functions for checking CSR legality from different privilege modes
static bool is_csr_illegal(Vkv32_csr* d, uint16_t addr) {
    idle(d);
    d->priv_mode = 3;  // PRIV_M
    d->csr_addr = addr;
    d->is_csr = 1;
    d->eval();
    bool result = d->csr_illegal;
    idle(d);
    return result;
}

static bool is_csr_illegal_from_s(Vkv32_csr* d, uint16_t addr) {
    idle(d);
    d->priv_mode = 1;  // PRIV_S
    d->csr_addr = addr;
    d->is_csr = 1;
    d->eval();
    bool result = d->csr_illegal;
    idle(d);
    return result;
}

static bool is_csr_illegal_from_u(Vkv32_csr* d, uint16_t addr) {
    idle(d);
    d->priv_mode = 0;  // PRIV_U
    d->csr_addr = addr;
    d->is_csr = 1;
    d->eval();
    bool result = d->csr_illegal;
    idle(d);
    return result;
}

// CSR addresses
static const uint16_t CsrMstatus=0x300, CsrMisa=0x301, CsrMie=0x304,
    CsrMtvec=0x305, CsrMcounteren=0x306, CsrMstatush=0x310, CsrMscratch=0x340,
    CsrMepc=0x341, CsrMcause=0x342, CsrMtval=0x343, CsrMip=0x344,
    CsrMvendorid=0xF11, CsrMarchid=0xF12, CsrMimpid=0xF13,
    CsrMhartid=0xF14, CsrMconfigptr=0xF15,
    CsrMcycle=0xB00, CsrMcycleh=0xB80,
    CsrMinstret=0xB02, CsrMinstreth=0xB82,
    // Phase 5: S-mode and delegation CSRs
    CsrSstatus=0x100, CsrSie=0x104, CsrStvec=0x105,
    CsrSscratch=0x140, CsrSepc=0x141, CsrScause=0x142, CsrStval=0x143,
    CsrSip=0x144, CsrSatp=0x180,
    CsrMedeleg=0x302, CsrMideleg=0x303,
    CsrScounteren=0x106, CsrMcounteren_p5=0x306,
    // U-mode counters
    CsrCycle=0xC00, CsrTime=0xC01, CsrInstret=0xC02,
    CsrCycleh=0xC80, CsrTimeh=0xC81, CsrInstreth=0xC82;

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
    expect_eq("reset misa", read_csr(d, CsrMisa), 0x40141105);       // I+M+C+A+S+U
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
    expect_eq("misa write ignored", read_csr(d, CsrMisa), 0x40141105);
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

    // ---- MIP writes: only SSIP (bit 1) is software-writable ----
    write_csr(d, CsrMip, 0xFFFFFFFF);
    expect_eq("mip write sets SSIP only", read_csr(d, CsrMip), 0x00000002);
    write_csr(d, CsrMip, 0);  // Clear SSIP
    expect_eq("mip clear SSIP", read_csr(d, CsrMip), 0);

    // ---- csr_illegal: satp (0x180) is now implemented (S-mode CSR) ----
    // From M-mode, satp access is legal
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0x180; // satp
    d->eval();
    expect_eq("satp read legal from M", d->csr_illegal, 0);
    // From S-mode, satp access is legal (unless TVM=1)
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0x180;
    d->priv_mode = 1; // PRIV_S
    d->eval();
    expect_eq("satp read legal from S", d->csr_illegal, 0);
    // From U-mode, satp access is illegal
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0x180;
    d->priv_mode = 0; // PRIV_U
    d->eval();
    expect_eq("satp read illegal from U", d->csr_illegal, 1);

    // ---- csr_illegal: cycle (0xC00) is now implemented (U-mode counter) ----
    // From M-mode, always legal
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0xC00; // cycle
    d->priv_mode = 3; // PRIV_M
    d->eval();
    expect_eq("cycle read legal from M", d->csr_illegal, 0);
    // From S-mode, gated by mcounteren[0] (currently 0 → illegal)
    idle(d);
    d->is_csr = 1;
    d->csr_addr = 0xC00;
    d->priv_mode = 1; // PRIV_S
    d->eval();
    expect_eq("cycle read illegal from S (mcounteren=0)", d->csr_illegal, 1);

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

    // ---- Privilege mode checking (Phase 5) ----
    // M-mode CSRs should be illegal when accessed from S-mode or U-mode
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMstatus;
    d->priv_mode = 1; // PRIV_S (2'b01)
    d->eval();
    expect_eq("mstatus from S-mode illegal", d->csr_illegal, 1);
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMstatus;
    d->priv_mode = 0; // PRIV_U (2'b00)
    d->eval();
    expect_eq("mstatus from U-mode illegal", d->csr_illegal, 1);
    idle(d);
    d->is_csr = 1;
    d->csr_addr = CsrMstatus;
    d->priv_mode = 3; // PRIV_M (2'b11)
    d->eval();
    expect_eq("mstatus from M-mode legal", d->csr_illegal, 0);

    // ---- Phase 5: S-mode CSR tests ----

    // sstatus is a masked view of mstatus (mask 0x000C_0122)
    // Reset mstatus first
    write_csr(d, CsrMstatus, 0);  // Clear all fields
    // Set some mstatus fields via mstatus write
    write_csr(d, CsrMstatus, 0x000C19AA);  // Set all writable bits
    // Read sstatus — only SIE[1], SPIE[5], SPP[8], SUM[18], MXR[19] visible
    expect_eq("sstatus masked read", read_csr(d, CsrSstatus), 0x000C0122);

    // Write via sstatus — only sstatus bits should change in mstatus
    write_csr(d, CsrMstatus, 0);  // Clear all
    write_csr(d, CsrSstatus, 0x000C0122);  // Set all sstatus-visible bits
    uint32_t ms = read_csr(d, CsrMstatus);
    expect_eq("sstatus write affects mstatus SIE", ms & 0x2, 0x2);      // SIE
    expect_eq("sstatus write affects mstatus SPIE", ms & 0x20, 0x20);   // SPIE
    expect_eq("sstatus write affects mstatus SPP", ms & 0x100, 0x100);  // SPP
    expect_eq("sstatus write affects mstatus SUM", ms & 0x40000, 0x40000); // SUM
    expect_eq("sstatus write affects mstatus MXR", ms & 0x80000, 0x80000); // MXR
    // M-mode bits should NOT be changed by sstatus write
    expect_eq("sstatus write preserves MIE", ms & 0x8, 0);    // MIE unchanged (0)
    expect_eq("sstatus write preserves MPP", ms & 0x1800, 0); // MPP unchanged (00)

    // sie is mie masked by mideleg
    write_csr(d, CsrMie, 0);
    write_csr(d, CsrMideleg, 0x00000222);  // Delegate S-mode interrupts (1,5,9)
    write_csr(d, CsrSie, 0xFFFFFFFF);  // Try to set all bits
    // Only delegated bits should be set in mie
    expect_eq("sie write only delegated bits", read_csr(d, CsrMie), 0x00000222);
    expect_eq("sie read = mie & mideleg", read_csr(d, CsrSie), 0x00000222);

    // S-mode trap CSRs are independent from M-mode
    write_csr(d, CsrMepc, 0xAAAA0000);
    write_csr(d, CsrSepc, 0x55550000);
    expect_eq("sepc independent from mepc", read_csr(d, CsrSepc), 0x55550000);
    expect_eq("mepc unchanged after sepc write", read_csr(d, CsrMepc), 0xAAAA0000);

    write_csr(d, CsrMcause, 0x11111111);
    write_csr(d, CsrScause, 0x22222222);
    expect_eq("scause independent from mcause", read_csr(d, CsrScause), 0x22222222);
    expect_eq("mcause unchanged after scause write", read_csr(d, CsrMcause), 0x11111111);

    // stvec allows vectored mode (MODE=1)
    write_csr(d, CsrStvec, 0x80000101);  // BASE=0x80000100, MODE=1 (vectored)
    expect_eq("stvec vectored mode", read_csr(d, CsrStvec), 0x80000101);
    write_csr(d, CsrStvec, 0x80000102);  // MODE=2 (invalid, should force to 0)
    expect_eq("stvec invalid mode forced to 0", read_csr(d, CsrStvec), 0x80000100);

    // mtvec also allows vectored mode now
    write_csr(d, CsrMtvec, 0x80000201);  // BASE=0x80000200, MODE=1 (vectored)
    expect_eq("mtvec vectored mode", read_csr(d, CsrMtvec), 0x80000201);

    // medeleg: bit 11 (ECALL from M) hardwired 0
    write_csr(d, CsrMedeleg, 0xFFFFFFFF);
    expect_eq("medeleg bit 11 hardwired 0", read_csr(d, CsrMedeleg), 0xFFFFF7FF);

    // mideleg: bits 3,7,11 (M-mode interrupts) hardwired 0
    write_csr(d, CsrMideleg, 0xFFFFFFFF);
    expect_eq("mideleg bits 3,7,11 hardwired 0", read_csr(d, CsrMideleg), 0xFFFFF777);

    // satp read/write
    write_csr(d, CsrSatp, 0x80000000);
    expect_eq("satp write/read", read_csr(d, CsrSatp), 0x80000000);

    // sscratch
    write_csr(d, CsrSscratch, 0xDEADBEEF);
    expect_eq("sscratch write/read", read_csr(d, CsrSscratch), 0xDEADBEEF);

    // scounteren
    write_csr(d, CsrScounteren, 0x00000005);  // cycle + instret bits
    expect_eq("scounteren write/read", read_csr(d, CsrScounteren), 0x00000005);

    // S-mode trap: update S-mode CSRs
    write_csr(d, CsrMstatus, 0x00000002);  // Set SIE=1
    idle(d);
    d->priv_mode = 1;  // PRIV_S
    d->trap_taken = 1;
    d->trap_to_smode = 1;
    d->trap_pc = 0x80000200;
    d->trap_cause = 0x8;  // ECALL from U-mode
    d->trap_val = 0x73;
    d->eval();
    tick(d);
    expect_eq("S-trap sepc", read_csr(d, CsrSepc), 0x80000200);
    expect_eq("S-trap scause", read_csr(d, CsrScause), 0x8);
    expect_eq("S-trap stval", read_csr(d, CsrStval), 0x73);
    // After S-trap: spie=sie=1, sie=0, spp=1 (from S-mode)
    uint32_t sms = read_csr(d, CsrMstatus);
    expect_eq("S-trap spie=1", (sms >> 5) & 1, 1);
    expect_eq("S-trap sie=0", sms & 0x2, 0);
    expect_eq("S-trap spp=1", (sms >> 8) & 1, 1);
    // M-mode trap CSRs should NOT be updated
    expect_eq("S-trap mepc unchanged", read_csr(d, CsrMepc), 0xAAAA0000);

    // SRET: restore sstatus fields
    idle(d);
    d->sret_taken = 1;
    d->eval();
    tick(d);
    // After SRET: sie=spie=1, spie=1, spp=0
    sms = read_csr(d, CsrMstatus);
    expect_eq("sret sie=spie", sms & 0x2, 0x2);       // SIE restored
    expect_eq("sret spie=1", (sms >> 5) & 1, 1);      // SPIE set to 1
    expect_eq("sret spp=0", (sms >> 8) & 1, 0);       // SPP cleared

    // ========== Stage 7: Counter access gating and final access control ==========

    // Reset privilege mode to M-mode for counter tests
    idle(d);
    d->priv_mode = 3;  // PRIV_M

    // M-mode: cycle/instret always accessible
    expect_eq("M-mode cycle access", is_csr_illegal(d, CsrCycle), 0);
    expect_eq("M-mode cycleh access", is_csr_illegal(d, CsrCycleh), 0);
    expect_eq("M-mode instret access", is_csr_illegal(d, CsrInstret), 0);
    expect_eq("M-mode instreth access", is_csr_illegal(d, CsrInstreth), 0);

    // time/timeh: always illegal (not implemented)
    expect_eq("M-mode time illegal", is_csr_illegal(d, CsrTime), 1);
    expect_eq("M-mode timeh illegal", is_csr_illegal(d, CsrTimeh), 1);
    expect_eq("S-mode time illegal", is_csr_illegal_from_s(d, CsrTime), 1);
    expect_eq("S-mode timeh illegal", is_csr_illegal_from_s(d, CsrTimeh), 1);
    expect_eq("U-mode time illegal", is_csr_illegal_from_u(d, CsrTime), 1);
    expect_eq("U-mode timeh illegal", is_csr_illegal_from_u(d, CsrTimeh), 1);

    // S-mode counter access gated by mcounteren
    // mcounteren currently has 0 (no bits set)
    expect_eq("S-mode cycle blocked (mcounteren=0)", is_csr_illegal_from_s(d, CsrCycle), 1);
    expect_eq("S-mode instret blocked (mcounteren=0)", is_csr_illegal_from_s(d, CsrInstret), 1);

    // Set mcounteren to allow cycle (bit 0)
    write_csr(d, CsrMcounteren, 0x00000001);
    expect_eq("S-mode cycle allowed (mcounteren[0]=1)", is_csr_illegal_from_s(d, CsrCycle), 0);
    expect_eq("S-mode cycleh allowed (mcounteren[0]=1)", is_csr_illegal_from_s(d, CsrCycleh), 0);
    expect_eq("S-mode instret still blocked (mcounteren[2]=0)", is_csr_illegal_from_s(d, CsrInstret), 1);

    // Set mcounteren to allow both cycle and instret
    write_csr(d, CsrMcounteren, 0x00000005);  // bits 0 and 2
    expect_eq("S-mode cycle allowed", is_csr_illegal_from_s(d, CsrCycle), 0);
    expect_eq("S-mode instret allowed", is_csr_illegal_from_s(d, CsrInstret), 0);

    // U-mode counter access gated by both mcounteren AND scounteren
    // Reset scounteren to 0 to test blocking
    write_csr(d, CsrScounteren, 0x00000000);
    expect_eq("U-mode cycle blocked (scounteren[0]=0)", is_csr_illegal_from_u(d, CsrCycle), 1);
    expect_eq("U-mode instret blocked (scounteren[2]=0)", is_csr_illegal_from_u(d, CsrInstret), 1);

    // Set scounteren to allow cycle (bit 0)
    write_csr(d, CsrScounteren, 0x00000001);
    expect_eq("U-mode cycle allowed (both enables)", is_csr_illegal_from_u(d, CsrCycle), 0);
    expect_eq("U-mode instret still blocked (scounteren[2]=0)", is_csr_illegal_from_u(d, CsrInstret), 1);

    // Set scounteren to allow both
    write_csr(d, CsrScounteren, 0x00000005);
    expect_eq("U-mode cycle allowed", is_csr_illegal_from_u(d, CsrCycle), 0);
    expect_eq("U-mode instret allowed", is_csr_illegal_from_u(d, CsrInstret), 0);

    // Test that disabling mcounteren blocks U-mode even if scounteren is set
    write_csr(d, CsrMcounteren, 0x00000000);
    expect_eq("U-mode cycle blocked (mcounteren=0)", is_csr_illegal_from_u(d, CsrCycle), 1);
    expect_eq("U-mode instret blocked (mcounteren=0)", is_csr_illegal_from_u(d, CsrInstret), 1);

    // satp TVM gating tests
    // Currently in M-mode, satp should be accessible
    expect_eq("M-mode satp accessible", is_csr_illegal(d, CsrSatp), 0);

    // Switch to S-mode
    idle(d);
    d->priv_mode = 1;  // PRIV_S

    // S-mode: satp accessible when TVM=0
    uint32_t mstatus_val = read_csr(d, CsrMstatus);
    expect_eq("S-mode satp accessible (TVM=0)", is_csr_illegal_from_s(d, CsrSatp), 0);

    // Set mstatus.TVM=1 (bit 20)
    idle(d);
    d->priv_mode = 3;  // Switch to M-mode to write mstatus
    write_csr(d, CsrMstatus, mstatus_val | 0x00100000);

    // S-mode: satp should now trap
    idle(d);
    d->priv_mode = 1;  // Back to S-mode
    expect_eq("S-mode satp trapped (TVM=1)", is_csr_illegal_from_s(d, CsrSatp), 1);

    // M-mode: satp still accessible even with TVM=1
    idle(d);
    d->priv_mode = 3;  // M-mode
    expect_eq("M-mode satp accessible (TVM=1)", is_csr_illegal(d, CsrSatp), 0);

    // Clear TVM for remaining tests
    write_csr(d, CsrMstatus, mstatus_val);

    delete d;
    printf("\n=== tb_csr: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
