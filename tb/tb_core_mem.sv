module tb_core_mem #(
    parameter int unsigned BRAM_WORDS = 16384
) (
    input logic clk,
    input logic rst_n,

    input logic [31:0] base_addr_i,
    input logic [31:0] entry_addr_i,
    input logic [31:0] tohost_addr_i,

    input logic [31:0] imem_fixed_latency_i,
    input logic        imem_random_latency_i,
    input logic [31:0] dmem_fixed_latency_i,
    input logic        dmem_random_latency_i,

    input logic        imem_req,
    input logic [31:0] imem_addr,
    input logic        imem_we,
    input logic [ 1:0] imem_size,
    input logic [31:0] imem_wdata,
    input logic [ 3:0] imem_be,
    input logic        imem_excl,
    output logic       imem_gnt,
    output logic       imem_ack,
    output logic [31:0] imem_rdata,
    output logic       imem_err,

    input logic        dmem_req,
    input logic [31:0] dmem_addr,
    input logic        dmem_we,
    input logic [ 1:0] dmem_size,
    input logic [31:0] dmem_wdata,
    input logic [ 3:0] dmem_be,
    input logic        dmem_excl,
    output logic       dmem_gnt,
    output logic       dmem_ack,
    output logic [31:0] dmem_rdata,
    output logic       dmem_err,

    output logic [31:0] tohost_word_o
);

  localparam logic [31:0] NOP_WORD = 32'h00000013;
  localparam logic [31:0] IMEM_LFSR_SEED = 32'h4B563332;
  localparam logic [31:0] DMEM_LFSR_SEED = 32'h1D872B41;

  localparam int unsigned MEM_IDX_W = $clog2(BRAM_WORDS);

  logic [31:0] mem[0:BRAM_WORDS-1] /* verilator public_flat_rw */;

  logic        imem_outstanding, dmem_outstanding;
  logic [31:0] imem_cycles_until_ack, dmem_cycles_until_ack;
  logic [31:0] imem_txn_addr, dmem_txn_addr;
  logic        dmem_txn_we;
  logic [31:0] dmem_txn_wdata;
  logic [ 3:0] dmem_txn_be;
  logic [31:0] imem_lfsr, dmem_lfsr;

  logic [31:0] imem_selected_latency, dmem_selected_latency;
  logic        imem_ack_due, dmem_ack_due;
  logic        imem_same_req_held, dmem_same_req_held;
  logic        imem_new_ack, dmem_new_ack;

  logic _unused_inputs;
  assign _unused_inputs = &{
    1'b0,
    imem_we,
    |imem_size,
    |imem_wdata,
    |imem_be,
    imem_excl,
    |dmem_size,
    dmem_excl
  };

  function automatic logic [31:0] next_lfsr(input logic [31:0] state);
    logic feedback;
    begin
      feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
      next_lfsr = {state[30:0], feedback};
    end
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] choose_latency(
      input logic        random_enabled,
      input logic [31:0] fixed_latency,
      input logic [31:0] lfsr_state
  );
    logic [31:0] band;
    logic [31:0] short_latency;
    logic [31:0] long_latency;
    begin
      if (!random_enabled) begin
        choose_latency = fixed_latency;
      end else begin
        band = {28'h0, lfsr_state[3:0]};
        short_latency = 32'd1 + {30'h0, lfsr_state[5:4]};
        long_latency = 32'd4 + ({29'h0, lfsr_state[8:6]} % 32'd7);
        choose_latency = (band < 9) ? short_latency : long_latency;
      end
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [31:0] trampoline_word(input logic [31:0] addr);
    logic [31:0] word_index;
    logic [31:0] upper;
    begin
      word_index = addr >> 2;
      unique case (word_index)
        32'd0: begin
          upper = (entry_addr_i + 32'h800) >> 12;
          trampoline_word = (upper << 12) | (32'd5 << 7) | 32'h37;
        end
        32'd1: begin
          trampoline_word = ((entry_addr_i & 32'hFFF) << 20) |
                            (32'd5 << 15) | 32'h67;
        end
        default: trampoline_word = NOP_WORD;
      endcase
    end
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] mem_read_word(input logic [31:0] addr);
    logic [31:0] off;
    logic [MEM_IDX_W-1:0] idx;
    begin
      if (base_addr_i != 32'h0 && addr < base_addr_i) begin
        mem_read_word = trampoline_word(addr);
      end else begin
        off = addr - base_addr_i;
        idx = off[MEM_IDX_W+1:2];
        mem_read_word = mem[idx];
      end
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off UNUSEDSIGNAL */
  task automatic mem_write_word(
      input logic [31:0] addr,
      input logic [31:0] wdata,
      input logic [ 3:0] be
  );
    logic [31:0] off;
    logic [MEM_IDX_W-1:0] idx;
    begin
      if (addr < base_addr_i) begin
        return;
      end

      off = addr - base_addr_i;
      idx = off[MEM_IDX_W+1:2];

      if (be[0]) mem[idx][7:0] <= wdata[7:0];
      if (be[1]) mem[idx][15:8] <= wdata[15:8];
      if (be[2]) mem[idx][23:16] <= wdata[23:16];
      if (be[3]) mem[idx][31:24] <= wdata[31:24];
    end
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  assign imem_selected_latency = choose_latency(
      imem_random_latency_i, imem_fixed_latency_i, imem_lfsr
  );
  assign dmem_selected_latency = choose_latency(
      dmem_random_latency_i, dmem_fixed_latency_i, dmem_lfsr
  );

  assign imem_ack_due = imem_outstanding && (imem_cycles_until_ack == 32'd1);
  assign dmem_ack_due = dmem_outstanding && (dmem_cycles_until_ack == 32'd1);

  assign imem_same_req_held = imem_outstanding && imem_req && (imem_addr == imem_txn_addr);
  assign dmem_same_req_held = dmem_outstanding && dmem_req &&
                              (dmem_addr == dmem_txn_addr) &&
                              (dmem_we == dmem_txn_we) &&
                              (dmem_wdata == dmem_txn_wdata) &&
                              (dmem_be == dmem_txn_be);

  assign imem_new_ack = !imem_outstanding && imem_req && (imem_selected_latency == 32'd0);
  assign dmem_new_ack = !dmem_outstanding && dmem_req && (dmem_selected_latency == 32'd0);

  assign imem_gnt = imem_req && (!imem_outstanding || (imem_same_req_held && !imem_ack_due));
  assign dmem_gnt = dmem_req && (!dmem_outstanding || (dmem_same_req_held && !dmem_ack_due));

  assign imem_ack = imem_ack_due || imem_new_ack;
  assign dmem_ack = dmem_ack_due || dmem_new_ack;

  assign imem_rdata = imem_ack_due ? mem_read_word(imem_txn_addr) :
                      (imem_new_ack ? mem_read_word(imem_addr) : 32'h0);
  assign dmem_rdata = dmem_ack_due ? mem_read_word(dmem_txn_addr) :
                      (dmem_new_ack ? mem_read_word(dmem_addr) : 32'h0);

  assign imem_err = 1'b0;
  assign dmem_err = 1'b0;
  assign tohost_word_o = mem_read_word(tohost_addr_i);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      imem_outstanding <= 1'b0;
      dmem_outstanding <= 1'b0;
      imem_cycles_until_ack <= 32'h0;
      dmem_cycles_until_ack <= 32'h0;
      imem_txn_addr <= 32'h0;
      dmem_txn_addr <= 32'h0;
      dmem_txn_we <= 1'b0;
      dmem_txn_wdata <= 32'h0;
      dmem_txn_be <= 4'h0;
      imem_lfsr <= IMEM_LFSR_SEED;
      dmem_lfsr <= DMEM_LFSR_SEED;
    end else begin
      if (imem_outstanding) begin
        if (imem_ack_due) begin
          imem_outstanding <= 1'b0;
        end else if (imem_cycles_until_ack > 32'd1) begin
          imem_cycles_until_ack <= imem_cycles_until_ack - 32'd1;
        end
      end else if (imem_req) begin
        if (imem_random_latency_i) begin
          imem_lfsr <= next_lfsr(imem_lfsr);
        end
        if (imem_selected_latency != 32'd0) begin
          imem_outstanding <= 1'b1;
          imem_cycles_until_ack <= imem_selected_latency;
          imem_txn_addr <= imem_addr;
        end
      end

      if (dmem_outstanding) begin
        if (dmem_ack_due) begin
          if (dmem_txn_we) begin
            mem_write_word(dmem_txn_addr, dmem_txn_wdata, dmem_txn_be);
          end
          dmem_outstanding <= 1'b0;
        end else if (dmem_cycles_until_ack > 32'd1) begin
          dmem_cycles_until_ack <= dmem_cycles_until_ack - 32'd1;
        end
      end else if (dmem_req) begin
        if (dmem_random_latency_i) begin
          dmem_lfsr <= next_lfsr(dmem_lfsr);
        end
        if (dmem_selected_latency == 32'd0) begin
          if (dmem_we) begin
            mem_write_word(dmem_addr, dmem_wdata, dmem_be);
          end
        end else begin
          dmem_outstanding <= 1'b1;
          dmem_cycles_until_ack <= dmem_selected_latency;
          dmem_txn_addr <= dmem_addr;
          dmem_txn_we <= dmem_we;
          dmem_txn_wdata <= dmem_wdata;
          dmem_txn_be <= dmem_be;
        end
      end
    end
  end

endmodule
