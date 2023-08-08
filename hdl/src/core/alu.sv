// File: alu.sv
// Brief: Arithmetic Logic Unit for RV32I. B* instructions are also done here.
`timescale 1 ns / 1 ps
//
`default_nettype none

module alu (
    input var  [ 3:0] op,
    input var  [31:0] a,
    input var  [31:0] b,
    output var [31:0] p,
    output var        z
);

  always_comb begin
    case (op[2:0])
      3'b000: begin  // ADD/SUB
        if (!op[3]) begin
          p = $signed(a) + $signed(b);
        end else begin
          p = $signed(a) - $signed(b);
        end
      end

      3'b001: begin  // SLL
        p = a << b[4:0];
      end

      3'b010: begin  // SLT
        p = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
      end

      3'b011: begin  // SLTU
        p = (a < b) ? 32'h1 : 32'h0;
      end

      3'b100: begin  // OR
        p = a ^ b;
      end

      3'b101: begin  // SRL/SRA
        if (!op[3]) begin
          p = a >> b[4:0];
        end else begin
          p = $signed(a) >>> b[4:0];
        end
      end

      3'b110: begin  // OR
        p = a | b;
      end

      3'b111: begin  // AND
        p = a & b;
      end

      default: begin
        p = $signed(a) + $signed(b);
      end
    endcase
    // For BRACH operation
    z = (p == 32'h0);
  end

endmodule

`default_nettype wire
