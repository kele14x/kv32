module kv32_alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [ 3:0] op,
    output logic [31:0] result
);

    // ALU operation encoding
    localparam logic [3:0] ALU_ADD  = 4'h0,
                           ALU_SUB  = 4'h1,
                           ALU_SLL  = 4'h2,
                           ALU_SLT  = 4'h3,
                           ALU_SLTU = 4'h4,
                           ALU_XOR  = 4'h5,
                           ALU_SRL  = 4'h6,
                           ALU_SRA  = 4'h7,
                           ALU_OR   = 4'h8,
                           ALU_AND  = 4'h9;

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
