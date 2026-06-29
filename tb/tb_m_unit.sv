// tb_m_unit.sv — unit test for kv32_m_unit (M-extension multiply/divide)
// Converted from tb_m_unit.cpp. All test vectors transcribed verbatim.

module tb_m_unit;

  logic        clk;
  logic        rst_n;
  logic        valid;
  logic        is_mul;
  logic [ 2:0] funct3;
  logic [31:0] op_a;
  logic [31:0] op_b;
  logic [31:0] result;
  // verilator lint_off UNUSEDSIGNAL
  logic        busy;
  // verilator lint_on UNUSEDSIGNAL
  logic        done;

  kv32_m_unit u_dut (
      .clk   (clk),
      .rst_n (rst_n),
      .valid (valid),
      .is_mul(is_mul),
      .funct3(funct3),
      .op_a  (op_a),
      .op_b  (op_b),
      .result(result),
      .busy  (busy),
      .done  (done)
  );

  int tests = 0;
  int failures = 0;

  initial clk = 0;
  always #5 clk = ~clk;

  task automatic tick();
    @(posedge clk);
  endtask

  // run_op: pulse valid for one cycle with the given inputs,
  // wait for done. The result is available on the `result` signal afterward.
  // Returns 32'hDEAD_BEEF in `result` on timeout.
  task automatic run_op(
      input int         iis_mul,
      input logic [2:0] ifunct3,
      input logic [31:0] ia,
      input logic [31:0] ib
  );
    int timeout;
    // Drive inputs (blocking — task is called from initial block)
    valid  = 1;
    is_mul = iis_mul[0];
    funct3 = ifunct3;
    op_a   = ia;
    op_b   = ib;

    // Clock in the request
    tick();

    // Deassert valid for subsequent cycles
    valid = 0;

    // Wait for completion (timeout after 100 cycles)
    timeout = 100;
    while (!done && timeout > 0) begin
      tick();
      timeout--;
    end

    if (timeout == 0) begin
      $display("TIMEOUT: is_mul=%0d funct3=%0d a=0x%08h b=0x%08h",
               iis_mul, ifunct3, ia, ib);
    end

    // Wait one more cycle to return to IDLE
    tick();
  endtask

  task automatic expect_eq(string name, logic [31:0] got, logic [31:0] want);
    tests++;
    if (got !== want) begin
      $display("FAIL  %-35s got=0x%08h want=0x%08h", name, got, want);
      failures++;
    end else begin
      $display("PASS  %-35s = 0x%08h", name, got);
    end
  endtask

  initial begin
    // Reset
    rst_n  = 0;
    valid  = 0;
    is_mul = 0;
    funct3 = 0;
    op_a   = 0;
    op_b   = 0;
    tick();
    rst_n = 1;

    // ---------------------------------------------------------------
    $display("\n=== MUL tests ===");
    // ---------------------------------------------------------------

    // MUL (funct3=0): result = (a * b)[31:0]
    run_op(1, 3'd0, 32'd7, 32'd6);
    expect_eq("MUL 7*6", result, 32'd42);

    run_op(1, 3'd0, 32'h0001_0000, 32'h0001_0000);
    expect_eq("MUL 0x10000*0x10000 (lower 32)", result, 32'h0);

    // MULH (funct3=1): result = (signed(a) * signed(b))[63:32]
    run_op(1, 3'd1, 32'h7FFF_FFFF, 32'd2);
    expect_eq("MULH 0x7FFFFFFF*2 (upper 32)", result, 32'h0);

    run_op(1, 3'd1, 32'h8000_0000, 32'd2);
    expect_eq("MULH 0x80000000*2 (signed overflow)", result, 32'hFFFF_FFFF);

    // MULHSU (funct3=2): result = (signed(a) * unsigned(b))[63:32]
    run_op(1, 3'd2, 32'hFFFF_FFFF, 32'd2);
    expect_eq("MULHSU -1*2 (upper 32)", result, 32'hFFFF_FFFF);

    // MULHU (funct3=3): result = (unsigned(a) * unsigned(b))[63:32]
    run_op(1, 3'd3, 32'hFFFF_FFFF, 32'd2);
    expect_eq("MULHU 0xFFFFFFFF*2 (upper 32)", result, 32'h1);

    // ---------------------------------------------------------------
    $display("\n=== DIV tests ===");
    // ---------------------------------------------------------------

    // DIV (funct3=4): signed divide, quotient
    run_op(0, 3'd4, 32'd100, 32'd7);
    expect_eq("DIV 100/7", result, 32'd14);

    run_op(0, 3'd4, -32'd100, 32'd7);
    expect_eq("DIV -100/7", result, -32'd14);

    // DIV by zero: result = -1 (all 1s)
    run_op(0, 3'd4, 32'd42, 32'd0);
    expect_eq("DIV by zero", result, 32'hFFFF_FFFF);

    // DIV overflow: INT_MIN / -1 = INT_MIN
    run_op(0, 3'd4, 32'h8000_0000, 32'hFFFF_FFFF);
    expect_eq("DIV INT_MIN/-1 (overflow)", result, 32'h8000_0000);

    // DIVU (funct3=5): unsigned divide, quotient
    run_op(0, 3'd5, 32'd100, 32'd7);
    expect_eq("DIVU 100/7", result, 32'd14);

    run_op(0, 3'd5, 32'hFFFF_FFFF, 32'd2);
    expect_eq("DIVU 0xFFFFFFFF/2", result, 32'h7FFF_FFFF);

    // DIVU by zero: result = 0xFFFFFFFF
    run_op(0, 3'd5, 32'd42, 32'd0);
    expect_eq("DIVU by zero", result, 32'hFFFF_FFFF);

    // ---------------------------------------------------------------
    $display("\n=== REM tests ===");
    // ---------------------------------------------------------------

    // REM (funct3=6): signed divide, remainder
    run_op(0, 3'd6, 32'd100, 32'd7);
    expect_eq("REM 100%%7", result, 32'd2);

    run_op(0, 3'd6, -32'd100, 32'd7);
    expect_eq("REM -100%%7", result, -32'd2);

    // REM by zero: result = dividend
    run_op(0, 3'd6, 32'd42, 32'd0);
    expect_eq("REM by zero (dividend)", result, 32'd42);

    // REM overflow: INT_MIN % -1 = 0
    run_op(0, 3'd6, 32'h8000_0000, 32'hFFFF_FFFF);
    expect_eq("REM INT_MIN%%-1 (overflow)", result, 32'h0);

    // REMU (funct3=7): unsigned divide, remainder
    run_op(0, 3'd7, 32'd100, 32'd7);
    expect_eq("REMU 100%%7", result, 32'd2);

    run_op(0, 3'd7, 32'hFFFF_FFFF, 32'd2);
    expect_eq("REMU 0xFFFFFFFF%%2", result, 32'd1);

    // REMU by zero: result = dividend
    run_op(0, 3'd7, 32'd42, 32'd0);
    expect_eq("REMU by zero (dividend)", result, 32'd42);

    // ---------------------------------------------------------------
    $display("\n=== tb_m_unit: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
