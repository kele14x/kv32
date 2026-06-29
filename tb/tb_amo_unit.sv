// tb_amo_unit.sv — unit test for kv32_amo_unit
// Verifies all 9 AMO operations with various operand combinations.

module tb_amo_unit;

  logic [31:0] old_val;
  logic [31:0] rs2_val;
  logic [ 4:0] funct5;
  logic [31:0] result;

  kv32_amo_unit u_dut (
      .old_val(old_val),
      .rs2_val(rs2_val),
      .funct5 (funct5),
      .result (result)
  );

  int tests = 0;
  int failures = 0;

  task automatic test_amo(
      input logic [31:0] iold,
      input logic [31:0] irs2,
      input logic [ 4:0] ifunct5,
      input logic [31:0] expected,
      input string name
  );
    old_val = iold;
    rs2_val = irs2;
    funct5  = ifunct5;
    #1;
    tests++;
    if (result !== expected) begin
      $display("FAIL  %-40s got=0x%08h want=0x%08h", name, result, expected);
      failures++;
    end
  endtask

  // AMO funct5 encoding
  localparam logic [4:0] AMOADD  = 5'b00000;
  localparam logic [4:0] AMOSWAP = 5'b00001;
  localparam logic [4:0] AMOXOR  = 5'b00100;
  localparam logic [4:0] AMOAND  = 5'b01100;
  localparam logic [4:0] AMOOR   = 5'b01000;
  localparam logic [4:0] AMOMIN  = 5'b10000;
  localparam logic [4:0] AMOMAX  = 5'b10100;
  localparam logic [4:0] AMOMINU = 5'b11000;
  localparam logic [4:0] AMOMAXU = 5'b11100;

  initial begin
    // ---- AMOSWAP: result = rs2 ----
    test_amo(32'h1234_5678, 32'hDEAD_BEEF, AMOSWAP, 32'hDEAD_BEEF, "amoswap basic");
    test_amo(32'hFFFF_FFFF, 32'h0000_0000, AMOSWAP, 32'h0000_0000, "amoswap to zero");
    test_amo(32'h0000_0000, 32'hFFFF_FFFF, AMOSWAP, 32'hFFFF_FFFF, "amoswap to max");

    // ---- AMOADD: result = old + rs2 ----
    test_amo(32'h1234_5678, 32'h0000_0001, AMOADD, 32'h1234_5679, "amoadd basic");
    test_amo(32'hFFFF_FFFF, 32'h0000_0001, AMOADD, 32'h0000_0000, "amoadd overflow");
    test_amo(32'h8000_0000, 32'h8000_0000, AMOADD, 32'h0000_0000, "amoadd neg+neg");
    test_amo(32'h0000_0000, 32'h0000_0000, AMOADD, 32'h0000_0000, "amoadd zeros");

    // ---- AMOAND: result = old & rs2 ----
    test_amo(32'hFF00_FF00, 32'h0F0F_0F0F, AMOAND, 32'h0F00_0F00, "amoand basic");
    test_amo(32'hFFFF_FFFF, 32'h1234_5678, AMOAND, 32'h1234_5678, "amoand mask all");
    test_amo(32'h1234_5678, 32'h0000_0000, AMOAND, 32'h0000_0000, "amoand mask zero");

    // ---- AMOOR: result = old | rs2 ----
    test_amo(32'hFF00_FF00, 32'h0F0F_0F0F, AMOOR, 32'hFF0F_FF0F, "amoor basic");
    test_amo(32'h0000_0000, 32'h1234_5678, AMOOR, 32'h1234_5678, "amoor with zero");
    test_amo(32'hFFFF_FFFF, 32'h0000_0000, AMOOR, 32'hFFFF_FFFF, "amoor with max");

    // ---- AMOXOR: result = old ^ rs2 ----
    test_amo(32'hFF00_FF00, 32'h0F0F_0F0F, AMOXOR, 32'hF00F_F00F, "amoxor basic");
    test_amo(32'h1234_5678, 32'h1234_5678, AMOXOR, 32'h0000_0000, "amoxor same val");
    test_amo(32'h0000_0000, 32'hFFFF_FFFF, AMOXOR, 32'hFFFF_FFFF, "amoxor invert");

    // ---- AMOMIN (signed): result = smin(old, rs2) ----
    test_amo(32'h0000_0005, 32'h0000_0003, AMOMIN, 32'h0000_0003, "amomin pos/pos");
    test_amo(32'h0000_0003, 32'h0000_0005, AMOMIN, 32'h0000_0003, "amomin pos/pos swap");
    test_amo(32'h8000_0000, 32'h7FFF_FFFF, AMOMIN, 32'h8000_0000, "amomin neg/pos");
    test_amo(32'h7FFF_FFFF, 32'h8000_0000, AMOMIN, 32'h8000_0000, "amomin pos/neg");
    test_amo(32'hFFFF_FFFE, 32'hFFFF_FFFF, AMOMIN, 32'hFFFF_FFFE, "amomin neg/neg");
    test_amo(32'hFFFF_FFFF, 32'hFFFF_FFFE, AMOMIN, 32'hFFFF_FFFE, "amomin neg/neg swap");

    // ---- AMOMAX (signed): result = smax(old, rs2) ----
    test_amo(32'h0000_0005, 32'h0000_0003, AMOMAX, 32'h0000_0005, "amomax pos/pos");
    test_amo(32'h0000_0003, 32'h0000_0005, AMOMAX, 32'h0000_0005, "amomax pos/pos swap");
    test_amo(32'h8000_0000, 32'h7FFF_FFFF, AMOMAX, 32'h7FFF_FFFF, "amomax neg/pos");
    test_amo(32'h7FFF_FFFF, 32'h8000_0000, AMOMAX, 32'h7FFF_FFFF, "amomax pos/neg");
    test_amo(32'hFFFF_FFFE, 32'hFFFF_FFFF, AMOMAX, 32'hFFFF_FFFF, "amomax neg/neg");
    test_amo(32'hFFFF_FFFF, 32'hFFFF_FFFE, AMOMAX, 32'hFFFF_FFFF, "amomax neg/neg swap");

    // ---- AMOMINU (unsigned): result = umin(old, rs2) ----
    test_amo(32'h0000_0005, 32'h0000_0003, AMOMINU, 32'h0000_0003, "amominu small/large");
    test_amo(32'h0000_0003, 32'h0000_0005, AMOMINU, 32'h0000_0003, "amominu large/small");
    test_amo(32'h8000_0000, 32'h7FFF_FFFF, AMOMINU, 32'h7FFF_FFFF, "amominu high bit");
    test_amo(32'hFFFF_FFFF, 32'h0000_0000, AMOMINU, 32'h0000_0000, "amominu max/zero");

    // ---- AMOMAXU (unsigned): result = umax(old, rs2) ----
    test_amo(32'h0000_0005, 32'h0000_0003, AMOMAXU, 32'h0000_0005, "amomaxu small/large");
    test_amo(32'h0000_0003, 32'h0000_0005, AMOMAXU, 32'h0000_0005, "amomaxu large/small");
    test_amo(32'h8000_0000, 32'h7FFF_FFFF, AMOMAXU, 32'h8000_0000, "amomaxu high bit");
    test_amo(32'hFFFF_FFFF, 32'h0000_0000, AMOMAXU, 32'hFFFF_FFFF, "amomaxu max/zero");

    $display("\n=== tb_amo_unit: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
