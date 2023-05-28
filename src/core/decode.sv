`timescale 1 ns / 1 ps
//
`default_nettype none

module decode (
    // DECODE
    input var  [6:0] opcode,
    input var  [2:0] funct3,
    input var  [6:0] funct7,
    //
    output var [2:0] imm_sel,
    //
    output var       alu_b_sel,
    output var [3:0] alu_op,
    // EXECUTE
    output var       jump,
    output var [1:0] branch,
    // MEM
    output var       dmem_en,
    output var [3:0] dmem_we,
    // WRITEBACK
    output var [1:0] result_sel,
    output var       we3
);


  logic is_load;
  logic is_store;
  logic is_branch;
  logic is_jalr;
  logic is_misc;
  logic is_jal;
  logic is_op_imm;
  logic is_op;
  logic is_system;
  logic is_auipc;
  logic is_lui;

  logic i_type;
  logic s_type;
  logic b_type;
  logic u_type;
  logic j_type;
  logic r_type;

  logic illegal_opcode;


  // DECODE
  //-------

  // Instruction opcode map
  // Inst[4:2]
  // Inst[6:5]    000         001      010         011       100      101          110     111
  //        00   LOAD(*)  LOAD-FP( )     -( ) MISC-MEM(*) OP-IMM(*) AUIPC(*) OP-IMM-32( )    -
  //        01  STORE(*) STORE-FP( )     -( )      AMO( )     OP(*)   LUI(*)     OP-32( )    -
  //        10   MADD        MSUB( ) NMSUB( )    NMADD( )  OP-FP( )     -( )         -( )    -
  //        11 BRANCH(*)     JALR(*)     -( )      JAL(*) SYSTEM(*)     -( )         -( )    -

  assign is_load        = (opcode == 7'b00_000_11);
  assign is_store       = (opcode == 7'b01_000_11);
  assign is_branch      = (opcode == 7'b11_000_11);
  assign is_jalr        = (opcode == 7'b11_001_11);
  assign is_misc        = (opcode == 7'b00_011_11);
  assign is_jal         = (opcode == 7'b11_011_11);
  assign is_op_imm      = (opcode == 7'b00_100_11);
  assign is_op          = (opcode == 7'b01_100_11);
  assign is_system      = (opcode == 7'b11_100_11);
  assign is_auipc       = (opcode == 7'b00_101_11);
  assign is_lui         = (opcode == 7'b01_101_11);

  // Instruction type decoding

  assign i_type         = is_load | is_jalr | is_op_imm | is_system | is_misc;
  assign s_type         = is_store;
  assign b_type         = is_branch;
  assign u_type         = is_auipc | is_lui;
  assign j_type         = is_jal;
  assign r_type         = is_op;
  // TODO: Treat is_system / is_misc as I Type, this may not right

  assign illegal_opcode = ~(i_type | s_type | b_type | u_type | j_type | r_type);

  // Immediate value selection
  // I/S/B/J/U is needed here

  always_comb begin
    if (i_type) begin
      imm_sel = 3'b000;
    end else if (s_type) begin
      imm_sel = 3'b001;
    end else if (b_type) begin
      imm_sel = 3'b010;
    end else if (j_type) begin
      imm_sel = 3'b011;
    end else if (u_type) begin
      imm_sel = 3'b100;
    end else begin  // R Type or system
      imm_sel = 3'b000;
    end
  end

  // ALU A value selection
  // 0: select RS1, 1: select PC

  // ALU B value selection
  // 0: select RS2, 1: select IMM

  always_comb begin
    if (is_load | is_branch | is_op_imm | is_auipc | is_store | is_jalr | is_jal) begin
      alu_b_sel = 1'b1;  // Imm
    end else begin
      alu_b_sel = 1'b0;  // rs2
    end
  end

  // ALU Op
  // funct7[5] marks the "alternative" version of ALU operation
  //
  // BRACH instruction to ALU OP mapping:
  //  BR
  // 3'b---: 4'b0_000: $signed(a) + signed(b), same as a + b
  // 3'b---: 4'b1_000: $signed(a) - signed(b), same as a - b
  // 3'b---: 4'bx_001: a << b[4:0]
  // 3'b10x: 4'bx_010: ($signed(a) < $signed(b)) ? 32'h1 : 32'h0
  // 3'b11x: 4'bx_011: (a < b) ? 32'h1 : 32'h0
  // 3'b00x: 4'bx_100: a ^ b
  // 3'b---: 4'b0_101: a >> b[4:0]
  // 3'b---: 4'b1_101: $signed(a) >>> b[4:0]
  // 3'b---: 4'bx_110: a | b
  // 3'b---: 4'bx_111: a & b

  always_comb begin
    if (is_branch) begin
      // BRANCH to ALU OP mapping
      if (funct3[1]) begin // BLTU, BGEU, funct3 = 3'b11x, since 3'b01x is invalid
        alu_op = 4'b0011; // a - b
      end else if (funct3[2]) begin // BLT, BGE, funct3 = 3'b10x
        alu_op = 4'b0010; // $signed(a) - $signed(b)
      end else begin // BEQ, BNE, funct3 == 3'b00x
        alu_op = 4'b0100; // ^
      end
    end else if (is_op | is_op_imm) begin
      alu_op = {r_type && funct7[5], funct3};
    end else begin
      alu_op = '0; // add
    end
  end


  // EXECUTE
  //--------

  assign jump = is_jalr | is_jal;

  // brach[1] marks the inversed brach condition
  assign branch = {funct3[0], is_branch};


  // MEM
  //----

  // TODO: add byte/half LOAD operation
  assign dmem_en = is_load;

  // TODO: add byte/half STORE operation
  assign dmem_we = {4{is_store}};


  // WRITEBACK
  //----------

  // Register write enable

  always_comb begin
    if (is_jalr | is_misc | is_jal | is_op_imm | is_op | is_auipc | is_lui) begin
      we3 = 1'b1;
    end else begin
      we3 = 1'b0;
    end
  end

  // Result selection

  always_comb begin
    if (is_load) begin
      result_sel = 2'b01;
    end else if (is_jalr | is_jal) begin
      result_sel = 2'b10;
    end else if (is_auipc) begin
      result_sel = 2'b11;
    end else begin // is_lui
      result_sel = 2'b00;
    end
  end

endmodule

`default_nettype wire
