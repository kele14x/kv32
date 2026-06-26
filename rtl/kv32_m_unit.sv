// kv32_m_unit.sv — M extension unit (multiply/divide)
// Implements RV32M: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
// Multi-cycle operation with stall-based pipeline integration

module kv32_m_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid,   // Start computation
    input  logic        is_mul,  // 1=multiply, 0=divide
    input  logic [ 2:0] funct3,  // Selects operation variant
    input  logic [31:0] op_a,    // rs1 value
    input  logic [31:0] op_b,    // rs2 value
    output logic [31:0] result,  // Computed result
    output logic        busy,    // Computation in progress (stall pipeline)
    output logic        done     // Result valid this cycle
);

  // State machine
  typedef enum logic [2:0] {
    IDLE,
    MUL_1,
    MUL_2,
    DIV_INIT,
    DIV_ITER,
    DIV_SIGN,
    DONE
  } state_t;

  state_t state, next_state;

  // Registered inputs (captured on valid)
  logic [2:0] funct3_reg;
  logic is_mul_reg;
  logic [31:0] a_reg, b_reg;

  // Multiplier signals
  logic [32:0] mul_a_ext, mul_b_ext;
  logic [63:0] mul_product;
  logic [31:0] mul_result;

  // Divider signals
  logic is_signed;
  logic a_sign, b_sign;
  logic [31:0] a_mag, b_mag;
  logic [31:0] div_remainder, div_quotient;
  logic [5:0] div_count;
  logic [31:0] next_remainder, next_quotient;
  logic quotient_sign, remainder_sign;
  logic [31:0] quotient_signed, remainder_signed;

  // Special case detection and latched result
  logic div_by_zero, signed_overflow;
  logic [31:0] special_result;
  logic special_case;
  logic [31:0] special_result_reg;
  logic special_case_reg;

  // State register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else state <= next_state;
  end

  // Input registers (capture on valid)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      funct3_reg <= 3'b0;
      is_mul_reg <= 1'b0;
      a_reg <= 32'h0;
      b_reg <= 32'h0;
    end else if (valid) begin
      funct3_reg <= funct3;
      is_mul_reg <= is_mul;
      a_reg <= op_a;
      b_reg <= op_b;
    end
  end

  // Multiplier: sign-extend operands based on funct3
  // MUL (000): unsigned x unsigned, lower 32 bits
  // MULH (001): signed x signed, upper 32 bits
  // MULHSU (010): signed x unsigned, upper 32 bits
  // MULHU (011): unsigned x unsigned, upper 32 bits
  always_comb begin
    mul_a_ext =
        (funct3_reg == 3'b001 || funct3_reg == 3'b010) ? {{1{a_reg[31]}}, a_reg} : {1'b0, a_reg};
    mul_b_ext = (funct3_reg == 3'b001) ? {{1{b_reg[31]}}, b_reg} : {1'b0, b_reg};
  end

  // Registered multiply (synthesis infers FPGA DSP blocks)
  always_ff @(posedge clk) begin
    if (state == MUL_1) mul_product <= $signed(mul_a_ext) * $signed(mul_b_ext);
  end

  // Multiplier result selection
  assign mul_result = (funct3_reg == 3'b000) ? mul_product[31:0] : mul_product[63:32];

  // Divider: signed/unsigned detection and magnitude conversion
  assign is_signed = (funct3_reg == 3'b100 || funct3_reg == 3'b110);
  assign a_sign = is_signed && a_reg[31];
  assign b_sign = is_signed && b_reg[31];
  assign a_mag = a_sign ? (~a_reg + 1'b1) : a_reg;
  assign b_mag = b_sign ? (~b_reg + 1'b1) : b_reg;

  // Iterative division: next-state logic
  always_comb begin
    next_remainder = {div_remainder[30:0], div_quotient[31]};
    next_quotient  = {div_quotient[30:0], 1'b0};

    if (next_remainder >= b_mag) begin
      next_remainder   = next_remainder - b_mag;
      next_quotient[0] = 1'b1;
    end
  end

  // Division registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_remainder <= 32'h0;
      div_quotient <= 32'h0;
      div_count <= 6'd0;
    end else if (state == DIV_INIT) begin
      div_remainder <= 32'h0;
      div_quotient <= a_mag;
      div_count <= 6'd32;
    end else if (state == DIV_ITER) begin
      div_remainder <= next_remainder;
      div_quotient <= next_quotient;
      div_count <= div_count - 1'd1;
    end
  end

  // Sign correction for signed division
  assign quotient_sign = a_sign ^ b_sign;
  assign remainder_sign = a_sign;
  assign quotient_signed = quotient_sign ? (~div_quotient + 1'b1) : div_quotient;
  assign remainder_signed = remainder_sign ? (~div_remainder + 1'b1) : div_remainder;

  // Special cases (RISC-V spec: no trap)
  assign div_by_zero = (op_b == 32'h0);
  assign signed_overflow =
      (funct3 == 3'b100 || funct3 == 3'b110) && (op_a == 32'h8000_0000) && (op_b == 32'hFFFF_FFFF);

  assign special_case = div_by_zero || signed_overflow;

  always_comb begin
    if (div_by_zero) begin
      // DIV/DIVU (funct3[1]=0): return -1; REM/REMU (funct3[1]=1): return dividend
      special_result = (funct3[1] == 1'b0) ? 32'hFFFF_FFFF : op_a;
    end else if (signed_overflow) begin
      // DIV: return INT_MIN; REM: return 0
      special_result = (funct3 == 3'b100) ? 32'h8000_0000 : 32'h0;
    end else begin
      special_result = 32'h0;
    end
  end

  // Latch special case result when detected
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      special_result_reg <= 32'h0;
      special_case_reg   <= 1'b0;
    end else if (valid && special_case) begin
      // Latch the special case result
      special_result_reg <= special_result;
      special_case_reg   <= 1'b1;
    end else if (state == IDLE) begin
      // Clear when returning to IDLE
      special_case_reg <= 1'b0;
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;

    case (state)
      IDLE: begin
        if (valid && is_mul) begin
          next_state = MUL_1;
        end else if (valid && !is_mul) begin
          if (div_by_zero || signed_overflow) begin
            next_state = DONE;
          end else begin
            next_state = DIV_INIT;
          end
        end
      end

      MUL_1: next_state = MUL_2;
      MUL_2: next_state = DONE;

      DIV_INIT: next_state = DIV_ITER;
      DIV_ITER: begin
        if (div_count == 1) next_state = is_signed ? DIV_SIGN : DONE;
      end
      DIV_SIGN: next_state = DONE;
      DONE: next_state = IDLE;

      default: next_state = IDLE;
    endcase
  end

  // Output logic
  // busy is purely state-based (no combinational dependency on valid)
  assign busy = (state != IDLE);
  assign done = (state == DONE);

  // Result selection
  always_comb begin
    if (special_case_reg) begin
      result = special_result_reg;
    end else if (is_mul_reg) begin
      result = mul_result;
    end else if (funct3_reg == 3'b100 || funct3_reg == 3'b101) begin
      // DIV or DIVU: quotient
      result = is_signed ? quotient_signed : div_quotient;
    end else begin
      // REM or REMU: remainder
      result = is_signed ? remainder_signed : div_remainder;
    end
  end

endmodule
