// tb_decompressor.sv — unit test for kv32_decompressor
// Verifies all RV32C instruction formats expand to correct 32-bit equivalents.
// Combinational DUT: set 16-bit instr, eval, check expanded + illegal.

module tb_decompressor;
  logic [15:0] instr;
  logic [31:0] expanded;
  logic        illegal;

  kv32_decompressor u_dut (.*);

  int tests = 0, failures = 0;

  // ---- Check task ----------------------------------------------------------

  task automatic check(
    string       name,
    logic [15:0] iinstr,
    logic [31:0] expected_expanded,
    logic        expected_illegal
  );
    instr = iinstr;
    #1;
    tests++;
    if (expected_illegal) begin
      if (!illegal) begin
        $display("FAIL %s: expected illegal but got expanded=0x%08h", name, expanded);
        failures++;
      end
    end else begin
      if (illegal) begin
        $display("FAIL %s: unexpected illegal", name);
        failures++;
      end else if (expanded !== expected_expanded) begin
        $display("FAIL %s: expanded=0x%08h expected=0x%08h", name, expanded, expected_expanded);
        failures++;
      end
    end
  endtask

  // ---- 32-bit instruction encoding helpers ---------------------------------

  // I-type: imm[11:0] | rs1 | funct3 | rd | opcode
  function automatic logic [31:0] i_type(
    logic [11:0] imm12, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op
  );
    return {imm12, rs1, f3, rd, op};
  endfunction

  // S-type: imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
  function automatic logic [31:0] s_type(
    logic [11:0] imm12, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [6:0] op
  );
    return {imm12[11:5], rs2, rs1, f3, imm12[4:0], op};
  endfunction

  // B-type
  function automatic logic [31:0] b_type(
    logic [12:0] imm13, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [6:0] op
  );
    return {imm13[12], imm13[10:5], rs2, rs1, f3, imm13[4:1], imm13[11], op};
  endfunction

  // U-type: imm[31:12] | rd | opcode
  function automatic logic [31:0] u_type(
    logic [31:0] imm20, logic [4:0] rd, logic [6:0] op
  );
    return {imm20[31:12], rd, op};
  endfunction

  // J-type
  function automatic logic [31:0] j_type(
    logic [20:0] imm21, logic [4:0] rd, logic [6:0] op
  );
    return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, op};
  endfunction

  // R-type: funct7 | rs2 | rs1 | funct3 | rd | opcode
  function automatic logic [31:0] r_type(
    logic [6:0] f7, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op
  );
    return {f7, rs2, rs1, f3, rd, op};
  endfunction

  // ---- Opcodes -------------------------------------------------------------

  localparam logic [6:0] OP_LUI   = 7'h37;
  localparam logic [6:0] OP_JAL   = 7'h6F;
  localparam logic [6:0] OP_JALR  = 7'h67;
  localparam logic [6:0] OP_BRANCH= 7'h63;
  localparam logic [6:0] OP_LOAD  = 7'h03;
  localparam logic [6:0] OP_STORE = 7'h23;
  localparam logic [6:0] OP_IMM   = 7'h13;
  localparam logic [6:0] OP_REG   = 7'h33;

  // Compressed register fields: x8 + bits[4:2] or x8 + bits[9:7]
  function automatic logic [4:0] rp(logic [2:0] bits3);
    return 5'(8 + 3'(bits3));
  endfunction

  // ---- Compressed instruction encoders -------------------------------------

  // C.ADDI4SPN: rd', nzuimm (nzuimm is multiple of 4, nonzero, 10-bit max)
  // Encoding: [15:13]=000, [12:5]=nzuimm bits, [4:2]=rd', [1:0]=00
  function automatic logic [15:0] c_addi4spn(logic [2:0] rd3, logic [9:0] nzuimm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[12:11] = nzuimm[5:4];
    enc[10:7]  = nzuimm[9:6];
    enc[6]     = nzuimm[2];
    enc[5]     = nzuimm[3];
    enc[4:2]   = rd3;
    enc[1:0]   = 2'b00;
    return enc;
  endfunction

  // C.LW: rd', offset(rs1')
  // Encoding: [15:13]=010, [12:10]=offset[5:3], [9:7]=rs1', [6]=offset[2], [5]=offset[6], [4:2]=rd', [1:0]=00
  function automatic logic [15:0] c_lw(logic [2:0] rd3, logic [2:0] rs1_3, logic [6:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b010;
    enc[12:10] = offset[5:3];
    enc[9:7]   = rs1_3;
    enc[6]     = offset[2];
    enc[5]     = offset[6];
    enc[4:2]   = rd3;
    enc[1:0]   = 2'b00;
    return enc;
  endfunction

  // C.SW: rs2', offset(rs1')
  // Encoding: [15:13]=110, [12:10]=offset[5:3], [9:7]=rs1', [6]=offset[2], [5]=offset[6], [4:2]=rs2', [1:0]=00
  function automatic logic [15:0] c_sw(logic [2:0] rs2_3, logic [2:0] rs1_3, logic [6:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b110;
    enc[12:10] = offset[5:3];
    enc[9:7]   = rs1_3;
    enc[6]     = offset[2];
    enc[5]     = offset[6];
    enc[4:2]   = rs2_3;
    enc[1:0]   = 2'b00;
    return enc;
  endfunction

  // C.ADDI / C.NOP: rd, imm
  // Encoding: [15:13]=000, [12]=imm[5], [11:7]=rd, [6:2]=imm[4:0], [1:0]=01
  function automatic logic [15:0] c_addi(logic [4:0] rd, logic [5:0] imm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b000;
    enc[12]    = imm[5];
    enc[11:7]  = rd;
    enc[6:2]   = imm[4:0];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.JAL (RV32): offset
  // Encoding: [15:13]=001, [12:2]=offset bits, [1:0]=01
  function automatic logic [15:0] c_jal(logic [11:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b001;
    enc[12]    = offset[11];
    enc[11]    = offset[4];
    enc[10:9]  = offset[9:8];
    enc[8]     = offset[10];
    enc[7]     = offset[6];
    enc[6]     = offset[7];
    enc[5:3]   = offset[3:1];
    enc[2]     = offset[5];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.LI: rd, imm
  // Encoding: [15:13]=010, [12]=imm[5], [11:7]=rd, [6:2]=imm[4:0], [1:0]=01
  function automatic logic [15:0] c_li(logic [4:0] rd, logic [5:0] imm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b010;
    enc[12]    = imm[5];
    enc[11:7]  = rd;
    enc[6:2]   = imm[4:0];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.ADDI16SP: nzimm (multiple of 16, nonzero)
  // Encoding: [15:13]=011, [12]=nzimm[9], [11:7]=2(x2), [6:2]=nzimm bits, [1:0]=01
  function automatic logic [15:0] c_addi16sp(logic [9:0] nzimm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b011;
    enc[12]    = nzimm[9];
    enc[11:7]  = 5'd2;  // rd = x2
    enc[6]     = nzimm[4];
    enc[5]     = nzimm[6];
    enc[4:3]   = nzimm[8:7];
    enc[2]     = nzimm[5];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.LUI: rd, nzimm
  // Encoding: [15:13]=011, [12]=nzimm[17], [11:7]=rd, [6:2]=nzimm[16:12], [1:0]=01
  function automatic logic [15:0] c_lui(logic [4:0] rd, logic [17:0] nzimm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b011;
    enc[12]    = nzimm[17];
    enc[11:7]  = rd;
    enc[6:2]   = nzimm[16:12];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.SRLI: rd', shamt
  // Encoding: [15:13]=100, [12]=0(shamt[5]), [11:10]=00, [9:7]=rd', [6:2]=shamt[4:0], [1:0]=01
  function automatic logic [15:0] c_srli(logic [2:0] rd3, logic [4:0] shamt);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[11:10] = 2'b00;
    enc[9:7]   = rd3;
    enc[6:2]   = shamt;
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.SRAI: rd', shamt
  // Encoding: [15:13]=100, [12]=0, [11:10]=01, [9:7]=rd', [6:2]=shamt[4:0], [1:0]=01
  function automatic logic [15:0] c_srai(logic [2:0] rd3, logic [4:0] shamt);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[11:10] = 2'b01;
    enc[9:7]   = rd3;
    enc[6:2]   = shamt;
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.ANDI: rd', imm
  // Encoding: [15:13]=100, [12]=imm[5], [11:10]=10, [9:7]=rd', [6:2]=imm[4:0], [1:0]=01
  function automatic logic [15:0] c_andi(logic [2:0] rd3, logic [5:0] imm);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[12]    = imm[5];
    enc[11:10] = 2'b10;
    enc[9:7]   = rd3;
    enc[6:2]   = imm[4:0];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.SUB/C.XOR/C.OR/C.AND: rd', rs2'
  // Encoding: [15:13]=100, [12]=0, [11:10]=11, [6:5]=funct, [9:7]=rd', [4:2]=rs2', [1:0]=01
  function automatic logic [15:0] c_alu(logic [1:0] funct2, logic [2:0] rd3, logic [2:0] rs2_3);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[11:10] = 2'b11;
    enc[12]    = 1'b0;  // bit[12] = 0 for RV32
    enc[6:5]   = funct2;
    enc[9:7]   = rd3;
    enc[4:2]   = rs2_3;
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.J: offset
  // Same encoding as C.JAL but funct3=101
  function automatic logic [15:0] c_j(logic [11:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b101;
    enc[12]    = offset[11];
    enc[11]    = offset[4];
    enc[10:9]  = offset[9:8];
    enc[8]     = offset[10];
    enc[7]     = offset[6];
    enc[6]     = offset[7];
    enc[5:3]   = offset[3:1];
    enc[2]     = offset[5];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.BEQZ: rs1', offset
  // Encoding: [15:13]=110, [12:10]=offset bits, [9:7]=rs1', [6:2]=offset bits, [1:0]=01
  function automatic logic [15:0] c_beqz(logic [2:0] rs1_3, logic [8:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b110;
    enc[12]    = offset[8];
    enc[11:10] = offset[4:3];
    enc[9:7]   = rs1_3;
    enc[6:5]   = offset[7:6];
    enc[4:3]   = offset[2:1];
    enc[2]     = offset[5];
    enc[1:0]   = 2'b01;
    return enc;
  endfunction

  // C.BNEZ: rs1', offset
  // Same as C.BEQZ but funct3=111
  function automatic logic [15:0] c_bnez(logic [2:0] rs1_3, logic [8:0] offset);
    logic [15:0] enc;
    enc = c_beqz(rs1_3, offset);
    enc[15:13] = 3'b111;
    return enc;
  endfunction

  // C.SLLI: rd, shamt
  // Encoding: [15:13]=000, [12]=0, [11:7]=rd, [6:2]=shamt[4:0], [1:0]=10
  function automatic logic [15:0] c_slli(logic [4:0] rd, logic [4:0] shamt);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b000;
    enc[11:7]  = rd;
    enc[6:2]   = shamt;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.LWSP: rd, offset
  // Encoding: [15:13]=010, [12]=offset[5], [11:7]=rd, [6:2]=offset bits, [1:0]=10
  function automatic logic [15:0] c_lwsp(logic [4:0] rd, logic [7:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b010;
    enc[12]    = offset[5];
    enc[11:7]  = rd;
    enc[6:4]   = offset[4:2];
    enc[3:2]   = offset[7:6];
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.JR: rs1
  // Encoding: [15:13]=100, [12]=0, [11:7]=rs1, [6:2]=0, [1:0]=10
  function automatic logic [15:0] c_jr(logic [4:0] rs1);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[11:7]  = rs1;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.MV: rd, rs2
  // Encoding: [15:13]=100, [12]=0, [11:7]=rd, [6:2]=rs2, [1:0]=10
  function automatic logic [15:0] c_mv(logic [4:0] rd, logic [4:0] rs2);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[11:7]  = rd;
    enc[6:2]   = rs2;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.JALR: rs1
  // Encoding: [15:13]=100, [12]=1, [11:7]=rs1, [6:2]=0, [1:0]=10
  function automatic logic [15:0] c_jalr(logic [4:0] rs1);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[12]    = 1'b1;
    enc[11:7]  = rs1;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.ADD: rd, rs2
  // Encoding: [15:13]=100, [12]=1, [11:7]=rd, [6:2]=rs2, [1:0]=10
  function automatic logic [15:0] c_add(logic [4:0] rd, logic [4:0] rs2);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b100;
    enc[12]    = 1'b1;
    enc[11:7]  = rd;
    enc[6:2]   = rs2;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // C.SWSP: rs2, offset
  // Encoding: [15:13]=110, [12:7]=offset bits, [6:2]=rs2, [1:0]=10
  function automatic logic [15:0] c_swsp(logic [4:0] rs2, logic [7:0] offset);
    logic [15:0] enc;
    enc = 16'h0;
    enc[15:13] = 3'b110;
    enc[12:9]  = offset[5:2];
    enc[8:7]   = offset[7:6];
    enc[6:2]   = rs2;
    enc[1:0]   = 2'b10;
    return enc;
  endfunction

  // ---- Test execution ------------------------------------------------------

  initial begin
    // =====================================================================
    // Quadrant 0 tests
    // =====================================================================

    // C.ADDI4SPN: addi x10, x2, 24
    check("C.ADDI4SPN x10,x2,24",
          c_addi4spn(3'd2, 10'd24),
          i_type(12'd24, 5'd2, 3'd0, rp(3'd2), OP_IMM),
          1'b0);

    // C.ADDI4SPN with nzuimm=0 should be illegal
    check("C.ADDI4SPN nzuimm=0 (illegal)",
          c_addi4spn(3'd0, 10'd0),
          32'd0, 1'b1);

    // C.LW: lw x10, 4(x12)
    check("C.LW x10,4(x12)",
          c_lw(3'd2, 3'd4, 7'd4),
          i_type(12'd4, rp(3'd4), 3'd2, rp(3'd2), OP_LOAD),
          1'b0);

    // C.LW: lw x8, 20(x15)
    check("C.LW x8,20(x15)",
          c_lw(3'd0, 3'd7, 7'd20),
          i_type(12'd20, rp(3'd7), 3'd2, rp(3'd0), OP_LOAD),
          1'b0);

    // C.SW: sw x10, 8(x12)
    check("C.SW x10,8(x12)",
          c_sw(3'd2, 3'd4, 7'd8),
          s_type(12'd8, rp(3'd2), rp(3'd4), 3'd2, OP_STORE),
          1'b0);

    // C.FLD (RV64 only) -- should be illegal in RV32
    check("C.FLD (illegal in RV32)",
          16'h2000,  // (3'b001 << 13) | 0x00
          32'd0, 1'b1);

    // C.FLW (RV32, but F ext not implemented) -- should be illegal
    check("C.FLW (illegal, no F ext)",
          16'h6000,  // (3'b011 << 13) | 0x00
          32'd0, 1'b1);

    // Reserved Q0 funct3=100
    check("Q0 reserved funct3=100",
          16'h8000,  // (3'b100 << 13) | 0x00
          32'd0, 1'b1);

    // =====================================================================
    // Quadrant 1 tests
    // =====================================================================

    // C.NOP: addi x0, x0, 0
    check("C.NOP",
          c_addi(5'd0, 6'd0),
          i_type(12'd0, 5'd0, 3'd0, 5'd0, OP_IMM),
          1'b0);

    // C.ADDI: addi x15, x15, -3
    check("C.ADDI x15,-3",
          c_addi(5'd15, 6'(signed'(-3))),
          i_type(12'($unsigned(-3)), 5'd15, 3'd0, 5'd15, OP_IMM),
          1'b0);

    // C.JAL (RV32): jal x1, offset
    // Test with offset = 10 (0xA)
    check("C.JAL offset=10",
          c_jal(12'd10),
          j_type(21'd10, 5'd1, OP_JAL),
          1'b0);

    // C.JAL with negative offset
    check("C.JAL offset=-16",
          c_jal(12'($unsigned(-16))),
          j_type(21'($unsigned(-16)), 5'd1, OP_JAL),
          1'b0);

    // C.LI: addi x5, x0, 7
    check("C.LI x5,7",
          c_li(5'd5, 6'd7),
          i_type(12'd7, 5'd0, 3'd0, 5'd5, OP_IMM),
          1'b0);

    // C.LI with negative immediate
    check("C.LI x5,-1",
          c_li(5'd5, 6'($unsigned(-1))),
          i_type(12'($unsigned(-1)), 5'd0, 3'd0, 5'd5, OP_IMM),
          1'b0);

    // C.ADDI16SP: addi x2, x2, 16
    check("C.ADDI16SP 16",
          c_addi16sp(10'd16),
          i_type(12'd16, 5'd2, 3'd0, 5'd2, OP_IMM),
          1'b0);

    // C.ADDI16SP with nzimm=0 should be illegal
    check("C.ADDI16SP nzimm=0 (illegal)",
          16'h6101,  // (3'b011 << 13) | (2 << 7) | 0x01
          32'd0, 1'b1);

    // C.LUI: lui x5, 0x1000
    check("C.LUI x5,0x1000",
          c_lui(5'd5, 18'h1000),
          u_type(32'h1000, 5'd5, OP_LUI),
          1'b0);

    // C.LUI with rd=0 should be illegal
    check("C.LUI rd=0 (illegal)",
          c_lui(5'd0, 18'h1000),
          32'd0, 1'b1);

    // C.LUI with nzimm=0 should be illegal
    check("C.LUI nzimm=0 (illegal)",
          c_lui(5'd5, 18'd0),
          32'd0, 1'b1);

    // C.SRLI: srli x8, x8, 3
    check("C.SRLI x8,3",
          c_srli(3'd0, 5'd3),
          i_type(12'd3, rp(3'd0), 3'd5, rp(3'd0), OP_IMM),
          1'b0);

    // C.SRAI: srai x9, x9, 5
    check("C.SRAI x9,5",
          c_srai(3'd1, 5'd5),
          r_type(7'b0100000, 5'd5, rp(3'd1), 3'd5, rp(3'd1), OP_IMM),
          1'b0);

    // C.SRLI with shamt[5]=1 should be illegal in RV32
    check("C.SRLI shamt[5]=1 (illegal)",
          16'h9001,  // (3'b100 << 13) | (2'b00 << 10) | (0 << 7) | (1 << 12) | 0x01
          32'd0, 1'b1);

    // C.ANDI: andi x10, x10, -5
    check("C.ANDI x10,-5",
          c_andi(3'd2, 6'($unsigned(-5))),
          i_type(12'($unsigned(-5)), rp(3'd2), 3'd7, rp(3'd2), OP_IMM),
          1'b0);

    // C.SUB: sub x8, x8, x9
    check("C.SUB x8,x9",
          c_alu(2'b00, 3'd0, 3'd1),
          r_type(7'b0100000, rp(3'd1), rp(3'd0), 3'd0, rp(3'd0), OP_REG),
          1'b0);

    // C.XOR: xor x8, x8, x9
    check("C.XOR x8,x9",
          c_alu(2'b01, 3'd0, 3'd1),
          r_type(7'b0000000, rp(3'd1), rp(3'd0), 3'd4, rp(3'd0), OP_REG),
          1'b0);

    // C.OR: or x8, x8, x9
    check("C.OR x8,x9",
          c_alu(2'b10, 3'd0, 3'd1),
          r_type(7'b0000000, rp(3'd1), rp(3'd0), 3'd6, rp(3'd0), OP_REG),
          1'b0);

    // C.AND: and x8, x8, x9
    check("C.AND x8,x9",
          c_alu(2'b11, 3'd0, 3'd1),
          r_type(7'b0000000, rp(3'd1), rp(3'd0), 3'd7, rp(3'd0), OP_REG),
          1'b0);

    // C.SUBW (RV64 only) -- should be illegal
    check("C.SUBW (illegal in RV32)",
          16'h9C01,  // (3'b100 << 13) | (1 << 12) | (2'b11 << 10) | (2'b00 << 5) | (0 << 7) | (0 << 2) | 0x01
          32'd0, 1'b1);

    // C.J: jal x0, offset
    check("C.J offset=8",
          c_j(12'd8),
          j_type(21'd8, 5'd0, OP_JAL),
          1'b0);

    // C.BEQZ: beq x8, x0, offset
    check("C.BEQZ x8,offset=6",
          c_beqz(3'd0, 9'd6),
          b_type(13'd6, 5'd0, rp(3'd0), 3'd0, OP_BRANCH),
          1'b0);

    // C.BNEZ: bne x8, x0, offset
    check("C.BNEZ x8,offset=10",
          c_bnez(3'd0, 9'd10),
          b_type(13'd10, 5'd0, rp(3'd0), 3'd1, OP_BRANCH),
          1'b0);

    // C.BEQZ with negative offset
    check("C.BEQZ x8,offset=-8",
          c_beqz(3'd0, 9'($unsigned(-8))),
          b_type(13'($unsigned(-8)), 5'd0, rp(3'd0), 3'd0, OP_BRANCH),
          1'b0);

    // =====================================================================
    // Quadrant 2 tests
    // =====================================================================

    // C.SLLI: slli x5, x5, 3
    check("C.SLLI x5,3",
          c_slli(5'd5, 5'd3),
          i_type(12'd3, 5'd5, 3'd1, 5'd5, OP_IMM),
          1'b0);

    // C.SLLI with shamt[5]=1 should be illegal in RV32
    check("C.SLLI shamt[5]=1 (illegal)",
          16'h1282,  // (3'b000 << 13) | (1 << 12) | (5 << 7) | 0x02
          32'd0, 1'b1);

    // C.SLLI with rd=0 should be illegal
    check("C.SLLI rd=0 (illegal)",
          c_slli(5'd0, 5'd3),
          32'd0, 1'b1);

    // C.LWSP: lw x5, 12(x2)
    check("C.LWSP x5,12(x2)",
          c_lwsp(5'd5, 8'd12),
          i_type(12'd12, 5'd2, 3'd2, 5'd5, OP_LOAD),
          1'b0);

    // C.LWSP with rd=0 should be illegal
    check("C.LWSP rd=0 (illegal)",
          c_lwsp(5'd0, 8'd12),
          32'd0, 1'b1);

    // C.FLDSP (RV64 only) -- should be illegal
    check("C.FLDSP (illegal in RV32)",
          16'h2002,  // (3'b001 << 13) | 0x02
          32'd0, 1'b1);

    // C.JR: jalr x0, x5, 0
    check("C.JR x5",
          c_jr(5'd5),
          i_type(12'd0, 5'd5, 3'd0, 5'd0, OP_JALR),
          1'b0);

    // C.JR with rs1=0 should be illegal
    check("C.JR rs1=0 (illegal)",
          c_jr(5'd0),
          32'd0, 1'b1);

    // C.MV: add x5, x0, x10
    check("C.MV x5,x10",
          c_mv(5'd5, 5'd10),
          r_type(7'd0, 5'd10, 5'd0, 3'd0, 5'd5, OP_REG),
          1'b0);

    // C.EBREAK: ebreak
    check("C.EBREAK",
          16'h9002,  // (3'b100 << 13) | (1 << 12) | 0x02
          32'h00100073,
          1'b0);

    // C.JALR: jalr x1, x5, 0
    check("C.JALR x5",
          c_jalr(5'd5),
          i_type(12'd0, 5'd5, 3'd0, 5'd1, OP_JALR),
          1'b0);

    // C.ADD: add x5, x5, x10
    check("C.ADD x5,x10",
          c_add(5'd5, 5'd10),
          r_type(7'd0, 5'd10, 5'd5, 3'd0, 5'd5, OP_REG),
          1'b0);

    // C.SWSP: sw x10, 16(x2)
    check("C.SWSP x10,16(x2)",
          c_swsp(5'd10, 8'd16),
          s_type(12'd16, 5'd10, 5'd2, 3'd2, OP_STORE),
          1'b0);

    // C.FSDSP (RV64 only) -- should be illegal
    check("C.FSDSP (illegal in RV32)",
          16'hA002,  // (3'b101 << 13) | 0x02
          32'd0, 1'b1);

    // C.FSWSP (RV32, but F ext not implemented) -- should be illegal
    check("C.FSWSP (illegal, no F ext)",
          16'hE002,  // (3'b111 << 13) | 0x02
          32'd0, 1'b1);

    // =====================================================================
    // Quadrant 3 (bits[1:0] = 11) -- not compressed, should signal illegal
    // =====================================================================
    check("Q3 (not compressed)",
          16'h0003,
          32'd0, 1'b1);

    // =====================================================================
    // Edge cases
    // =====================================================================

    // C.ADDI with maximum positive immediate (31)
    check("C.ADDI x1,31",
          c_addi(5'd1, 6'd31),
          i_type(12'd31, 5'd1, 3'd0, 5'd1, OP_IMM),
          1'b0);

    // C.ADDI with maximum negative immediate (-32)
    check("C.ADDI x1,-32",
          c_addi(5'd1, 6'($unsigned(-32))),
          i_type(12'($unsigned(-32)), 5'd1, 3'd0, 5'd1, OP_IMM),
          1'b0);

    // C.LUI with negative nzimm (bit 17 set)
    // nzimm = -4096 (0xFFFFF000 in 32-bit)
    check("C.LUI x5,-4096",
          c_lui(5'd5, 18'($unsigned(-4096))),
          u_type(32'hFFFFF000, 5'd5, OP_LUI),
          1'b0);

    // =====================================================================
    // Results
    // =====================================================================

    $display("\n=== tb_decompressor: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
