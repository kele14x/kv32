// kv32_csr.sv — M-mode CSR register file (Phase 1)
// Implements RISC-V privileged spec M-mode CSRs for kv32 processor

module kv32_csr
  import kv32_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // CSR read/write port (from EX stage)
    input  logic [11:0] csr_addr,   // CSR address
    input  logic [31:0] csr_wdata,  // Write data (already computed by pipeline)
    input  logic [ 1:0] csr_op,     // 00=none, 01=write(CSRRW), 10=set(CSRRS), 11=clear(CSRRC)
    input  logic        csr_wen,    // Write enable
    input  logic        is_csr,     // Instruction is a CSR access (gates legality)
    output logic [31:0] csr_rdata,  // Read data (read-before-write)

    // External interrupt inputs (from CLINT/PLIC)
    input logic irq_external,  // MEIP
    input logic irq_timer,     // MTIP
    input logic irq_software,  // MSIP

    // Trap interface (from pipeline)
    input logic        trap_taken,  // A trap is being taken this cycle
    // verilator lint_off UNUSEDSIGNAL
    // PC of trapping instruction (bit0 unused: always 0 in RISC-V)
    input logic [31:0] trap_pc,
    // verilator lint_on UNUSEDSIGNAL
    input logic [31:0] trap_cause,  // mcause value
    input logic [31:0] trap_val,    // mtval value

    // MRET interface
    input logic mret_taken,  // MRET executing

    // Outputs to pipeline
    output logic [31:0] mtvec_out,    // For trap vector calculation
    output logic [31:0] mepc_out,     // For MRET return address
    output logic        mstatus_mie,  // Global M-mode interrupt enable
    output logic        csr_illegal,  // CSR access is illegal (raises trap)

    // Retired instruction signal
    input logic instr_retired
);

  // -------------------------------------------------------------------------
  // CSR address constants
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
  // Phase 1: only the I extension is implemented.
  // Extensions bitmap (bits [25:0]): A=0, C=2, D=3, F=5, I=8, M=12, S=18, U=20.
  // Update this value as each extension lands.
  // -------------------------------------------------------------------------
  localparam logic [31:0] MisaVal = {2'b01, 4'b0000, 26'b00_0000_0000_0000_0001_0000_0000};

  // -------------------------------------------------------------------------
  // CSR storage registers
  // -------------------------------------------------------------------------

  // mstatus fields
  logic        mstatus_mpie;
  logic [ 1:0] mstatus_mpp;

  // Other CSRs
  logic [31:0] mie_r;
  logic [31:0] mtvec_r;
  logic [31:0] mcounteren_r;
  logic [31:0] mscratch_r;
  logic [31:0] mepc_r;
  logic [31:0] mcause_r;
  logic [31:0] mtval_r;

  // 64-bit cycle counter
  logic [63:0] mcycle_r;
  // 64-bit instret counter
  logic [63:0] minstret_r;

  // -------------------------------------------------------------------------
  // Reconstructed CSR read values
  // -------------------------------------------------------------------------
  logic [31:0] mstatus_rval;
  logic [31:0] mip_rval;

  // mstatus: MIE=bit3, MPIE=bit7, MPP=bits[12:11]
  // All other fields are 0 (no big-endian, no FP, no VM)
  assign mstatus_rval = {
    19'b0,  // [31:13]
    mstatus_mpp,  // [12:11]
    3'b0,  // [10:8]
    mstatus_mpie,  // [7]
    3'b0,  // [6:4]
    mstatus_mie,  // [3]
    3'b0  // [2:0]
  };

  // mip: MSIP=bit3, MTIP=bit7, MEIP=bit11 (hardware-driven, read-only from CSR write)
  assign mip_rval = {
    20'b0,  // [31:12]
    irq_external,  // [11] MEIP
    3'b0,  // [10:8]
    irq_timer,  // [7] MTIP
    3'b0,  // [6:4]
    irq_software,  // [3] MSIP
    3'b0  // [2:0]
  };

  // -------------------------------------------------------------------------
  // CSR legality check (combinational)
  // An access is illegal if:
  //   - the CSR address is not implemented, OR
  //   - the CSR is read-only and a write is attempted.
  // Read-only CSRs are those with addr[11:10]==2'b11 (mvendorid/marchid/
  // mimpid/mhartid/mconfigptr here). Writes to them raise illegal
  // instruction. CSRRS/CSRRC with rs1=x0 suppress csr_wen in the decoder,
  // so a read of a read-only CSR is legal. Unimplemented CSRs trap on
  // any access (read or write) — software is expected to use the
  // trap-and-skip pattern (set mtvec to the next insn before probing).
  // -------------------------------------------------------------------------
  always_comb begin
    if (!is_csr) begin
      csr_illegal = 1'b0;  // not a CSR instruction
    end else begin
      unique case (csr_addr)
        CsrMstatus, CsrMisa, CsrMie, CsrMtvec, CsrMcounteren, CsrMstatush,
                CsrMscratch, CsrMepc, CsrMcause, CsrMtval, CsrMip,
                CsrMcycle, CsrMcycleh, CsrMinstret, CsrMinstreth:
        csr_illegal = 1'b0;  // implemented, read-write
        CsrMvendorid, CsrMarchid, CsrMimpid, CsrMhartid, CsrMconfigptr:
        csr_illegal = csr_wen;  // read-only: write is illegal
        default: csr_illegal = 1'b1;  // unimplemented: any access illegal
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // CSR read (combinational, read-before-write)
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (csr_addr)
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
      // Identity CSRs — read-only, return 0 for this soft core
      CsrMvendorid:  csr_rdata = 32'h0;  // No commercial vendor
      CsrMarchid:    csr_rdata = 32'h0;  // No official architecture ID
      CsrMimpid:     csr_rdata = 32'h0;  // No implementation ID
      CsrMhartid:    csr_rdata = 32'h0;  // Single-hart: always hart 0
      CsrMconfigptr: csr_rdata = 32'h0;  // No configuration table
      CsrMcycle:     csr_rdata = mcycle_r[31:0];
      CsrMcycleh:    csr_rdata = mcycle_r[63:32];
      CsrMinstret:   csr_rdata = minstret_r[31:0];
      CsrMinstreth:  csr_rdata = minstret_r[63:32];
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
  // Priority: trap_taken > mret_taken > CSR write instruction
  // -------------------------------------------------------------------------
  // Temp for CSR write value: iverilog cannot bit/part-select a function
  // call return directly (e.g. csr_new_val(...)[3]), so cases that need a
  // slice assign the full result to newv first (blocking), then index it
  // for the non-blocking FF update. The blocking assignment is safe: newv
  // is a local temp with no cross-cycle state; its value is computed and
  // consumed within the same clock edge.
  always_ff @(posedge clk or negedge rst_n) begin : csr_write_proc
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] newv;
    /* verilator lint_on UNUSEDSIGNAL */
    if (!rst_n) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mstatus_mpp  <= 2'b11;
      mie_r        <= 32'h0;
      mtvec_r      <= 32'h0;
      mcounteren_r <= 32'h0;
      mscratch_r   <= 32'h0;
      mepc_r       <= 32'h0;
      mcause_r     <= 32'h0;
      mtval_r      <= 32'h0;
      mcycle_r     <= 64'h0;
      minstret_r   <= 64'h0;
    end else begin
      // ------------------------------------------------------------------
      // Counters: increment unless being written via CSR this cycle.
      //   - mcycle_r: increments every cycle (unless CSR-written).
      //   - minstret_r: increments when instr_retired is high
      //     (unless CSR-written).
      //
      // The write-suppress guard is needed because the counter
      // increment (full 64-bit non-blocking) and the CSR write
      // (partial 32-bit non-blocking) would otherwise conflict —
      // the increment would clobber the written value on the same
      // clock edge.
      //
      // On a trap, the faulting instruction's WB slot is squashed
      // (EX/MEM register cleared in kv32_core.sv), so
      // instr_retired is low that cycle and the trapping
      // instruction does NOT count toward minstret. This is the
      // RISC-V-preferred behavior: a trapping instruction is not
      // considered retired.
      // ------------------------------------------------------------------
      if (!(csr_wen && csr_op != CSR_OP_NONE && (csr_addr == CsrMcycle || csr_addr == CsrMcycleh)))
        mcycle_r <= mcycle_r + 64'h1;

      if (instr_retired &&
                !(csr_wen && csr_op != CSR_OP_NONE &&
                  (csr_addr == CsrMinstret || csr_addr == CsrMinstreth)))
        minstret_r <= minstret_r + 64'h1;

      // ------------------------------------------------------------------
      // Trap taken: update mepc, mcause, mtval, mstatus fields
      // ------------------------------------------------------------------
      if (trap_taken) begin
        mepc_r       <= {trap_pc[31:1], 1'b0};  // bit0 always 0
        mcause_r     <= trap_cause;
        mtval_r      <= trap_val;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
        mstatus_mpp  <= 2'b11;  // M-mode only in Phase 1

        // ------------------------------------------------------------------
        // MRET: restore mstatus fields
        // ------------------------------------------------------------------
      end else if (mret_taken) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
        mstatus_mpp  <= 2'b11;

        // ------------------------------------------------------------------
        // Normal CSR write instruction
        // ------------------------------------------------------------------
      end else if (csr_wen && (csr_op != CSR_OP_NONE)) begin
        unique case (csr_addr)
          CsrMstatus: begin
            /* verilator lint_off BLKSEQ */
            newv = csr_new_val(mstatus_rval, csr_op, csr_wdata);
            /* verilator lint_on BLKSEQ */
            mstatus_mie  <= newv[3];
            mstatus_mpie <= newv[7];
            mstatus_mpp  <= newv[12:11];
          end
          CsrMisa: ; // Read-only, ignore write
          CsrMie:
                        mie_r <= csr_new_val(mie_r, csr_op, csr_wdata);
          CsrMtvec:
                        // MODE field [1:0] forced to 0 (Direct-only).
                        // Vectored mode (MODE=1) is not yet supported;
                        // implement when async interrupt-taking is added (Phase 5).
                        begin
                            /* verilator lint_off BLKSEQ */
                            newv = csr_new_val(mtvec_r, csr_op, csr_wdata);
                            /* verilator lint_on BLKSEQ */
                            mtvec_r <= {newv[31:2], 2'b00};
                        end
          CsrMcounteren:
                        mcounteren_r <= csr_new_val(mcounteren_r, csr_op, csr_wdata);
          CsrMstatush: ; // All zeros, no big-endian — ignore write
          CsrMscratch:
                        mscratch_r <= csr_new_val(mscratch_r, csr_op, csr_wdata);
          CsrMepc:
                        begin
                            /* verilator lint_off BLKSEQ */
                            newv = csr_new_val(mepc_r, csr_op, csr_wdata);
                            /* verilator lint_on BLKSEQ */
                            mepc_r <= {newv[31:1], 1'b0};
                        end
          CsrMcause:
                        mcause_r <= csr_new_val(mcause_r, csr_op, csr_wdata);
          CsrMtval:
                        mtval_r <= csr_new_val(mtval_r, csr_op, csr_wdata);
          CsrMip: ; // Hardware-driven bits, writes ignored
          CsrMvendorid: ; // Read-only, ignore write
          CsrMarchid:   ; // Read-only, ignore write
          CsrMimpid:    ; // Read-only, ignore write
          CsrMhartid:   ; // Read-only, ignore write
          CsrMconfigptr: ; // Read-only, ignore write
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
  assign mtvec_out = mtvec_r;
  assign mepc_out  = mepc_r;

endmodule
