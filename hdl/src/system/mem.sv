`timescale 1 ns / 1 ps
//
`default_nettype none

module mem #(
    parameter int    INIT_MEM    = 0,
    parameter string INIT_FILE = "",
    parameter int    ADDR_WIDTH  = 32,
    parameter int    DATA_WIDTH  = 32,
    parameter int    MEMORY_SIZE = 8192
) (
    input var                     clk,
    input var                     rst,
    //
    input var                     en,
    input var  [DATA_WIDTH/8-1:0] we,
    input var  [  ADDR_WIDTH-1:0] addr,
    input var  [  DATA_WIDTH-1:0] din,
    output var [  DATA_WIDTH-1:0] dout
);

  localparam int AddrWidthInt = $clog2(MEMORY_SIZE);

  logic [AddrWidthInt-1:0] mem_addr;

  logic [DATA_WIDTH-1:0] mem[MEMORY_SIZE/4];

  initial begin
    if (INIT_MEM) begin
      for (int i = 0; i < 2 ** AddrWidthInt; i++) begin
        mem[i] = '0;
      end
      if (INIT_FILE != "") begin
        $readmemh(INIT_FILE, mem, 0, MEMORY_SIZE / 4 - 1);
      end
    end
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

  // Write

  always_ff @(posedge clk) begin
    if (en) begin
      for (int i = 0; i < DATA_WIDTH / 8; i++) begin
        if (we[i]) begin
          mem[mem_addr][i*8+7-:8] <= din[i*8+7-:8];
        end
      end
    end
  end

endmodule

`default_nettype wire
