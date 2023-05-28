`timescale 1 ns / 1 ps
//
`default_nettype none

module dff #(
    parameter int WIDTH = 8
) (
    input var              clk,
    input var              rst,
    input var              en,
    input var  [WIDTH-1:0] din,
    output var [WIDTH-1:0] dout
);

  always_ff @(posedge clk) begin
    if (rst) begin
      dout <= '0;
    end else if (en) begin
      dout <= din;
    end
  end

endmodule
