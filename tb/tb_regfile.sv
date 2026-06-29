// tb_regfile.sv — unit test for kv32_regfile
// Verifies: x0 hardwire, write/read, write-during-read (old value),
//           write enable gating, dual-port reads.

module tb_regfile;

  logic        clk;
  logic        we;
  logic [ 4:0] rd_addr;
  logic [31:0] rd_data;
  logic [ 4:0] rs1_addr;
  logic [ 4:0] rs2_addr;
  logic [31:0] rs1_data;
  logic [31:0] rs2_data;

  kv32_regfile u_dut (
      .clk     (clk),
      .we      (we),
      .rd_addr (rd_addr),
      .rd_data (rd_data),
      .rs1_addr(rs1_addr),
      .rs2_addr(rs2_addr),
      .rs1_data(rs1_data),
      .rs2_data(rs2_data)
  );

  int tests = 0;
  int failures = 0;

  initial clk = 0;

  task automatic tick();
    #5 clk = 1;
    #5 clk = 0;
  endtask

  task automatic expect_eq(string name, logic [31:0] got, logic [31:0] want);
    tests++;
    if (got !== want) begin
      $display("FAIL  %-25s got=0x%08h want=0x%08h", name, got, want);
      failures++;
    end
  endtask

  initial begin
    // Initialize
    we       = 0;
    rd_addr  = 0;
    rd_data  = 0;
    rs1_addr = 0;
    rs2_addr = 0;
    tick();

    // x0 always reads as 0, even after attempted write
    we = 1; rd_addr = 0; rd_data = 32'hDEAD_BEEF;
    tick();
    we = 0;
    rs1_addr = 0; rs2_addr = 0; #1;
    expect_eq("x0 after write (rs1)", rs1_data, 32'h0);
    expect_eq("x0 after write (rs2)", rs2_data, 32'h0);

    // Write x1, read back
    we = 1; rd_addr = 1; rd_data = 32'h1234_5678;
    tick();
    we = 0;
    rs1_addr = 1; #1;
    expect_eq("write x1, read rs1", rs1_data, 32'h1234_5678);

    // Write x5, read on rs2
    we = 1; rd_addr = 5; rd_data = 32'hAABB_CCDD;
    tick();
    we = 0;
    rs2_addr = 5; #1;
    expect_eq("write x5, read rs2", rs2_data, 32'hAABB_CCDD);

    // Dual-port read of two different registers
    rs1_addr = 1; rs2_addr = 5; #1;
    expect_eq("dual-port rs1=x1", rs1_data, 32'h1234_5678);
    expect_eq("dual-port rs2=x5", rs2_data, 32'hAABB_CCDD);

    // Write-during-read: writing x10 while reading x10 same cycle
    // should return the OLD value (write happens on clock edge)
    we = 1; rd_addr = 10; rd_data = 32'hCAFE_BABE;
    rs1_addr = 10; #1;
    expect_eq("write-during-read (old val)", rs1_data, 32'h0);
    tick();  // write commits
    we = 0;
    rs1_addr = 10; #1;
    expect_eq("write-during-read (new val)", rs1_data, 32'hCAFE_BABE);

    // we=0 must not write
    we = 0; rd_addr = 10; rd_data = 32'h1111_1111;
    tick();
    rs1_addr = 10; #1;
    expect_eq("we=0 no write", rs1_data, 32'hCAFE_BABE);

    // Write all 31 registers, read back a few
    for (int i = 1; i <= 31; i++) begin
      we = 1; rd_addr = i[4:0]; rd_data = i * 32'h10 + i;
      tick();
    end
    we = 0;
    rs1_addr = 1;  #1; expect_eq("scan x1",  rs1_data, 32'h0000_0011);
    rs1_addr = 15; #1; expect_eq("scan x15", rs1_data, 32'h0000_00FF);
    rs1_addr = 31; #1; expect_eq("scan x31", rs1_data, 32'h0000_020F);

    $display("\n=== tb_regfile: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule
