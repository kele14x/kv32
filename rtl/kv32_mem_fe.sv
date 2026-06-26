// kv32_mem_fe: Data memory front-end
//
// Sits between the core MEM stage and the external dmem bus.
// Handles: sub-word store positioning, misaligned access splitting,
// load data extraction with sign/zero extension.
//
// Upstream protocol (core side):
//   req held high until rdata_valid. addr/we/size/wdata/funct3 stable.
//   rdata_valid pulses for one cycle when the operation completes.
//
// Downstream protocol (bus side): req/gnt/ack
//   dmem_req is held high until dmem_gnt accepts the beat. dmem_ack then
//   returns the response later (possibly in the same cycle for zero-latency).
//
// Misalignment handling:
//   - Naturally aligned: single bus transaction, passthrough.
//   - Non-crossing misaligned (SH@addr[1:0]=01 only): single bus
//     transaction with word-aligned address, BE=0110, rdata shift.
//   - Word-crossing misaligned: two sequential bus transactions via
//     4-state FSM (IDLE→FIRST→BETWEEN→SECOND→IDLE).

module kv32_mem_fe (
    input logic clk,
    input logic rst_n,

    // Upstream: from/to core MEM stage
    input logic        req,
    input logic [31:0] addr,
    input logic        we,
    input logic [ 1:0] size,
    input logic [31:0] wdata,
    input logic [ 2:0] funct3,
    input logic        excl,

    output logic [31:0] rdata,
    output logic        rdata_valid,
    output logic        err,

    // Downstream: to/from external dmem bus (req/gnt/ack protocol)
    output logic        dmem_req,
    output logic [31:0] dmem_addr,
    output logic        dmem_we,
    output logic [ 1:0] dmem_size,
    output logic [31:0] dmem_wdata,
    output logic [ 3:0] dmem_be,
    output logic        dmem_excl,
    input  logic        dmem_gnt,
    input  logic        dmem_ack,
    input  logic [31:0] dmem_rdata,
    input  logic        dmem_err
);

  // -------------------------------------------------------------------------
  // Sub-word store positioning
  // Positions write data into the correct byte lane and computes byte enables.
  // For aligned accesses this is the final bus output. For crossing accesses
  // the FSM overrides with first_be/first_wdata and second_be/second_wdata.
  // -------------------------------------------------------------------------
  logic [ 3:0] aligned_be;
  logic [31:0] aligned_wdata;
  always_comb begin
    aligned_be    = 4'b1111;
    aligned_wdata = wdata;
    unique case (size)
      2'b00: begin  // SB
        unique case (addr[1:0])
          2'b00: begin
            aligned_be    = 4'b0001;
            aligned_wdata = {24'h0, wdata[7:0]};
          end
          2'b01: begin
            aligned_be    = 4'b0010;
            aligned_wdata = {16'h0, wdata[7:0], 8'h0};
          end
          2'b10: begin
            aligned_be    = 4'b0100;
            aligned_wdata = {8'h0, wdata[7:0], 16'h0};
          end
          2'b11: begin
            aligned_be    = 4'b1000;
            aligned_wdata = {wdata[7:0], 24'h0};
          end
        endcase
      end
      2'b01: begin  // SH
        unique case (addr[1])
          1'b0: begin
            aligned_be    = 4'b0011;
            aligned_wdata = {16'h0, wdata[15:0]};
          end
          1'b1: begin
            aligned_be    = 4'b1100;
            aligned_wdata = {wdata[15:0], 16'h0};
          end
        endcase
      end
      default: begin  // SW
        aligned_be    = 4'b1111;
        aligned_wdata = wdata;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // Misalignment detection
  //
  // non_crossing_ma is only ever set for the SH@addr[1:0]=01 case (a
  // halfword straddling bytes 1-2 of a single word). Any other misaligned
  // access either crosses a word boundary (word_crossing) or is naturally
  // aligned. The load-side shift below relies on this exact-case
  // assumption — do not generalize without revisiting that shift logic.
  // -------------------------------------------------------------------------
  logic word_crossing;
  logic non_crossing_ma;
  always_comb begin
    word_crossing   = 1'b0;
    non_crossing_ma = 1'b0;
    if (req && ma_state == MA_IDLE) begin
      if (size == 2'b01 && addr[0]) begin
        if (addr[1]) word_crossing = 1'b1;
        else non_crossing_ma = 1'b1;
      end else if (size == 2'b10 && addr[1:0] != 2'b00) begin
        word_crossing = 1'b1;
      end
    end
  end

  // Crossing overflow: a crossing access whose second beat (aligned_base + 4)
  // would wrap past 0xFFFFFFFF (i.e. addr[31:2] all-ones). Reported as err
  // immediately — no beat is issued, the FSM stays in IDLE. Without this the
  // second beat would silently alias to 0x00000000.
  logic crossing_overflow;
  assign crossing_overflow = word_crossing && &addr[31:2];

  // -------------------------------------------------------------------------
  // Crossing access helpers
  // -------------------------------------------------------------------------

  // Raw halfword from wdata. The core passes raw rs2 without positioning,
  // so the halfword to store is always in wdata[15:0] regardless of addr.
  logic [15:0] raw_hw;
  assign raw_hw = wdata[15:0];

  // First-access byte enables and write data (crossing case)
  logic [ 3:0] first_be;
  logic [31:0] first_wdata;
  always_comb begin
    first_be    = aligned_be;
    first_wdata = aligned_wdata;
    if (size == 2'b01) begin
      // SH crossing (addr[1:0]=11 only): low byte to byte lane 3
      first_be    = 4'b1000;
      first_wdata = {raw_hw[7:0], 24'h0};
    end else begin
      // SW crossing
      unique case (addr[1:0])
        2'b01: begin
          first_be    = 4'b1110;
          first_wdata = {wdata[23:0], 8'h0};
        end
        2'b10: begin
          first_be    = 4'b1100;
          first_wdata = {wdata[15:0], 16'h0};
        end
        2'b11: begin
          first_be    = 4'b1000;
          first_wdata = {wdata[7:0], 24'h0};
        end
        default: begin
          first_be    = 4'b1111;
          first_wdata = wdata;
        end
      endcase
    end
  end

  // Second-access byte enables and write data (crossing case, writes only)
  logic [ 3:0] second_be;
  logic [31:0] second_wdata;
  always_comb begin
    second_be    = 4'b1111;
    second_wdata = wdata;
    if (ma_size == 2'b01) begin
      // SH crossing (addr[1:0]=11): high byte to byte lane 0 of second word
      second_wdata = {24'h0, raw_hw[15:8]};
      second_be    = 4'b0001;
    end else begin
      // SW crossing: remaining bytes go to low positions of second word
      unique case (ma_offset)
        2'b01: begin
          second_wdata = {24'h0, wdata[31:24]};
          second_be    = 4'b0001;
        end
        2'b10: begin
          second_wdata = {16'h0, wdata[31:16]};
          second_be    = 4'b0011;
        end
        2'b11: begin
          second_wdata = {8'h0, wdata[31:8]};
          second_be    = 4'b0111;
        end
        default: begin
          second_wdata = wdata;
          second_be    = 4'b1111;
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Alignment handler FSM (5-state, req/gnt/ack protocol)
  //
  // IDLE        → aligned/non-crossing beat, crossing overflow (err inline),
  //               or crossing first beat.
  // SINGLE_WAIT → single-beat request accepted, waiting for ack.
  // FIRST_WAIT  → first crossing beat accepted, waiting for its ack.
  // SECOND_REQ  → second beat pending grant.
  // SECOND_WAIT → second beat accepted, waiting for ack.
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    MA_IDLE,
    MA_SINGLE_WAIT,
    MA_FIRST_WAIT,
    MA_SECOND_REQ,
    MA_SECOND_WAIT
  } ma_state_t;

  // verilator lint_off UNUSEDSIGNAL
  ma_state_t        ma_state;
  logic      [31:0] ma_first_rdata;  // [7:0] unused — crossing stitch only reads upper bytes
  logic      [31:0] ma_base;
  logic      [ 1:0] ma_offset;
  logic      [ 1:0] ma_size;
  logic             ma_single_non_crossing;
  // verilator lint_on UNUSEDSIGNAL

  // Word-aligned base address for crossing accesses
  logic      [31:0] aligned_base;
  assign aligned_base = {addr[31:2], 2'b00};

  logic single_beat;
  logic single_accept;
  logic single_complete;
  logic first_accept;
  logic first_complete;
  logic second_complete;
  logic non_crossing_single_complete;

  assign single_beat = req && !word_crossing && !crossing_overflow;
  assign single_accept = (ma_state == MA_IDLE) && single_beat && dmem_gnt;
  assign single_complete      = (single_accept && dmem_ack) ||
                                ((ma_state == MA_SINGLE_WAIT) && dmem_ack);
  assign first_accept         = (ma_state == MA_IDLE) && req && word_crossing &&
                                !crossing_overflow && dmem_gnt;
  assign first_complete = (first_accept && dmem_ack) || ((ma_state == MA_FIRST_WAIT) && dmem_ack);
  assign second_complete      = ((ma_state == MA_SECOND_REQ) && dmem_gnt && dmem_ack) ||
  ((ma_state == MA_SECOND_WAIT) && dmem_ack);
  assign non_crossing_single_complete =
      (single_accept && dmem_ack && non_crossing_ma) ||
      ((ma_state == MA_SINGLE_WAIT) && dmem_ack && ma_single_non_crossing);

  // Downstream bus signals (muxed by FSM state)
  //
  // Note on dmem_size for split beats: for a word-crossing access, each beat
  // carries a subset of the original bytes (dmem_be is authoritative). dmem_size
  // still reflects the *original* access size (e.g. 2'b10 for a split SW), not
  // the beat width. Slaves must use dmem_be for write granularity and must not
  // cross-check dmem_size against dmem_addr/dmem_be. See SPEC §4.1.
  always_comb begin
    dmem_req   = 1'b0;
    dmem_addr  = addr;
    dmem_we    = we;
    dmem_size  = size;
    dmem_wdata = aligned_wdata;
    dmem_be    = aligned_be;
    dmem_excl  = excl;

    unique case (ma_state)
      MA_IDLE: begin
        if (req) begin
          dmem_we   = we;
          dmem_size = size;
          if (crossing_overflow) begin
            dmem_addr = aligned_base;
          end else if (word_crossing) begin
            dmem_req   = 1'b1;
            dmem_addr  = aligned_base;
            dmem_wdata = first_wdata;
            dmem_be    = first_be;
          end else begin
            dmem_req = 1'b1;
            if (non_crossing_ma) begin
              dmem_addr = aligned_base;
              dmem_be   = 4'b0110;
              if (we) dmem_wdata = {wdata[23:0], 8'h0};
            end
          end
        end
      end

      MA_SINGLE_WAIT: begin
        dmem_addr = addr;
        dmem_we   = we;
        dmem_size = size;
      end

      MA_FIRST_WAIT: begin
        dmem_addr = ma_base;
        dmem_we   = we;
        dmem_size = ma_size;
      end

      MA_SECOND_REQ: begin
        dmem_req   = req;
        dmem_addr  = ma_base + 32'd4;
        dmem_we    = we;
        dmem_size  = ma_size;
        dmem_wdata = second_wdata;
        dmem_be    = second_be;
      end

      MA_SECOND_WAIT: begin
        dmem_addr = ma_base + 32'd4;
        dmem_we   = we;
        dmem_size = ma_size;
      end

      default: ;
    endcase
  end

  // FSM state transitions
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ma_state               <= MA_IDLE;
      ma_first_rdata         <= 32'h0;
      ma_base                <= 32'h0;
      ma_offset              <= 2'b00;
      ma_size                <= 2'b00;
      ma_single_non_crossing <= 1'b0;
    end else begin
      unique case (ma_state)
        MA_IDLE: begin
          if (req && word_crossing && !crossing_overflow) begin
            ma_base <= aligned_base;
            ma_offset <= addr[1:0];
            ma_size <= size;
            ma_single_non_crossing <= 1'b0;
            if (dmem_gnt) begin
              if (dmem_ack) begin
                if (dmem_err) begin
                  ma_state <= MA_IDLE;
                end else begin
                  ma_first_rdata <= dmem_rdata;
                  ma_state       <= MA_SECOND_REQ;
                end
              end else begin
                ma_state <= MA_FIRST_WAIT;
              end
            end
          end else if (single_beat && dmem_gnt && !dmem_ack) begin
            ma_single_non_crossing <= non_crossing_ma;
            ma_state <= MA_SINGLE_WAIT;
          end else begin
            ma_single_non_crossing <= 1'b0;
          end
        end

        MA_SINGLE_WAIT: begin
          if (dmem_ack) begin
            ma_single_non_crossing <= 1'b0;
            ma_state <= MA_IDLE;
          end
        end

        MA_FIRST_WAIT: begin
          if (dmem_ack) begin
            if (dmem_err) begin
              ma_state <= MA_IDLE;
            end else begin
              ma_first_rdata <= dmem_rdata;
              ma_state <= MA_SECOND_REQ;
            end
          end
        end

        MA_SECOND_REQ: begin
          if (dmem_gnt) begin
            if (dmem_ack) begin
              ma_state <= MA_IDLE;
            end else begin
              ma_state <= MA_SECOND_WAIT;
            end
          end
        end

        MA_SECOND_WAIT: begin
          if (dmem_ack) begin
            ma_state <= MA_IDLE;
          end
        end

        default: ma_state <= MA_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Load data extraction
  //
  // Selects and extends the correct bytes from the bus word based on
  // funct3 and the original (unaligned) address. For crossing accesses
  // the data is stitched from two halves; for non-crossing misaligned
  // SH@01 the data is pre-shifted right by 8 bits.
  // -------------------------------------------------------------------------

  // Raw data word for extraction:
  // - Crossing: stitched from ma_first_rdata + dmem_rdata
  // - Non-crossing misaligned (SH@01): dmem_rdata >> 8
  // - Otherwise: dmem_rdata directly
  logic [31:0] raw_rdata;
  always_comb begin
    raw_rdata = dmem_rdata;

    // Stitched data for crossing accesses
    if (second_complete) begin
      unique case (ma_size)
        2'b01: begin  // Halfword (addr[1:0]=11 only)
          raw_rdata = {dmem_rdata[7:0], ma_first_rdata[31:24], 16'h0};
        end
        2'b10: begin  // Word
          unique case (ma_offset)
            2'b01:   raw_rdata = {dmem_rdata[7:0], ma_first_rdata[31:8]};
            2'b10:   raw_rdata = {dmem_rdata[15:0], ma_first_rdata[31:16]};
            2'b11:   raw_rdata = {dmem_rdata[23:0], ma_first_rdata[31:24]};
            default: raw_rdata = dmem_rdata;
          endcase
        end
        default: raw_rdata = dmem_rdata;
      endcase
    end

    // Non-crossing misaligned: only SH@addr[1:0]=01 reaches here.
    // Shift right by 8 so the LH extractor (keyed on addr[1]=0)
    // picks up bytes 1,2 as the low halfword.
    if (non_crossing_single_complete && !we) begin
      raw_rdata = {8'h0, dmem_rdata[31:8]};
    end
  end

  // Extract and extend based on funct3 and original addr[1:0].
  // Uses the original (unaligned) address for byte selection — the
  // crossing stitch and non-crossing shift have already placed the
  // desired bytes at the positions that match the original offset.
  logic        is_load;
  logic [31:0] extracted;
  always_comb begin
    is_load   = !we;
    extracted = raw_rdata;
    if (is_load) begin
      unique case (funct3)
        3'b000: begin  // LB - sign-extend
          unique case (addr[1:0])
            2'b00: extracted = {{24{raw_rdata[7]}}, raw_rdata[7:0]};
            2'b01: extracted = {{24{raw_rdata[15]}}, raw_rdata[15:8]};
            2'b10: extracted = {{24{raw_rdata[23]}}, raw_rdata[23:16]};
            2'b11: extracted = {{24{raw_rdata[31]}}, raw_rdata[31:24]};
          endcase
        end
        3'b001: begin  // LH - sign-extend
          unique case (addr[1])
            1'b0: extracted = {{16{raw_rdata[15]}}, raw_rdata[15:0]};
            1'b1: extracted = {{16{raw_rdata[31]}}, raw_rdata[31:16]};
          endcase
        end
        3'b010:  extracted = raw_rdata;  // LW
        3'b100: begin  // LBU - zero-extend
          unique case (addr[1:0])
            2'b00: extracted = {24'h0, raw_rdata[7:0]};
            2'b01: extracted = {24'h0, raw_rdata[15:8]};
            2'b10: extracted = {24'h0, raw_rdata[23:16]};
            2'b11: extracted = {24'h0, raw_rdata[31:24]};
          endcase
        end
        3'b101: begin  // LHU - zero-extend
          unique case (addr[1])
            1'b0: extracted = {16'h0, raw_rdata[15:0]};
            1'b1: extracted = {16'h0, raw_rdata[31:16]};
          endcase
        end
        default: extracted = raw_rdata;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output logic
  //
  // rdata_valid pulses for one cycle when the operation completes:
  //   - aligned / non-crossing: single-beat ack
  //   - crossing overflow: detected in IDLE, no beat issued (err path)
  //   - crossing first-beat err: first ack with dmem_err (abort)
  //   - crossing second-beat: second-beat ack (success or err)
  //
  // err is meaningful only alongside rdata_valid. It fires on:
  //   - any dmem_ack with dmem_err (single-beat, first-beat abort, second-beat)
  //   - crossing overflow (no beat issued)
  // -------------------------------------------------------------------------
  assign rdata_valid = single_complete ||
                       ((ma_state == MA_IDLE) && crossing_overflow) ||
                       (first_complete && dmem_err) ||
                       second_complete;

  assign err = ((ma_state == MA_IDLE) && crossing_overflow) ||
               (single_complete && dmem_err) ||
               (first_complete && dmem_err) ||
               (second_complete && dmem_err);

  assign rdata = extracted;

endmodule
