module tb_core (
    input logic clk,
    input logic rst_n,
    input logic irq_external_i,
    input logic irq_timer_i,
    input logic irq_software_i,

    input logic [31:0] imem_fixed_latency_i,
    input logic        imem_random_latency_i,
    input logic [31:0] dmem_fixed_latency_i,
    input logic        dmem_random_latency_i,

    input logic [31:0] mem_base_i,
    input logic [31:0] entry_addr_i,
    input logic [31:0] tohost_addr_i,

    output logic [31:0] tohost_word_o
);

  logic        imem_req, imem_gnt, imem_ack, imem_we, imem_err, imem_excl;
  logic [31:0] imem_addr, imem_wdata, imem_rdata;
  logic [ 1:0] imem_size;
  logic [ 3:0] imem_be;

  logic        dmem_req, dmem_gnt, dmem_ack, dmem_we, dmem_err, dmem_excl;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [ 1:0] dmem_size;
  logic [ 3:0] dmem_be;

  kv32_core u_core (
      .clk           (clk),
      .rst_n         (rst_n),
      .irq_external_i(irq_external_i),
      .irq_timer_i   (irq_timer_i),
      .irq_software_i(irq_software_i),

      .imem_req  (imem_req),
      .imem_addr (imem_addr),
      .imem_we   (imem_we),
      .imem_size (imem_size),
      .imem_wdata(imem_wdata),
      .imem_be   (imem_be),
      .imem_excl (imem_excl),
      .imem_gnt  (imem_gnt),
      .imem_ack  (imem_ack),
      .imem_rdata(imem_rdata),
      .imem_err  (imem_err),

      .dmem_req  (dmem_req),
      .dmem_addr (dmem_addr),
      .dmem_we   (dmem_we),
      .dmem_size (dmem_size),
      .dmem_wdata(dmem_wdata),
      .dmem_be   (dmem_be),
      .dmem_excl (dmem_excl),
      .dmem_gnt  (dmem_gnt),
      .dmem_ack  (dmem_ack),
      .dmem_rdata(dmem_rdata),
      .dmem_err  (dmem_err)
  );

  tb_core_mem u_mem (
      .clk                   (clk),
      .rst_n                 (rst_n),
      .base_addr_i           (mem_base_i),
      .entry_addr_i          (entry_addr_i),
      .tohost_addr_i         (tohost_addr_i),
      .imem_fixed_latency_i  (imem_fixed_latency_i),
      .imem_random_latency_i (imem_random_latency_i),
      .dmem_fixed_latency_i  (dmem_fixed_latency_i),
      .dmem_random_latency_i (dmem_random_latency_i),
      .imem_req              (imem_req),
      .imem_addr             (imem_addr),
      .imem_we               (imem_we),
      .imem_size             (imem_size),
      .imem_wdata            (imem_wdata),
      .imem_be               (imem_be),
      .imem_excl             (imem_excl),
      .imem_gnt              (imem_gnt),
      .imem_ack              (imem_ack),
      .imem_rdata            (imem_rdata),
      .imem_err              (imem_err),
      .dmem_req              (dmem_req),
      .dmem_addr             (dmem_addr),
      .dmem_we               (dmem_we),
      .dmem_size             (dmem_size),
      .dmem_wdata            (dmem_wdata),
      .dmem_be               (dmem_be),
      .dmem_excl             (dmem_excl),
      .dmem_gnt              (dmem_gnt),
      .dmem_ack              (dmem_ack),
      .dmem_rdata            (dmem_rdata),
      .dmem_err              (dmem_err),
      .tohost_word_o         (tohost_word_o)
  );

endmodule
