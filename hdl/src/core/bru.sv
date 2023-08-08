// File: bru.sv
// Brief: Branch target unit, calculates the brach target address for BRACH
//        instruction. Also AUIPC (rd = ) is done here.
`timescale 1 ns / 1 ps
//
`default_nettype none

module bru (
    input var  [31:0] a,
    input var  [31:0] b,
    output var [31:0] p
);

  always_comb begin
    p = a + b;
  end

endmodule

`default_nettype wire
