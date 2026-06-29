// tb_decoder.sv — unit test for kv32_decoder
// Verifies all opcodes, immediate types, control signals, and CSR variants.
// Combinational DUT: set instr, eval, check outputs.

module tb_decoder;

  logic [31:0] instr;
  logic [ 4:0] rd;
  logic [ 2:0] funct3;
  logic [ 4:0] rs1;
  logic [ 4:0] rs2;
  logic [31:0] imm;
  logic        use_imm;
  logic        alu_op_valid;
  logic [ 3:0] alu_op;
  logic        mem_read;
  logic        mem_write;
  logic        reg_write;
  logic        branch;
  logic        jump;
  logic        is_jalr;
  logic        illegal;
  logic        lui;
  logic        auipc;
  logic [ 1:0] csr_op;
  logic        csr_wen;
  logic        is_csr;
  logic        is_mret;
  logic        is_sret;
  logic        is_wfi;
  logic        is_sfence_vma;
  logic        use_zimm;
  logic        is_ecall;
  logic        is_ebreak;
  logic        is_lr;
  logic        is_sc;
  logic        is_amo;

  kv32_decoder u_dut (
      .instr         (instr),
      .rd            (rd),
      .funct3        (funct3),
      .rs1           (rs1),
      .rs2           (rs2),
      .imm           (imm),
      .use_imm       (use_imm),
      .alu_op_valid  (alu_op_valid),
      .alu_op        (alu_op),
      .mem_read      (mem_read),
      .mem_write     (mem_write),
      .reg_write     (reg_write),
      .branch        (branch),
      .jump          (jump),
      .is_jalr       (is_jalr),
      .illegal       (illegal),
      .lui           (lui),
      .auipc         (auipc),
      .csr_op        (csr_op),
      .csr_wen       (csr_wen),
      .is_csr        (is_csr),
      .is_mret       (is_mret),
      .is_sret       (is_sret),
      .is_wfi        (is_wfi),
      .is_sfence_vma (is_sfence_vma),
      .use_zimm      (use_zimm),
      .is_ecall      (is_ecall),
      .is_ebreak     (is_ebreak),
      .is_lr         (is_lr),
      .is_sc         (is_sc),
      .is_amo        (is_amo)
  );

  int tests = 0;
  int failures = 0;

  // ALU op codes (from kv32_pkg)
  localparam logic [3:0] AluAdd = 4'd0, AluSub = 4'd1, AluSll = 4'd2, AluSlt = 4'd3,
                          AluSltu = 4'd4, AluXor = 4'd5, AluSrl = 4'd6, AluSra = 4'd7,
                          AluOr = 4'd8, AluAnd = 4'd9;

  // CSR op codes
  localparam logic [1:0] CSR_NONE = 2'd0, CSR_WRITE = 2'd1, CSR_SET = 2'd2, CSR_CLEAR = 2'd3;

  // Opcodes
  localparam logic [6:0] OpLui = 7'h37, OpAuipc = 7'h17, OpJal = 7'h6F, OpJalr = 7'h67,
                          OpBranch = 7'h63, OpLoad = 7'h03, OpStore = 7'h23, OpImm = 7'h13,
                          OpReg = 7'h33, OpMiscMem = 7'h0F, OpSystem = 7'h73, OpAmo = 7'h2F;

  // Instruction encoders
  function automatic logic [31:0] r_type(
      logic [6:0] f7, logic [4:0] rs2, logic [4:0] rs1,
      logic [2:0] f3, logic [4:0] rd, logic [6:0] op
  );
    return {f7, rs2, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] i_type(
      logic [11:0] imm12, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op
  );
    return {imm12, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] s_type(
      logic [11:0] imm12, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [6:0] op
  );
    return {imm12[11:5], rs2, rs1, f3, imm12[4:0], op};
  endfunction

  function automatic logic [31:0] b_type(
      logic [12:0] imm13, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [6:0] op
  );
    return {imm13[12], imm13[10:5], rs2, rs1, f3, imm13[4:1], imm13[11], op};
  endfunction

  function automatic logic [31:0] u_type(logic [19:0] imm20, logic [4:0] rd, logic [6:0] op);
    return {imm20, rd, op};
  endfunction

  function automatic logic [31:0] j_type(
      logic [20:0] imm21, logic [4:0] rd, logic [6:0] op
  );
    return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, op};
  endfunction

  // Check task — raw fields (rd, funct3, rs1, rs2) are auto-extracted from
  // the instruction word, matching what the decoder always outputs.
  task automatic check(
      string name,
      input logic [31:0] iinstr,
      input logic [31:0] iimm, input logic iuse_imm, input logic ialu_op_valid, input logic [3:0] ialu_op,
      input logic imem_read, input logic imem_write, input logic ireg_write,
      input logic ibranch, input logic ijump, input logic iis_jalr,
      input logic iillegal, input logic ilui, input logic iauipc,
      input logic [1:0] icsr_op, input logic icsr_wen, input logic iis_csr,
      input logic iis_mret, input logic iis_sret, input logic iis_wfi, input logic iis_sfence_vma,
      input logic iuse_zimm, input logic iis_ecall, input logic iis_ebreak,
      input logic iis_lr, input logic iis_sc, input logic iis_amo
  );
    instr = iinstr;
    #1;
    tests++;
    begin
      int prev_failures = failures;
      // Auto-extract raw fields from instruction word
      logic [ 4:0] exp_rd    = iinstr[11:7];
      logic [ 2:0] exp_funct3 = iinstr[14:12];
      logic [ 4:0] exp_rs1    = iinstr[19:15];
      logic [ 4:0] exp_rs2    = iinstr[24:20];
      // Check raw fields
      if (rd !== exp_rd) begin $display("FAIL  %-18s .rd got=%0d want=%0d", name, rd, exp_rd); failures++; end
      if (funct3 !== exp_funct3) begin $display("FAIL  %-18s .funct3 got=%0d want=%0d", name, funct3, exp_funct3); failures++; end
      if (rs1 !== exp_rs1) begin $display("FAIL  %-18s .rs1 got=%0d want=%0d", name, rs1, exp_rs1); failures++; end
      if (rs2 !== exp_rs2) begin $display("FAIL  %-18s .rs2 got=%0d want=%0d", name, rs2, exp_rs2); failures++; end
      if (imm !== iimm) begin $display("FAIL  %-18s .imm got=0x%08h want=0x%08h", name, imm, iimm); failures++; end
      if (use_imm !== iuse_imm) begin $display("FAIL  %-18s .use_imm got=%0d want=%0d", name, use_imm, iuse_imm); failures++; end
      if (alu_op_valid !== ialu_op_valid) begin $display("FAIL  %-18s .alu_op_valid got=%0d want=%0d", name, alu_op_valid, ialu_op_valid); failures++; end
      if (alu_op !== ialu_op) begin $display("FAIL  %-18s .alu_op got=%0d want=%0d", name, alu_op, ialu_op); failures++; end
      if (mem_read !== imem_read) begin $display("FAIL  %-18s .mem_read got=%0d want=%0d", name, mem_read, imem_read); failures++; end
      if (mem_write !== imem_write) begin $display("FAIL  %-18s .mem_write got=%0d want=%0d", name, mem_write, imem_write); failures++; end
      if (reg_write !== ireg_write) begin $display("FAIL  %-18s .reg_write got=%0d want=%0d", name, reg_write, ireg_write); failures++; end
      if (branch !== ibranch) begin $display("FAIL  %-18s .branch got=%0d want=%0d", name, branch, ibranch); failures++; end
      if (jump !== ijump) begin $display("FAIL  %-18s .jump got=%0d want=%0d", name, jump, ijump); failures++; end
      if (is_jalr !== iis_jalr) begin $display("FAIL  %-18s .is_jalr got=%0d want=%0d", name, is_jalr, iis_jalr); failures++; end
      if (illegal !== iillegal) begin $display("FAIL  %-18s .illegal got=%0d want=%0d", name, illegal, iillegal); failures++; end
      if (lui !== ilui) begin $display("FAIL  %-18s .lui got=%0d want=%0d", name, lui, ilui); failures++; end
      if (auipc !== iauipc) begin $display("FAIL  %-18s .auipc got=%0d want=%0d", name, auipc, iauipc); failures++; end
      if (csr_op !== icsr_op) begin $display("FAIL  %-18s .csr_op got=%0d want=%0d", name, csr_op, icsr_op); failures++; end
      if (csr_wen !== icsr_wen) begin $display("FAIL  %-18s .csr_wen got=%0d want=%0d", name, csr_wen, icsr_wen); failures++; end
      if (is_csr !== iis_csr) begin $display("FAIL  %-18s .is_csr got=%0d want=%0d", name, is_csr, iis_csr); failures++; end
      if (is_mret !== iis_mret) begin $display("FAIL  %-18s .is_mret got=%0d want=%0d", name, is_mret, iis_mret); failures++; end
      if (is_sret !== iis_sret) begin $display("FAIL  %-18s .is_sret got=%0d want=%0d", name, is_sret, iis_sret); failures++; end
      if (is_wfi !== iis_wfi) begin $display("FAIL  %-18s .is_wfi got=%0d want=%0d", name, is_wfi, iis_wfi); failures++; end
      if (is_sfence_vma !== iis_sfence_vma) begin $display("FAIL  %-18s .is_sfence_vma got=%0d want=%0d", name, is_sfence_vma, iis_sfence_vma); failures++; end
      if (use_zimm !== iuse_zimm) begin $display("FAIL  %-18s .use_zimm got=%0d want=%0d", name, use_zimm, iuse_zimm); failures++; end
      if (is_ecall !== iis_ecall) begin $display("FAIL  %-18s .is_ecall got=%0d want=%0d", name, is_ecall, iis_ecall); failures++; end
      if (is_ebreak !== iis_ebreak) begin $display("FAIL  %-18s .is_ebreak got=%0d want=%0d", name, is_ebreak, iis_ebreak); failures++; end
      if (is_lr !== iis_lr) begin $display("FAIL  %-18s .is_lr got=%0d want=%0d", name, is_lr, iis_lr); failures++; end
      if (is_sc !== iis_sc) begin $display("FAIL  %-18s .is_sc got=%0d want=%0d", name, is_sc, iis_sc); failures++; end
      if (is_amo !== iis_amo) begin $display("FAIL  %-18s .is_amo got=%0d want=%0d", name, is_amo, iis_amo); failures++; end
      if (failures != prev_failures) $display("  (instr=0x%08h)", iinstr);
    end
  endtask

  initial begin
    // LUI
    check("LUI", u_type(20'h12345, 5, OpLui),
          32'h1234_5000, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 1, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // AUIPC
    check("AUIPC", u_type(20'hABCDE, 6, OpAuipc),
          32'hABCD_E000, 1, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 1, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // JAL
    check("JAL +0x100", j_type(21'h100, 1, OpJal),
          32'h0000_0100, 0, 0, AluAdd,
          0, 0, 1, 0, 1, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // JAL -4
    check("JAL -4", j_type(21'h1FFFFC, 1, OpJal),
          32'hFFFF_FFFC, 0, 0, AluAdd,
          0, 0, 1, 0, 1, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // JALR
    check("JALR", i_type(12'h4, 2, 0, 1, OpJalr),
          32'h0000_0004, 1, 0, AluAdd,
          0, 0, 1, 0, 1, 1, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // BEQ
    check("BEQ +8", b_type(13'h8, 2, 1, 0, OpBranch),
          32'h0000_0008, 0, 0, AluAdd,
          0, 0, 0, 1, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // BNE -16
    check("BNE -16", b_type(13'h1FF0, 2, 1, 1, OpBranch),
          32'hFFFF_FFF0, 0, 0, AluAdd,
          0, 0, 0, 1, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // LW
    check("LW", i_type(12'h10, 4, 2, 3, OpLoad),
          32'h0000_0010, 1, 1, AluAdd,
          1, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // LH
    check("LH", i_type(12'h0, 4, 1, 3, OpLoad),
          32'h0000_0000, 1, 1, AluAdd,
          1, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SW
    check("SW", s_type(12'h8, 2, 3, 2, OpStore),
          32'h0000_0008, 1, 1, AluAdd,
          0, 1, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SB -4
    check("SB -4", s_type(12'hFFC, 2, 3, 0, OpStore),
          32'hFFFF_FFFC, 1, 1, AluAdd,
          0, 1, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // ADDI
    check("ADDI", i_type(12'h5, 2, 0, 1, OpImm),
          32'h0000_0005, 1, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLLI
    check("SLLI", i_type(12'h4, 2, 1, 1, OpImm),
          32'h0000_0004, 1, 1, AluSll,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLTI -1
    check("SLTI -1", i_type(12'hFFF, 2, 2, 1, OpImm),
          32'hFFFF_FFFF, 1, 1, AluSlt,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLTIU
    check("SLTIU", i_type(12'h1, 2, 3, 1, OpImm),
          32'h0000_0001, 1, 1, AluSltu,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // XORI
    check("XORI", i_type(12'hFF, 2, 4, 1, OpImm),
          32'h0000_00FF, 1, 1, AluXor,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SRLI
    check("SRLI", i_type(12'h4, 2, 5, 1, OpImm),
          32'h0000_0004, 1, 1, AluSrl,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SRAI
    check("SRAI", i_type(12'h404, 2, 5, 1, OpImm),
          32'h0000_0404, 1, 1, AluSra,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // ORI
    check("ORI", i_type(12'hF0, 2, 6, 1, OpImm),
          32'h0000_00F0, 1, 1, AluOr,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // ANDI
    check("ANDI", i_type(12'hFF, 2, 7, 1, OpImm),
          32'h0000_00FF, 1, 1, AluAnd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // ADD
    check("ADD", r_type(7'h0, 3, 2, 0, 1, OpReg),
          32'h0, 0, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SUB
    check("SUB", r_type(7'h20, 3, 2, 0, 1, OpReg),
          32'h0, 0, 1, AluSub,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLL
    check("SLL", r_type(7'h0, 3, 2, 1, 1, OpReg),
          32'h0, 0, 1, AluSll,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLT
    check("SLT", r_type(7'h0, 3, 2, 2, 1, OpReg),
          32'h0, 0, 1, AluSlt,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SLTU
    check("SLTU", r_type(7'h0, 3, 2, 3, 1, OpReg),
          32'h0, 0, 1, AluSltu,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // XOR
    check("XOR", r_type(7'h0, 3, 2, 4, 1, OpReg),
          32'h0, 0, 1, AluXor,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SRL
    check("SRL", r_type(7'h0, 3, 2, 5, 1, OpReg),
          32'h0, 0, 1, AluSrl,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SRA
    check("SRA", r_type(7'h20, 3, 2, 5, 1, OpReg),
          32'h0, 0, 1, AluSra,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // OR
    check("OR", r_type(7'h0, 3, 2, 6, 1, OpReg),
          32'h0, 0, 1, AluOr,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // AND
    check("AND", r_type(7'h0, 3, 2, 7, 1, OpReg),
          32'h0, 0, 1, AluAnd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // FENCE (NOP)
    check("FENCE", 32'h0000_000F,
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // CSRRW (imm=0: decoder does not extract CSR address as imm)
    check("CSRRW", i_type(12'h340, 2, 1, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_WRITE, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // CSRRS rs1!=0
    check("CSRRS rs1!=0", i_type(12'h340, 2, 2, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_SET, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // CSRRS rs1=x0
    check("CSRRS rs1=x0", i_type(12'h340, 0, 2, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_SET, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // CSRRC
    check("CSRRC", i_type(12'h340, 2, 3, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_CLEAR, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // CSRRWI
    check("CSRRWI", i_type(12'h340, 5, 5, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_WRITE, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0);

    // CSRRSI zimm!=0
    check("CSRRSI zimm!=0", i_type(12'h340, 5, 6, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_SET, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0);

    // CSRRSI zimm=0
    check("CSRRSI zimm=0", i_type(12'h340, 0, 6, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_SET, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0);

    // CSRRCI
    check("CSRRCI", i_type(12'h340, 5, 7, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 1, 0, 0, 0, 0, 0, 0, CSR_CLEAR, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0);

    // ECALL
    check("ECALL", i_type(12'h0, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0);

    // EBREAK (imm=0: decoder does not extract funct12 as imm)
    check("EBREAK", i_type(12'h1, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0);

    // MRET (imm=0)
    check("MRET", i_type(12'h302, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // SRET (imm=0)
    check("SRET", i_type(12'h102, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0);

    // WFI (imm=0)
    check("WFI", i_type(12'h105, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);

    // SFENCE.VMA
    check("SFENCE.VMA", r_type(7'b0001001, 0, 0, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0);

    // SFENCE.VMA rs1/rs2
    check("SFENCE.VMA rs1/rs2", r_type(7'b0001001, 5, 3, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0);

    // Illegal opcode
    check("illegal opcode", 32'h0000_007F,
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal ADD funct7
    check("illegal ADD funct7", r_type(7'h10, 3, 2, 0, 1, OpReg),
          32'h0, 0, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal SLL funct7 (alu_op falls through to default AluAdd, not AluSll)
    check("illegal SLL funct7", r_type(7'h20, 3, 2, 1, 1, OpReg),
          32'h0, 0, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal SLLI funct7 (alu_op falls through to default AluAdd, not AluSll)
    check("illegal SLLI funct7", i_type(12'h204, 2, 1, 1, OpImm),
          32'h0000_0204, 1, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal BRANCH funct3=010
    check("illegal BRANCH funct3=010", b_type(13'h8, 2, 1, 2, OpBranch),
          32'h0000_0008, 0, 0, AluAdd,
          0, 0, 0, 1, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal BRANCH funct3=011
    check("illegal BRANCH funct3=011", b_type(13'h8, 2, 1, 3, OpBranch),
          32'h0000_0008, 0, 0, AluAdd,
          0, 0, 0, 1, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal LOAD funct3=011
    check("illegal LOAD funct3=011", i_type(12'h0, 4, 3, 3, OpLoad),
          32'h0000_0000, 1, 1, AluAdd,
          1, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal LOAD funct3=110
    check("illegal LOAD funct3=110", i_type(12'h0, 4, 6, 3, OpLoad),
          32'h0000_0000, 1, 1, AluAdd,
          1, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal STORE funct3=011
    check("illegal STORE funct3=011", s_type(12'h8, 2, 3, 3, OpStore),
          32'h0000_0008, 1, 1, AluAdd,
          0, 1, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal STORE funct3=100
    check("illegal STORE funct3=100", s_type(12'h8, 2, 3, 4, OpStore),
          32'h0000_0008, 1, 1, AluAdd,
          0, 1, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal JALR funct3=001
    check("illegal JALR funct3=001", i_type(12'h4, 2, 1, 1, OpJalr),
          32'h0000_0004, 1, 0, AluAdd,
          0, 0, 1, 0, 1, 1, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal MISC-MEM funct3=010
    check("illegal MISC-MEM funct3=010", i_type(12'h0, 0, 2, 0, OpMiscMem),
          32'h0000_0000, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal ECALL rd
    check("illegal ECALL rd", i_type(12'h0, 0, 0, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal EBREAK rs1 (imm=0)
    check("illegal EBREAK rs1", i_type(12'h1, 1, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal MRET rd (imm=0)
    check("illegal MRET rd", i_type(12'h302, 0, 0, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal MRET rs1 (imm=0)
    check("illegal MRET rs1", i_type(12'h302, 1, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal SRET rd (imm=0)
    check("illegal SRET rd", i_type(12'h102, 0, 0, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal SRET rs1 (imm=0)
    check("illegal SRET rs1", i_type(12'h102, 1, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal WFI rd (imm=0)
    check("illegal WFI rd", i_type(12'h105, 0, 0, 1, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal WFI rs1 (imm=0)
    check("illegal WFI rs1", i_type(12'h105, 1, 0, 0, OpSystem),
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // FENCE.I valid NOP (funct3=1 auto-extracted from instruction bits)
    check("FENCE.I valid NOP", 32'h0000_100F,
          32'h0, 0, 0, AluAdd,
          0, 0, 0, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // LR.W
    check("LR.W", {5'b00010, 1'b0, 1'b0, 5'b0, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 0, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0);

    // SC.W
    check("SC.W", {5'b00011, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          0, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0);

    // AMOSWAP.W
    check("AMOSWAP.W", {5'b00001, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOADD.W
    check("AMOADD.W", {5'b00000, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOAND.W
    check("AMOAND.W", {5'b01100, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOOR.W
    check("AMOOR.W", {5'b01000, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOXOR.W
    check("AMOXOR.W", {5'b00100, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOMAX.W
    check("AMOMAX.W", {5'b10100, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOMIN.W
    check("AMOMIN.W", {5'b10000, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOMAXU.W
    check("AMOMAXU.W", {5'b11100, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOMINU.W
    check("AMOMINU.W", {5'b11000, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // AMOADD.W with aq/rl
    check("AMOADD.W with aq/rl", {5'b00000, 1'b1, 1'b1, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          1, 1, 1, 0, 0, 0, 0, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);

    // Illegal AMO funct3=000
    check("illegal AMO funct3=000", {5'b00000, 1'b0, 1'b0, 5'd3, 5'd4, 3'd0, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    // Illegal AMO funct5=00101
    check("illegal AMO funct5=00101", {5'b00101, 1'b0, 1'b0, 5'd3, 5'd4, 3'd2, 5'd5, OpAmo},
          32'h0, 1, 1, AluAdd,
          0, 0, 1, 0, 0, 0, 1, 0, 0, CSR_NONE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    $display("\n=== tb_decoder: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
