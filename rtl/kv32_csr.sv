// kv32_csr.sv — CSR register file (Phase 5: M/S/U privilege modes)
// Implements RISC-V privileged spec CSRs for kv32 processor.
// M-mode CSRs, S-mode CSRs (restricted views + independent registers),
// delegation, extended mstatus, U-mode counter access gating.

module kv32_csr
  import kv32_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Current privilege mode
    input priv_mode_t priv_mode,

    // CSR read/write port (from EX stage)
    input  logic [11:0] csr_addr,   // CSR address
    input  logic [31:0] csr_wdata,  // Write data (already computed by pipeline)
    input  logic [ 1:0] csr_op,     // 00=none, 01=write(CSRRW), 10=set(CSRRS), 11=clear(CSRRC)
    input  logic        csr_wen,    // Write enable
    input  logic        is_csr,     // Instruction is a CSR access (gates legality)
    output logic [31:0] csr_rdata,  // Read data (read-before-write)

    // External interrupt inputs (from CLINT/PLIC)
    input logic irq_external,  // MEIP
    /* verilator lint_off UNUSEDSIGNAL */
    input logic irq_timer,     // MTIP (Phase 6: will be used for STIP)
    /* verilator lint_on UNUSEDSIGNAL */
    input logic irq_software,  // MSIP

    // Trap interface (from pipeline)
    input logic        trap_taken,  // A trap is being taken this cycle
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] trap_pc,     // PC of trapping instruction (bit0 always 0)
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [31:0] trap_cause,  // mcause/scause value
    input logic [31:0] trap_val,    // mtval/stval value
    input logic        trap_to_smode,  // Trap routed to S-mode handler

    // MRET/SRET interface
    input logic mret_taken,  // MRET executing
    input logic sret_taken,  // SRET executing

    // Outputs to pipeline
    output logic [31:0] mtvec_out,       // M-mode trap vector
    output logic [31:0] mepc_out,        // M-mode return address
    output logic [31:0] stvec_out,       // S-mode trap vector
    output logic [31:0] sepc_out,        // S-mode return address
    output logic [31:0] medeleg_out,     // Exception delegation bitmap
    output logic [31:0] mideleg_out,     // Interrupt delegation bitmap
    output logic        mstatus_mie,     // M-mode global interrupt enable
    output logic        mstatus_sie_o,   // S-mode global interrupt enable
    output logic        mstatus_mprv,    // Modify privilege (data access)
    output logic        mstatus_tsr,     // Trap SRET from S-mode
    output logic        mstatus_tw,      // Timeout WFI from S/U-mode
    output logic        mstatus_tvm,     // Trap satp access from S-mode
    output logic [ 1:0] mstatus_mpp_out, // M-mode previous privilege
    output logic        mstatus_spp_out, // S-mode previous privilege
    output logic        csr_illegal,     // CSR access is illegal (raises trap)

    // Interrupt pending interface
    output logic        irq_pending,     // An interrupt is pending and enabled
    output logic [31:0] irq_cause,       // Cause value for pending interrupt

    // Retired instruction signal
    input logic instr_retired
);

  // -------------------------------------------------------------------------
  // CSR address constants (M-mode only, not in package)
  // -------------------------------------------------------------------------
  localparam logic [11:0] CsrMstatus = 12'h300;
  localparam logic [11:0] CsrMisa = 12'h301;
  localparam logic [11:0] CsrMie = 12'h304;
  localparam logic [11:0] CsrMtvec = 12'h305;
  localparam logic [11:0] CsrMcounteren = 12'h306;
  localparam logic [11:0] CsrMstatush = 12'h310;
  localparam logic [11:0] CsrMscratch = 12'h340;
  localparam logic [11:0] CsrMepc = 12'h341;
  localparam logic [11:0] CsrMcause = 12'h342;
  localparam logic [11:0] CsrMtval = 12'h343;
  localparam logic [11:0] CsrMip = 12'h344;
  localparam logic [11:0] CsrMvendorid = 12'hF11;
  localparam logic [11:0] CsrMarchid = 12'hF12;
  localparam logic [11:0] CsrMimpid = 12'hF13;
  localparam logic [11:0] CsrMhartid = 12'hF14;
  localparam logic [11:0] CsrMconfigptr = 12'hF15;
  localparam logic [11:0] CsrMcycle = 12'hB00;
  localparam logic [11:0] CsrMinstret = 12'hB02;
  localparam logic [11:0] CsrMcycleh = 12'hB80;
  localparam logic [11:0] CsrMinstreth = 12'hB82;

  // -------------------------------------------------------------------------
  // misa fixed value: MXL=01 (32-bit).
  // Phase 5: I, M, C, A, S, U extensions.
  // Extensions bitmap (bits [25:0]): A=0, C=2, I=8, M=12, S=18, U=20.
  // = 0x141105
  // -------------------------------------------------------------------------
  localparam logic [31:0] MisaVal = {2'b01, 4'b0000, 26'b00_0001_0100_0001_0001_0000_0101};

  // -------------------------------------------------------------------------
  // sstatus mask: only these bits are visible/modified via sstatus CSR
  // SIE[1], SPIE[5], SPP[8], SUM[18], MXR[19]
  // -------------------------------------------------------------------------
  localparam logic [31:0] SstatusMask = 32'h000C_0122;

  // -------------------------------------------------------------------------
  // CSR storage registers
  // -------------------------------------------------------------------------

  // mstatus fields (all stored as individual bits for field-level masking)
  logic        mstatus_sie;    // [1]  S-mode interrupt enable
  // mstatus_mie is already declared as output port [3]
  logic        mstatus_spie;   // [5]  S-mode previous interrupt enable
  logic        mstatus_mpie;   // [7]  M-mode previous interrupt enable
  logic        mstatus_spp;    // [8]  S-mode previous privilege (1 bit)
  logic [ 1:0] mstatus_mpp;    // [12:11] M-mode previous privilege
  logic        mstatus_mprv_r; // [17] modify privilege (data access mode)
  logic        mstatus_sum;    // [18] supervisor user memory access
  logic        mstatus_mxr;    // [19] make executable readable
  logic        mstatus_tvm_r;  // [20] trap virtual memory (satp/SFENCE.VMA)
  logic        mstatus_tw_r;   // [21] timeout WFI
  logic        mstatus_tsr_r;  // [22] trap SRET from S-mode

  // M-mode trap CSRs
  logic [31:0] mie_r;
  logic [31:0] mtvec_r;
  logic [31:0] mcounteren_r;
  logic [31:0] mscratch_r;
  logic [31:0] mepc_r;
  logic [31:0] mcause_r;
  logic [31:0] mtval_r;

  // S-mode trap CSRs (independent registers)
  logic [31:0] stvec_r;
  logic [31:0] sscratch_r;
  logic [31:0] sepc_r;
  logic [31:0] scause_r;
  logic [31:0] stval_r;
  logic [31:0] scounteren_r;

  // Delegation CSRs
  logic [31:0] medeleg_r;  // Exception delegation bitmap
  logic [31:0] mideleg_r;  // Interrupt delegation bitmap

  // satp (storage only — translation is Phase 6)
  logic [31:0] satp_r;

  // mip: SSIP (bit 1) is software-writable
  logic        mip_ssip;

  // 64-bit cycle counter
  logic [63:0] mcycle_r;
  // 64-bit instret counter
  logic [63:0] minstret_r;

  // -------------------------------------------------------------------------
  // Reconstructed CSR read values
  // -------------------------------------------------------------------------
  logic [31:0] mstatus_rval;
  logic [31:0] mip_rval;

  // mstatus: all implemented fields
  assign mstatus_rval = {
    9'b0,           // [31:23]
    mstatus_tsr_r,  // [22]
    mstatus_tw_r,   // [21]
    mstatus_tvm_r,  // [20]
    mstatus_mxr,    // [19]
    mstatus_sum,    // [18]
    mstatus_mprv_r, // [17]
    4'b0,           // [16:13] (XS, FS — not implemented)
    mstatus_mpp,    // [12:11]
    2'b0,           // [10:9]
    mstatus_spp,    // [8]
    mstatus_mpie,   // [7]
    1'b0,           // [6]
    mstatus_spie,   // [5]
    1'b0,           // [4]
    mstatus_mie,    // [3]
    1'b0,           // [2]
    mstatus_sie,    // [1]
    1'b0            // [0]
  };

  // mip: hardware-driven + SSIP (software-writable)
  // SSIP[1]=software-writable, MSIP[3]=irq_software, MTIP[7]=irq_timer,
  // MEIP[11]=irq_external
  assign mip_rval = {
    20'b0,          // [31:12]
    irq_external,   // [11] MEIP (read-only)
    1'b0,           // [10]
    1'b0,           // [9]  SEIP (not implemented)
    1'b0,           // [8]
    irq_timer,      // [7]  MTIP (read-only)
    1'b0,           // [6]
    1'b0,           // [5]  STIP (not implemented)
    1'b0,           // [4]
    irq_software,   // [3]  MSIP (read-only)
    1'b0,           // [2]
    mip_ssip,       // [1]  SSIP (software-writable)
    1'b0            // [0]
  };

  // -------------------------------------------------------------------------
  // Interrupt pending logic
  // An interrupt is pending if (mip & mie) has any bits set, AND the
  // interrupt is enabled based on current privilege mode and global enable bits.
  // Priority order (highest to lowest): MEI, MSI, MTI, SEI, SSI, STI
  // -------------------------------------------------------------------------

  // Check if interrupts are globally enabled
  // In M-mode: need mstatus_mie
  // In S-mode: need mstatus_sie (for S-mode interrupts) or always enabled for M-mode interrupts
  // In U-mode: always enabled for M-mode interrupts, need mstatus_sie for S-mode interrupts
  logic mie_enabled;
  always_comb begin
    if (priv_mode == PRIV_M) begin
      mie_enabled = mstatus_mie;
    end else begin
      mie_enabled = 1'b1;  // M-mode interrupts always enabled in lower privilege modes
    end
  end

  logic sie_enabled;
  always_comb begin
    if (priv_mode == PRIV_S) begin
      sie_enabled = mstatus_sie;
    end else if (priv_mode == PRIV_U) begin
      sie_enabled = mstatus_sie;
    end else begin
      sie_enabled = 1'b0;  // S-mode interrupts not enabled in M-mode
    end
  end

  always_comb begin
    irq_pending = 1'b0;
    irq_cause = 32'h0;

    // Check M-mode interrupts (not delegated) in priority order
    // MEI (bit 11), MSI (bit 3), MTI (bit 7)
    if (mie_enabled && mip_rval[11] && mie_r[11] && !mideleg_r[11]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd11};  // MEI
    end else if (mie_enabled && mip_rval[3] && mie_r[3] && !mideleg_r[3]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd3};   // MSI
    end else if (mie_enabled && mip_rval[7] && mie_r[7] && !mideleg_r[7]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd7};   // MTI
    end
    // Check S-mode interrupts (delegated) in priority order
    // SEI (bit 9), SSI (bit 1), STI (bit 5)
    else if (sie_enabled && mip_rval[9] && mie_r[9] && mideleg_r[9]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd9};   // SEI
    end else if (sie_enabled && mip_rval[1] && mie_r[1] && mideleg_r[1]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd1};   // SSI
    end else if (sie_enabled && mip_rval[5] && mie_r[5] && mideleg_r[5]) begin
      irq_pending = 1'b1;
      irq_cause = {1'b1, 31'd5};   // STI
    end
  end

  // -------------------------------------------------------------------------
  // CSR legality check (combinational)
  // An access is illegal if:
  //   - the CSR address is not implemented, OR
  //   - the CSR is read-only and a write is attempted, OR
  //   - the current privilege mode is insufficient for the CSR.
  // -------------------------------------------------------------------------
  always_comb begin
    if (!is_csr) begin
      csr_illegal = 1'b0;
    end else begin
      unique case (csr_addr)
        // --- M-mode RW CSRs: require M-mode ---
        CsrMstatus, CsrMie, CsrMtvec, CsrMcounteren,
                CsrMscratch, CsrMepc, CsrMcause, CsrMtval, CsrMip,
                CsrMedeleg, CsrMideleg,
                CsrMcycle, CsrMcycleh, CsrMinstret, CsrMinstreth:
        csr_illegal = (priv_mode != PRIV_M);

        // --- M-mode read-only CSRs: require M-mode, write illegal ---
        CsrMisa, CsrMstatush, CsrMvendorid, CsrMarchid, CsrMimpid, CsrMhartid, CsrMconfigptr:
        csr_illegal = (priv_mode != PRIV_M) || csr_wen;

        // --- S-mode RW CSRs: require S-mode or above ---
        CsrSstatus, CsrSie, CsrStvec, CsrScounteren,
                CsrSscratch, CsrSepc, CsrScause, CsrStval, CsrSip:
        csr_illegal = (priv_mode == PRIV_U);

        // satp: requires S-mode, but trapped by TVM from S-mode
        CsrSatp:
        csr_illegal = (priv_mode == PRIV_U) || (priv_mode == PRIV_S && mstatus_tvm_r);

        // --- U-mode read-only counters: gated by mcounteren/scounteren ---
        CsrCycle, CsrCycleh, CsrInstret, CsrInstreth: begin
          if (priv_mode == PRIV_M) begin
            csr_illegal = 1'b0;  // M-mode always has access
          end else if (priv_mode == PRIV_S) begin
            // S-mode: gated by mcounteren
            // Cycle=bit0, Instret=bit2
            csr_illegal = (csr_addr == CsrCycle || csr_addr == CsrCycleh) ?
                          !mcounteren_r[0] : !mcounteren_r[2];
          end else begin  // PRIV_U
            // U-mode: gated by both mcounteren AND scounteren
            csr_illegal = (csr_addr == CsrCycle || csr_addr == CsrCycleh) ?
                          !(mcounteren_r[0] && scounteren_r[0]) :
                          !(mcounteren_r[2] && scounteren_r[2]);
          end
        end

        default: csr_illegal = 1'b1;  // unimplemented: any access illegal
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // CSR read (combinational, read-before-write)
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (csr_addr)
      // M-mode CSRs
      CsrMstatus:    csr_rdata = mstatus_rval;
      CsrMisa:       csr_rdata = MisaVal;
      CsrMie:        csr_rdata = mie_r;
      CsrMtvec:      csr_rdata = mtvec_r;
      CsrMcounteren: csr_rdata = mcounteren_r;
      CsrMstatush:   csr_rdata = 32'h0;  // No big-endian support
      CsrMscratch:   csr_rdata = mscratch_r;
      CsrMepc:       csr_rdata = mepc_r;
      CsrMcause:     csr_rdata = mcause_r;
      CsrMtval:      csr_rdata = mtval_r;
      CsrMip:        csr_rdata = mip_rval;
      CsrMedeleg:    csr_rdata = medeleg_r;
      CsrMideleg:    csr_rdata = mideleg_r;

      // Identity CSRs — read-only, return 0
      CsrMvendorid:  csr_rdata = 32'h0;
      CsrMarchid:    csr_rdata = 32'h0;
      CsrMimpid:     csr_rdata = 32'h0;
      CsrMhartid:    csr_rdata = 32'h0;
      CsrMconfigptr: csr_rdata = 32'h0;

      // M-mode counters
      CsrMcycle:     csr_rdata = mcycle_r[31:0];
      CsrMcycleh:    csr_rdata = mcycle_r[63:32];
      CsrMinstret:   csr_rdata = minstret_r[31:0];
      CsrMinstreth:  csr_rdata = minstret_r[63:32];

      // S-mode CSRs
      CsrSstatus:    csr_rdata = mstatus_rval & SstatusMask;
      CsrSie:        csr_rdata = mie_r & mideleg_r;
      CsrStvec:      csr_rdata = stvec_r;
      CsrScounteren: csr_rdata = scounteren_r;
      CsrSscratch:   csr_rdata = sscratch_r;
      CsrSepc:       csr_rdata = sepc_r;
      CsrScause:     csr_rdata = scause_r;
      CsrStval:      csr_rdata = stval_r;
      CsrSip:        csr_rdata = mip_rval & mideleg_r;
      CsrSatp:       csr_rdata = satp_r;

      // U-mode counter shadows (read-only)
      CsrCycle:      csr_rdata = mcycle_r[31:0];
      CsrCycleh:     csr_rdata = mcycle_r[63:32];
      CsrInstret:    csr_rdata = minstret_r[31:0];
      CsrInstreth:   csr_rdata = minstret_r[63:32];

      default:       csr_rdata = 32'h0;  // Unimplemented CSR returns 0
    endcase
  end

  // -------------------------------------------------------------------------
  // Helper: compute new CSR value based on operation
  // -------------------------------------------------------------------------
  function automatic logic [31:0] csr_new_val(input logic [31:0] old_val, input logic [1:0] op,
                                              input logic [31:0] wdata);
    unique case (op)
      CSR_OP_WRITE: csr_new_val = wdata;
      CSR_OP_SET:   csr_new_val = old_val | wdata;
      CSR_OP_CLEAR: csr_new_val = old_val & ~wdata;
      default:      csr_new_val = old_val;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // CSR write logic (sequential)
  // Priority: trap_taken > mret_taken > sret_taken > CSR write instruction
  // -------------------------------------------------------------------------
  // Temp for CSR write value: iverilog cannot bit/part-select a function
  // call return directly (e.g. csr_new_val(...)[3]), so cases that need a
  // slice assign the full result to newv first (blocking), then index it
  // for the non-blocking FF update.
  always_ff @(posedge clk or negedge rst_n) begin : csr_write_proc
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] newv;
    /* verilator lint_on UNUSEDSIGNAL */
    if (!rst_n) begin
      mstatus_sie  <= 1'b0;
      mstatus_mie  <= 1'b0;
      mstatus_spie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_spp  <= 1'b0;
      mstatus_mpp  <= 2'b11;
      mstatus_mprv_r <= 1'b0;
      mstatus_sum  <= 1'b0;
      mstatus_mxr  <= 1'b0;
      mstatus_tvm_r  <= 1'b0;
      mstatus_tw_r   <= 1'b0;
      mstatus_tsr_r  <= 1'b0;
      mie_r        <= 32'h0;
      mtvec_r      <= 32'h0;
      mcounteren_r <= 32'h0;
      mscratch_r   <= 32'h0;
      mepc_r       <= 32'h0;
      mcause_r     <= 32'h0;
      mtval_r      <= 32'h0;
      stvec_r      <= 32'h0;
      sscratch_r   <= 32'h0;
      sepc_r       <= 32'h0;
      scause_r     <= 32'h0;
      stval_r      <= 32'h0;
      scounteren_r <= 32'h0;
      medeleg_r    <= 32'h0;
      mideleg_r    <= 32'h0;
      satp_r       <= 32'h0;
      mip_ssip     <= 1'b0;
      mcycle_r     <= 64'h0;
      minstret_r   <= 64'h0;
    end else begin
      // ------------------------------------------------------------------
      // Counters: increment unless being written via CSR this cycle.
      // ------------------------------------------------------------------
      if (!(csr_wen && csr_op != CSR_OP_NONE && (csr_addr == CsrMcycle || csr_addr == CsrMcycleh)))
        mcycle_r <= mcycle_r + 64'h1;

      if (instr_retired &&
                !(csr_wen && csr_op != CSR_OP_NONE &&
                  (csr_addr == CsrMinstret || csr_addr == CsrMinstreth)))
        minstret_r <= minstret_r + 64'h1;

      // ------------------------------------------------------------------
      // Trap taken: update trap CSRs based on delegation
      // ------------------------------------------------------------------
      if (trap_taken) begin
        if (trap_to_smode) begin
          // S-mode trap: update sepc, scause, stval, sstatus fields
          sepc_r       <= {trap_pc[31:1], 1'b0};
          scause_r     <= trap_cause;
          stval_r      <= trap_val;
          mstatus_spie <= mstatus_sie;
          mstatus_sie  <= 1'b0;
          mstatus_spp  <= priv_mode[0];  // 1 if from S, 0 if from U
        end else begin
          // M-mode trap: update mepc, mcause, mtval, mstatus fields
          mepc_r       <= {trap_pc[31:1], 1'b0};
          mcause_r     <= trap_cause;
          mtval_r      <= trap_val;
          mstatus_mpie <= mstatus_mie;
          mstatus_mie  <= 1'b0;
          mstatus_mpp  <= priv_mode;
        end

        // ------------------------------------------------------------------
        // MRET: restore mstatus fields
        // ------------------------------------------------------------------
      end else if (mret_taken) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
        mstatus_mpp  <= 2'b11;  // Default to M after MRET (core updates priv_mode)
        mstatus_mprv_r <= (mstatus_mpp == PRIV_M) ? mstatus_mprv_r : 1'b0;

        // ------------------------------------------------------------------
        // SRET: restore sstatus fields
        // ------------------------------------------------------------------
      end else if (sret_taken) begin
        mstatus_sie  <= mstatus_spie;
        mstatus_spie <= 1'b1;
        mstatus_spp  <= 1'b0;  // SPP is 1 bit; clear after SRET

        // ------------------------------------------------------------------
        // Normal CSR write instruction
        // ------------------------------------------------------------------
      end else if (csr_wen && (csr_op != CSR_OP_NONE)) begin
        unique case (csr_addr)
          // --- M-mode mstatus: full write to all implemented fields ---
          CsrMstatus: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mstatus_rval, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mstatus_sie  <= newv[1];
            mstatus_mie  <= newv[3];
            mstatus_spie <= newv[5];
            mstatus_mpie <= newv[7];
            mstatus_spp  <= newv[8];
            mstatus_mpp  <= newv[12:11];
            mstatus_mprv_r <= newv[17];
            mstatus_sum  <= newv[18];
            mstatus_mxr  <= newv[19];
            mstatus_tvm_r  <= newv[20];
            mstatus_tw_r   <= newv[21];
            mstatus_tsr_r  <= newv[22];
          end

          // --- S-mode sstatus: masked write (only sstatus-visible bits) ---
          CsrSstatus: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mstatus_rval & SstatusMask, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            // Only update sstatus-visible bits; leave M-mode bits untouched
            mstatus_sie  <= newv[1];
            mstatus_spie <= newv[5];
            mstatus_spp  <= newv[8];
            mstatus_sum  <= newv[18];
            mstatus_mxr  <= newv[19];
          end

          CsrMisa: ; // Read-only, ignore write

          // --- M-mode mie: full write ---
          CsrMie:
                        mie_r <= csr_new_val(mie_r, csr_op, csr_wdata);

          // --- S-mode sie: masked write (only delegated bits) ---
          CsrSie: begin
            // Writes only modify mideleg-masked bits of mie
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mie_r & mideleg_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mie_r <= (mie_r & ~mideleg_r) | (newv & mideleg_r);
          end

          // --- mtvec: allow vectored mode (MODE=0 or MODE=1) ---
          CsrMtvec: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mtvec_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            // MODE[1:0]: only 0 (Direct) and 1 (Vectored) are valid
            mtvec_r <= (newv[1:0] == 2'b00 || newv[1:0] == 2'b01) ?
                       newv : {newv[31:2], 2'b00};
          end

          // --- stvec: same as mtvec ---
          CsrStvec: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(stvec_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            stvec_r <= (newv[1:0] == 2'b00 || newv[1:0] == 2'b01) ?
                       newv : {newv[31:2], 2'b00};
          end

          CsrMcounteren:
                        mcounteren_r <= csr_new_val(mcounteren_r, csr_op, csr_wdata);
          CsrScounteren:
                        scounteren_r <= csr_new_val(scounteren_r, csr_op, csr_wdata);
          CsrMstatush: ; // All zeros, no big-endian — ignore write
          CsrMscratch:
                        mscratch_r <= csr_new_val(mscratch_r, csr_op, csr_wdata);
          CsrSscratch:
                        sscratch_r <= csr_new_val(sscratch_r, csr_op, csr_wdata);
          CsrMepc: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mepc_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mepc_r <= {newv[31:1], 1'b0};
          end
          CsrSepc: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(sepc_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            sepc_r <= {newv[31:1], 1'b0};
          end
          CsrMcause:
                        mcause_r <= csr_new_val(mcause_r, csr_op, csr_wdata);
          CsrScause:
                        scause_r <= csr_new_val(scause_r, csr_op, csr_wdata);
          CsrMtval:
                        mtval_r <= csr_new_val(mtval_r, csr_op, csr_wdata);
          CsrStval:
                        stval_r <= csr_new_val(stval_r, csr_op, csr_wdata);

          // --- mip: only SSIP (bit 1) is software-writable ---
          CsrMip: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mip_rval, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mip_ssip <= newv[1];
          end

          // --- sip: masked view of mip (only delegated bits) ---
          CsrSip: begin
            // Only SSIP (bit 1, if delegated) is writable via sip
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mip_rval & mideleg_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            if (mideleg_r[1]) mip_ssip <= newv[1];
          end

          // --- Delegation CSRs ---
          // medeleg: bit 11 (ECALL from M) hardwired 0 — M-mode ECALLs cannot be delegated
          CsrMedeleg: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(medeleg_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            medeleg_r <= newv & ~32'h0000_0800;  // Clear bit 11
          end

          // mideleg: bits 3,7,11 (M-mode interrupts) hardwired 0
          CsrMideleg: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mideleg_r, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mideleg_r <= newv & ~32'h0000_0888;  // Clear bits 3,7,11
          end

          // satp: storage only (translation is Phase 6)
          CsrSatp:
                        satp_r <= csr_new_val(satp_r, csr_op, csr_wdata);

          // Read-only CSRs — ignore writes
          CsrMvendorid: ;
          CsrMarchid:   ;
          CsrMimpid:    ;
          CsrMhartid:   ;
          CsrMconfigptr: ;

          // M-mode counters
          CsrMcycle:
                        mcycle_r[31:0] <= csr_new_val(mcycle_r[31:0], csr_op, csr_wdata);
          CsrMcycleh:
                        mcycle_r[63:32] <= csr_new_val(mcycle_r[63:32], csr_op, csr_wdata);
          CsrMinstret:
                        minstret_r[31:0] <= csr_new_val(minstret_r[31:0], csr_op, csr_wdata);
          CsrMinstreth:
                        minstret_r[63:32] <= csr_new_val(minstret_r[63:32], csr_op, csr_wdata);

          default: ; // Unimplemented CSR, ignore write
        endcase
      end
    end
  end

  // -------------------------------------------------------------------------
  // Output assignments
  // -------------------------------------------------------------------------
  assign mtvec_out       = mtvec_r;
  assign mepc_out        = mepc_r;
  assign stvec_out       = stvec_r;
  assign sepc_out        = sepc_r;
  assign medeleg_out     = medeleg_r;
  assign mideleg_out     = mideleg_r;
  assign mstatus_sie_o   = mstatus_sie;
  assign mstatus_mprv    = mstatus_mprv_r;
  assign mstatus_tsr     = mstatus_tsr_r;
  assign mstatus_tw      = mstatus_tw_r;
  assign mstatus_tvm     = mstatus_tvm_r;
  assign mstatus_mpp_out = mstatus_mpp;
  assign mstatus_spp_out = mstatus_spp;

endmodule
