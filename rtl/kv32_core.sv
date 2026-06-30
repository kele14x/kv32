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
    ST_WRITEBACK,
    ST_PTW  // Page table walk (Phase 6)
  } state_t;

  state_t            state;

  // Current instruction's PC and instruction word
  logic       [31:0] pc_reg;
  logic       [31:0] instr_reg;

  // Fetch handshake tracking
  logic              fetch_req;
  logic              fetch_wait;

  // Latched results from EXEC (for MEM/WRITEBACK)
  logic       [31:0] ex_result_reg;
  logic       [31:0] rs2_data_reg;
  logic       [31:0] load_data_reg;  // Latched load data from mem_fe

  // Branch/jump redirect target (latched in EXEC, used in WRITEBACK)
  logic       [31:0] branch_target_reg;
  logic              branch_redirect;

  // Access fault from MEM state — prevents writeback on fault
  logic              trap_from_mem;

  // Current privilege mode (Phase 5: M/S/U support)
  priv_mode_t        priv_mode;

  // MMU signals (Phase 6: Sv32 virtual memory)
  logic              mmu_bypass;  // Translation bypass (bare mode or M-mode)
  logic              i_translated;  // Instruction translation ready
  logic              d_translated;  // Data translation ready
  logic              ptw_source;  // 0=from fetch, 1=from data (for return after PTW)
  logic              sfence_vma_pulse;  // sfence.vma pulse to MMU (registered)
  logic       [19:0] mmu_sfence_va;  // Virtual address for sfence (registered)
  logic       [ 8:0] mmu_sfence_asid;  // ASID for sfence (registered)

  // ===========================================================================
  // C extension: instruction alignment and decompression
  // ===========================================================================
  // With C extension, PC can be half-word-aligned (pc[1:0] = 00 or 10).
  // Always fetch full 32-bit words, then extract the instruction:
  // - pc[1]=0: instruction starts at bits[15:0]
  //   - bits[1:0] != 11: 16-bit compressed instruction
  //   - bits[1:0] == 11: 32-bit instruction
  // - pc[1]=1: instruction starts at bits[31:16]
  //   - bits[17:16] != 11: 16-bit compressed instruction
  //   - bits[17:16] == 11: 32-bit instruction straddling word boundary
  //     (requires second fetch of next word)
  // ===========================================================================

  logic              fetch_second;  // Second fetch needed for straddling
  logic       [15:0] instr_half;  // Upper half of straddling instruction
  logic              is_compressed_reg;  // Latched version for EXEC/MEM/WB

  // Word-align the fetch address
  logic       [31:0] fetch_addr;
  logic       [31:0] fetch_phys_addr;
  assign fetch_addr = fetch_second ? {pc_reg[31:2] + 30'd1, 2'b00} : {pc_reg[31:2], 2'b00};
  // Phase 6: translate instruction address (use physical PPN from MMU or pass-through)
  // Note: Sv32 produces 34-bit physical addresses (22-bit PPN + 12-bit offset).
  // We use only PPN[19:0] since our memory interface is 32-bit. If PPN[21:20] != 0,
  // mmu_i_above_4g fires and an access fault is raised (see trap detection below).
  assign fetch_phys_addr = mmu_i_tlb_hit ? {mmu_i_phys_ppn[19:0], pc_reg[11:0]} : fetch_addr;

  // ===========================================================================
  // Instruction memory interface (driven during FETCH state)
  // ===========================================================================

  // verilator lint_off UNUSEDSIGNAL
  logic i_err;
  // verilator lint_on UNUSEDSIGNAL

  // Phase 6: gate fetch on translation readiness, no page fault, no above-4G fault
  assign imem_req   = (state == ST_FETCH) && fetch_req && !fetch_wait && i_translated && !mmu_i_page_fault && !mmu_i_above_4g;
  assign imem_addr = fetch_phys_addr;
  assign imem_we = 1'b0;
  assign imem_size = 2'b10;  // always word
  assign imem_wdata = 32'h0;
  assign imem_be = 4'hF;
  assign imem_excl = 1'b0;
  assign i_err = imem_err;

  // ===========================================================================
  // Memory front-end
  // ===========================================================================

  // Internal data port signals (driven during MEM state)
  logic        d_req;
  logic [31:0] d_addr;
  logic        d_we;
  logic [ 1:0] d_size;
  logic [31:0] d_wdata;
  logic        d_excl;

  // Memory front-end outputs
  logic [31:0] fe_rdata;
  logic        fe_rdata_valid;
  logic        fe_err;

  // Phase 6: internal signals from kv32_mem_fe (before PTW bus mux)
  logic        fe_dmem_req;
  logic [31:0] fe_dmem_addr;
  logic        fe_dmem_we;
  logic [ 1:0] fe_dmem_size;
  logic [31:0] fe_dmem_wdata;
  logic [ 3:0] fe_dmem_be;
  logic        fe_dmem_excl;

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
      .excl       (d_excl),
      .rdata      (fe_rdata),
      .rdata_valid(fe_rdata_valid),
      .err        (fe_err),
      .dmem_req   (fe_dmem_req),
      .dmem_addr  (fe_dmem_addr),
      .dmem_we    (fe_dmem_we),
      .dmem_size  (fe_dmem_size),
      .dmem_wdata (fe_dmem_wdata),
      .dmem_be    (fe_dmem_be),
      .dmem_excl  (fe_dmem_excl),
      .dmem_gnt   (dmem_gnt),
      .dmem_ack   (dmem_ack),
      .dmem_rdata (dmem_rdata),
      .dmem_err   (dmem_err)
  );

  // Phase 6: bus mux — PTW drives dmem directly when in ST_PTW state
  assign dmem_req   = (state == ST_PTW) ? mmu_ptw_req : fe_dmem_req;
  assign dmem_addr  = (state == ST_PTW) ? mmu_ptw_addr : fe_dmem_addr;
  assign dmem_we    = (state == ST_PTW) ? mmu_ptw_we : fe_dmem_we;
  assign dmem_size  = (state == ST_PTW) ? 2'b10 : fe_dmem_size;  // PTW: always word
  assign dmem_wdata = (state == ST_PTW) ? mmu_ptw_wdata : fe_dmem_wdata;
  assign dmem_be    = (state == ST_PTW) ? 4'hF : fe_dmem_be;  // PTW: always full word
  assign dmem_excl  = (state == ST_PTW) ? 1'b0 : fe_dmem_excl;

  // ===========================================================================
  // Decompressor (C extension — expands 16-bit instructions to 32-bit)
  // ===========================================================================

  logic [31:0] instr_decompressed;
  logic        decomp_illegal;

  kv32_decompressor u_decompressor (
      .instr   (instr_reg[15:0]),
      .expanded(instr_decompressed),
      .illegal (decomp_illegal)
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
  /* verilator lint_off UNUSEDSIGNAL */
  logic csr_wen_id, is_csr_id, is_mret_id, is_sret_id, is_wfi_id, is_sfence_vma_id, use_zimm_id;
  /* verilator lint_on UNUSEDSIGNAL */
  logic is_ecall_id, is_ebreak_id;
  logic is_m_mul_id, is_m_div_id;
  logic is_lr_id, is_sc_id, is_amo_id;

  // Select decompressed or raw instruction for decoder
  logic [31:0] decoder_instr;
  assign decoder_instr = is_compressed_reg ? instr_decompressed : instr_reg;

  // Illegal if decompressor flagged it (for compressed instructions)
  logic illegal_combined;
  assign illegal_combined = (is_compressed_reg & decomp_illegal) | illegal_id;

  kv32_decoder u_decoder (
      .instr        (decoder_instr),
      .rd           (rd_id),
      .funct3       (funct3_id),
      .rs1          (rs1_id),
      .rs2          (rs2_id),
      .imm          (imm_id),
      .use_imm      (use_imm_id),
      .alu_op_valid (alu_op_valid_id),
      .alu_op       (alu_op_id),
      .mem_read     (mem_read_id),
      .mem_write    (mem_write_id),
      .reg_write    (reg_write_id),
      .branch       (branch_id),
      .jump         (jump_id),
      .is_jalr      (is_jalr_id),
      .illegal      (illegal_id),
      .lui          (lui_id),
      .auipc        (auipc_id),
      .csr_op       (csr_op_id),
      .csr_wen      (csr_wen_id),
      .is_csr       (is_csr_id),
      .is_mret      (is_mret_id),
      .is_sret      (is_sret_id),
      .is_wfi       (is_wfi_id),
      .is_sfence_vma(is_sfence_vma_id),
      .use_zimm     (use_zimm_id),
      .is_ecall     (is_ecall_id),
      .is_ebreak    (is_ebreak_id),
      .is_m_mul     (is_m_mul_id),
      .is_m_div     (is_m_div_id),
      .is_lr        (is_lr_id),
      .is_sc        (is_sc_id),
      .is_amo       (is_amo_id)
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
  // verilator lint_off UNUSEDSIGNAL
  logic        m_busy;
  // verilator lint_on UNUSEDSIGNAL
  logic        m_done;
  logic        m_unit_start;
  logic        m_started;  // Track that we've started the M-unit for this instruction

  // Start M-unit once when entering EXEC with an M-extension instruction.
  // m_started prevents re-triggering while the unit computes or while the
  // result is still in the DONE state.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_started <= 1'b0;
    end else if (state == ST_EXEC && (is_m_mul_id || is_m_div_id)) begin
      if (!m_started) begin
        m_started <= 1'b1;  // Mark that we've started
      end
    end else if (state != ST_EXEC) begin
      m_started <= 1'b0;  // Clear when leaving EXEC
    end
  end

  assign m_unit_start = (state == ST_EXEC) && (is_m_mul_id || is_m_div_id) && !m_started;

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
  // A extension: AMO compute unit + reservation register
  // ===========================================================================

  // AMO compute: combinational, takes latched read data and rs2
  logic [31:0] amo_result;
  logic [ 4:0] amo_funct5;

  kv32_amo_unit u_amo_unit (
      .old_val(load_data_reg),
      .rs2_val(rs2_data_reg),
      .funct5 (amo_funct5),
      .result (amo_result)
  );

  // Reservation register for LR.W / SC.W
  logic        reservation_valid;
  logic [31:0] reservation_addr;

  // SC result: 0 = success (reservation valid & address matches), 1 = failure
  // Latched in ST_MEM, used in ST_WRITEBACK
  logic [31:0] sc_result_reg;
  logic        sc_result_valid;

  // AMO phase FSM (read-modify-write within ST_MEM)
  typedef enum logic [1:0] {
    AMO_IDLE,
    AMO_READ_WAIT,    // Read phase in progress
    AMO_WRITE_ISSUE,  // Write phase ready to issue
    AMO_WRITE_WAIT    // Write phase in progress
  } amo_state_t;

  amo_state_t amo_state;

  // Reservation register update
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reservation_valid <= 1'b0;
      reservation_addr  <= 32'h0;
      sc_result_reg     <= 32'h1;
      sc_result_valid   <= 1'b0;
    end else if (state == ST_MEM && is_lr_id && fe_rdata_valid && !fe_err) begin
      // Successful LR.W: set reservation
      reservation_valid <= 1'b1;
      reservation_addr  <= ex_result_reg;
    end else if (state == ST_MEM && is_sc_id &&
                 (reservation_valid && reservation_addr == ex_result_reg) &&
                 fe_rdata_valid) begin
      // Successful SC.W: clear reservation (write committed), latch success result
      reservation_valid <= 1'b0;
      sc_result_reg     <= 32'h0;  // Success
      sc_result_valid   <= 1'b1;
    end else if (state == ST_MEM && is_sc_id &&
                 !(reservation_valid && reservation_addr == ex_result_reg)) begin
      // Failed SC.W (no reservation or mismatch): clear reservation, latch failure result
      reservation_valid <= 1'b0;
      sc_result_reg     <= 32'h1;  // Failure
      sc_result_valid   <= 1'b1;
    end else if (state == ST_MEM && !is_sc_id && !is_lr_id && mem_write_id &&
                 fe_rdata_valid && !fe_err &&
                 reservation_valid && ex_result_reg == reservation_addr) begin
      // Non-SC store to same address invalidates reservation
      reservation_valid <= 1'b0;
    end else if (state == ST_WRITEBACK) begin
      // Clear SC result valid when leaving ST_WRITEBACK
      sc_result_valid <= 1'b0;
    end
  end

  // AMO phase FSM update
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      amo_state  <= AMO_IDLE;
      amo_funct5 <= 5'h0;
    end else begin
      unique case (amo_state)
        AMO_IDLE: begin
          if (state == ST_MEM && is_amo_id) begin
            amo_funct5 <= instr_reg[31:27];
            amo_state  <= AMO_READ_WAIT;
          end
        end
        AMO_READ_WAIT: begin
          if (fe_rdata_valid) begin
            if (!fe_err) begin
              amo_state <= AMO_WRITE_ISSUE;
            end else begin
              amo_state <= AMO_IDLE;  // Error — abort
            end
          end
        end
        AMO_WRITE_ISSUE: begin
          // Hold d_req high until write completes
          if (fe_rdata_valid) begin
            amo_state <= AMO_IDLE;
          end
        end
        AMO_WRITE_WAIT: begin
          // This state is no longer used, but kept for enum completeness
          if (fe_rdata_valid) begin
            amo_state <= AMO_IDLE;
          end
        end
        default: amo_state <= AMO_IDLE;
      endcase
    end
  end

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
  logic [31:0] stvec_out;
  logic [31:0] medeleg_out;
  logic [31:0] mideleg_out;
  logic        mstatus_tsr;
  logic        mstatus_tw;
  logic        mstatus_tvm;
  logic        mstatus_sie;
  logic [ 1:0] mstatus_mpp;
  logic        mstatus_spp;
  logic        mstatus_mprv;  // Phase 6: MMU uses for data access privilege
  logic        mstatus_sum;  // Phase 6: S-mode can access U-pages (data only)
  logic        mstatus_mxr;  // Phase 6: Make executable pages readable
  logic        satp_mode;  // Phase 6: Translation mode (0=Bare, 1=Sv32)
  logic [ 8:0] satp_asid;  // Phase 6: Address space identifier
  logic [21:0] satp_ppn;  // Phase 6: Root page table PPN
  logic [31:0] sepc_out;  // Used in Stage 5 for SRET
  logic        irq_pending;  // Interrupt pending from CSR module
  logic [31:0] irq_cause;  // Cause value for pending interrupt
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

  // Trap routing: should this trap go to S-mode handler?
  logic        trap_to_smode;
  logic [31:0] trap_vector_pc;  // PC to redirect to (mtvec or stvec, direct or vectored)

  always_comb begin
    trap_taken = 1'b0;
    trap_pc = pc_reg;
    trap_cause = 32'h0;
    trap_val = 32'h0;

    // Asynchronous interrupt checking: at ST_FETCH boundary (between instructions)
    if (state == ST_FETCH && irq_pending && !fetch_req && !fetch_wait) begin
      trap_taken = 1'b1;
      trap_cause = irq_cause;
      trap_val   = 32'h0;
    end

    if (state == ST_EXEC) begin
      // EXEC-stage traps: privilege checks first, then breakpoint/ecall/illegal
      // MRET: only legal in M-mode
      if (is_mret_id && priv_mode != PRIV_M) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
        // SRET: illegal in U-mode, or in S-mode if mstatus.tsr=1
      end else if (is_sret_id && (priv_mode == PRIV_U ||
                                  (priv_mode == PRIV_S && mstatus_tsr))) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
        // WFI: traps if in S/U-mode with mstatus.tw=1
      end else if (is_wfi_id && priv_mode != PRIV_M && mstatus_tw) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
        // SFENCE.VMA: traps if in S-mode with mstatus.tvm=1
      end else if (is_sfence_vma_id && priv_mode == PRIV_S && mstatus_tvm) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
      end else if (is_ebreak_id) begin
        trap_taken = 1'b1;
        trap_cause = 32'd3;  // Breakpoint
        trap_val   = pc_reg;
      end else if (is_ecall_id) begin
        trap_taken = 1'b1;
        // ECALL cause varies by privilege level: 8=U, 9=S, 11=M
        trap_cause = (priv_mode == PRIV_U) ? 32'd8 : (priv_mode == PRIV_S) ? 32'd9 : 32'd11;
        trap_val   = 32'h0;
      end else if (illegal_combined || csr_illegal) begin
        trap_taken = 1'b1;
        trap_cause = 32'd2;  // Illegal instruction
        trap_val   = instr_reg;
      end else if ((is_lr_id || is_sc_id || is_amo_id) && ex_result[1:0] != 2'b00) begin
        // LR/SC/AMO address misalignment: must be word-aligned (bits[1:0] = 00)
        // LR uses cause 4 (load address misaligned), SC/AMO use cause 6 (store/AMO address misaligned)
        trap_taken = 1'b1;
        trap_cause = is_lr_id ? 32'd4 : 32'd6;
        trap_val   = ex_result;
      end else if (branch_taken && branch_target[0]) begin
        // H3: instruction-address-misaligned trap (cause 0)
        // With C extension, instructions can be half-word-aligned (bit[1:0] = 00 or 10)
        // but bit[0] must always be 0. JALR clears bit 0 with & ~32'h1, and
        // branch/jump immediates always have bit[0]=0, so this should never fire
        // in correct code — it's a safety net for software bugs.
        trap_taken = 1'b1;
        trap_cause = 32'd0;  // Instruction address misaligned
        trap_val   = branch_target;
      end
    end else if (state == ST_MEM) begin
      // MEM-stage access fault
      if (fe_err && fe_rdata_valid) begin
        trap_taken = 1'b1;
        trap_cause = mem_write_id ? 32'd7 : 32'd5;  // Store / Load access fault
        trap_val   = ex_result_reg;  // Faulting address
      end  // Phase 6: above-4G physical address (PPN[21:20] != 0)
      else if (!mmu_bypass && mmu_d_above_4g) begin
        trap_taken = 1'b1;
        trap_cause = mem_write_id ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT;
        trap_val   = ex_result_reg;  // Faulting virtual address
      end  // Phase 6: data page fault (from MMU TLB lookup)
      else if (!mmu_bypass && mmu_d_page_fault) begin
        trap_taken = 1'b1;
        trap_cause = mem_write_id ? EXC_STORE_PAGE_FAULT : EXC_LOAD_PAGE_FAULT;
        trap_val   = ex_result_reg;  // Faulting virtual address
      end
    end else if (state == ST_FETCH) begin
      // Phase 6: above-4G physical address (PPN[21:20] != 0)
      if (!mmu_bypass && mmu_i_above_4g) begin
        trap_taken = 1'b1;
        trap_cause = EXC_INSTR_ACCESS_FAULT;
        trap_val   = pc_reg;  // Faulting virtual PC
      end  // Phase 6: instruction page fault (from MMU TLB lookup)
      else if (!mmu_bypass && mmu_i_page_fault) begin
        trap_taken = 1'b1;
        trap_cause = EXC_INSTR_PAGE_FAULT;
        trap_val   = pc_reg;  // Faulting virtual PC
      end
    end
  end

  // -------------------------------------------------------------------------
  // Trap delegation: determine whether trap goes to S-mode or M-mode handler
  // -------------------------------------------------------------------------
  always_comb begin
    trap_to_smode = 1'b0;
    if (trap_taken) begin
      if (trap_cause[31]) begin
        // Interrupt: check mideleg
        if (priv_mode <= PRIV_S && mideleg_out[trap_cause[4:0]]) trap_to_smode = 1'b1;
      end else begin
        // Exception: check medeleg
        if (priv_mode <= PRIV_S && medeleg_out[trap_cause[4:0]]) trap_to_smode = 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Trap vector PC: compute redirect address (direct or vectored)
  // -------------------------------------------------------------------------
  always_comb begin
    if (trap_to_smode) begin
      // S-mode trap: use stvec
      if (trap_cause[31] && stvec_out[1:0] == 2'b01) begin
        // Vectored mode for interrupts: BASE + 4 * cause
        trap_vector_pc = {stvec_out[31:2], 2'b00} + {25'b0, trap_cause[4:0], 2'b00};
      end else begin
        trap_vector_pc = {stvec_out[31:2], 2'b00};
      end
    end else begin
      // M-mode trap: use mtvec
      if (trap_cause[31] && mtvec_out[1:0] == 2'b01) begin
        // Vectored mode for interrupts: BASE + 4 * cause
        trap_vector_pc = {mtvec_out[31:2], 2'b00} + {25'b0, trap_cause[4:0], 2'b00};
      end else begin
        trap_vector_pc = {mtvec_out[31:2], 2'b00};
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
        // MRET: return from M-mode trap
        // Privilege check: only legal in M-mode
        if (priv_mode != PRIV_M) begin
          // Illegal instruction trap
        end else begin
          branch_taken  = 1'b1;
          branch_target = mepc_out;
        end
      end else if (is_sret_id) begin
        // SRET: return from S-mode trap
        // Privilege check: illegal in U-mode, or in S-mode if mstatus.tsr=1
        if (priv_mode == PRIV_U) begin
          // Illegal instruction trap
        end else if (priv_mode == PRIV_S && mstatus_tsr) begin
          // Illegal instruction trap
        end else begin
          branch_taken  = 1'b1;
          branch_target = sepc_out;
        end
      end else if (is_wfi_id) begin
        // WFI: wait for interrupt
        // Privilege check: traps if executed in S/U-mode with mstatus.tw=1
        if (priv_mode != PRIV_M && mstatus_tw) begin
          // Illegal instruction trap (handled in trap detection)
        end else begin
          // NOP (no actual wait in this implementation)
        end
      end else if (is_sfence_vma_id) begin
        // SFENCE.VMA: fence TLB entries
        // Privilege check: traps if executed in S-mode with mstatus.tvm=1
        if (priv_mode == PRIV_S && mstatus_tvm) begin
          // Illegal instruction trap (handled in trap detection)
        end else begin
          // Phase 6: invalidate TLB entries via MMU
          // rs1 = virtual address (x0 = all addresses)
          // rs2 = ASID (x0 = all ASIDs)
          // Pulse is registered in the always_ff block
        end
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
      ex_result = pc_reg + (is_compressed_reg ? 32'd2 : 32'd4);  // For JAL/JALR link address
    end
  end

  // ===========================================================================
  // Data memory port (driven during MEM state)
  // ===========================================================================

  // Exclusive access hint for LR/SC (not for AMO — those are regular bus ops)
  assign d_excl = is_lr_id || is_sc_id;

  // Phase 6: translated data address (use physical PPN from MMU or pass-through)
  // Note: Sv32 produces 34-bit physical addresses. We use only PPN[19:0] since
  // our memory interface is 32-bit. If PPN[21:20] != 0, mmu_d_above_4g fires
  // and an access fault is raised (see trap detection below).
  logic [31:0] d_addr_translated;
  assign d_addr_translated = mmu_d_tlb_hit
                           ? {mmu_d_phys_ppn[19:0], ex_result_reg[11:0]}
                           : ex_result_reg;

  // Phase 6: gate data access on translation readiness, no page fault, no above-4G fault
  logic d_access_ok;
  assign d_access_ok = d_translated && !mmu_d_page_fault && !mmu_d_above_4g;

  always_comb begin
    if (state == ST_MEM) begin
      d_addr = d_addr_translated;  // Phase 6: use translated address
      d_size = funct3_id[1:0];  // LB/LH/LW/LBU/LHU or SB/SH/SW

      if (is_lr_id) begin
        // LR.W: simple load, reservation set on success
        d_req   = d_access_ok;
        d_we    = 1'b0;
        d_wdata = 32'h0;
      end else if (is_sc_id) begin
        // SC.W: conditional store (only if reservation valid & address matches & translation ok)
        d_req   = d_access_ok && reservation_valid && (reservation_addr == ex_result_reg);
        d_we    = 1'b1;
        d_wdata = rs2_data_reg;
      end else if (is_amo_id) begin
        // AMO*: read-modify-write, multi-phase
        unique case (amo_state)
          AMO_IDLE, AMO_READ_WAIT: begin
            // Read phase: load old value
            d_req   = d_access_ok;
            d_we    = 1'b0;
            d_wdata = 32'h0;
          end
          AMO_WRITE_ISSUE, AMO_WRITE_WAIT: begin
            // Write phase: store computed result
            d_req   = d_access_ok;
            d_we    = 1'b1;
            d_wdata = amo_result;
          end
          default: begin
            d_req   = 1'b0;
            d_we    = 1'b0;
            d_wdata = 32'h0;
          end
        endcase
      end else begin
        // Normal load/store
        d_req   = d_access_ok && (mem_read_id || mem_write_id);
        d_we    = mem_write_id;
        d_wdata = rs2_data_reg;
        d_size  = funct3_id[1:0];
      end
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

  assign regfile_we = (state == ST_WRITEBACK) && reg_write_id && !trap_from_mem;
  assign regfile_rd = rd_id;
  // Writeback mux: SC writes 0/1 (success/failure), loads/AMO write memory data
  assign regfile_wdata = (is_sc_id && sc_result_valid) ? sc_result_reg :
                         mem_read_id ? load_data_reg :
                         ex_result_reg;

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

  // sret_taken: same gating as mret_taken
  logic sret_taken;
  assign sret_taken = is_sret_id && (state == ST_EXEC);

  // ===========================================================================
  // CSR module instantiation
  // ===========================================================================

  /* verilator lint_off PINCONNECTEMPTY */
  kv32_csr u_csr (
      .clk            (clk),
      .rst_n          (rst_n),
      .priv_mode      (priv_mode),
      .csr_addr       (csr_addr_w),
      .csr_wdata      (csr_wdata_w),
      .csr_op         (csr_op_id),
      .csr_wen        (csr_wen_gated),
      .is_csr         (is_csr_id),
      .csr_rdata      (csr_rdata),
      .irq_external   (irq_external_i),
      .irq_timer      (irq_timer_i),
      .irq_software   (irq_software_i),
      .trap_taken     (trap_taken),
      .trap_pc        (trap_pc),
      .trap_cause     (trap_cause),
      .trap_val       (trap_val),
      .trap_to_smode  (trap_to_smode),
      .mret_taken     (mret_taken),
      .sret_taken     (sret_taken),
      .mtvec_out      (mtvec_out),
      .mepc_out       (mepc_out),
      .stvec_out      (stvec_out),
      .sepc_out       (sepc_out),
      .medeleg_out    (medeleg_out),
      .mideleg_out    (mideleg_out),
      .mstatus_mie    (mstatus_mie),
      .mstatus_sie_o  (mstatus_sie),
      .mstatus_mprv   (mstatus_mprv),
      .mstatus_tsr    (mstatus_tsr),
      .mstatus_tw     (mstatus_tw),
      .mstatus_tvm    (mstatus_tvm),
      .mstatus_mpp_out(mstatus_mpp),
      .mstatus_spp_out(mstatus_spp),
      .mstatus_sum_o  (mstatus_sum),
      .mstatus_mxr_o  (mstatus_mxr),
      .satp_mode      (satp_mode),
      .satp_asid      (satp_asid),
      .satp_ppn       (satp_ppn),
      .csr_illegal    (csr_illegal),
      .irq_pending    (irq_pending),
      .irq_cause      (irq_cause),
      .instr_retired  (instr_retired)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ===========================================================================
  // MMU (Phase 6: Sv32 virtual memory)
  // ===========================================================================

  // MMU internal signals
  /* verilator lint_off UNUSEDSIGNAL */
  logic [21:0] mmu_i_phys_ppn;
  logic        mmu_i_tlb_hit;
  logic        mmu_i_page_fault;
  logic [21:0] mmu_d_phys_ppn;
  logic        mmu_d_tlb_hit;
  logic        mmu_d_page_fault;
  // Phase 6: Sv32 produces 34-bit physical addresses (22-bit PPN + 12-bit offset).
  // PPN[21:20] != 0 means the physical address is above 4GB, which our 32-bit
  // memory interface cannot represent — raise an access fault.
  logic        mmu_i_above_4g;
  logic        mmu_d_above_4g;
  assign mmu_i_above_4g = mmu_i_tlb_hit && |mmu_i_phys_ppn[21:20];
  assign mmu_d_above_4g = mmu_d_tlb_hit && |mmu_d_phys_ppn[21:20];
  logic        mmu_ptw_start;
  logic [19:0] mmu_walk_vpn;
  logic [ 1:0] mmu_walk_access_type;
  logic        mmu_ptw_req;
  logic [31:0] mmu_ptw_addr;
  logic        mmu_ptw_we;
  logic [31:0] mmu_ptw_wdata;
  logic        mmu_ptw_gnt;
  logic        mmu_ptw_ack;
  logic [31:0] mmu_ptw_rdata;
  logic        mmu_ptw_err;
  logic        mmu_ptw_busy;  // unused: PTW state tracked via ptw_done/ptw_fault
  logic        mmu_ptw_done;
  logic        mmu_ptw_fault;
  logic [31:0] mmu_ptw_fault_cause;  // unused: trap cause from trap detection logic
  /* verilator lint_on UNUSEDSIGNAL */

  // Translation bypass: bare mode or M-mode (unless MPRV with MPP != M for data)
  always_comb begin
    // For instruction fetch: bypass if bare mode or M-mode
    mmu_bypass = !satp_mode || (priv_mode == PRIV_M);
  end

  // Translation ready signals
  assign i_translated = mmu_bypass || mmu_i_tlb_hit;
  assign d_translated = mmu_bypass || mmu_d_tlb_hit;

  kv32_mmu u_mmu (
      .clk             (clk),
      .rst_n           (rst_n),
      .satp_asid       (satp_asid),
      .satp_ppn        (satp_ppn),
      .mstatus_sum     (mstatus_sum),
      .mstatus_mxr     (mstatus_mxr),
      .mstatus_mprv    (mstatus_mprv),
      .mstatus_mpp     (mstatus_mpp),
      .priv_mode       (priv_mode),
      .i_vpn           (pc_reg[31:12]),
      .i_phys_ppn      (mmu_i_phys_ppn),
      .i_tlb_hit       (mmu_i_tlb_hit),
      .i_page_fault    (mmu_i_page_fault),
      .d_vpn           (ex_result_reg[31:12]),
      .d_phys_ppn      (mmu_d_phys_ppn),
      .d_tlb_hit       (mmu_d_tlb_hit),
      .d_page_fault    (mmu_d_page_fault),
      .ptw_start       (mmu_ptw_start),
      .walk_vpn        (mmu_walk_vpn),
      .walk_access_type(mmu_walk_access_type),
      .sfence_vma      (sfence_vma_pulse),
      .sfence_va       (mmu_sfence_va),
      .sfence_asid     (mmu_sfence_asid),
      .ptw_req         (mmu_ptw_req),
      .ptw_addr        (mmu_ptw_addr),
      .ptw_we          (mmu_ptw_we),
      .ptw_wdata       (mmu_ptw_wdata),
      .ptw_gnt         (mmu_ptw_gnt),
      .ptw_ack         (mmu_ptw_ack),
      .ptw_rdata       (mmu_ptw_rdata),
      .ptw_err         (mmu_ptw_err),
      .ptw_busy        (mmu_ptw_busy),
      .ptw_done        (mmu_ptw_done),
      .ptw_fault       (mmu_ptw_fault),
      .ptw_fault_cause (mmu_ptw_fault_cause)
  );

  // PTW bus routing: PTW uses dmem bus when in ST_PTW state
  assign mmu_ptw_gnt   = (state == ST_PTW) ? dmem_gnt : 1'b0;
  assign mmu_ptw_ack   = (state == ST_PTW) ? dmem_ack : 1'b0;
  assign mmu_ptw_rdata = dmem_rdata;
  assign mmu_ptw_err   = dmem_err;

  // ===========================================================================
  // Main FSM
  // ===========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state                <= ST_FETCH;
      pc_reg               <= 32'h0;
      instr_reg            <= 32'h0;
      fetch_req            <= 1'b1;
      fetch_wait           <= 1'b0;
      fetch_second         <= 1'b0;
      instr_half           <= 16'h0;
      is_compressed_reg    <= 1'b0;
      ex_result_reg        <= 32'h0;
      rs2_data_reg         <= 32'h0;
      load_data_reg        <= 32'h0;
      branch_target_reg    <= 32'h0;
      branch_redirect      <= 1'b0;
      trap_from_mem        <= 1'b0;
      priv_mode            <= PRIV_M;  // Boot in M-mode
      ptw_source           <= 1'b0;
      mmu_ptw_start        <= 1'b0;
      mmu_walk_vpn         <= 20'b0;
      mmu_walk_access_type <= 2'b0;
      sfence_vma_pulse     <= 1'b0;
    end else begin
      trap_from_mem <= 1'b0;  // Default: clear each cycle
      mmu_ptw_start <= 1'b0;  // PTW start is a pulse
      sfence_vma_pulse <= 1'b0;  // sfence.vma is a pulse

      unique case (state)
        ST_FETCH: begin
          // Check for pending interrupts before fetching
          // This is the "between instructions" boundary where async interrupts are taken
          if (trap_taken) begin
            // Interrupt pending: redirect to trap vector
            pc_reg     <= trap_vector_pc;
            priv_mode  <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req  <= 1'b1;
            fetch_wait <= 1'b0;
            // Stay in ST_FETCH to begin fetching from trap vector
          end else if (!mmu_bypass && mmu_i_above_4g) begin
            // Phase 6: Above-4G physical address — access fault
            trap_from_mem <= 1'b1;
            pc_reg        <= trap_vector_pc;
            priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req     <= 1'b1;
            fetch_wait    <= 1'b0;
            state         <= ST_FETCH;
          end else if (!mmu_bypass && mmu_i_page_fault) begin
            // Phase 6: Instruction page fault — take trap immediately
            // (trap detection logic will set trap_cause = 12)
            trap_from_mem <= 1'b1;
            pc_reg        <= trap_vector_pc;
            priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req     <= 1'b1;
            fetch_wait    <= 1'b0;
            state         <= ST_FETCH;
          end else if (!mmu_bypass && !mmu_i_tlb_hit && !fetch_req && !fetch_wait) begin
            // Phase 6: Instruction TLB miss — start page table walk
            ptw_source <= 1'b0;  // Came from fetch
            mmu_ptw_start <= 1'b1;
            mmu_walk_vpn <= pc_reg[31:12];
            mmu_walk_access_type <= 2'd0;  // EXEC (instruction fetch)
            state <= ST_PTW;
          end else begin
            // Normal fetch: handle imem handshake
            if (fetch_req && imem_gnt && !imem_ack) begin
              // Request granted but no ack yet — wait for ack
              fetch_req  <= 1'b0;
              fetch_wait <= 1'b1;
            end

            if (imem_ack) begin
              fetch_req  <= 1'b0;
              fetch_wait <= 1'b0;

              if (fetch_second) begin
                // Second fetch for straddling 32-bit instruction complete
                // Assemble: {second_word[15:0], first_word[31:16]}
                instr_reg         <= {imem_rdata[15:0], instr_half};
                is_compressed_reg <= 1'b0;
                fetch_second      <= 1'b0;
                state             <= ST_DECODE;
              end else if (pc_reg[1]) begin
                // pc[1]=1: instruction starts at upper halfword
                if (imem_rdata[17:16] != 2'b11) begin
                  // 16-bit compressed instruction in upper halfword
                  instr_reg         <= {16'h0, imem_rdata[31:16]};
                  is_compressed_reg <= 1'b1;
                  state             <= ST_DECODE;
                end else begin
                  // 32-bit instruction straddling word boundary
                  // Latch upper half, fetch next word for lower half
                  instr_half   <= imem_rdata[31:16];
                  fetch_second <= 1'b1;
                  // Stay in ST_FETCH — next fetch will get the second word
                end
              end else begin
                // pc[1]=0: instruction starts at lower halfword
                if (imem_rdata[1:0] != 2'b11) begin
                  // 16-bit compressed instruction in lower halfword
                  instr_reg         <= {16'h0, imem_rdata[15:0]};
                  is_compressed_reg <= 1'b1;
                  state             <= ST_DECODE;
                end else begin
                  // 32-bit instruction, fully contained in fetched word
                  instr_reg         <= imem_rdata;
                  is_compressed_reg <= 1'b0;
                  state             <= ST_DECODE;
                end
              end
            end else if (!fetch_req && !fetch_wait) begin
              // No request outstanding — issue one
              fetch_req <= 1'b1;
            end
          end
        end

        ST_DECODE: begin
          // Decode is combinational; regfile reads are combinational.
          // Advance to EXEC immediately.
          state <= ST_EXEC;
        end

        ST_EXEC: begin
          if (trap_taken) begin
            // Trap: redirect PC to trap vector, update privilege, return to FETCH
            pc_reg     <= trap_vector_pc;
            priv_mode  <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req  <= 1'b1;
            fetch_wait <= 1'b0;
            state      <= ST_FETCH;
          end else if (is_sfence_vma_id) begin
            // sfence.vma: invalidate TLB entries
            // Pulse the sfence signal for one cycle
            sfence_vma_pulse <= 1'b1;
            mmu_sfence_va    <= rs1_data[31:12];
            mmu_sfence_asid  <= rs2_data[8:0];
            state <= ST_WRITEBACK;  // Advance to writeback (no memory access)
          end else if (branch_taken) begin
            // Branch/jump/MRET/SRET: latch target and result, go to MEM (pass-through)
            // then WRITEBACK to write link register if needed
            branch_target_reg <= branch_target;
            branch_redirect   <= 1'b1;
            ex_result_reg     <= ex_result;
            rs2_data_reg      <= rs2_data;
            state             <= ST_MEM;

            // MRET/SRET: restore privilege mode from saved fields
            if (is_mret_id) begin
              priv_mode <= priv_mode_t'(mstatus_mpp);
            end else if (is_sret_id) begin
              priv_mode <= mstatus_spp ? PRIV_S : PRIV_U;
            end
          end else if ((is_m_mul_id || is_m_div_id) && !m_done) begin
            // M-unit still computing — stay in EXEC
          end else begin
            // Normal instruction or M-unit complete: latch EX result, advance to MEM
            ex_result_reg <= ex_result;
            rs2_data_reg  <= rs2_data;
            state         <= ST_MEM;
          end
        end

        ST_MEM: begin
          // Phase 6: Check for above-4G fault, data page fault, or TLB miss
          if (!mmu_bypass && mmu_d_above_4g) begin
            // Above-4G physical address — access fault
            trap_from_mem <= 1'b1;
            pc_reg        <= trap_vector_pc;
            priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req     <= 1'b1;
            fetch_wait    <= 1'b0;
            state         <= ST_FETCH;
          end else if (!mmu_bypass && mmu_d_page_fault) begin
            // Data page fault — take trap immediately
            trap_from_mem <= 1'b1;
            pc_reg        <= trap_vector_pc;
            priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req     <= 1'b1;
            fetch_wait    <= 1'b0;
            state         <= ST_FETCH;
          end else if (!mmu_bypass && !mmu_d_tlb_hit && (mem_read_id || mem_write_id)) begin
            // Data TLB miss — start page table walk
            ptw_source <= 1'b1;  // Came from data access
            mmu_ptw_start <= 1'b1;
            mmu_walk_vpn <= ex_result_reg[31:12];
            mmu_walk_access_type <= mem_write_id ? 2'd2 : 2'd1;  // STORE or LOAD
            state <= ST_PTW;
          end else if (is_amo_id) begin
            // AMO: multi-phase read-modify-write
            unique case (amo_state)
              AMO_READ_WAIT: begin
                if (fe_rdata_valid) begin
                  if (fe_err) begin
                    // Read phase failed
                    trap_from_mem <= 1'b1;
                    pc_reg        <= trap_vector_pc;
                    priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
                    fetch_req     <= 1'b1;
                    fetch_wait    <= 1'b0;
                    state         <= ST_FETCH;
                  end else begin
                    // Read succeeded, latch data and advance to write phase
                    load_data_reg <= fe_rdata;
                  end
                end
              end
              AMO_WRITE_ISSUE: begin
                if (fe_rdata_valid) begin
                  if (fe_err) begin
                    // Write phase failed
                    trap_from_mem <= 1'b1;
                    pc_reg        <= trap_vector_pc;
                    priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
                    fetch_req     <= 1'b1;
                    fetch_wait    <= 1'b0;
                    state         <= ST_FETCH;
                  end else begin
                    // Write succeeded, advance to writeback
                    state <= ST_WRITEBACK;
                  end
                end
              end
              default: ;  // AMO_IDLE, AMO_WRITE_WAIT: wait for state machine
            endcase
          end else if (is_sc_id) begin
            // SC: conditional store based on reservation
            if (!reservation_valid || reservation_addr != ex_result_reg) begin
              // Reservation failed: skip write, return 1 (failure)
              state <= ST_WRITEBACK;
            end else if (fe_rdata_valid) begin
              // Reservation succeeded: write completed
              if (fe_err) begin
                trap_from_mem <= 1'b1;
                pc_reg        <= trap_vector_pc;
                priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
                fetch_req     <= 1'b1;
                fetch_wait    <= 1'b0;
                state         <= ST_FETCH;
              end else begin
                state <= ST_WRITEBACK;
              end
            end
          end else begin
            // Normal load/store or LR
            if (fe_rdata_valid) begin
              // Memory operation complete — latch load data if it's a load
              if (mem_read_id) begin
                load_data_reg <= fe_rdata;
              end

              if (fe_err) begin
                trap_from_mem <= 1'b1;
                // Trap: redirect PC to trap vector, update privilege, return to FETCH (skip WRITEBACK)
                pc_reg        <= trap_vector_pc;
                priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
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
        end

        ST_WRITEBACK: begin
          // Update PC: use redirect target if branch was taken, else increment
          // Compressed instructions advance PC by 2, full instructions by 4
          if (branch_redirect) begin
            pc_reg          <= branch_target_reg;
            branch_redirect <= 1'b0;
          end else begin
            pc_reg <= pc_reg + (is_compressed_reg ? 32'd2 : 32'd4);
          end
          fetch_req  <= 1'b1;
          fetch_wait <= 1'b0;
          state      <= ST_FETCH;
        end

        // Phase 6: Page table walk state
        ST_PTW: begin
          // PTW is in progress (mmu_ptw_busy)
          // On completion, return to the original state (FETCH or MEM)
          if (mmu_ptw_done) begin
            // TLB filled, retry the original access
            if (ptw_source) begin
              // Came from ST_MEM — retry data access
              state <= ST_MEM;
            end else begin
              // Came from ST_FETCH — retry instruction fetch
              fetch_req <= 1'b1;
              state     <= ST_FETCH;
            end
          end else if (mmu_ptw_fault) begin
            // Page fault: take trap
            trap_from_mem <= 1'b1;
            pc_reg        <= trap_vector_pc;
            priv_mode     <= trap_to_smode ? PRIV_S : PRIV_M;
            fetch_req     <= 1'b1;
            fetch_wait    <= 1'b0;
            state         <= ST_FETCH;
          end
          // Otherwise stay in ST_PTW (PTW in progress)
        end

        default: begin
          state <= ST_FETCH;
        end
      endcase
    end
  end

endmodule
