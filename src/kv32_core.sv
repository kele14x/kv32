// File: kv32_core
// Brief: A simple RISC-V core.
`timescale 1 ns / 1 ps
//
`default_nettype none

module kv32_core #(
    // PC resister reset value
    parameter logic [31:0] PC_INIT = 32'h0000_0000
) (
    input var         clk,
    input var         rst,
    // IMEM
    output var [31:0] imem_addr,
    output var        imem_en,
    input var  [31:0] imem_dout,
    // DMEM
    output var [31:0] dmem_addr,
    output var        dmem_en,
    output var [ 3:0] dmem_we,
    output var [31:0] dmem_din,
    input var  [31:0] dmem_dout,
    //
    output var        halt
);

  // FSM

  typedef enum int {
     S_RST,
     S_FETCH,
     S_DECODE,
     S_EXECUTE,
     S_MEMORY,
     S_WRITEBACK,
     S_HALT
  } state_t;

  state_t state, state_next;

  // Program counter

  logic [31:0] pc;
  logic        pc_sel;
  logic [31:0] pc_next;
  logic [31:0] pc_target;
  logic [31:0] pc_p4;
  logic        pc_v;

  // Decode

  logic [31:0] inst;
  logic        inst_v;

  logic [ 6:0] opcode;
  logic [ 2:0] funct3;
  logic [ 6:0] funct7;
  logic [11:0] funct12;

  logic [ 4:0] rd;
  logic [ 4:0] rs1id;
  logic [ 4:0] rs2id;

  logic        is_load;
  logic        is_store;
  logic        is_branch;
  logic        is_jalr;
  logic        is_misc;
  logic        is_jal;
  logic        is_op_imm;
  logic        is_op;
  logic        is_system;
  logic        is_auipc;
  logic        is_lui;

  logic        i_type;
  logic        s_type;
  logic        b_type;
  logic        j_type;
  logic        r_type;
  logic        u_type;

  logic        illegal_opcode;

  // Register File

  (* ram_style="distributed" *)
  logic [31:0] regfile                              [32];

  logic [31:0] rs1;
  logic [31:0] rs2;
  logic        we3;

  // Imm Extend

  logic [31:0] imm_i;  // I-type
  logic [31:0] imm_s;  // S-type
  logic [31:0] imm_b;  // B-type, variants of S-type
  logic [31:0] imm_j;  // J-type, variants of U-type
  logic [31:0] imm_u;  // U-type
  logic [31:0] imm;

  // ALU

  logic        op1_sel;
  logic        op2_sel;

  logic [31:0] alu_op1;
  logic [31:0] alu_op2;
  logic [31:0] alu_res;

  // BRU

  logic        bru_z;

  // write back

  logic [ 1:0] result_sel;
  logic [31:0] result;


  // Control
  //--------
  
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_RST;
    end else begin
      state <= state_next;
    end
  end
  
  always_comb begin
    case(state)
      S_RST: begin
        state_next = S_FETCH;
      end

      S_FETCH: begin
        state_next = S_DECODE;
      end

      S_DECODE: begin
        state_next = S_EXECUTE;
      end

      S_EXECUTE: begin
        state_next = S_MEMORY;
      end

      S_MEMORY: begin
        state_next = S_WRITEBACK;
      end

      default: begin
        state_next = S_RST;
      end
    endcase
  end

  assign halt = state == S_HALT;


  // Program Counter
  //----------------

  // By default PC will move to +4 and fetch next instruction, unless current
  // instruction is Branch or Jump. Here list the Branch and Jump instructions:
  //
  // Conditional Branches:
  //   BEQ: if (rs1 == rs2) pc_next = pc + imm_b;
  //   BNE: if (rs1 != rs2) pc_next = pc + imm_b;
  //   BLT: if (rs1 < rs2) pc_next = pc + imm_b;
  //   BGE: if (rs1 >= rs2) pc_next = pc + imm_b;
  //   BLTU: if (rs1 < rs2) pc_next = pc + imm_b;
  //   BGEU: if (rs1 >= rs2) pc_next = pc + imm_b;
  //
  // Unconditional Jumps:
  //   JALR: pc_next = rs1 + imm_i;
  //   JAL: pc_next = pc + imm_j;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc <= PC_INIT;
    end else begin
      pc <= pc_next;
    end
  end

  // PC next value selection, JAL/JALR/BRANCH target adder



  assign pc_next = pc_sel ? pc_target : pc_p4;

  assign pc_p4 = pc + 4;

  assign pc_v = state == S_FETCH;

  always_comb begin
    if (is_branch && bru_z) begin
      pc_target = pc + imm_b;
    end else if (is_jalr) begin
      pc_target = rs1 + imm_i;
    end else if (is_jal) begin
      pc_target = pc + imm_j;
    end else begin
      pc_target = 'x;
    end
  end


  // Instruction fetch
  //------------------

  assign imem_addr = pc;
  assign imem_en   = pc_v;
  assign inst      = imem_dout;

  always_ff @(posedge clk) begin
    inst_v <= pc_v;
  end


  // Instruction decode
  //-------------------

  assign opcode    = inst[6:0];
  assign funct3    = inst[14:12];
  assign funct7    = inst[31:25];
  assign funct12   = inst[31:20];

  assign rd        = inst[11:7];
  assign rs1id     = inst[19:15];
  assign rs2id     = inst[24:20];

  // Instruction opcode map
  //           Inst[4:2]
  // Inst[6:5]    000         001      010         011       100      101          110     111
  //        00   LOAD(*)  LOAD-FP( )     -( ) MISC-MEM(*) OP-IMM(*) AUIPC(*) OP-IMM-32( )    -
  //        01  STORE(*) STORE-FP( )     -( )      AMO( )     OP(*)   LUI(*)     OP-32( )    -
  //        10   MADD        MSUB( ) NMSUB( )    NMADD( )  OP-FP( )     -( )         -( )    -
  //        11 BRANCH(*)     JALR(*)     -( )      JAL(*) SYSTEM(*)     -( )         -( )    -

  assign is_load   = (opcode == 7'b00_000_11);
  assign is_store  = (opcode == 7'b01_000_11);
  assign is_branch = (opcode == 7'b11_000_11);
  assign is_jalr   = (opcode == 7'b11_001_11);
  assign is_misc   = (opcode == 7'b00_011_11);  // FENCE
  assign is_jal    = (opcode == 7'b11_011_11);
  assign is_op_imm = (opcode == 7'b00_100_11);
  assign is_op     = (opcode == 7'b01_100_11);
  assign is_system = (opcode == 7'b11_100_11);  // ECALL/EBREAK/CSR**
  assign is_auipc  = (opcode == 7'b00_101_11);
  assign is_lui    = (opcode == 7'b01_101_11);

  // Instruction type decoding I/S/B/J/R/U
  // TODO: is_system / is_misc is not list here

  assign i_type    = is_load | is_jalr | is_op_imm;
  assign s_type    = is_store;
  assign b_type    = is_branch;
  assign j_type    = is_jal;
  assign r_type    = is_op;
  assign u_type    = is_auipc | is_lui;

  always_comb begin
    if (i_type | s_type | b_type | j_type | r_type | u_type) begin
      illegal_opcode = 1'b0;
    end else if (is_misc | is_system) begin
      illegal_opcode = 1'b0;
    end else begin
      illegal_opcode = 1'b1;
    end
  end


  // Register File
  //--------------

  assign we3 = state == S_WRITEBACK;

  initial begin
    for (int i = 0; i < 32; i++) begin
      regfile[i] = '0;
    end
  end

  // register file reading is combination
  assign rs1 = regfile[rs1id];
  assign rs2 = regfile[rs2id];

  // register file write is sequenced, should be fine to be read at next cycle
  always_ff @(posedge clk) begin
    // x0 should be zero and never be update
    if (we3 && (rd != '0)) begin
      regfile[rd] <= result;
    end
  end


  // Imm Extend
  //-----------

  // Immediate decoding
  // All immediate values are signed extended

  assign imm_i = {{20{inst[31]}}, inst[31:20]};
  assign imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  assign imm_b = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
  assign imm_j = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
  assign imm_u = {inst[31:12], 11'b0};

  // Immediate value selection
  // I/S/B/J/U is needed here

  always_comb begin
    if (i_type) begin
      imm = imm_i;
    end else if (s_type) begin
      imm = imm_s;
    end else if (b_type) begin
      imm = imm_b;
    end else if (j_type) begin
      imm = imm_j;
    end else if (u_type) begin
      imm = imm_u;
    end else begin  // r_type or other
      imm = 'x;
    end
  end


  // ALU
  //----

  always_comb begin
    if (is_load | is_branch | is_op_imm | is_auipc | is_store | is_jalr | is_jal) begin
      op2_sel = 1'b1;  // Imm
    end else begin
      op2_sel = 1'b0;  // rs2
    end
  end

  assign alu_op1 = op1_sel ? imm_u : rs1;
  assign alu_op2 = op2_sel ? imm : rs2;

  // ALU Op
  // funct7[5] marks the "alternative" version of ALU operation
  //
  // {funct7[5], func3}:
  // 4'b0_000: $signed(a) + signed(b), same as a + b
  // 4'b1_000: $signed(a) - signed(b), same as a - b
  // 4'bx_001: a << b[4:0]
  // 4'bx_010: ($signed(a) < $signed(b)) ? 32'h1 : 32'h0
  // 4'bx_011: (a < b) ? 32'h1 : 32'h0
  // 4'bx_100: a ^ b
  // 4'b0_101: a >> b[4:0]
  // 4'b1_101: $signed(a) >>> b[4:0]
  // 4'bx_110: a | b
  // 4'bx_111: a & b

  always_comb begin
    case (funct3)
      3'b000: begin  // ADD/SUB
        if (!funct7[5]) begin
          alu_res = $signed(alu_op1) + $signed(alu_op2);
        end else begin
          alu_res = $signed(alu_op1) - $signed(alu_op2);
        end
      end

      3'b001: begin  // SLL
        alu_res = alu_op1 << alu_op2[4:0];
      end

      3'b010: begin  // SLT
        alu_res = ($signed(alu_op1) < $signed(alu_op2)) ? 32'h1 : 32'h0;
      end

      3'b011: begin  // SLTU
        alu_res = (alu_op1 < alu_op2) ? 32'h1 : 32'h0;
      end

      3'b100: begin  // OR
        alu_res = alu_op1 ^ alu_op2;
      end

      3'b101: begin  // SRL/SRA
        if (!funct7[5]) begin
          alu_res = alu_op1 >> alu_op2[4:0];
        end else begin
          alu_res = $signed(alu_op1) >>> alu_op2[4:0];
        end
      end

      3'b110: begin  // OR
        alu_res = alu_op1 | alu_op2;
      end

      3'b111: begin  // AND
        alu_res = alu_op1 & alu_op2;
      end

      default: begin
        alu_res = $signed(alu_op1) + $signed(alu_op2);
      end
    endcase
  end


  // BRU
  //----

  // `bru_z` indicates whether the BRANCH condition is satisfied, only valid
  // if current instruction is BRANCH
  always_comb begin
    case (funct3)
      3'b000:  bru_z = (rs1 == rs2);  // BEQ
      3'b001:  bru_z = (rs1 != rs2);  // BNE
      3'b100:  bru_z = ($signed(rs1) < $signed(rs2));  // BLT
      3'b101:  bru_z = ($signed(rs1) >= $signed(rs2));  // BGE
      3'b110:  bru_z = (rs1 < rs2);  // BLTU
      3'b111:  bru_z = (rs1 >= rs2);  // BGEU
      default: bru_z = 1'b0;  // fault
    endcase
  end


  // DMEM
  //-----

  // Memory read/write address is always got from ALU
  assign dmem_addr = alu_res;
  assign dmem_din  = rs2;


  // Write back
  //----------

  always_comb begin
    case (result_sel)
      2'b00:   result = alu_res;
      2'b01:   result = dmem_dout;
      2'b10:   result = pc_target;
      2'b11:   result = pc_p4;
      default: result = 'x;
    endcase
  end

endmodule

`default_nettype wire
