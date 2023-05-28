`timescale 1 ns / 1 ps
//
`default_nettype none

module regfile (
    input var         clk,
    // rd
    input var  [ 4:0] a1,   // read
    input var  [ 4:0] a2,   // read
    output var [31:0] rd1,
    output var [31:0] rd2,
    // wr
    input var         we3,
    input var  [ 4:0] a3,   // write
    input var  [31:0] wd3
);

  (* ram_style="distributed" *)
  logic [31:0] regfile[32];

  initial begin
    regfile[0] = '0;  // x0 should be initialized since it will never be write
  end

  // Read ports

  always_comb begin
    rd1 = regfile[a1];
  end

  always_comb begin
    rd2 = regfile[a2];
  end

  // Write port

  always_ff @(posedge clk) begin
    // x0 should be zero and never be update
    if (we3 && a3 != '0) begin
      regfile[a3] <= wd3;
    end
  end

endmodule

`default_nettype wire
