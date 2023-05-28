`timescale 1 ns / 1 ps
//
`default_nettype none

module pcu #(
    parameter logic [31:0] INIT_ADDR = 32'h0000_0000
) (
    input var         clk,
    input var         rst,
    //
    input var         en,
    //
    input var         pc_sel,
    input var  [31:0] pc_target,
    output var [31:0] pc,
    output var [31:0] pc_p4,
    output var        pc_v
);

  // By default PC will move to +4 and fetch next instruction, unless current
  // instruction is Branch or Jump. Here list the Branch and Jump instructions:
  //
  // Unconditional Jumps:
  //   JAL: pc_next = pc + imm_j;
  //   JALR: pc_next = rs1 + imm_i;
  //
  // Conditional Branches:
  //   BEQ: if (rs1 == rs2) pc_next = pc + imm_b;
  //   BNE: if (rs1 != rs2) pc_next = pc + imm_b;
  //   BLT: if (rs1 < rs2) pc_next = pc + imm_b;
  //   BGE: if (rs1 >= rs2) pc_next = pc + imm_b;
  //   BLTU: if (rs1 < rs2) pc_next = pc + imm_b;
  //   BGEU: if (rs1 >= rs2) pc_next = pc + imm_b;

  logic        init;
  logic [31:0] pc_next;

  always_ff @(posedge clk) begin
    if (rst) begin
      init <= 1'b0;
    end else if (en) begin
      init <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pc <= INIT_ADDR;
    end else if (init && en) begin
      pc <= pc_next;
    end
  end

  always_comb begin
    pc_p4 = pc + 32'h4;
  end

  always_comb begin
    if (!pc_sel) begin
      pc_next = pc_p4;
    end else begin
      pc_next = pc_target;
    end
  end


  always_ff @(posedge clk) begin
    if (rst) begin
      pc_v <= 1'b0;
    end else begin
      pc_v <= en;
    end
  end

endmodule

`default_nettype wire
