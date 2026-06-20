module kv32_alu
  import kv32_pkg::*;
(
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [ 3:0] op,
    output logic [31:0] result
);

  always_comb begin
    unique case (op)
      AluAdd:  result = a + b;
      AluSub:  result = a - b;
      AluSll:  result = a << b[4:0];
      AluSlt:  result = {31'h0, $signed(a) < $signed(b)};
      AluSltu: result = {31'h0, a < b};
      AluXor:  result = a ^ b;
      AluSrl:  result = a >> b[4:0];
      AluSra:  result = $signed(a) >>> b[4:0];
      AluOr:   result = a | b;
      AluAnd:  result = a & b;
      default: result = 32'h0;
    endcase
  end

endmodule
