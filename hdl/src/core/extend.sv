`timescale 1 ns / 1 ps
//
`default_nettype wire

module extend (
    input var  [31:7] instr,
    input var  [ 2:0] imm_sel,
    output var [31:0] imm_ext
);


  logic [31:0] imm_i;  // I-type
  logic [31:0] imm_s;  // S-type
  logic [31:0] imm_b;  // B-type, variants of S-type
  logic [31:0] imm_j;  // J-type, variants of U-type
  logic [31:0] imm_u;  // U-type

  // Immediate decoding
  // All immediate values are signed extended

  assign imm_i = {{20{instr[31]}}, instr[31:20]};
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
  assign imm_u = {instr[31:12], 11'b0};

  always_comb begin
    if (imm_sel[2]) begin // 3'b1xx
      imm_ext = imm_u;
    end else if (imm_sel[1:0] == 2'b00) begin
      imm_ext = imm_i;
    end else if (imm_sel[1:0] == 2'b01) begin
      imm_ext = imm_s;
    end else if (imm_sel[1:0] == 2'b10) begin
      imm_ext = imm_b;
    end else begin // 2'b11
      imm_ext = imm_j;
    end
  end

endmodule

`default_nettype wire
