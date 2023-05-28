`timescale 1 ns / 1 ps
//
`default_nettype none

module kv32 (
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

  // Program counter

  logic        pc_en;

  logic [31:0] pc;
  logic [31:0] pc_d;
  logic [31:0] pc_e;

  logic [31:0] pc_p4;
  logic [31:0] pc_p4_d;
  logic [31:0] pc_p4_e;
  logic [31:0] pc_p4_m;
  logic [31:0] pc_p4_w;

  // Decoder

  logic [31:0] instr_d;

  logic [ 6:0] opcode_d;
  logic [ 2:0] funct3_d;
  logic [ 6:0] funct7_d;

  // Register File

  logic [ 4:0] rs1_d;
  logic [ 4:0] rs2_d;

  logic [31:0] rd1_d;
  logic [31:0] rd1_e;

  logic [31:0] rd2_d;
  logic [31:0] rd2_e;
  logic [31:0] rd2_m;

  logic        we3_d;
  logic        we3_e;
  logic        we3_w;
  logic        we3_m;

  logic [ 4:0] rd_d;
  logic [ 4:0] rd_e;
  logic [ 4:0] rd_w;
  logic [ 4:0] rd_m;

  // Imm Extend

  logic [ 2:0] imm_sel_d;

  logic [31:0] imm_d;
  logic [31:0] imm_e;

  // ALU

  logic [ 3:0] alu_op_d;
  logic [ 3:0] alu_op_e;

  logic        alu_b_sel_d;
  logic        alu_b_sel_e;

  logic [31:0] alu_b_e;

  logic [31:0] alu_p_e;
  logic [31:0] alu_p_m;
  logic [31:0] alu_p_w;

  logic        alu_z_d;
  logic        alu_z_e;

  // BRU

  logic        jump_d;
  logic        jump_e;

  logic [ 1:0] branch_d;
  logic [ 1:0] branch_e;

  logic        pc_sel_e;

  logic [31:0] pc_target_e;
  logic [31:0] pc_target_m;
  logic [31:0] pc_target_w;

  // DMEM

  logic        dmem_en_d;
  logic        dmem_en_e;
  logic        dmem_en_m;

  logic [ 3:0] dmem_we_d;
  logic [ 3:0] dmem_we_e;
  logic [ 3:0] dmem_we_m;

  // write back

  logic [ 1:0] result_sel_d;
  logic [ 1:0] result_sel_e;
  logic [ 1:0] result_sel_m;
  logic [ 1:0] result_sel_w;

  logic [31:0] result_w;


  // Control Unit
  //-------------

  control i_control (
      .clk  (clk),
      .rst  (rst),
      //
      .pc   (pc),
      .pc_en(pc_en),
      //
      .halt (halt)
  );


  // PC Unit
  //--------

  pcu i_pcu (
      .clk      (clk),
      .rst      (rst),
      //
      .en       (pc_en),
      //
      .pc_sel   (pc_sel_e),
      .pc_target(pc_target_e),
      .pc       (pc),
      .pc_p4    (pc_p4)
  );

  always_ff @(posedge clk) begin
    pc_d <= pc;
    pc_e <= pc_d;
  end

  always_ff @(posedge clk) begin
    pc_p4_d <= pc_p4;
    pc_p4_e <= pc_p4_d;
    pc_p4_m <= pc_p4_e;
    pc_p4_w <= pc_p4_m;
  end


  // IMEM interface
  //---------

  always_ff @(posedge clk) begin
    imem_en <= pc_en;
  end

  assign imem_addr = pc;

  // pipelined in IMEM
  assign instr_d = imem_dout;


  // Instruction decode
  //-------------------

  assign opcode_d = instr_d[6:0];
  assign funct3_d = instr_d[14:12];
  assign funct7_d = instr_d[31:25];

  assign rd_d = instr_d[11:7];
  assign rs1_d = instr_d[19:15];
  assign rs2_d = instr_d[24:20];

  decode i_decode (
      .opcode    (opcode_d),
      .funct3    (funct3_d),
      .funct7    (funct7_d),
      //
      .imm_sel   (imm_sel_d),
      //
      .alu_b_sel (alu_b_sel_d),
      .alu_op    (alu_op_d),
      //
      .jump      (jump_d),
      .branch    (branch_d),
      //
      .dmem_en   (dmem_en_d),
      .dmem_we   (dmem_we_d),
      //
      .result_sel(result_sel_d),
      .we3       (we3_d)
  );

  always_ff @(posedge clk) begin
    alu_op_e <= alu_op_d;
  end

  always_ff @(posedge clk) begin
    alu_b_sel_e <= alu_b_sel_d;
  end

  always_ff @(posedge clk) begin
    jump_e <= jump_d;
  end

  always_ff @(posedge clk) begin
    branch_e <= branch_d;
  end

  always_ff @(posedge clk) begin
    dmem_en_e <= dmem_en_d;
    dmem_en_m <= dmem_en_e;
  end

  always_ff @(posedge clk) begin
    dmem_we_e <= dmem_we_d;
    dmem_we_m <= dmem_we_e;
  end

  always_ff @(posedge clk) begin
    result_sel_e <= result_sel_d;
    result_sel_m <= result_sel_e;
    result_sel_w <= result_sel_m;
  end

  // Register File
  //--------------

  regfile i_regfile (
      .clk(clk),
      // rd
      .a1 (rs1_d),
      .a2 (rs2_d),
      .rd1(rd1_d),
      .rd2(rd2_d),
      // wr
      .we3(we3_w),
      .a3 (rd_w),
      .wd3(result_w)
  );

  always_ff @(posedge clk) begin
    rd1_e <= rd1_d;
  end

  always_ff @(posedge clk) begin
    rd2_e <= rd2_d;
    rd2_m <= rd2_e;
  end

  always_ff @(posedge clk) begin
    we3_e <= we3_d;
    we3_m <= we3_e;
    we3_w <= we3_m;
  end

  always_ff @(posedge clk) begin
    rd_e <= rd_d;
    rd_m <= rd_e;
    rd_w <= rd_m;
  end

  // Imm Extend
  //-----------

  extend i_extend (
      .instr  (instr_d[31:7]),
      .imm_sel(imm_sel_d),
      .imm_ext(imm_d)
  );

  always_ff @(posedge clk) begin
    imm_e <= imm_d;
  end


  // ALU
  //----

  always_comb begin
    if (alu_b_sel_e == 1'b0) begin
      alu_b_e = rd2_e;
    end else begin
      alu_b_e = imm_e;
    end
  end

  alu i_alu (
      .op   (alu_op_e),
      .a    (rd1_e),
      .b    (alu_b_e),
      .p    (alu_p_e),
      .z    (alu_z_e)
  );

  always_ff @(posedge clk) begin
    alu_p_m <= alu_p_e;
    alu_p_w <= alu_p_m;
  end


  // Branch Unit
  //------------

  bru i_bru (
      .a(pc_e),
      .b(imm_e),
      .p(pc_target_e)
  );

  always_ff @(posedge clk) begin
    pc_target_m <= pc_target_e;
    pc_target_w <= pc_target_m;
  end

  // PC next value selection

  always_comb begin
    if (jump_e) begin  // unconditional jumps
      pc_sel_e = 1'b1;
    end else if (branch_e[0] && (alu_z_e ^ branch_e[1])) begin  // conditional branches
      pc_sel_e = 1'b1;
    end else begin
      pc_sel_e = 1'b0;
    end
  end


  // DMEM
  //-----

  assign dmem_en   = dmem_en_m;
  assign dmem_we   = dmem_we_m;
  assign dmem_addr = alu_p_m;
  assign dmem_din  = rd2_m;


  // WRITEBACK
  //----------

  always_comb begin
    case (result_sel_w)
      2'b00:   result_w = alu_p_w;
      2'b01:   result_w = dmem_dout;
      2'b10:   result_w = pc_target_w;
      2'b11:   result_w = pc_p4_w;
      default: result_w = alu_p_w;
    endcase
  end

endmodule

`default_nettype wire
