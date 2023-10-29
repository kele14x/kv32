// File: kv32.sv
// Brief: Simple RISC-V SoC
`timescale 1 ns / 1 ps
//
`default_nettype none

module kv32 (
    input var  clk,
    input var  rst,
    //
    output var halt
);

  logic [31:0] imem_addr;
  logic        imem_en;
  logic [31:0] imem_dout;

  logic [31:0] dmem_addr;
  logic        dmem_en;
  logic [ 3:0] dmem_we;
  logic [31:0] dmem_din;
  logic [31:0] dmem_dout;


  kv32_core #(
      .PC_INIT(32'h0000_1000)
  )i_core (
      .clk      (clk),
      .rst      (rst),
      //
      .imem_addr(imem_addr),
      .imem_en  (imem_en),
      .imem_dout(imem_dout),
      .dmem_addr(dmem_addr),
      //
      .dmem_en  (dmem_en),
      .dmem_we  (dmem_we),
      .dmem_din (dmem_din),
      .dmem_dout(dmem_dout),
      //
      .halt     (halt)
  );

  imem #(
      .INIT_FILE  ("imem.mem"),
      .MEMORY_SIZE(4096)
  ) i_imem (
      .clk (clk),
      .rst (rst),
      //
      .en  (imem_en),
      .addr(imem_addr),
      .dout(imem_dout)
  );

  dmem #(
      .MEMORY_SIZE(4096)
  ) i_dmem (
      .clk (clk),
      .rst (rst),
      //
      .en  (dmem_en),
      .we  (dmem_we),
      .addr(dmem_addr),
      .din (dmem_din),
      .dout(dmem_dout)
  );

endmodule

`default_nettype wire
