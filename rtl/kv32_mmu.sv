// kv32_mmu.sv — Sv32 MMU (Phase 6: virtual memory)
// Two-level page table walker, ITLB/DTLB (16 entries each, direct-mapped),
// permission checking with SUM/MXR/MPRV overrides, hardware A/D bit update.
//
// Reference: RISC-V Privileged Spec v20211203, Chapter 4 (Supervisor-Level ISA)

module kv32_mmu
  import kv32_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // CSR inputs (from kv32_csr)
    input logic [ 8:0] satp_asid,  // Address space identifier
    input logic [21:0] satp_ppn,   // Root page table physical PPN

    input logic       mstatus_sum,   // S-mode can access U-pages (data only)
    input logic       mstatus_mxr,   // Make executable pages readable
    input logic       mstatus_mprv,  // Modify privilege for data access
    input logic [1:0] mstatus_mpp,   // M-mode previous privilege

    input priv_mode_t priv_mode,  // Current privilege mode

    // Instruction TLB lookup (from core, ST_FETCH)
    input  logic [19:0] i_vpn,        // Virtual page number (pc_reg[31:12])
    output logic [21:0] i_phys_ppn,   // Translated physical PPN
    output logic        i_tlb_hit,    // Translation cached in ITLB
    output logic        i_page_fault, // Permission/alignment fault

    // Data TLB lookup (from core, ST_MEM)
    input  logic [19:0] d_vpn,        // Virtual page number (ex_result_reg[31:12])
    output logic [21:0] d_phys_ppn,   // Translated physical PPN
    output logic        d_tlb_hit,    // Translation cached in DTLB
    output logic        d_page_fault, // Permission/alignment fault

    // PTW control (from core)
    input logic        ptw_start,        // Start page table walk (pulse)
    input logic [19:0] walk_vpn,         // VPN to walk
    input logic [ 1:0] walk_access_type, // 0=EXEC, 1=LOAD, 2=STORE

    // sfence.vma (from core, ST_EXEC)
    input logic        sfence_vma,  // Invalidation pulse
    input logic [19:0] sfence_va,   // Virtual address (rs1[31:12], x0=all)
    input logic [ 8:0] sfence_asid, // ASID (rs2[8:0], x0=all)

    // PTW bus interface (to core mux → kv32_mem_fe)
    output logic        ptw_req,    // Memory request
    output logic [31:0] ptw_addr,   // PTE address (word-aligned)
    output logic        ptw_we,     // Write enable (A/D bit update)
    output logic [31:0] ptw_wdata,  // PTE data to write
    input  logic        ptw_gnt,    // Bus grant
    input  logic        ptw_ack,    // Bus response (rdata valid / write complete)
    input  logic [31:0] ptw_rdata,  // PTE read data
    input  logic        ptw_err,    // Bus error

    // PTW status (to core)
    output logic        ptw_busy,        // Walk in progress, core should stall
    output logic        ptw_done,        // Walk complete, TLB filled (pulse)
    output logic        ptw_fault,       // Walk faulted (pulse)
    output logic [31:0] ptw_fault_cause  // 12=instr, 13=load, 15=store page fault
);

  // =========================================================================
  // TLB structure (16 entries, direct-mapped, indexed by vpn[3:0])
  // =========================================================================

  localparam TLB_ENTRIES = 16;
  localparam TLB_IDX_W = 4;  // log2(16)

  typedef struct packed {
    logic        valid;
    logic        g;
    logic [8:0]  asid;
    logic [19:0] vpn;
    logic [21:0] ppn;
    logic        r;
    logic        w;
    logic        x;
    logic        u;
    logic        psize;  // 0=4KiB, 1=4MiB (superpage)
  } tlb_entry_t;

  tlb_entry_t                 itlb    [TLB_ENTRIES];
  tlb_entry_t                 dtlb    [TLB_ENTRIES];

  // =========================================================================
  // ITLB lookup (combinational)
  // =========================================================================

  logic       [TLB_IDX_W-1:0] i_idx;
  logic                       i_match;
  logic                       i_valid;
  /* verilator lint_off UNUSEDSIGNAL */
  // i_entry.r and i_entry.w are stored but unused for instruction fetch (only .x needed)
  tlb_entry_t                 i_entry;

  assign i_idx = i_vpn[TLB_IDX_W-1:0];
  assign i_entry = itlb[i_idx];
  /* verilator lint_on UNUSEDSIGNAL */

  // Match: valid && (global || asid match) && vpn match
  assign i_match = i_entry.valid &&
                   (i_entry.g || (i_entry.asid == satp_asid)) &&
                   (i_entry.vpn == i_vpn);

  assign i_valid = i_match;

  // Output PPN (replace upper VPN bits with PPN)
  assign i_phys_ppn = i_entry.psize ? {i_entry.ppn[21:10], i_vpn[9:0]}  // 4MiB superpage
      : i_entry.ppn;  // 4KiB page

  assign i_tlb_hit = i_valid;

  // =========================================================================
  // Instruction permission checker (combinational)
  // =========================================================================

  // Effective privilege for instruction fetch is always priv_mode
  // (MPRV only affects data accesses)
  logic i_exec_ok;
  logic i_priv_ok;

  assign i_exec_ok = i_entry.x;

  // Privilege check:
  // - U-page (U=1): only U-mode can execute
  // - S-page (U=0): S-mode or M-mode can execute
  always_comb begin
    if (i_entry.u) begin
      // U-page: only U-mode
      i_priv_ok = (priv_mode == PRIV_U);
    end else begin
      // S-page: S-mode or M-mode
      i_priv_ok = (priv_mode == PRIV_S || priv_mode == PRIV_M);
    end
  end

  assign i_page_fault = i_tlb_hit && (!i_exec_ok || !i_priv_ok);

  // =========================================================================
  // DTLB lookup (combinational)
  // =========================================================================

  logic       [TLB_IDX_W-1:0] d_idx;
  logic                       d_match;
  logic                       d_valid;
  tlb_entry_t                 d_entry;

  assign d_idx = d_vpn[TLB_IDX_W-1:0];
  assign d_entry = dtlb[d_idx];

  assign d_match = d_entry.valid &&
                   (d_entry.g || (d_entry.asid == satp_asid)) &&
                   (d_entry.vpn == d_vpn);

  assign d_valid = d_match;

  assign d_phys_ppn = d_entry.psize ? {d_entry.ppn[21:10], d_vpn[9:0]}  // 4MiB superpage
      : d_entry.ppn;  // 4KiB page

  assign d_tlb_hit = d_valid;

  // =========================================================================
  // Data permission checker (combinational)
  // =========================================================================

  // Effective privilege: MPRV overrides for data accesses
  priv_mode_t d_effective_priv;
  logic       d_access_ok;
  logic       d_priv_ok;

  always_comb begin
    // MPRV: use MPP as effective privilege for data accesses
    if (mstatus_mprv) d_effective_priv = priv_mode_t'(mstatus_mpp);
    else d_effective_priv = priv_mode;
  end

  always_comb begin
    // Access type check (LOAD vs STORE vs EXEC)
    // EXEC doesn't go through DTLB (uses ITLB), so only LOAD/STORE here
    case (walk_access_type)
      2'd1:    d_access_ok = d_entry.r || (mstatus_mxr && d_entry.x);  // LOAD: R or (MXR && X)
      2'd2:    d_access_ok = d_entry.w;  // STORE: W
      default: d_access_ok = 1'b0;  // EXEC shouldn't be here
    endcase
  end

  always_comb begin
    // Privilege check
    if (d_entry.u) begin
      // U-page: U-mode always OK, S-mode with SUM (data only, not EXEC)
      if (d_effective_priv == PRIV_U) d_priv_ok = 1'b1;
      else if (d_effective_priv == PRIV_S && mstatus_sum)
        d_priv_ok = 1'b1;  // SUM allows S-mode data access to U-pages
      else d_priv_ok = 1'b0;
    end else begin
      // S-page: S-mode or M-mode
      d_priv_ok = (d_effective_priv == PRIV_S || d_effective_priv == PRIV_M);
    end
  end

  assign d_page_fault = d_tlb_hit && (!d_access_ok || !d_priv_ok);

  // =========================================================================
  // PTW FSM
  // =========================================================================

  typedef enum logic [2:0] {
    PTW_IDLE,     // Waiting for ptw_start
    PTW_REQ,      // Issue read/write request
    PTW_WAIT,     // Wait for grant
    PTW_CHECK,    // Parse PTE, check validity/permissions
    PTW_WR_REQ,   // Issue write for A/D bit update
    PTW_WR_WAIT,  // Wait for write grant
    PTW_DONE      // Walk complete (one-cycle pulse)
  } ptw_state_t;

  ptw_state_t ptw_state, ptw_state_next;

  // PTW registers
  logic [19:0] ptw_vpn;  // VPN being walked
  logic [ 1:0] ptw_level;  // Current level (1 or 0)
  logic [ 1:0] ptw_atype;  // Access type for this walk
  logic [31:0] ptw_pte_addr;  // Address of current PTE
  logic [31:0] ptw_pte_data;  // PTE read from memory

  // PTE field extraction
  logic [21:0] pte_ppn;
  logic pte_v, pte_r, pte_w, pte_x, pte_u, pte_g, pte_a, pte_d;
  logic pte_valid, pte_leaf, pte_reserved;

  assign pte_ppn      = ptw_pte_data[31:10];
  assign pte_v        = ptw_pte_data[0];
  assign pte_r        = ptw_pte_data[1];
  assign pte_w        = ptw_pte_data[2];
  assign pte_x        = ptw_pte_data[3];
  assign pte_u        = ptw_pte_data[4];
  assign pte_g        = ptw_pte_data[5];
  assign pte_a        = ptw_pte_data[6];
  assign pte_d        = ptw_pte_data[7];

  // PTE validity checks
  assign pte_valid    = pte_v && !(pte_w && !pte_r);  // V=1, not (W=1 && R=0)
  assign pte_leaf     = pte_r || pte_x;  // R=1 or X=1 → leaf
  assign pte_reserved = !pte_valid;  // Invalid or reserved

  // A/D bit update logic
  logic ptw_need_a_update;
  logic ptw_need_d_update;
  logic [31:0] ptw_pte_updated;

  assign ptw_need_a_update = pte_leaf && !pte_a;
  assign ptw_need_d_update = pte_leaf && (ptw_atype == 2'd2) && !pte_d;  // Store needs D

  // Updated PTE with A/D bits set
  assign ptw_pte_updated = {
    ptw_pte_data[31:8],
    ptw_pte_data[7] | ptw_need_d_update,  // D bit
    1'b1,  // A bit (always set)
    ptw_pte_data[5:0]
  };

  // PTW bus outputs
  assign ptw_req = (ptw_state == PTW_REQ) || (ptw_state == PTW_WR_REQ);
  assign ptw_addr = ptw_pte_addr;
  assign ptw_we = (ptw_state == PTW_WR_REQ);
  assign ptw_wdata = ptw_pte_updated;

  assign ptw_busy = (ptw_state != PTW_IDLE);
  assign ptw_done = (ptw_state == PTW_DONE);

  // PTW FSM transitions
  always_comb begin
    ptw_state_next = ptw_state;

    unique case (ptw_state)
      PTW_IDLE: begin
        if (ptw_start) ptw_state_next = PTW_REQ;
      end

      PTW_REQ: begin
        if (ptw_gnt) ptw_state_next = PTW_WAIT;
      end

      PTW_WAIT: begin
        if (ptw_ack) ptw_state_next = PTW_CHECK;
      end

      PTW_CHECK: begin
        if (pte_reserved || ptw_err) begin
          // Fault: invalid PTE or bus error
          ptw_state_next = PTW_IDLE;
        end else if (!pte_leaf) begin
          // Non-leaf: descend to next level
          if (ptw_level == 2'd1) ptw_state_next = PTW_REQ;  // Go to level 0
          else ptw_state_next = PTW_IDLE;  // Error: non-leaf at level 0
        end else begin
          // Leaf PTE
          if (ptw_need_a_update || ptw_need_d_update)
            ptw_state_next = PTW_WR_REQ;  // Update A/D bits
          else ptw_state_next = PTW_DONE;  // Walk complete
        end
      end

      PTW_WR_REQ: begin
        if (ptw_gnt) ptw_state_next = PTW_WR_WAIT;
      end

      PTW_WR_WAIT: begin
        if (ptw_ack) ptw_state_next = PTW_DONE;
      end

      PTW_DONE: begin
        ptw_state_next = PTW_IDLE;  // One-cycle pulse, return to idle
      end

      default: ptw_state_next = PTW_IDLE;
    endcase
  end

  // PTW register updates
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptw_state    <= PTW_IDLE;
      ptw_vpn      <= 20'b0;
      ptw_level    <= 2'b0;
      ptw_atype    <= 2'b0;
      ptw_pte_addr <= 32'b0;
      ptw_pte_data <= 32'b0;
    end else begin
      ptw_state <= ptw_state_next;

      // On ptw_start: initialize walk at level 1
      if (ptw_start) begin
        ptw_vpn      <= walk_vpn;
        ptw_level    <= 2'd1;
        ptw_atype    <= walk_access_type;
        // PTE address: (satp_ppn << 12) + (vpn[1] << 2)
        ptw_pte_addr <= {satp_ppn, 10'b0} + {20'b0, walk_vpn[19:10], 2'b00};
      end

      // On non-leaf at level 1: descend to level 0
      if (ptw_state == PTW_CHECK && !pte_leaf && ptw_level == 2'd1) begin
        ptw_level    <= 2'd0;
        // PTE address: (pte_ppn << 12) + (vpn[0] << 2)
        ptw_pte_addr <= {pte_ppn, 10'b0} + {20'b0, ptw_vpn[9:0], 2'b00};
      end

      // On PTE read: latch data
      if (ptw_state == PTW_WAIT && ptw_ack) ptw_pte_data <= ptw_rdata;
    end
  end

  // PTW fault detection
  logic ptw_fault_pending;
  logic [31:0] ptw_fault_cause_r;

  always_comb begin
    ptw_fault_pending = 1'b0;
    ptw_fault_cause_r = 32'b0;

    if (ptw_state == PTW_CHECK) begin
      // Invalid PTE or reserved encoding
      if (pte_reserved || ptw_err) begin
        ptw_fault_pending = 1'b1;
        ptw_fault_cause_r = (ptw_atype == 2'd0) ? EXC_INSTR_PAGE_FAULT :
                            (ptw_atype == 2'd1) ? EXC_LOAD_PAGE_FAULT :
                                                   EXC_STORE_PAGE_FAULT;
      end  // Non-leaf at level 0 (shouldn't happen)
      else if (!pte_leaf && ptw_level == 2'd0) begin
        ptw_fault_pending = 1'b1;
        ptw_fault_cause_r = (ptw_atype == 2'd0) ? EXC_INSTR_PAGE_FAULT :
                            (ptw_atype == 2'd1) ? EXC_LOAD_PAGE_FAULT :
                                                   EXC_STORE_PAGE_FAULT;
      end  // Leaf at level 1: check superpage alignment (PPN[0] must be 0)
      else if (pte_leaf && ptw_level == 2'd1 && pte_ppn[9:0] != 10'b0) begin
        ptw_fault_pending = 1'b1;
        ptw_fault_cause_r = (ptw_atype == 2'd0) ? EXC_INSTR_PAGE_FAULT :
                            (ptw_atype == 2'd1) ? EXC_LOAD_PAGE_FAULT :
                                                   EXC_STORE_PAGE_FAULT;
      end  // Permission check (reusing logic from data permission checker)
      else if (pte_leaf) begin
        // Simplified permission check for PTW
        priv_mode_t eff_priv;
        logic access_ok, priv_ok;

        eff_priv = mstatus_mprv ? priv_mode_t'(mstatus_mpp) : priv_mode;

        case (ptw_atype)
          2'd0: access_ok = pte_x;
          2'd1: access_ok = pte_r || (mstatus_mxr && pte_x);
          2'd2: access_ok = pte_w;
          default: access_ok = 1'b0;
        endcase

        if (pte_u) begin
          if (eff_priv == PRIV_U) priv_ok = 1'b1;
          else if (eff_priv == PRIV_S && ptw_atype != 2'd0 && mstatus_sum)
            priv_ok = 1'b1;  // SUM for data only
          else priv_ok = 1'b0;
        end else begin
          priv_ok = (eff_priv == PRIV_S || eff_priv == PRIV_M);
        end

        if (!access_ok || !priv_ok) begin
          ptw_fault_pending = 1'b1;
          ptw_fault_cause_r = (ptw_atype == 2'd0) ? EXC_INSTR_PAGE_FAULT :
                              (ptw_atype == 2'd1) ? EXC_LOAD_PAGE_FAULT :
                                                     EXC_STORE_PAGE_FAULT;
        end
      end
    end
  end

  assign ptw_fault       = ptw_fault_pending && (ptw_state == PTW_CHECK);
  assign ptw_fault_cause = ptw_fault_cause_r;

  // =========================================================================
  // TLB fill (on PTW completion)
  // =========================================================================

  logic tlb_fill_itlb;
  logic tlb_fill_dtlb;

  assign tlb_fill_itlb = (ptw_state == PTW_DONE) && (ptw_atype == 2'd0);
  assign tlb_fill_dtlb = (ptw_state == PTW_DONE) && (ptw_atype != 2'd0);

  // ITLB write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TLB_ENTRIES; i++) begin
        itlb[i].valid <= 1'b0;
      end
    end else begin
      if (tlb_fill_itlb) begin
        itlb[ptw_vpn[TLB_IDX_W-1:0]].valid <= 1'b1;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].g     <= pte_g;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].asid  <= pte_g ? 9'b0 : satp_asid;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].vpn   <= ptw_vpn;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].ppn   <= pte_ppn;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].r     <= pte_r;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].w     <= pte_w;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].x     <= pte_x;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].u     <= pte_u;
        itlb[ptw_vpn[TLB_IDX_W-1:0]].psize <= (ptw_level == 2'd1);
      end

      // sfence.vma invalidation
      if (sfence_vma) begin
        for (int i = 0; i < TLB_ENTRIES; i++) begin
          logic invalidate;
          invalidate = 1'b0;

          if (itlb[i].valid && !itlb[i].g) begin
            // Check if this entry should be invalidated
            if (sfence_va == 20'b0 && sfence_asid == 9'b0) begin
              // rs1=x0, rs2=x0: invalidate all non-global
              invalidate = 1'b1;
            end else if (sfence_va != 20'b0 && sfence_asid == 9'b0) begin
              // rs1≠x0, rs2=x0: invalidate matching VPN (all ASIDs)
              invalidate = (itlb[i].vpn == sfence_va);
            end else if (sfence_va == 20'b0 && sfence_asid != 9'b0) begin
              // rs1=x0, rs2≠x0: invalidate matching ASID (all VPNs)
              invalidate = (itlb[i].asid == sfence_asid);
            end else begin
              // rs1≠x0, rs2≠x0: invalidate matching both
              invalidate = (itlb[i].vpn == sfence_va) && (itlb[i].asid == sfence_asid);
            end
          end

          if (invalidate) itlb[i].valid <= 1'b0;
        end
      end
    end
  end

  // DTLB write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TLB_ENTRIES; i++) begin
        dtlb[i].valid <= 1'b0;
      end
    end else begin
      if (tlb_fill_dtlb) begin
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].valid <= 1'b1;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].g     <= pte_g;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].asid  <= pte_g ? 9'b0 : satp_asid;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].vpn   <= ptw_vpn;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].ppn   <= pte_ppn;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].r     <= pte_r;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].w     <= pte_w;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].x     <= pte_x;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].u     <= pte_u;
        dtlb[ptw_vpn[TLB_IDX_W-1:0]].psize <= (ptw_level == 2'd1);
      end

      // sfence.vma invalidation
      if (sfence_vma) begin
        for (int i = 0; i < TLB_ENTRIES; i++) begin
          logic invalidate;
          invalidate = 1'b0;

          if (dtlb[i].valid && !dtlb[i].g) begin
            if (sfence_va == 20'b0 && sfence_asid == 9'b0) invalidate = 1'b1;
            else if (sfence_va != 20'b0 && sfence_asid == 9'b0)
              invalidate = (dtlb[i].vpn == sfence_va);
            else if (sfence_va == 20'b0 && sfence_asid != 9'b0)
              invalidate = (dtlb[i].asid == sfence_asid);
            else invalidate = (dtlb[i].vpn == sfence_va) && (dtlb[i].asid == sfence_asid);
          end

          if (invalidate) dtlb[i].valid <= 1'b0;
        end
      end
    end
  end

endmodule
