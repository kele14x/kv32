// tb_csr.sv — unit test for kv32_csr
// Verifies: reset values, CSR read/write/set/clear, read-before-write,
//           read-only CSRs, mtvec MODE masking, mepc bit0 masking,
//           trap updates, MRET restore, counter increment/writes,
//           priority chain (trap > mret > csr_wen).

module tb_csr;
  import kv32_pkg::*;

  logic              clk = 0;
  // Manual clock - driven by tick() task

  // DUT signals
  logic              rst_n;
  priv_mode_t        priv_mode;
  logic       [11:0] csr_addr;
  logic       [31:0] csr_wdata;
  logic       [ 1:0] csr_op;
  logic              csr_wen;
  logic              is_csr;
  logic       [31:0] csr_rdata;
  logic              irq_external;
  logic              irq_timer;
  logic              irq_software;
  logic              trap_taken;
  logic       [31:0] trap_pc;
  logic       [31:0] trap_cause;
  logic       [31:0] trap_val;
  logic              trap_to_smode;
  logic              mret_taken;
  logic              sret_taken;
  logic       [31:0] mtvec_out;
  logic       [31:0] mepc_out;
  logic       [31:0] stvec_out;
  logic       [31:0] sepc_out;
  logic       [31:0] medeleg_out;
  logic       [31:0] mideleg_out;
  logic              mstatus_mie;
  logic              mstatus_sie_o;
  logic              mstatus_mprv;
  logic              mstatus_tsr;
  logic              mstatus_tw;
  logic              mstatus_tvm;
  logic       [ 1:0] mstatus_mpp_out;
  logic              mstatus_spp_out;
  logic              mstatus_sum_o;
  logic              mstatus_mxr_o;
  logic              satp_mode;
  logic       [ 8:0] satp_asid;
  logic       [21:0] satp_ppn;
  logic              csr_illegal;
  logic              irq_pending;
  logic       [31:0] irq_cause;
  logic              instr_retired;

  kv32_csr u_dut (.*);

  int tests = 0, failures = 0;

  // CSR address constants (M-mode only, not in kv32_pkg)
  localparam logic [11:0] CsrMstatus = 12'h300;
  localparam logic [11:0] CsrMisa = 12'h301;
  localparam logic [11:0] CsrMie = 12'h304;
  localparam logic [11:0] CsrMtvec = 12'h305;
  localparam logic [11:0] CsrMcounteren = 12'h306;
  localparam logic [11:0] CsrMstatush = 12'h310;
  localparam logic [11:0] CsrMscratch = 12'h340;
  localparam logic [11:0] CsrMepc = 12'h341;
  localparam logic [11:0] CsrMcause = 12'h342;
  localparam logic [11:0] CsrMtval = 12'h343;
  localparam logic [11:0] CsrMip = 12'h344;
  localparam logic [11:0] CsrMvendorid = 12'hF11;
  localparam logic [11:0] CsrMarchid = 12'hF12;
  localparam logic [11:0] CsrMimpid = 12'hF13;
  localparam logic [11:0] CsrMhartid = 12'hF14;
  localparam logic [11:0] CsrMconfigptr = 12'hF15;
  localparam logic [11:0] CsrMcycle = 12'hB00;
  localparam logic [11:0] CsrMcycleh = 12'hB80;
  localparam logic [11:0] CsrMinstret = 12'hB02;
  localparam logic [11:0] CsrMinstreth = 12'hB82;
  // U-mode time (not implemented, but needed for illegal access tests)
  localparam logic [11:0] CsrTime = 12'hC01;
  localparam logic [11:0] CsrTimeh = 12'hC81;
  // S-mode and delegation CSRs are imported from kv32_pkg:
  //   CsrSstatus, CsrSie, CsrStvec, CsrScounteren, CsrSscratch, CsrSepc,
  //   CsrScause, CsrStval, CsrSip, CsrSatp, CsrMedeleg, CsrMideleg
  // U-mode counters are imported from kv32_pkg:
  //   CsrCycle, CsrCycleh, CsrInstret, CsrInstreth

  task automatic tick();
    clk = 0;
    #5;
    clk = 1;
    #5;
  endtask

  task automatic idle();
    priv_mode     = PRIV_M;
    csr_addr      = 12'h0;
    csr_wdata     = 32'h0;
    csr_op        = CSR_OP_NONE;
    csr_wen       = 1'b0;
    is_csr        = 1'b0;
    irq_external  = 1'b0;
    irq_timer     = 1'b0;
    irq_software  = 1'b0;
    trap_taken    = 1'b0;
    trap_pc       = 32'h0;
    trap_cause    = 32'h0;
    trap_val      = 32'h0;
    trap_to_smode = 1'b0;
    mret_taken    = 1'b0;
    sret_taken    = 1'b0;
    instr_retired = 1'b0;
  endtask

  task automatic expect_eq(string name, logic [31:0] got, logic [31:0] want);
    tests++;
    if (got !== want) begin
      $display("FAIL  %-30s got=0x%08h want=0x%08h", name, got, want);
      failures++;
    end
  endtask

  task automatic expect_bit(string name, logic got, logic want);
    tests++;
    if (got !== want) begin
      $display("FAIL  %-30s got=%0d want=%0d", name, got, want);
      failures++;
    end
  endtask

  task automatic read_csr(input logic [11:0] addr, output logic [31:0] rdata);
    idle();
    csr_addr = addr;
    #1;  // let combinational logic settle
    rdata = csr_rdata;
  endtask

  task automatic write_csr(input logic [11:0] addr, input logic [31:0] wdata,
                           output logic [31:0] old);
    idle();
    csr_addr = addr;
    csr_wdata = wdata;
    csr_op = CSR_OP_WRITE;
    csr_wen = 1;
    #1;  // let combinational logic settle for read-before-write
    old = csr_rdata;
    tick();
    idle();
  endtask

  task automatic is_csr_illegal(input logic [11:0] addr, output logic result);
    idle();
    priv_mode = PRIV_M;
    csr_addr = addr;
    is_csr = 1;
    #1;
    result = csr_illegal;
  endtask

  task automatic is_csr_illegal_from_s(input logic [11:0] addr, output logic result);
    idle();
    priv_mode = PRIV_S;
    csr_addr = addr;
    is_csr = 1;
    #1;
    result = csr_illegal;
  endtask

  task automatic is_csr_illegal_from_u(input logic [11:0] addr, output logic result);
    idle();
    priv_mode = PRIV_U;
    csr_addr = addr;
    is_csr = 1;
    #1;
    result = csr_illegal;
  endtask

  initial begin
    // Scratch variables for task output parameters
    logic [31:0] rdata, old, ms;
    logic ill;

    // Reset - match C++ testbench: rst_n=0 for one tick, then release
    rst_n = 0;
    idle();
    tick();  // one cycle with reset active
    rst_n = 1;
    #1;  // let combinational logic settle after reset release

    // ---- Reset values ----
    read_csr(CsrMstatus, rdata);
    expect_eq("reset mstatus", rdata, 32'h00001800);  // mpp=11
    read_csr(CsrMisa, rdata);
    expect_eq("reset misa", rdata, 32'h40141105);  // I+M+C+A+S+U
    read_csr(CsrMie, rdata);
    expect_eq("reset mie", rdata, 32'h00000000);
    read_csr(CsrMtvec, rdata);
    expect_eq("reset mtvec", rdata, 32'h00000000);
    read_csr(CsrMscratch, rdata);
    expect_eq("reset mscratch", rdata, 32'h00000000);
    read_csr(CsrMepc, rdata);
    expect_eq("reset mepc", rdata, 32'h00000000);
    read_csr(CsrMcause, rdata);
    expect_eq("reset mcause", rdata, 32'h00000000);
    read_csr(CsrMtval, rdata);
    expect_eq("reset mtval", rdata, 32'h00000000);
    read_csr(CsrMcycle, rdata);
    expect_eq("reset mcycle", rdata, 32'h00000000);
    read_csr(CsrMinstret, rdata);
    expect_eq("reset minstret", rdata, 32'h00000000);

    // ---- Identity CSRs (read-only, return 0) ----
    read_csr(CsrMvendorid, rdata);
    expect_eq("mvendorid", rdata, 32'h00000000);
    read_csr(CsrMarchid, rdata);
    expect_eq("marchid", rdata, 32'h00000000);
    read_csr(CsrMimpid, rdata);
    expect_eq("mimpid", rdata, 32'h00000000);
    read_csr(CsrMhartid, rdata);
    expect_eq("mhartid", rdata, 32'h00000000);
    read_csr(CsrMconfigptr, rdata);
    expect_eq("mconfigptr", rdata, 32'h00000000);
    read_csr(CsrMstatush, rdata);
    expect_eq("mstatush", rdata, 32'h00000000);

    // ---- CSRRW mscratch: read-before-write returns old, then new value ----
    write_csr(CsrMscratch, 32'hDEADBEEF, old);
    expect_eq("mscratch old (RBW)", old, 32'h00000000);
    read_csr(CsrMscratch, rdata);
    expect_eq("mscratch after write", rdata, 32'hDEADBEEF);

    // ---- CSRRS mscratch: set bits ----
    idle();
    csr_addr  = CsrMscratch;
    csr_wdata = 32'h0000FF00;
    csr_op    = CSR_OP_SET;
    csr_wen   = 1'b1;
    tick();
    read_csr(CsrMscratch, rdata);
    expect_eq("mscratch after SET", rdata, 32'hDEADFFEF);

    // ---- CSRRC mscratch: clear bits ----
    idle();
    csr_addr  = CsrMscratch;
    csr_wdata = 32'h00FF0000;
    csr_op    = CSR_OP_CLEAR;
    csr_wen   = 1'b1;
    tick();
    read_csr(CsrMscratch, rdata);
    expect_eq("mscratch after CLEAR", rdata, 32'hDE00FFEF);

    // ---- mtvec MODE masking: write with MODE=3, read back MODE=0 ----
    write_csr(CsrMtvec, 32'h80001203, old);
    read_csr(CsrMtvec, rdata);
    expect_eq("mtvec MODE masked", rdata, 32'h80001200);

    // ---- mepc bit0 masking: write odd address, bit0 cleared ----
    write_csr(CsrMepc, 32'h80000101, old);
    read_csr(CsrMepc, rdata);
    expect_eq("mepc bit0 cleared", rdata, 32'h80000100);

    // ---- Read-only CSRs ignore writes ----
    write_csr(CsrMisa, 32'hFFFFFFFF, old);
    read_csr(CsrMisa, rdata);
    expect_eq("misa write ignored", rdata, 32'h40141105);
    write_csr(CsrMvendorid, 32'hFFFFFFFF, old);
    read_csr(CsrMvendorid, rdata);
    expect_eq("mvendorid write ignored", rdata, 32'h00000000);
    write_csr(CsrMstatush, 32'hFFFFFFFF, old);
    read_csr(CsrMstatush, rdata);
    expect_eq("mstatush write ignored", rdata, 32'h00000000);

    // ---- mstatus write: set MIE (bit 3) ----
    // Note: writing 0x08 sets MIE=1 but clears MPP to 00 (U-mode) because
    // MPP bits [12:11] are not in the write value. This is correct CSR
    // behavior — software must read-modify-write to preserve MPP.
    write_csr(CsrMstatus, 32'h00000008, old);  // MIE=1
    read_csr(CsrMstatus, rdata);
    expect_eq("mstatus MIE=1 (MPP cleared)", rdata, 32'h00000008);

    // ---- Trap: check mepc, mcause, mtval, mstatus.mpie/mie/mpp ----
    idle();
    trap_taken = 1'b1;
    trap_pc = 32'h80000100;
    trap_cause = 32'h0000000B;  // Machine ECALL
    trap_val = 32'h00000000;
    tick();
    read_csr(CsrMepc, rdata);
    expect_eq("trap mepc", rdata, 32'h80000100);
    read_csr(CsrMcause, rdata);
    expect_eq("trap mcause", rdata, 32'h0000000B);
    read_csr(CsrMtval, rdata);
    expect_eq("trap mtval", rdata, 32'h00000000);
    // After trap: mpie=1 (saved mie), mie=0, mpp=11
    read_csr(CsrMstatus, rdata);
    expect_eq("trap mstatus", rdata, 32'h00001880);  // mpie=1, mie=0, mpp=11

    // ---- MRET: restore mstatus ----
    idle();
    mret_taken = 1'b1;
    tick();
    // After MRET: mie=mpie=1, mpie=1, mpp=11
    read_csr(CsrMstatus, rdata);
    expect_eq("mret mstatus", rdata, 32'h00001888);  // mpie=1, mie=1, mpp=11

    // ---- Counter: mcycle increments each cycle ----
    begin
      logic [31:0] cyc_before, cyc_after;
      read_csr(CsrMcycle, cyc_before);
      tick();  // one idle cycle
      read_csr(CsrMcycle, cyc_after);
      expect_eq("mcycle incremented", cyc_after, cyc_before + 1);
    end

    // ---- Counter: minstret increments on instr_retired ----
    begin
      logic [31:0] inst_before, inst_after;
      read_csr(CsrMinstret, inst_before);
      idle();
      instr_retired = 1'b1;
      tick();
      read_csr(CsrMinstret, inst_after);
      expect_eq("minstret incremented", inst_after, inst_before + 1);
    end

    // ---- Counter writes: mcycle low/high ----
    write_csr(CsrMcycle, 32'h12345678, old);
    write_csr(CsrMcycleh, 32'h0000ABCD, old);
    read_csr(CsrMcycle, rdata);
    expect_eq("mcycle low after write", rdata, 32'h12345678);
    read_csr(CsrMcycleh, rdata);
    expect_eq("mcycleh after write", rdata, 32'h0000ABCD);

    // ---- minstret write ----
    write_csr(CsrMinstret, 32'hCAFEBABE, old);
    read_csr(CsrMinstret, rdata);
    expect_eq("minstret after write", rdata, 32'hCAFEBABE);

    // ---- Priority: trap_taken > csr_wen ----
    // Set mscratch to a known value, then try CSRRW + trap simultaneously
    write_csr(CsrMscratch, 32'h11111111, old);
    idle();
    csr_addr   = CsrMscratch;
    csr_wdata  = 32'h22222222;
    csr_op     = CSR_OP_WRITE;
    csr_wen    = 1'b1;
    trap_taken = 1'b1;
    trap_pc    = 32'h00000040;
    trap_cause = 32'h00000002;
    trap_val   = 32'h00000000;
    tick();
    // Trap should win: mscratch NOT written, mepc updated
    read_csr(CsrMscratch, rdata);
    expect_eq("priority: mscratch unchanged", rdata, 32'h11111111);
    read_csr(CsrMepc, rdata);
    expect_eq("priority: mepc updated", rdata, 32'h00000040);

    // ---- Priority: mret_taken > csr_wen ----
    // Set mstatus.MIE=0 first, then try CSRRW + MRET simultaneously
    write_csr(CsrMstatus, 32'h00001800, old);  // mie=0, mpie=0
    idle();
    csr_addr   = CsrMstatus;
    csr_wdata  = 32'h00000008;  // try to set MIE=1
    csr_op     = CSR_OP_WRITE;
    csr_wen    = 1'b1;
    mret_taken = 1'b1;
    tick();
    // MRET should win: mstatus NOT written by CSRRW, mpie set to 1 by MRET
    // After MRET with mpie=0: mie=mpie=0, mpie=1, mpp=11
    read_csr(CsrMstatus, rdata);
    expect_eq("priority: mret over csr", rdata, 32'h00001880);

    // ---- MIP reads hardware-driven interrupt bits ----
    idle();
    irq_external = 1'b1;
    irq_timer    = 1'b1;
    irq_software = 1'b1;
    csr_addr     = CsrMip;
    tick();
    // MEIP=bit11, MTIP=bit7, MSIP=bit3
    expect_eq("mip all irqs", csr_rdata, 32'h00000888);
    irq_external = 1'b0;
    irq_timer    = 1'b0;
    irq_software = 1'b0;
    #1;
    expect_eq("mip no irqs", csr_rdata, 32'h00000000);

    // ---- MIP writes: only SSIP (bit 1) is software-writable ----
    write_csr(CsrMip, 32'hFFFFFFFF, old);
    read_csr(CsrMip, rdata);
    expect_eq("mip write sets SSIP only", rdata, 32'h00000002);
    write_csr(CsrMip, 32'h00000000, old);  // Clear SSIP
    read_csr(CsrMip, rdata);
    expect_eq("mip clear SSIP", rdata, 32'h00000000);

    // ---- csr_illegal: satp (0x180) is now implemented (S-mode CSR) ----
    // From M-mode, satp access is legal
    idle();
    is_csr   = 1'b1;
    csr_addr = 12'h180;  // satp
    #1;
    expect_bit("satp read legal from M", csr_illegal, 1'b0);
    // From S-mode, satp access is legal (unless TVM=1)
    idle();
    is_csr = 1'b1;
    csr_addr = 12'h180;
    priv_mode = PRIV_S;
    #1;
    expect_bit("satp read legal from S", csr_illegal, 1'b0);
    // From U-mode, satp access is illegal
    idle();
    is_csr = 1'b1;
    csr_addr = 12'h180;
    priv_mode = PRIV_U;
    #1;
    expect_bit("satp read illegal from U", csr_illegal, 1'b1);

    // ---- csr_illegal: cycle (0xC00) is now implemented (U-mode counter) ----
    // From M-mode, always legal
    idle();
    is_csr = 1'b1;
    csr_addr = 12'hC00;  // cycle
    priv_mode = PRIV_M;
    #1;
    expect_bit("cycle read legal from M", csr_illegal, 1'b0);
    // From S-mode, gated by mcounteren[0] (currently 0 -> illegal)
    idle();
    is_csr = 1'b1;
    csr_addr = 12'hC00;
    priv_mode = PRIV_S;
    #1;
    expect_bit("cycle read illegal from S (mcounteren=0)", csr_illegal, 1'b1);

    // ---- csr_illegal: implemented RW CSR (read and write legal) ----
    idle();
    is_csr   = 1'b1;
    csr_addr = CsrMscratch;
    #1;
    expect_bit("mscratch read legal", csr_illegal, 1'b0);
    idle();
    is_csr   = 1'b1;
    csr_addr = CsrMscratch;
    csr_wdata = 32'hAAAAAAAA;
    csr_op    = CSR_OP_WRITE;
    csr_wen   = 1'b1;
    #1;
    expect_bit("mscratch write legal", csr_illegal, 1'b0);

    // ---- csr_illegal: read-only CSR write is illegal, read is legal ----
    idle();
    is_csr   = 1'b1;
    csr_addr = CsrMvendorid;
    #1;
    expect_bit("mvendorid read legal", csr_illegal, 1'b0);
    idle();
    is_csr   = 1'b1;
    csr_addr = CsrMvendorid;
    csr_wdata = 32'hFFFFFFFF;
    csr_op    = CSR_OP_WRITE;
    csr_wen   = 1'b1;
    #1;
    expect_bit("mvendorid write illegal", csr_illegal, 1'b1);
    // CSRRS with rs1=x0 (csr_wen=0) reading a read-only CSR is legal.
    idle();
    is_csr   = 1'b1;
    csr_addr = CsrMvendorid;
    csr_op   = CSR_OP_SET;
    csr_wen  = 1'b0;
    #1;
    expect_bit("mvendorid CSRRS x0 legal", csr_illegal, 1'b0);

    // ---- csr_illegal: non-CSR instruction never reports illegal ----
    idle();
    is_csr   = 1'b0;
    csr_addr = 12'h180;  // would be illegal if accessed
    #1;
    expect_bit("non-csr not illegal", csr_illegal, 1'b0);

    // ---- Privilege mode checking (Phase 5) ----
    // M-mode CSRs should be illegal when accessed from S-mode or U-mode
    idle();
    is_csr = 1'b1;
    csr_addr = CsrMstatus;
    priv_mode = PRIV_S;
    #1;
    expect_bit("mstatus from S-mode illegal", csr_illegal, 1'b1);
    idle();
    is_csr = 1'b1;
    csr_addr = CsrMstatus;
    priv_mode = PRIV_U;
    #1;
    expect_bit("mstatus from U-mode illegal", csr_illegal, 1'b1);
    idle();
    is_csr = 1'b1;
    csr_addr = CsrMstatus;
    priv_mode = PRIV_M;
    #1;
    expect_bit("mstatus from M-mode legal", csr_illegal, 1'b0);

    // ---- Phase 5: S-mode CSR tests ----

    // sstatus is a masked view of mstatus (mask 0x000C_0122)
    // Reset mstatus first
    write_csr(CsrMstatus, 32'h00000000, old);  // Clear all fields
    // Set some mstatus fields via mstatus write
    write_csr(CsrMstatus, 32'h000C19AA, old);  // Set all writable bits
    // Read sstatus — only SIE[1], SPIE[5], SPP[8], SUM[18], MXR[19] visible
    read_csr(CsrSstatus, rdata);
    expect_eq("sstatus masked read", rdata, 32'h000C0122);

    // Write via sstatus — only sstatus bits should change in mstatus
    write_csr(CsrMstatus, 32'h00000000, old);  // Clear all
    write_csr(CsrSstatus, 32'h000C0122, old);  // Set all sstatus-visible bits
    read_csr(CsrMstatus, ms);
    expect_eq("sstatus write affects mstatus SIE", ms & 32'h2, 32'h2);  // SIE
    expect_eq("sstatus write affects mstatus SPIE", ms & 32'h20, 32'h20);  // SPIE
    expect_eq("sstatus write affects mstatus SPP", ms & 32'h100, 32'h100);  // SPP
    expect_eq("sstatus write affects mstatus SUM", ms & 32'h40000, 32'h40000);  // SUM
    expect_eq("sstatus write affects mstatus MXR", ms & 32'h80000, 32'h80000);  // MXR
    // M-mode bits should NOT be changed by sstatus write
    expect_eq("sstatus write preserves MIE", ms & 32'h8, 32'h0);  // MIE unchanged (0)
    expect_eq("sstatus write preserves MPP", ms & 32'h1800, 32'h0);  // MPP unchanged (00)

    // sie is mie masked by mideleg
    write_csr(CsrMie, 32'h00000000, old);
    write_csr(CsrMideleg, 32'h00000222, old);  // Delegate S-mode interrupts (1,5,9)
    write_csr(CsrSie, 32'hFFFFFFFF, old);  // Try to set all bits
    // Only delegated bits should be set in mie
    read_csr(CsrMie, rdata);
    expect_eq("sie write only delegated bits", rdata, 32'h00000222);
    read_csr(CsrSie, rdata);
    expect_eq("sie read = mie & mideleg", rdata, 32'h00000222);

    // S-mode trap CSRs are independent from M-mode
    write_csr(CsrMepc, 32'hAAAA0000, old);
    write_csr(CsrSepc, 32'h55550000, old);
    read_csr(CsrSepc, rdata);
    expect_eq("sepc independent from mepc", rdata, 32'h55550000);
    read_csr(CsrMepc, rdata);
    expect_eq("mepc unchanged after sepc write", rdata, 32'hAAAA0000);

    write_csr(CsrMcause, 32'h11111111, old);
    write_csr(CsrScause, 32'h22222222, old);
    read_csr(CsrScause, rdata);
    expect_eq("scause independent from mcause", rdata, 32'h22222222);
    read_csr(CsrMcause, rdata);
    expect_eq("mcause unchanged after scause write", rdata, 32'h11111111);

    // stvec allows vectored mode (MODE=1)
    write_csr(CsrStvec, 32'h80000101, old);  // BASE=0x80000100, MODE=1 (vectored)
    read_csr(CsrStvec, rdata);
    expect_eq("stvec vectored mode", rdata, 32'h80000101);
    write_csr(CsrStvec, 32'h80000102, old);  // MODE=2 (invalid, should force to 0)
    read_csr(CsrStvec, rdata);
    expect_eq("stvec invalid mode forced to 0", rdata, 32'h80000100);

    // mtvec also allows vectored mode now
    write_csr(CsrMtvec, 32'h80000201, old);  // BASE=0x80000200, MODE=1 (vectored)
    read_csr(CsrMtvec, rdata);
    expect_eq("mtvec vectored mode", rdata, 32'h80000201);

    // medeleg: bit 11 (ECALL from M) hardwired 0
    write_csr(CsrMedeleg, 32'hFFFFFFFF, old);
    read_csr(CsrMedeleg, rdata);
    expect_eq("medeleg bit 11 hardwired 0", rdata, 32'hFFFFF7FF);

    // mideleg: bits 3,7,11 (M-mode interrupts) hardwired 0
    write_csr(CsrMideleg, 32'hFFFFFFFF, old);
    read_csr(CsrMideleg, rdata);
    expect_eq("mideleg bits 3,7,11 hardwired 0", rdata, 32'hFFFFF777);

    // satp read/write
    write_csr(CsrSatp, 32'h80000000, old);
    read_csr(CsrSatp, rdata);
    expect_eq("satp write/read", rdata, 32'h80000000);

    // sscratch
    write_csr(CsrSscratch, 32'hDEADBEEF, old);
    read_csr(CsrSscratch, rdata);
    expect_eq("sscratch write/read", rdata, 32'hDEADBEEF);

    // scounteren
    write_csr(CsrScounteren, 32'h00000005, old);  // cycle + instret bits
    read_csr(CsrScounteren, rdata);
    expect_eq("scounteren write/read", rdata, 32'h00000005);

    // S-mode trap: update S-mode CSRs
    write_csr(CsrMstatus, 32'h00000002, old);  // Set SIE=1
    idle();
    priv_mode     = PRIV_S;
    trap_taken    = 1'b1;
    trap_to_smode = 1'b1;
    trap_pc       = 32'h80000200;
    trap_cause    = 32'h00000008;  // ECALL from U-mode
    trap_val      = 32'h00000073;
    tick();
    read_csr(CsrSepc, rdata);
    expect_eq("S-trap sepc", rdata, 32'h80000200);
    read_csr(CsrScause, rdata);
    expect_eq("S-trap scause", rdata, 32'h00000008);
    read_csr(CsrStval, rdata);
    expect_eq("S-trap stval", rdata, 32'h00000073);
    // After S-trap: spie=sie=1, sie=0, spp=1 (from S-mode)
    read_csr(CsrMstatus, ms);
    expect_bit("S-trap spie=1", ms[5], 1'b1);
    expect_eq("S-trap sie=0", ms & 32'h2, 32'h0);
    expect_bit("S-trap spp=1", ms[8], 1'b1);
    // M-mode trap CSRs should NOT be updated
    read_csr(CsrMepc, rdata);
    expect_eq("S-trap mepc unchanged", rdata, 32'hAAAA0000);

    // SRET: restore sstatus fields
    idle();
    sret_taken = 1'b1;
    tick();
    // After SRET: sie=spie=1, spie=1, spp=0
    read_csr(CsrMstatus, ms);
    expect_eq("sret sie=spie", ms & 32'h2, 32'h2);  // SIE restored
    expect_bit("sret spie=1", ms[5], 1'b1);  // SPIE set to 1
    expect_bit("sret spp=0", ms[8], 1'b0);  // SPP cleared

    // ========== Stage 7: Counter access gating and final access control ==========

    // Reset privilege mode to M-mode for counter tests
    idle();
    priv_mode = PRIV_M;

    // M-mode: cycle/instret always accessible
    is_csr_illegal(CsrCycle, ill);
    expect_bit("M-mode cycle access", ill, 1'b0);
    is_csr_illegal(CsrCycleh, ill);
    expect_bit("M-mode cycleh access", ill, 1'b0);
    is_csr_illegal(CsrInstret, ill);
    expect_bit("M-mode instret access", ill, 1'b0);
    is_csr_illegal(CsrInstreth, ill);
    expect_bit("M-mode instreth access", ill, 1'b0);

    // time/timeh: always illegal (not implemented)
    is_csr_illegal(CsrTime, ill);
    expect_bit("M-mode time illegal", ill, 1'b1);
    is_csr_illegal(CsrTimeh, ill);
    expect_bit("M-mode timeh illegal", ill, 1'b1);
    is_csr_illegal_from_s(CsrTime, ill);
    expect_bit("S-mode time illegal", ill, 1'b1);
    is_csr_illegal_from_s(CsrTimeh, ill);
    expect_bit("S-mode timeh illegal", ill, 1'b1);
    is_csr_illegal_from_u(CsrTime, ill);
    expect_bit("U-mode time illegal", ill, 1'b1);
    is_csr_illegal_from_u(CsrTimeh, ill);
    expect_bit("U-mode timeh illegal", ill, 1'b1);

    // S-mode counter access gated by mcounteren
    // mcounteren currently has 0 (no bits set)
    is_csr_illegal_from_s(CsrCycle, ill);
    expect_bit("S-mode cycle blocked (mcounteren=0)", ill, 1'b1);
    is_csr_illegal_from_s(CsrInstret, ill);
    expect_bit("S-mode instret blocked (mcounteren=0)", ill, 1'b1);

    // Set mcounteren to allow cycle (bit 0)
    write_csr(CsrMcounteren, 32'h00000001, old);
    is_csr_illegal_from_s(CsrCycle, ill);
    expect_bit("S-mode cycle allowed (mcounteren[0]=1)", ill, 1'b0);
    is_csr_illegal_from_s(CsrCycleh, ill);
    expect_bit("S-mode cycleh allowed (mcounteren[0]=1)", ill, 1'b0);
    is_csr_illegal_from_s(CsrInstret, ill);
    expect_bit("S-mode instret still blocked (mcounteren[2]=0)", ill, 1'b1);

    // Set mcounteren to allow both cycle and instret
    write_csr(CsrMcounteren, 32'h00000005, old);  // bits 0 and 2
    is_csr_illegal_from_s(CsrCycle, ill);
    expect_bit("S-mode cycle allowed", ill, 1'b0);
    is_csr_illegal_from_s(CsrInstret, ill);
    expect_bit("S-mode instret allowed", ill, 1'b0);

    // U-mode counter access gated by both mcounteren AND scounteren
    // Reset scounteren to 0 to test blocking
    write_csr(CsrScounteren, 32'h00000000, old);
    is_csr_illegal_from_u(CsrCycle, ill);
    expect_bit("U-mode cycle blocked (scounteren[0]=0)", ill, 1'b1);
    is_csr_illegal_from_u(CsrInstret, ill);
    expect_bit("U-mode instret blocked (scounteren[2]=0)", ill, 1'b1);

    // Set scounteren to allow cycle (bit 0)
    write_csr(CsrScounteren, 32'h00000001, old);
    is_csr_illegal_from_u(CsrCycle, ill);
    expect_bit("U-mode cycle allowed (both enables)", ill, 1'b0);
    is_csr_illegal_from_u(CsrInstret, ill);
    expect_bit("U-mode instret still blocked (scounteren[2]=0)", ill, 1'b1);

    // Set scounteren to allow both
    write_csr(CsrScounteren, 32'h00000005, old);
    is_csr_illegal_from_u(CsrCycle, ill);
    expect_bit("U-mode cycle allowed", ill, 1'b0);
    is_csr_illegal_from_u(CsrInstret, ill);
    expect_bit("U-mode instret allowed", ill, 1'b0);

    // Test that disabling mcounteren blocks U-mode even if scounteren is set
    write_csr(CsrMcounteren, 32'h00000000, old);
    is_csr_illegal_from_u(CsrCycle, ill);
    expect_bit("U-mode cycle blocked (mcounteren=0)", ill, 1'b1);
    is_csr_illegal_from_u(CsrInstret, ill);
    expect_bit("U-mode instret blocked (mcounteren=0)", ill, 1'b1);

    // satp TVM gating tests
    // Currently in M-mode, satp should be accessible
    is_csr_illegal(CsrSatp, ill);
    expect_bit("M-mode satp accessible", ill, 1'b0);

    // Switch to S-mode
    idle();
    priv_mode = PRIV_S;

    // S-mode: satp accessible when TVM=0
    begin
      logic [31:0] mstatus_val;
      read_csr(CsrMstatus, mstatus_val);
      is_csr_illegal_from_s(CsrSatp, ill);
      expect_bit("S-mode satp accessible (TVM=0)", ill, 1'b0);

      // Set mstatus.TVM=1 (bit 20)
      idle();
      priv_mode = PRIV_M;  // Switch to M-mode to write mstatus
      write_csr(CsrMstatus, mstatus_val | 32'h00100000, old);

      // S-mode: satp should now trap
      idle();
      priv_mode = PRIV_S;  // Back to S-mode
      is_csr_illegal_from_s(CsrSatp, ill);
      expect_bit("S-mode satp trapped (TVM=1)", ill, 1'b1);

      // M-mode: satp still accessible even with TVM=1
      idle();
      priv_mode = PRIV_M;  // M-mode
      is_csr_illegal(CsrSatp, ill);
      expect_bit("M-mode satp accessible (TVM=1)", ill, 1'b0);

      // Clear TVM for remaining tests
      write_csr(CsrMstatus, mstatus_val, old);
    end

    $display("\n=== tb_csr: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
