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

  // Internal memory ports
  logic i_req, d_req;
  logic [31:0] i_addr, d_addr;
  logic        d_we;
  logic [ 1:0] d_size;
  logic [31:0] d_wdata;
  logic        i_valid;
  logic [31:0] i_rdata;
  logic [31:0] i_pc_data;
  logic        i_wait_resp;
  logic        i_buf_valid;
  logic [31:0] i_buf_pc, i_buf_instr;
  logic        i_drop_resp;
  logic        i_redirect_pending;
  logic [31:0] i_redirect_pc;

  // Error signals reserved for exception handling (Phase 5)
  // verilator lint_off UNUSEDSIGNAL
  logic        i_err;
  // verilator lint_on UNUSEDSIGNAL

  // Memory front-end outputs
  logic [31:0] fe_rdata;
  logic        fe_rdata_valid;
  logic        fe_err;

  // Instruction memory: direct passthrough from IF stage
  assign imem_req   = i_req && !i_wait_resp;
  assign imem_addr  = i_addr;
  assign imem_we    = 1'b0;
  assign imem_size  = 2'b10;  // always word
  assign imem_wdata = 32'h0;
  assign imem_be    = 4'hF;
  assign imem_excl  = 1'b0;
  assign i_valid    = i_buf_valid;
  assign i_rdata    = i_buf_instr;
  assign i_pc_data  = i_buf_pc;
  assign i_err      = imem_err;

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
      .funct3     (funct3_mem),
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

  // Pipeline registers
  // verilator lint_off UNUSEDSIGNAL
  logic [31:0] pc_if, pc_id, pc_ex, pc_mem;
  logic [31:0] instr_id, instr_ex;
  // verilator lint_on UNUSEDSIGNAL

  // Instruction-valid tracking: distinguishes real instructions from
  // bubbles (flushed slots, load-use bubbles, reset state) so that
  // minstret counts every retired instruction, not just those that
  // write a register.
  logic instr_valid_id, instr_valid_ex, instr_valid_mem, instr_valid_wb;

  // Decode outputs
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

  // Register file
  logic [31:0] rs1_data, rs2_data;
  logic        regfile_we;
  logic [ 4:0] regfile_rd;
  logic [31:0] regfile_wdata;

  // Decoder
  kv32_decoder u_decoder (
      .instr       (instr_id),
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
      .is_ebreak   (is_ebreak_id)
  );

  // EX stage
  logic [4:0] rd_ex, rs1_ex, rs2_ex;
  logic [2:0] funct3_ex;

  // Register file (reads from EX stage for forwarding)
  kv32_regfile u_regfile (
      .clk     (clk),
      .rs1_addr(rs1_ex),
      .rs1_data(rs1_data),
      .rs2_addr(rs2_ex),
      .rs2_data(rs2_data),
      .we      (regfile_we),
      .rd_addr (regfile_rd),
      .rd_data (regfile_wdata)
  );
  logic [31:0] imm_ex;
  logic use_imm_ex, alu_op_valid_ex, mem_read_ex, mem_write_ex;
  logic reg_write_ex, branch_ex, jump_ex, is_jalr_ex, illegal_ex;
  logic lui_ex, auipc_ex;
  logic    [3:0] alu_op_ex;
  csr_op_t       csr_op_ex;
  logic csr_wen_ex, is_csr_ex, is_mret_ex, use_zimm_ex;
  logic is_ecall_ex, is_ebreak_ex;

  logic [31:0] alu_a, alu_b, alu_result;
  logic [31:0] ex_result;
  logic [31:0] fwd_a, fwd_b;

  kv32_alu u_alu (
      .a     (alu_a),
      .b     (alu_b),
      .op    (alu_op_ex),
      .result(alu_result)
  );

  // CSR module signals
  logic [31:0] csr_rdata;
  logic [11:0] csr_addr_w;
  logic [31:0] csr_wdata_w;
  logic        csr_wen_gated;
  logic        csr_illegal;

  // mtvec[1:0] is the MODE field; we use Direct mode (bits stripped)
  // verilator lint_off UNUSEDSIGNAL
  logic [31:0] mtvec_out;
  // verilator lint_on UNUSEDSIGNAL
  // mstatus_mie reserved for interrupt handling (Phase 5)
  // verilator lint_off UNUSEDSIGNAL
  logic        mstatus_mie;
  // verilator lint_on UNUSEDSIGNAL
  logic [31:0] mepc_out;
  logic        instr_retired;

  // Trap detection signals
  logic        trap_taken;
  logic [31:0] trap_pc;
  logic [31:0] trap_cause;
  logic [31:0] trap_val;

  // Pipeline control signals (declared here, before first use, because
  // iverilog does not forward-reference signals declared later in the
  // module. The assigns for these live further down in "Pipeline control".)
  // verilator lint_off UNUSEDSIGNAL
  logic if_stall, if_flush;
  // verilator lint_on UNUSEDSIGNAL
  logic id_stall, ex_stall, mem_stall;
  logic id_flush, ex_flush;
  logic load_use_hazard, if_wait;

  assign csr_addr_w    = instr_ex[31:20];
  assign csr_wdata_w   = use_zimm_ex ? {27'b0, instr_ex[19:15]} : fwd_a;
  // Gate the CSR write on !mem_stall so a CSR instruction stuck behind
  // a stalled MEM doesn't re-write every cycle. !trap_taken is NOT needed
  // here: the CSR module's write priority chain (trap > mret > csr write)
  // already suppresses the write when a trap is taken. Omitting !trap_taken
  // avoids a combinational loop through csr_illegal → trap_taken.
  // Load-use bubbles don't need an explicit gate here: when a load-use
  // bubble is inserted, the ID/EX register clears csr_wen_ex to 0 the
  // following cycle, so csr_wen_gated naturally deasserts. Same reasoning
  // applies to mret_taken below.
  assign csr_wen_gated = csr_wen_ex && !mem_stall;

  // Instruction retired: a real (non-bubble) instruction is leaving WB
  // this cycle. Gated by !mem_stall so each instruction counts exactly
  // once (when WB advances), not repeatedly during MEM stalls.
  assign instr_retired = instr_valid_wb && !mem_stall;

  // -------------------------------------------------------------------------
  // Trap detection: MEM-stage (access fault) and EX-stage (illegal/ecall/ebreak)
  // RISC-V mcause codes:
  //   2 = Illegal instruction
  //   3 = Breakpoint
  //   5 = Load access fault
  //   7 = Store/AMO access fault
  //   11 = Environment call from M-mode
  // Priority: MEM-stage access fault (earlier instruction) > EX-stage traps.
  // EX-stage priority per SPEC: breakpoint > ecall > illegal instruction.
  // -------------------------------------------------------------------------
  always_comb begin
    trap_taken = 1'b0;
    trap_pc    = pc_ex;
    trap_cause = 32'h0;
    trap_val   = 32'h0;

    if (!mem_stall) begin
      // MEM-stage trap: load/store access fault (checked first — earlier instruction)
      if (fe_err && fe_rdata_valid) begin
        trap_taken = 1'b1;
        trap_pc    = pc_mem;
        trap_cause = mem_write_mem ? 32'd7 : 32'd5;  // Store / Load access fault
        trap_val   = mem_addr_mem;  // Faulting address
        // EX-stage traps: breakpoint > ecall > illegal
      end else if (is_ebreak_ex) begin
        trap_taken = 1'b1;
        trap_cause = 32'd3;  // Breakpoint
        trap_val   = pc_ex;
      end else if (is_ecall_ex) begin
        trap_taken = 1'b1;
        trap_cause = 32'd11;  // Environment call from M-mode
        trap_val   = 32'h0;
      end else if (illegal_ex || csr_illegal) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_ex;  // The bad instruction
      end
    end
  end

  // Branch comparison
  logic branch_taken;
  logic [31:0] branch_target;

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = pc_ex + 4;

    if (is_mret_ex) begin
      branch_taken  = 1'b1;
      branch_target = mepc_out;
    end else if (branch_ex) begin
      unique case (funct3_ex)
        3'b000:  branch_taken = (fwd_a == fwd_b);  // BEQ
        3'b001:  branch_taken = (fwd_a != fwd_b);  // BNE
        3'b100:  branch_taken = ($signed(fwd_a) < $signed(fwd_b));  // BLT
        3'b101:  branch_taken = ($signed(fwd_a) >= $signed(fwd_b));  // BGE
        3'b110:  branch_taken = (fwd_a < fwd_b);  // BLTU
        3'b111:  branch_taken = (fwd_a >= fwd_b);  // BGEU
        default: branch_taken = 1'b0;
      endcase

      if (branch_taken) begin
        branch_target = pc_ex + imm_ex;
      end
    end

    if (jump_ex) begin
      branch_taken = 1'b1;
      if (is_jalr_ex) begin
        branch_target = (fwd_a + imm_ex) & ~32'h1;
      end else begin  // JAL
        branch_target = pc_ex + imm_ex;
      end
    end
  end

  // ALU input mux with forwarding
  assign alu_a = auipc_ex ? pc_ex : fwd_a;
  assign alu_b = use_imm_ex ? imm_ex : fwd_b;

  // EX result mux
  always_comb begin
    if (is_csr_ex) begin
      ex_result = csr_rdata;
    end else if (lui_ex) begin
      ex_result = imm_ex;
    end else if (alu_op_valid_ex || auipc_ex) begin
      ex_result = alu_result;
    end else begin
      ex_result = pc_ex + 4;  // For JAL/JALR link address
    end
  end

  // MEM stage
  logic [4:0] rd_mem;
  logic mem_read_mem, mem_write_mem, reg_write_mem;
  logic [31:0] mem_wdata_mem, mem_addr_mem;
  logic [ 1:0] mem_size_mem;
  logic [ 2:0] funct3_mem;
  logic [31:0] mem_result;

  always_comb begin
    d_req   = mem_read_mem || mem_write_mem;
    d_addr  = mem_addr_mem;
    d_we    = mem_write_mem;
    d_size  = mem_size_mem;
    d_wdata = mem_wdata_mem;

    // mem_result: load data from mem_fe, or ALU result for non-loads
    mem_result = mem_read_mem ? fe_rdata : mem_addr_mem;
  end


  // WB stage
  logic [ 4:0] rd_wb;
  logic        reg_write_wb;
  logic [31:0] wb_data;

  assign regfile_we    = reg_write_wb;
  assign regfile_rd    = rd_wb;
  assign regfile_wdata = wb_data;

  // Forwarding unit: select forwarded values from MEM or WB stages
  always_comb begin
    // Default: use register file values
    fwd_a = rs1_data;
    fwd_b = rs2_data;

    // MEM→EX forwarding (highest priority)
    if (reg_write_mem && rd_mem != 5'h0) begin
      if (rd_mem == rs1_ex) fwd_a = mem_result;
      if (rd_mem == rs2_ex) fwd_b = mem_result;
    end

    // WB→EX forwarding (lower priority, overridden by MEM→EX)
    if (reg_write_wb && rd_wb != 5'h0) begin
      if (rd_wb == rs1_ex && !(reg_write_mem && rd_mem == rs1_ex)) begin
        fwd_a = wb_data;
      end
      if (rd_wb == rs2_ex && !(reg_write_mem && rd_mem == rs2_ex)) begin
        fwd_b = wb_data;
      end
    end
  end

  // Pipeline control (signal declarations moved above, before first use)
  // Hazard detection: stall if EX stage has a load and ID stage uses its result
  assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 && ((rd_ex == rs1_id) || (rd_ex == rs2_id));

  // IF wait: instruction fetch pending grant/response with no buffered result.
  assign if_wait = (i_req || i_wait_resp) && !i_valid;

  // MEM stalls when waiting for data memory response
  assign mem_stall = (mem_read_mem || mem_write_mem) && !fe_rdata_valid;

  // Backpressure: mem_stall propagates to all earlier stages
  assign ex_stall = mem_stall;
  assign id_stall = load_use_hazard || mem_stall || if_wait;
  assign if_stall = if_wait || load_use_hazard || mem_stall;

  // Flush: branch_taken OR trap_taken both flush IF and ID stages.
  // ex_flush also inserts a bubble into EX for both cases:
  //   - trap_taken: squashes the faulting instruction (don't write back)
  //   - branch_taken: squashes the instruction in ID that would have
  //     advanced to EX. The branch itself is in EX and continues to
  //     MEM/WB normally (EX/MEM register checks trap_taken, not
  //     ex_flush, so the branch's reg_write still propagates).
  // Without the branch_taken case in ex_flush, the instruction in ID
  // at the moment of the branch would advance to EX and execute
  // despite being flushed from IF/ID.
  assign if_flush = branch_taken || trap_taken;
  assign id_flush = branch_taken || trap_taken;
  assign ex_flush = branch_taken || trap_taken;

  // IF stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_if <= 32'h0;
      i_req <= 1'b1;
      i_wait_resp <= 1'b0;
      i_buf_valid <= 1'b0;
      i_buf_pc <= 32'h0;
      i_buf_instr <= 32'h0;
      i_drop_resp <= 1'b0;
      i_redirect_pending <= 1'b0;
      i_redirect_pc <= 32'h0;
    end else begin
      if (i_buf_valid && !id_stall && !id_flush) begin
        i_buf_valid <= 1'b0;
        if (!i_req && !i_wait_resp && !i_redirect_pending) begin
          pc_if <= pc_if + 32'd4;
          i_req <= 1'b1;
        end
      end

      if (trap_taken || branch_taken) begin
        i_buf_valid <= 1'b0;
        if (i_req || i_wait_resp) begin
          i_drop_resp <= 1'b1;
          i_redirect_pending <= 1'b1;
          i_redirect_pc <= trap_taken ? {mtvec_out[31:2], 2'b00} : branch_target;
        end else begin
          pc_if <= trap_taken ? {mtvec_out[31:2], 2'b00} : branch_target;
          i_req <= 1'b1;
          i_wait_resp <= 1'b0;
          i_drop_resp <= 1'b0;
          i_redirect_pending <= 1'b0;
        end
      end

      if (!i_buf_valid && imem_ack) begin
        i_wait_resp <= 1'b0;
        if (i_drop_resp || trap_taken || branch_taken) begin
          i_drop_resp <= 1'b0;
          if (i_redirect_pending || trap_taken || branch_taken) begin
            pc_if <= trap_taken ? {mtvec_out[31:2], 2'b00}
                                : (branch_taken ? branch_target : i_redirect_pc);
            i_req <= 1'b1;
            i_redirect_pending <= 1'b0;
          end else begin
            i_req <= 1'b0;
          end
        end else begin
          i_buf_valid <= 1'b1;
          i_buf_pc <= pc_if;
          i_buf_instr <= imem_rdata;
          i_req <= 1'b0;
        end
      end else if (!i_buf_valid && i_req && imem_gnt) begin
        i_req <= 1'b0;
        i_wait_resp <= 1'b1;
      end else if (!i_req && !i_wait_resp && !i_buf_valid && !i_redirect_pending) begin
        i_req <= 1'b1;
      end
    end
  end

  assign i_addr = pc_if;

  // IF/ID pipeline register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_id          <= 32'h0;
      instr_id       <= 32'h00000013;  // NOP (ADDI x0, x0, 0)
      instr_valid_id <= 1'b0;
    end else if (id_flush) begin
      instr_id       <= 32'h00000013;  // NOP
      instr_valid_id <= 1'b0;  // Squashed by branch/trap
    end else if (!id_stall) begin
      if (i_valid) begin
        pc_id          <= i_pc_data;
        instr_id       <= i_rdata;
        instr_valid_id <= 1'b1;  // Real instruction loaded
      end
    end
  end

  // ID/EX pipeline register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_ex           <= 32'h0;
      instr_ex        <= 32'h0;
      rd_ex           <= 5'h0;
      rs1_ex          <= 5'h0;
      rs2_ex          <= 5'h0;
      funct3_ex       <= 3'h0;
      imm_ex          <= 32'h0;
      use_imm_ex      <= 1'b0;
      alu_op_valid_ex <= 1'b0;
      alu_op_ex       <= 4'h0;
      mem_read_ex     <= 1'b0;
      mem_write_ex    <= 1'b0;
      reg_write_ex    <= 1'b0;
      branch_ex       <= 1'b0;
      jump_ex         <= 1'b0;
      is_jalr_ex      <= 1'b0;
      illegal_ex      <= 1'b0;
      lui_ex          <= 1'b0;
      auipc_ex        <= 1'b0;
      csr_op_ex       <= CSR_OP_NONE;
      csr_wen_ex      <= 1'b0;
      is_csr_ex       <= 1'b0;
      is_mret_ex      <= 1'b0;
      use_zimm_ex     <= 1'b0;
      is_ecall_ex     <= 1'b0;
      is_ebreak_ex    <= 1'b0;
      instr_valid_ex  <= 1'b0;
    end else if (ex_stall) begin
      // Backpressure from MEM stage — freeze ID/EX
    end else if (ex_flush) begin
      reg_write_ex   <= 1'b0;
      mem_read_ex    <= 1'b0;
      mem_write_ex   <= 1'b0;
      branch_ex      <= 1'b0;
      jump_ex        <= 1'b0;
      is_jalr_ex     <= 1'b0;
      lui_ex         <= 1'b0;
      auipc_ex       <= 1'b0;
      csr_wen_ex     <= 1'b0;
      is_csr_ex      <= 1'b0;
      is_mret_ex     <= 1'b0;
      illegal_ex     <= 1'b0;
      is_ecall_ex    <= 1'b0;
      is_ebreak_ex   <= 1'b0;
      instr_valid_ex <= 1'b0;  // Trap squashes the faulting instruction
    end else if (load_use_hazard || if_wait) begin
      // Insert bubble: load-use hazard or IF waiting for instruction
      reg_write_ex    <= 1'b0;
      mem_read_ex     <= 1'b0;
      mem_write_ex    <= 1'b0;
      branch_ex       <= 1'b0;
      jump_ex         <= 1'b0;
      is_jalr_ex      <= 1'b0;
      lui_ex          <= 1'b0;
      auipc_ex        <= 1'b0;
      alu_op_valid_ex <= 1'b0;
      rd_ex           <= 5'h0;
      csr_wen_ex      <= 1'b0;
      is_csr_ex       <= 1'b0;
      is_mret_ex      <= 1'b0;
      illegal_ex      <= 1'b0;
      is_ecall_ex     <= 1'b0;
      is_ebreak_ex    <= 1'b0;
      instr_valid_ex  <= 1'b0;  // Bubble inserted
    end else begin
      pc_ex           <= pc_id;
      instr_ex        <= instr_id;
      rd_ex           <= rd_id;
      rs1_ex          <= rs1_id;
      rs2_ex          <= rs2_id;
      funct3_ex       <= funct3_id;
      imm_ex          <= imm_id;
      use_imm_ex      <= use_imm_id;
      alu_op_valid_ex <= alu_op_valid_id;
      alu_op_ex       <= alu_op_id;
      mem_read_ex     <= mem_read_id;
      mem_write_ex    <= mem_write_id;
      reg_write_ex    <= reg_write_id;
      branch_ex       <= branch_id;
      jump_ex         <= jump_id;
      is_jalr_ex      <= is_jalr_id;
      illegal_ex      <= illegal_id;
      lui_ex          <= lui_id;
      auipc_ex        <= auipc_id;
      csr_op_ex       <= csr_op_id;
      csr_wen_ex      <= csr_wen_id;
      is_csr_ex       <= is_csr_id;
      is_mret_ex      <= is_mret_id;
      use_zimm_ex     <= use_zimm_id;
      is_ecall_ex     <= is_ecall_id;
      is_ebreak_ex    <= is_ebreak_id;
      instr_valid_ex  <= instr_valid_id;
    end
  end

  // EX/MEM pipeline register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_mem          <= 32'h0;
      rd_mem          <= 5'h0;
      mem_read_mem    <= 1'b0;
      mem_write_mem   <= 1'b0;
      reg_write_mem   <= 1'b0;
      mem_addr_mem    <= 32'h0;
      mem_wdata_mem   <= 32'h0;
      mem_size_mem    <= 2'b00;
      funct3_mem      <= 3'b000;
      instr_valid_mem <= 1'b0;
    end else if (trap_taken) begin
      // Trap squashes the faulting instruction — insert bubble
      mem_read_mem    <= 1'b0;
      mem_write_mem   <= 1'b0;
      reg_write_mem   <= 1'b0;
      rd_mem          <= 5'h0;
      instr_valid_mem <= 1'b0;  // Faulting instruction does not retire
    end else if (!mem_stall) begin
      pc_mem          <= pc_ex;
      rd_mem          <= rd_ex;
      mem_read_mem    <= mem_read_ex;
      mem_write_mem   <= mem_write_ex;
      reg_write_mem   <= reg_write_ex;
      mem_addr_mem    <= ex_result;
      funct3_mem      <= funct3_ex;
      instr_valid_mem <= instr_valid_ex;

      // Pass raw rs2 to mem_fe — sub-word positioning is handled there
      mem_wdata_mem   <= fwd_b;
      mem_size_mem    <= funct3_ex[1:0];  // Load/store size from EX stage
    end
  end

  // MEM/WB pipeline register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_wb          <= 5'h0;
      reg_write_wb   <= 1'b0;
      wb_data        <= 32'h0;
      instr_valid_wb <= 1'b0;
    end else if (fe_err && fe_rdata_valid) begin
      // Access fault: squash the faulting load/store from writing back
      rd_wb          <= 5'h0;
      reg_write_wb   <= 1'b0;
      wb_data        <= 32'h0;
      instr_valid_wb <= 1'b0;  // Faulting instruction does not retire
    end else if (!mem_stall) begin
      rd_wb          <= rd_mem;
      reg_write_wb   <= reg_write_mem;
      wb_data        <= mem_result;
      instr_valid_wb <= instr_valid_mem;
    end
  end

  // CSR module instantiation
  kv32_csr u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .csr_addr     (csr_addr_w),
      .csr_wdata    (csr_wdata_w),
      .csr_op       (csr_op_ex),
      .csr_wen      (csr_wen_gated),
      .is_csr       (is_csr_ex),
      .csr_rdata    (csr_rdata),
      .irq_external (irq_external_i),
      .irq_timer    (irq_timer_i),
      .irq_software (irq_software_i),
      .trap_taken   (trap_taken),
      .trap_pc      (trap_pc),
      .trap_cause   (trap_cause),
      .trap_val     (trap_val),
      // MRET: gated by !mem_stall so a stalled MRET doesn't fire
      // repeatedly. Load-use bubbles clear is_mret_ex via the ID/EX
      // register, so no extra gate is needed for that path. See the
      // csr_wen_gated comment above for the same reasoning.
      .mret_taken   (is_mret_ex && !mem_stall),
      .mtvec_out    (mtvec_out),
      .mepc_out     (mepc_out),
      .mstatus_mie  (mstatus_mie),
      .csr_illegal  (csr_illegal),
      .instr_retired(instr_retired)
  );

endmodule
