module kv32_core
  import kv32_pkg::*;
(
    input logic clk,
    input logic rst_n,
    input logic irq_external_i,
    input logic irq_timer_i,
    input logic irq_software_i,

    // Instruction memory interface (req/gnt/ack protocol)
    output logic        imem_req,
    output logic [31:0] imem_addr,
    output logic        imem_we,
    output logic [ 1:0] imem_size,
    output logic [31:0] imem_wdata,
    output logic [ 3:0] imem_be,
    output logic        imem_excl,
    input  logic        imem_gnt,
    input  logic        imem_ack,
    input  logic [31:0] imem_rdata,
    input  logic        imem_err,

    // Data memory interface (req/gnt/ack protocol, through kv32_mem_fe)
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

  // ===========================================================================
  // FSM state machine
  // ===========================================================================

  typedef enum logic [2:0] {
    ST_FETCH,
    ST_DECODE,
    ST_EXEC,
    ST_MEM,
    ST_WRITEBACK
  } state_t;

  state_t state;

  // Current instruction's PC and instruction word
  logic [31:0] pc_reg;
  logic [31:0] instr_reg;

  // Fetch handshake tracking
  logic fetch_req;
  logic fetch_wait;

  // Latched results from EXEC (for MEM/WRITEBACK)
  logic [31:0] ex_result_reg;
  logic [31:0] rs2_data_reg;
  logic [31:0] load_data_reg;  // Latched load data from mem_fe

  // Branch/jump redirect target (latched in EXEC, used in WRITEBACK)
  logic [31:0] branch_target_reg;
  logic branch_redirect;

  // Access fault from MEM state — prevents writeback on fault
  logic trap_from_mem;

  // ===========================================================================
  // Instruction memory interface (driven during FETCH state)
  // ===========================================================================

  // verilator lint_off UNUSEDSIGNAL
  logic i_err;
  // verilator lint_on UNUSEDSIGNAL

  assign imem_req   = (state == ST_FETCH) && fetch_req && !fetch_wait;
  assign imem_addr  = pc_reg;
  assign imem_we    = 1'b0;
  assign imem_size  = 2'b10;  // always word
  assign imem_wdata = 32'h0;
  assign imem_be    = 4'hF;
  assign imem_excl  = 1'b0;
  assign i_err      = imem_err;

  // ===========================================================================
  // Memory front-end
  // ===========================================================================

  // Internal data port signals (driven during MEM state)
  logic        d_req;
  logic [31:0] d_addr;
  logic        d_we;
  logic [ 1:0] d_size;
  logic [31:0] d_wdata;

  // Memory front-end outputs
  logic [31:0] fe_rdata;
  logic        fe_rdata_valid;
  logic        fe_err;

  // Data memory front-end: handles alignment, sub-word positioning,
  // load extraction, and misaligned access splitting.
  kv32_mem_fe u_mem_fe (
      .clk        (clk),
      .rst_n      (rst_n),
      .req        (d_req),
      .addr       (d_addr),
      .we         (d_we),
      .size       (d_size),
      .wdata      (d_wdata),
      .funct3     (funct3_id),
      .rdata      (fe_rdata),
      .rdata_valid(fe_rdata_valid),
      .err        (fe_err),
      .dmem_req   (dmem_req),
      .dmem_addr  (dmem_addr),
      .dmem_we    (dmem_we),
      .dmem_size  (dmem_size),
      .dmem_wdata (dmem_wdata),
      .dmem_be    (dmem_be),
      .dmem_excl  (dmem_excl),
      .dmem_gnt   (dmem_gnt),
      .dmem_ack   (dmem_ack),
      .dmem_rdata (dmem_rdata),
      .dmem_err   (dmem_err)
  );

  // ===========================================================================
  // Decoder (combinational — decodes instr_reg)
  // ===========================================================================

  logic [4:0] rd_id, rs1_id, rs2_id;
  logic [ 2:0] funct3_id;
  logic [31:0] imm_id;
  logic use_imm_id, alu_op_valid_id, mem_read_id, mem_write_id;
  logic reg_write_id, branch_id, jump_id, is_jalr_id, illegal_id;
  logic lui_id, auipc_id;
  logic    [3:0] alu_op_id;
  csr_op_t       csr_op_id;
  logic csr_wen_id, is_csr_id, is_mret_id, use_zimm_id;
  logic is_ecall_id, is_ebreak_id;
  logic is_m_mul_id, is_m_div_id;

  kv32_decoder u_decoder (
      .instr       (instr_reg),
      .rd          (rd_id),
      .funct3      (funct3_id),
      .rs1         (rs1_id),
      .rs2         (rs2_id),
      .imm         (imm_id),
      .use_imm     (use_imm_id),
      .alu_op_valid(alu_op_valid_id),
      .alu_op      (alu_op_id),
      .mem_read    (mem_read_id),
      .mem_write   (mem_write_id),
      .reg_write   (reg_write_id),
      .branch      (branch_id),
      .jump        (jump_id),
      .is_jalr     (is_jalr_id),
      .illegal     (illegal_id),
      .lui         (lui_id),
      .auipc       (auipc_id),
      .csr_op      (csr_op_id),
      .csr_wen     (csr_wen_id),
      .is_csr      (is_csr_id),
      .is_mret     (is_mret_id),
      .use_zimm    (use_zimm_id),
      .is_ecall    (is_ecall_id),
      .is_ebreak   (is_ebreak_id),
      .is_m_mul    (is_m_mul_id),
      .is_m_div    (is_m_div_id)
  );

  // ===========================================================================
  // Register file
  // ===========================================================================

  logic [31:0] rs1_data, rs2_data;
  logic        regfile_we;
  logic [ 4:0] regfile_rd;
  logic [31:0] regfile_wdata;

  kv32_regfile u_regfile (
      .clk     (clk),
      .rs1_addr(rs1_id),
      .rs1_data(rs1_data),
      .rs2_addr(rs2_id),
      .rs2_data(rs2_data),
      .we      (regfile_we),
      .rd_addr (regfile_rd),
      .rd_data (regfile_wdata)
  );

  // ===========================================================================
  // ALU
  // ===========================================================================

  logic [31:0] alu_a, alu_b, alu_result;

  assign alu_a = auipc_id ? pc_reg : rs1_data;
  assign alu_b = use_imm_id ? imm_id : rs2_data;

  kv32_alu u_alu (
      .a     (alu_a),
      .b     (alu_b),
      .op    (alu_op_id),
      .result(alu_result)
  );

  // ===========================================================================
  // M extension unit (multiply/divide)
  // ===========================================================================

  logic [31:0] m_result;
  logic        m_busy;
  logic        m_done;
  logic        m_unit_start;

  // Start M-unit once when entering EXEC with an M-extension instruction.
  // Don't re-pulse while the FSM stays in EXEC waiting for m_busy.
  assign m_unit_start = (state == ST_EXEC) && (is_m_mul_id || is_m_div_id) && !m_busy && !m_done;

  kv32_m_unit u_m_unit (
      .clk   (clk),
      .rst_n (rst_n),
      .valid (m_unit_start),
      .is_mul(is_m_mul_id),
      .funct3(funct3_id),
      .op_a  (rs1_data),
      .op_b  (rs2_data),
      .result(m_result),
      .busy  (m_busy),
      .done  (m_done)
  );

  // ===========================================================================
  // CSR module
  // ===========================================================================

  logic [31:0] csr_rdata;
  logic [11:0] csr_addr_w;
  logic [31:0] csr_wdata_w;
  logic        csr_wen_gated;
  logic        csr_illegal;
  // verilator lint_off UNUSEDSIGNAL
  logic [31:0] mtvec_out;
  logic        mstatus_mie;
  // verilator lint_on UNUSEDSIGNAL
  logic [31:0] mepc_out;
  logic        instr_retired;

  assign csr_addr_w = instr_reg[31:20];
  assign csr_wdata_w = use_zimm_id ? {27'b0, instr_reg[19:15]} : rs1_data;

  // Gate CSR write by FSM state — writes only during EXEC.
  // !trap_taken is NOT needed here: the CSR module's write priority chain
  // (trap > mret > csr write) already suppresses the write when a trap is
  // taken. Omitting !trap_taken avoids a combinational loop through
  // csr_illegal → trap_taken.
  assign csr_wen_gated = csr_wen_id && (state == ST_EXEC);

  // ===========================================================================
  // Trap detection
  // ===========================================================================

  logic        trap_taken;
  logic [31:0] trap_pc;
  logic [31:0] trap_cause;
  logic [31:0] trap_val;

  always_comb begin
    trap_taken = 1'b0;
    trap_pc = pc_reg;
    trap_cause = 32'h0;
    trap_val = 32'h0;

    if (state == ST_EXEC) begin
      // EXEC-stage traps: breakpoint > ecall > illegal
      if (is_ebreak_id) begin
        trap_taken = 1'b1;
        trap_cause = 32'd3;  // Breakpoint
        trap_val   = pc_reg;
      end else if (is_ecall_id) begin
        trap_taken = 1'b1;
        trap_cause = 32'd11;  // Environment call from M-mode
        trap_val   = 32'h0;
      end else if (illegal_id || csr_illegal) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
      end
    end else if (state == ST_MEM) begin
      // MEM-stage access fault
      if (fe_err && fe_rdata_valid) begin
        trap_taken = 1'b1;
        trap_cause = mem_write_id ? 32'd7 : 32'd5;  // Store / Load access fault
        trap_val   = ex_result_reg;  // Faulting address
      end
    end
  end

  // ===========================================================================
  // Branch / jump evaluation
  // ===========================================================================

  logic        branch_taken;
  logic [31:0] branch_target;

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = pc_reg + 4;

    if (state == ST_EXEC) begin
      if (is_mret_id) begin
        branch_taken  = 1'b1;
        branch_target = mepc_out;
      end else if (branch_id) begin
        unique case (funct3_id)
          3'b000:  branch_taken = (rs1_data == rs2_data);  // BEQ
          3'b001:  branch_taken = (rs1_data != rs2_data);  // BNE
          3'b100:  branch_taken = ($signed(rs1_data) < $signed(rs2_data));  // BLT
          3'b101:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));  // BGE
          3'b110:  branch_taken = (rs1_data < rs2_data);  // BLTU
          3'b111:  branch_taken = (rs1_data >= rs2_data);  // BGEU
          default: branch_taken = 1'b0;
        endcase

        if (branch_taken) begin
          branch_target = pc_reg + imm_id;
        end
      end

      if (jump_id) begin
        branch_taken = 1'b1;
        if (is_jalr_id) begin
          branch_target = (rs1_data + imm_id) & ~32'h1;
        end else begin  // JAL
          branch_target = pc_reg + imm_id;
        end
      end
    end
  end

  // ===========================================================================
  // EX result mux
  // ===========================================================================

  logic [31:0] ex_result;

  always_comb begin
    if (is_csr_id) begin
      ex_result = csr_rdata;
    end else if (lui_id) begin
      ex_result = imm_id;
    end else if (is_m_mul_id || is_m_div_id) begin
      ex_result = m_result;
    end else if (alu_op_valid_id || auipc_id) begin
      ex_result = alu_result;
    end else begin
      ex_result = pc_reg + 4;  // For JAL/JALR link address
    end
  end

  // ===========================================================================
  // Data memory port (driven during MEM state)
  // ===========================================================================

  always_comb begin
    if (state == ST_MEM) begin
      d_req   = mem_read_id || mem_write_id;
      d_addr  = ex_result_reg;  // Effective address from EXEC
      d_we    = mem_write_id;
      d_size  = funct3_id[1:0];
      d_wdata = rs2_data_reg;  // Latched rs2 from EXEC
    end else begin
      d_req   = 1'b0;
      d_addr  = 32'h0;
      d_we    = 1'b0;
      d_size  = 2'b00;
      d_wdata = 32'h0;
    end
  end

  // ===========================================================================
  // Writeback
  // ===========================================================================

  assign regfile_we    = (state == ST_WRITEBACK) && reg_write_id && !trap_from_mem;
  assign regfile_rd    = rd_id;
  assign regfile_wdata = mem_read_id ? load_data_reg : ex_result_reg;

  // Instruction retired: asserted during WRITEBACK for non-trapping instructions
  assign instr_retired = (state == ST_WRITEBACK) && !trap_from_mem;

  // ===========================================================================
  // MRET handling
  // ===========================================================================

  // mret_taken: gated by state == ST_EXEC so a stalled MRET doesn't fire
  // repeatedly (the FSM only stays in EXEC while waiting for M-unit, which
  // can't happen for MRET — but the gate is still correct).
  logic mret_taken;
  assign mret_taken = is_mret_id && (state == ST_EXEC);

  // ===========================================================================
  // CSR module instantiation
  // ===========================================================================

  kv32_csr u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .csr_addr     (csr_addr_w),
      .csr_wdata    (csr_wdata_w),
      .csr_op       (csr_op_id),
      .csr_wen      (csr_wen_gated),
      .is_csr       (is_csr_id),
      .csr_rdata    (csr_rdata),
      .irq_external (irq_external_i),
      .irq_timer    (irq_timer_i),
      .irq_software (irq_software_i),
      .trap_taken   (trap_taken),
      .trap_pc      (trap_pc),
      .trap_cause   (trap_cause),
      .trap_val     (trap_val),
      .mret_taken   (mret_taken),
      .mtvec_out    (mtvec_out),
      .mepc_out     (mepc_out),
      .mstatus_mie  (mstatus_mie),
      .csr_illegal  (csr_illegal),
      .instr_retired(instr_retired)
  );

  // ===========================================================================
  // Main FSM
  // ===========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state             <= ST_FETCH;
      pc_reg            <= 32'h0;
      instr_reg         <= 32'h0;
      fetch_req         <= 1'b1;
      fetch_wait        <= 1'b0;
      ex_result_reg     <= 32'h0;
      rs2_data_reg      <= 32'h0;
      load_data_reg     <= 32'h0;
      branch_target_reg <= 32'h0;
      branch_redirect   <= 1'b0;
      trap_from_mem     <= 1'b0;
    end else begin
      trap_from_mem <= 1'b0;  // Default: clear each cycle

      unique case (state)
        ST_FETCH: begin
          // Handle imem handshake
          if (fetch_req && imem_gnt && !imem_ack) begin
            // Request granted but no ack yet — wait for ack
            fetch_req  <= 1'b0;
            fetch_wait <= 1'b1;
          end

          if (imem_ack) begin
            // Instruction fetch complete — latch and advance
            instr_reg  <= imem_rdata;
            fetch_req  <= 1'b0;
            fetch_wait <= 1'b0;
            state      <= ST_DECODE;
          end else if (!fetch_req && !fetch_wait) begin
            // No request outstanding — issue one
            fetch_req <= 1'b1;
          end
        end

        ST_DECODE: begin
          // Decode is combinational; regfile reads are combinational.
          // Advance to EXEC immediately.
          state <= ST_EXEC;
        end

        ST_EXEC: begin
          if (trap_taken) begin
            // Trap: redirect PC to mtvec, return to FETCH
            pc_reg     <= {mtvec_out[31:2], 2'b00};
            fetch_req  <= 1'b1;
            fetch_wait <= 1'b0;
            state      <= ST_FETCH;
          end else if (branch_taken) begin
            // Branch/jump/MRET: latch target and result, go to MEM (pass-through)
            // then WRITEBACK to write link register if needed
            branch_target_reg <= branch_target;
            branch_redirect   <= 1'b1;
            ex_result_reg     <= ex_result;
            rs2_data_reg      <= rs2_data;
            state             <= ST_MEM;
          end else if ((is_m_mul_id || is_m_div_id) && m_busy) begin
            // M-unit still computing — stay in EXEC
          end else begin
            // Normal instruction: latch EX result, advance to MEM
            ex_result_reg <= ex_result;
            rs2_data_reg  <= rs2_data;
            state         <= ST_MEM;
          end
        end

        ST_MEM: begin
          if (fe_rdata_valid) begin
            // Memory operation complete — latch load data if it's a load
            if (mem_read_id) begin
              load_data_reg <= fe_rdata;
            end

            if (fe_err) begin
              trap_from_mem <= 1'b1;
              // Trap: redirect PC to mtvec, return to FETCH (skip WRITEBACK)
              pc_reg        <= {mtvec_out[31:2], 2'b00};
              fetch_req     <= 1'b1;
              fetch_wait    <= 1'b0;
              state         <= ST_FETCH;
            end else begin
              state <= ST_WRITEBACK;
            end
          end else if (!(mem_read_id || mem_write_id)) begin
            // Non-memory instruction — pass through
            state <= ST_WRITEBACK;
          end
        end

        ST_WRITEBACK: begin
          // Update PC: use redirect target if branch was taken, else increment
          if (branch_redirect) begin
            pc_reg          <= branch_target_reg;
            branch_redirect <= 1'b0;
          end else begin
            pc_reg <= pc_reg + 32'd4;
          end
          fetch_req  <= 1'b1;
          fetch_wait <= 1'b0;
          state      <= ST_FETCH;
        end

        default: begin
          state <= ST_FETCH;
        end
      endcase
    end
  end

endmodule
