// tb_alu.sv — unit test for kv32_alu
// Verifies all 10 ALU operations with edge cases.
// Combinational DUT: set inputs, eval, check output.

module tb_alu;

  logic [31:0] a;
  logic [31:0] b;
  logic [ 3:0] op;
  logic [31:0] result;

  kv32_alu u_dut (
      .a     (a),
      .b     (b),
      .op    (op),
      .result(result)
  );

  int tests = 0;
  int failures = 0;

  task automatic check(
      string name,
      input logic [31:0] ia,
      input logic [31:0] ib,
      input logic [ 3:0] iop,
      input logic [31:0] expected
  );
    a  = ia;
    b  = ib;
    op = iop;
    #1;
    tests++;
    if (result !== expected) begin
      $display("FAIL  %-7s a=0x%08h b=0x%08h op=%0d  got=0x%08h want=0x%08h",
               name, ia, ib, iop, result, expected);
      failures++;
    end
  endtask

  initial begin
    // ADD
    check("ADD", 32'h0000_0005, 32'h0000_0003, 4'd0, 32'h0000_0008);
    check("ADD", 32'h0000_0000, 32'h0000_0000, 4'd0, 32'h0000_0000);
    check("ADD", 32'hFFFF_FFFF, 32'h0000_0001, 4'd0, 32'h0000_0000);  // wrap
    check("ADD", 32'h7FFF_FFFF, 32'h0000_0001, 4'd0, 32'h8000_0000);

    // SUB
    check("SUB", 32'h0000_000A, 32'h0000_0003, 4'd1, 32'h0000_0007);
    check("SUB", 32'h0000_0000, 32'h0000_0001, 4'd1, 32'hFFFF_FFFF);  // underflow
    check("SUB", 32'h0000_0005, 32'h0000_0005, 4'd1, 32'h0000_0000);

    // SLL (shift amount is b[4:0])
    check("SLL", 32'h0000_0001, 32'h0000_0004, 4'd2, 32'h0000_0010);
    check("SLL", 32'h0000_00FF, 32'h0000_0008, 4'd2, 32'h0000_FF00);
    check("SLL", 32'h0000_0001, 32'h0000_001F, 4'd2, 32'h8000_0000);
    check("SLL", 32'h0000_0001, 32'h0000_0000, 4'd2, 32'h0000_0001);
    check("SLL", 32'h1234_5678, 32'h0000_0004, 4'd2, 32'h2345_6780);  // shift masked to 5 bits

    // SLT (signed)
    check("SLT", 32'h0000_0005, 32'h0000_000A, 4'd3, 32'h0000_0001);
    check("SLT", 32'hFFFF_FFFF, 32'h0000_0000, 4'd3, 32'h0000_0001);  // -1 < 0
    check("SLT", 32'h0000_0000, 32'hFFFF_FFFF, 4'd3, 32'h0000_0000);  // 0 < -1 is false
    check("SLT", 32'h0000_000A, 32'h0000_0005, 4'd3, 32'h0000_0000);
    check("SLT", 32'hFFFF_FFFB, 32'hFFFF_FFFD, 4'd3, 32'h0000_0001);  // -5 < -3

    // SLTU (unsigned)
    check("SLTU", 32'h0000_0005, 32'h0000_000A, 4'd4, 32'h0000_0001);
    check("SLTU", 32'hFFFF_FFFF, 32'h0000_0001, 4'd4, 32'h0000_0000);
    check("SLTU", 32'h0000_0000, 32'h0000_0001, 4'd4, 32'h0000_0001);
    check("SLTU", 32'h0000_000A, 32'h0000_0005, 4'd4, 32'h0000_0000);

    // XOR
    check("XOR", 32'h0000_00FF, 32'h0000_000F, 4'd5, 32'h0000_00F0);
    check("XOR", 32'h0000_0000, 32'h0000_0000, 4'd5, 32'h0000_0000);
    check("XOR", 32'hFFFF_FFFF, 32'hFFFF_FFFF, 4'd5, 32'h0000_0000);

    // SRL (logical right shift)
    check("SRL", 32'h8000_0000, 32'h0000_0004, 4'd6, 32'h0800_0000);
    check("SRL", 32'h0000_00FF, 32'h0000_0000, 4'd6, 32'h0000_00FF);
    check("SRL", 32'h8000_0000, 32'h0000_001F, 4'd6, 32'h0000_0001);

    // SRA (arithmetic right shift)
    check("SRA", 32'h8000_0000, 32'h0000_0004, 4'd7, 32'hF800_0000);  // sign-extends
    check("SRA", 32'h4000_0000, 32'h0000_0004, 4'd7, 32'h0400_0000);  // no sign bit
    check("SRA", 32'h8000_0000, 32'h0000_001F, 4'd7, 32'hFFFF_FFFF);

    // OR
    check("OR", 32'h0000_00F0, 32'h0000_000F, 4'd8, 32'h0000_00FF);
    check("OR", 32'h0000_0000, 32'h0000_0000, 4'd8, 32'h0000_0000);
    check("OR", 32'h0000_00FF, 32'h0000_00FF, 4'd8, 32'h0000_00FF);

    // AND
    check("AND", 32'h0000_00FF, 32'h0000_000F, 4'd9, 32'h0000_000F);
    check("AND", 32'h0000_0000, 32'h0000_0000, 4'd9, 32'h0000_0000);
    check("AND", 32'h0000_00FF, 32'h0000_00FF, 4'd9, 32'h0000_00FF);

    $display("\n=== tb_alu: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
