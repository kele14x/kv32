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
            ALU_ADD:  result = a + b;
            ALU_SUB:  result = a - b;
            ALU_SLL:  result = a << b[4:0];
            ALU_SLT:  result = {31'h0, $signed(a) < $signed(b)};
            ALU_SLTU: result = {31'h0, a < b};
            ALU_XOR:  result = a ^ b;
            ALU_SRL:  result = a >> b[4:0];
            ALU_SRA:  result = $signed(a) >>> b[4:0];
            ALU_OR:   result = a | b;
            ALU_AND:  result = a & b;
            default:  result = 32'h0;
        endcase
    end

endmodule
