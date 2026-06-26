// kv32_amo_unit.sv — A extension AMO compute unit
// Combinational logic for all 9 AMO operations (read-modify-write).
// Takes old memory value and rs2 register value, outputs the computed result.

module kv32_amo_unit (
    input  logic [31:0] old_val,  // Value read from memory
    input  logic [31:0] rs2_val,  // Register rs2 value
    input  logic [ 4:0] funct5,   // AMO operation selector from instr[31:27]
    output logic [31:0] result    // Computed result (to be written back)
);

  // AMO funct5 encoding (from RISC-V A extension spec)
  localparam logic [4:0] AMOADD = 5'b00000;
  localparam logic [4:0] AMOSWAP = 5'b00001;
  localparam logic [4:0] AMOXOR = 5'b00100;
  localparam logic [4:0] AMOAND = 5'b01100;
  localparam logic [4:0] AMOOR = 5'b01000;
  localparam logic [4:0] AMOMIN = 5'b10000;
  localparam logic [4:0] AMOMAX = 5'b10100;
  localparam logic [4:0] AMOMINU = 5'b11000;
  localparam logic [4:0] AMOMAXU = 5'b11100;

  always_comb begin
    unique case (funct5)
      AMOADD:  result = old_val + rs2_val;
      AMOSWAP: result = rs2_val;
      AMOXOR:  result = old_val ^ rs2_val;
      AMOAND:  result = old_val & rs2_val;
      AMOOR:   result = old_val | rs2_val;
      AMOMIN:  result = ($signed(old_val) < $signed(rs2_val)) ? old_val : rs2_val;
      AMOMAX:  result = ($signed(old_val) > $signed(rs2_val)) ? old_val : rs2_val;
      AMOMINU: result = (old_val < rs2_val) ? old_val : rs2_val;
      AMOMAXU: result = (old_val > rs2_val) ? old_val : rs2_val;
      default: result = 32'h0;  // Undefined — should not occur (decoder marks illegal)
    endcase
  end

endmodule
