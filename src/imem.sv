// File: imem.sv
// Brief: Instruction memory.
`timescale 1 ns / 1 ps
//
`default_nettype none

module imem #(
    parameter string INIT_FILE   = "",
    parameter int    MEMORY_SIZE = 8192
) (
    input var         clk,
    input var         rst,
    //
    input var         en,
    input var  [31:0] addr,
    output var [31:0] dout
);

  localparam int AddrWidthInt = $clog2(MEMORY_SIZE);

  logic [AddrWidthInt-1:0] mem_addr;

  logic [31:0] mem[MEMORY_SIZE/4];

  initial begin
    $readmemh(INIT_FILE, mem, 0, MEMORY_SIZE / 4 - 1);
  end

  assign mem_addr = addr[AddrWidthInt+1:2];

  // Read

  always_ff @(posedge clk) begin
    if (rst) begin
      dout <= '0;
    end else if (en) begin
      dout <= mem[mem_addr];
    end
  end

endmodule

`default_nettype wire
