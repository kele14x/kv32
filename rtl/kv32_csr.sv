// kv32_csr.sv — M-mode CSR register file (Phase 1)
// Implements RISC-V privileged spec M-mode CSRs for kv32 processor

module kv32_csr
  import kv32_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // CSR read/write port (from EX stage)
    input  logic [11:0] csr_addr,      // CSR address
    input  logic [31:0] csr_wdata,     // Write data (already computed by pipeline)
    input  logic [1:0]  csr_op,        // 00=none, 01=write(CSRRW), 10=set(CSRRS), 11=clear(CSRRC)
    input  logic        csr_wen,       // Write enable
    output logic [31:0] csr_rdata,     // Read data (read-before-write)

    // External interrupt inputs (from CLINT/PLIC)
    input  logic        irq_external,  // MEIP
    input  logic        irq_timer,     // MTIP
    input  logic        irq_software,  // MSIP

    // Trap interface (from pipeline)
    input  logic        trap_taken,    // A trap is being taken this cycle
    // verilator lint_off UNUSEDSIGNAL
    input  logic [31:0] trap_pc,       // PC of trapping instruction (bit0 unused: always 0 in RISC-V)
    // verilator lint_on UNUSEDSIGNAL
    input  logic [31:0] trap_cause,    // mcause value
    input  logic [31:0] trap_val,      // mtval value

    // MRET interface
    input  logic        mret_taken,    // MRET executing

    // Outputs to pipeline
    output logic [31:0] mtvec_out,     // For trap vector calculation
    output logic [31:0] mepc_out,      // For MRET return address
    output logic        mstatus_mie,   // Global M-mode interrupt enable

    // Retired instruction signal
    input  logic        instr_retired
);

    // -------------------------------------------------------------------------
    // CSR address constants
    // -------------------------------------------------------------------------
    localparam logic [11:0] CSR_MSTATUS    = 12'h300;
    localparam logic [11:0] CSR_MISA       = 12'h301;
    localparam logic [11:0] CSR_MIE        = 12'h304;
    localparam logic [11:0] CSR_MTVEC      = 12'h305;
    localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
    localparam logic [11:0] CSR_MSTATUSH   = 12'h310;
    localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
    localparam logic [11:0] CSR_MEPC       = 12'h341;
    localparam logic [11:0] CSR_MCAUSE     = 12'h342;
    localparam logic [11:0] CSR_MTVAL      = 12'h343;
    localparam logic [11:0] CSR_MIP        = 12'h344;
    localparam logic [11:0] CSR_MVENDORID  = 12'hF11;
    localparam logic [11:0] CSR_MARCHID    = 12'hF12;
    localparam logic [11:0] CSR_MIMPID     = 12'hF13;
    localparam logic [11:0] CSR_MHARTID    = 12'hF14;
    localparam logic [11:0] CSR_MCONFIGPTR = 12'hF15;
    localparam logic [11:0] CSR_MCYCLE     = 12'hB00;
    localparam logic [11:0] CSR_MINSTRET   = 12'hB02;
    localparam logic [11:0] CSR_MCYCLEH    = 12'hB80;
    localparam logic [11:0] CSR_MINSTRETH  = 12'hB82;

    // -------------------------------------------------------------------------
    // misa fixed value: MXL=01 (32-bit).
    // Phase 1: only the I extension is implemented.
    // Extensions bitmap (bits [25:0]): A=0, C=2, D=3, F=5, I=8, M=12, S=18, U=20.
    // Update this value as each extension lands.
    // -------------------------------------------------------------------------
    localparam logic [31:0] MISA_VAL = {2'b01, 4'b0000, 26'b00_0000_0000_0001_0000_0000_0000};

    // -------------------------------------------------------------------------
    // CSR storage registers
    // -------------------------------------------------------------------------

    // mstatus fields
    logic        mstatus_mpie;
    logic [1:0]  mstatus_mpp;

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
        19'b0,           // [31:13]
        mstatus_mpp,     // [12:11]
        3'b0,            // [10:8]
        mstatus_mpie,    // [7]
        3'b0,            // [6:4]
        mstatus_mie,     // [3]
        3'b0             // [2:0]
    };

    // mip: MSIP=bit3, MTIP=bit7, MEIP=bit11 (hardware-driven, read-only from CSR write)
    assign mip_rval = {
        20'b0,           // [31:12]
        irq_external,    // [11] MEIP
        3'b0,            // [10:8]
        irq_timer,       // [7] MTIP
        3'b0,            // [6:4]
        irq_software,    // [3] MSIP
        3'b0             // [2:0]
    };

    // -------------------------------------------------------------------------
    // CSR read (combinational, read-before-write)
    // -------------------------------------------------------------------------
    always_comb begin
        unique case (csr_addr)
            CSR_MSTATUS:    csr_rdata = mstatus_rval;
            CSR_MISA:       csr_rdata = MISA_VAL;
            CSR_MIE:        csr_rdata = mie_r;
            CSR_MTVEC:      csr_rdata = mtvec_r;
            CSR_MCOUNTEREN: csr_rdata = mcounteren_r;
            CSR_MSTATUSH:   csr_rdata = 32'h0;   // No big-endian support
            CSR_MSCRATCH:   csr_rdata = mscratch_r;
            CSR_MEPC:       csr_rdata = mepc_r;
            CSR_MCAUSE:     csr_rdata = mcause_r;
            CSR_MTVAL:      csr_rdata = mtval_r;
            CSR_MIP:        csr_rdata = mip_rval;
            // Identity CSRs — read-only, return 0 for this soft core
            CSR_MVENDORID:  csr_rdata = 32'h0;   // No commercial vendor
            CSR_MARCHID:    csr_rdata = 32'h0;   // No official architecture ID
            CSR_MIMPID:     csr_rdata = 32'h0;   // No implementation ID
            CSR_MHARTID:    csr_rdata = 32'h0;   // Single-hart: always hart 0
            CSR_MCONFIGPTR: csr_rdata = 32'h0;   // No configuration table
            CSR_MCYCLE:     csr_rdata = mcycle_r[31:0];
            CSR_MCYCLEH:    csr_rdata = mcycle_r[63:32];
            CSR_MINSTRET:   csr_rdata = minstret_r[31:0];
            CSR_MINSTRETH:  csr_rdata = minstret_r[63:32];
            default:        csr_rdata = 32'h0;  // Unimplemented CSR returns 0
        endcase
    end

    // -------------------------------------------------------------------------
    // Helper: compute new CSR value based on operation
    // -------------------------------------------------------------------------
    function automatic logic [31:0] csr_new_val(
        input logic [31:0] old_val,
        input logic [1:0]  op,
        input logic [31:0] wdata
    );
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
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b0;
            mstatus_mpp   <= 2'b11;
            mie_r         <= 32'h0;
            mtvec_r       <= 32'h0;
            mcounteren_r  <= 32'h0;
            mscratch_r    <= 32'h0;
            mepc_r        <= 32'h0;
            mcause_r      <= 32'h0;
            mtval_r       <= 32'h0;
            mcycle_r      <= 64'h0;
            minstret_r    <= 64'h0;
        end else begin
            // ------------------------------------------------------------------
            // Counters (always increment, structurally outside the
            // trap_taken > mret_taken > csr_wen priority chain below).
            //   - mcycle_r: increments every cycle (correct by definition).
            //   - minstret_r: increments when instr_retired is high.
            //     On a trap, the faulting instruction's WB slot is squashed
            //     (EX/MEM register cleared in kv32_core.sv), so
            //     instr_retired is low that cycle and the trapping
            //     instruction does NOT count toward minstret. This is the
            //     RISC-V-preferred behavior: a trapping instruction is not
            //     considered retired.
            // ------------------------------------------------------------------
            mcycle_r <= mcycle_r + 64'h1;

            if (instr_retired)
                minstret_r <= minstret_r + 64'h1;

            // ------------------------------------------------------------------
            // Trap taken: update mepc, mcause, mtval, mstatus fields
            // ------------------------------------------------------------------
            if (trap_taken) begin
                mepc_r        <= {trap_pc[31:1], 1'b0};  // bit0 always 0
                mcause_r      <= trap_cause;
                mtval_r       <= trap_val;
                mstatus_mpie  <= mstatus_mie;
                mstatus_mie   <= 1'b0;
                mstatus_mpp   <= 2'b11;  // M-mode only in Phase 1

            // ------------------------------------------------------------------
            // MRET: restore mstatus fields
            // ------------------------------------------------------------------
            end else if (mret_taken) begin
                mstatus_mie   <= mstatus_mpie;
                mstatus_mpie  <= 1'b1;
                mstatus_mpp   <= 2'b11;

            // ------------------------------------------------------------------
            // Normal CSR write instruction
            // ------------------------------------------------------------------
            end else if (csr_wen && (csr_op != CSR_OP_NONE)) begin
                unique case (csr_addr)
                    CSR_MSTATUS: begin
                        mstatus_mie  <= csr_new_val(mstatus_rval, csr_op, csr_wdata)[3];
                        mstatus_mpie <= csr_new_val(mstatus_rval, csr_op, csr_wdata)[7];
                        mstatus_mpp  <= csr_new_val(mstatus_rval, csr_op, csr_wdata)[12:11];
                    end
                    CSR_MISA: ; // Read-only, ignore write
                    CSR_MIE:
                        mie_r <= csr_new_val(mie_r, csr_op, csr_wdata);
                    CSR_MTVEC:
                        // MODE field [1:0] forced to 0 (Direct-only).
                        // Vectored mode (MODE=1) is not yet supported;
                        // implement when async interrupt-taking is added (Phase 5).
                        mtvec_r <= {csr_new_val(mtvec_r, csr_op, csr_wdata)[31:2], 2'b00};
                    CSR_MCOUNTEREN:
                        mcounteren_r <= csr_new_val(mcounteren_r, csr_op, csr_wdata);
                    CSR_MSTATUSH: ; // All zeros, no big-endian — ignore write
                    CSR_MSCRATCH:
                        mscratch_r <= csr_new_val(mscratch_r, csr_op, csr_wdata);
                    CSR_MEPC:
                        mepc_r <= {csr_new_val(mepc_r, csr_op, csr_wdata)[31:1], 1'b0};
                    CSR_MCAUSE:
                        mcause_r <= csr_new_val(mcause_r, csr_op, csr_wdata);
                    CSR_MTVAL:
                        mtval_r <= csr_new_val(mtval_r, csr_op, csr_wdata);
                    CSR_MIP: ; // Hardware-driven bits, writes ignored
                    CSR_MVENDORID: ; // Read-only, ignore write
                    CSR_MARCHID:   ; // Read-only, ignore write
                    CSR_MIMPID:    ; // Read-only, ignore write
                    CSR_MHARTID:   ; // Read-only, ignore write
                    CSR_MCONFIGPTR: ; // Read-only, ignore write
                    CSR_MCYCLE:
                        mcycle_r[31:0] <= csr_new_val(mcycle_r[31:0], csr_op, csr_wdata);
                    CSR_MCYCLEH:
                        mcycle_r[63:32] <= csr_new_val(mcycle_r[63:32], csr_op, csr_wdata);
                    CSR_MINSTRET:
                        minstret_r[31:0] <= csr_new_val(minstret_r[31:0], csr_op, csr_wdata);
                    CSR_MINSTRETH:
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
