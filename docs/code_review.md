# Code Review: Outstanding Items (2026-06-25)

Full subsystem review of kv32 Phase 1 RTL. All 42 riscv-tests passing, clean lint.

## Completed

| # | Item | Fix |
|---|------|-----|
| C1 | No load/store access-fault trap — `fe_err` not connected to trap detection | Connected `fe_err` to trap chain (mcause 5/7), added MEM/WB squash |
| C2 | Trap priority inversion — illegal checked before breakpoint/ecall | Reordered to breakpoint > ecall > illegal |

---

## High Priority (Should Fix)

### H1. `misa` writes silently ignored instead of trapping
**Files**: `rtl/kv32_csr.sv:145-148` (legality), `:286` (write path)

`misa` is in the "implemented RW" legality group, so `CSRRW x1, misa, x2` succeeds without trapping, but the write path silently discards the value. Stricter: classify `misa` as read-only so writes trap as illegal instruction. Same applies to `mstatush`.

**Fix**: Move `CsrMisa` and `CsrMstatush` to the read-only legality group at `kv32_csr.sv:149-150`, matching identity CSRs (0xF11-0xF15).

### H2. ECALL mtval contradicts project SPEC
**Files**: `rtl/kv32_core.sv:274` (sets `trap_val = 32'h0`), `SPEC.md:437` (states "PC")

Implementation follows RISC-V privileged spec (mtval=0 for ecall), but SPEC table says "PC". Either SPEC or implementation is wrong.

**Fix**: Update `SPEC.md` line 437 to state "0" for cause 11 (ecall from M-mode), matching RISC-V spec and implementation.

### H3. JAL target has no instruction-address-misaligned trap
**File**: `rtl/kv32_core.sv:315`

JAL sets `branch_target = pc_ex + imm_ex` without misalignment check. No mcause=0 trap anywhere in design. SPEC.md lines 446-448 require this for misaligned jump targets. Will manifest when C extension is added.

**Fix**: Add misalignment check: for non-C-extension, trap if `branch_target[1] != 0` for taken branches/jumps. Can defer until C extension work begins, but trap infrastructure should be designed now.

### H4. `imem_req` gating diverges from documentation
**Files**: `rtl/kv32_core.sv:66` (code: `i_req && !i_wait_resp`), `docs/memory.md:35` (docs: `i_req`)

Code correctly suppresses `imem_req` while waiting for response. Documentation is stale.

**Fix**: Update `docs/memory.md` line 35 to `assign imem_req = i_req && !i_wait_resp;`.

### H5. FSM state names mismatch between docs/SPEC and RTL
**Files**: `docs/memory.md:99`, `SPEC.md:232` (reference `MA_BETWEEN`), `rtl/kv32_mem_fe.sv:221-227` (uses `MA_SECOND_REQ`), `tb/tb_mem_fe.cpp:303,534,625` (comments reference `MA_BETWEEN`)

RTL's `MA_SECOND_REQ` is more descriptive but inconsistent with docs.

**Fix**: Update `docs/memory.md`, `SPEC.md`, and testbench comments to use RTL's actual state names.

---

## Medium Priority (Consider Fixing)

### M1. Dead signals should be removed or utilized
**Files**: `rtl/kv32_core.sv:227-229` (`if_stall`, `if_flush`), `:61-63` (`fe_err` — now fixed), `:213` (`mstatus_mie`)

`if_stall` and `if_flush` are declared, assigned, but never read — suppressed with `lint_off UNUSEDSIGNAL`. Remnants of simplified logic. `mstatus_mie` is read in CSR module but not used for interrupt gating (documented Phase 5 deferral).

**Fix**: Remove `if_stall` and `if_flush`. Keep `mstatus_mie` with comment noting Phase 5 interrupt use.

### M2. Unused struct types in kv32_pkg.sv
**File**: `rtl/kv32_pkg.sv:3-15` (`mem_req_t`, `mem_resp_t`)

Two memory interface struct types defined but never instantiated. Core and mem_fe pass individual signals. Dead code adding maintenance burden.

**Fix**: Either remove structs or refactor memory interfaces to use them. Struct approach would be cleaner for future phases.

### M3. Inconsistent signal clearing in `ex_flush` vs bubble paths
**Files**: `rtl/kv32_core.sv:533-548` (`ex_flush`), `:549-567` (bubble)

`ex_flush` omits clearing `alu_op_valid_ex`, `use_imm_ex`, `funct3_ex`, `use_zimm_ex`, `csr_op_ex`, `rd_ex`, `rs1_ex`, `rs2_ex`, `imm_ex`, `pc_ex`, `instr_ex`. Bubble path clears some of these. EX/MEM squash on trap (`:612-618`) omits `mem_size_mem`, `funct3_mem`, `mem_wdata_mem`, `mem_addr_mem`, `pc_mem`. Functionally harmless (control signals gate usage) but inconsistent.

**Fix**: Consolidate bubble paths (also addresses M4) and add missing signals to EX/MEM squash for consistency.

### M4. Duplicated bubble-insertion logic in ID/EX register
**File**: `rtl/kv32_core.sv:533-567`

`ex_flush` block (lines 533-548) and `load_use_hazard || if_wait` block (lines 549-567) clear nearly identical signal sets across ~35 lines of duplicated assignments.

**Fix**: Refactor into a single condition:
```systemverilog
if (ex_flush || load_use_hazard || if_wait) begin
  // Common bubble insertion
end
```

### M5. IF/ID register lacks explicit bubble on `!id_stall && !i_valid`
**File**: `rtl/kv32_core.sv:492-498`

When ID not stalled but no instruction available, IF/ID silently holds previous value. Correctness depends on `if_wait` invariant in IF stage. Explicit else clause inserting NOP bubble would make design robust against future IF-stage changes.

**Fix**: Add `else begin instr_id <= 32'h00000013; instr_valid_id <= 1'b0; end`.

### M6. Repetitive OpReg decoder logic
**File**: `rtl/kv32_decoder.sv:213-280`

Every `funct3` case checks `funct7 == 7'b0000000` or `funct7 == 7'b0100000` individually. Block could be reduced by ~40 lines by extracting common `funct7` checks.

**Fix**: Extract `funct7_valid` and `funct7_sub` signals and simplify case logic.

### M7. Dense IF-stage redirect logic lacks comments
**File**: `rtl/kv32_core.sv:439-460`

Branch/trap redirect priority chain and PC mux are complex but minimally commented. Line 459 is a long ternary with no explanation of priority chain.

**Fix**: Add inline comments explaining trap > branch priority and PC selection logic.

---

## Low Priority (Nice to Have)

| # | Issue | Location |
|---|-------|----------|
| L1 | FENCE/FENCE.I don't validate reserved fields — non-standard encodings silently accepted as NOPs | `rtl/kv32_decoder.sv:282-292` |
| L2 | RO detection comment mismatch — comment says `addr[11:10]==2'b11` but code uses explicit enumeration | `rtl/kv32_csr.sv:133-134,149-150` |
| L3 | Load stitch runs for stores (unnecessary toggling) — gate with `!we` like non-crossing shift | `rtl/kv32_mem_fe.sv:427-442` |
| L4 | `dmem_wdata`/`dmem_be` not held after gnt in wait states — falls through to defaults instead of holding | `rtl/kv32_mem_fe.sv:275-276,308-312,323-327` |
| L5 | `dmem_addr` set on overflow with no request — harmless but unnecessary | `rtl/kv32_mem_fe.sv:284-285` |
| L6 | `logic` declaration inside `always_ff` block — legal SV2012 but unconventional (iverilog workaround) | `rtl/kv32_csr.sv:211` |
| L7 | Confusing double `_mem_mem` suffix — `mem_read_mem`, `mem_write_mem`, `mem_addr_mem` | `rtl/kv32_core.sv:339` |
| L8 | Hex/binary literal inconsistency — `imem_be = 4'hF` vs rest using `4'b1111` | `rtl/kv32_core.sv:71` |
| L9 | Redundant default in decoder immediate generation — `default: imm = 32'h0` duplicates init at line 63 | `rtl/kv32_decoder.sv:91` |
| L10 | Indentation inconsistency in `second_complete` — 2-space vs 6-space continuation | `rtl/kv32_mem_fe.sv:257-258` |
| L11 | `dmem_req = req` vs `dmem_req = 1'b1` style inconsistency in mem_fe FSM states | `rtl/kv32_mem_fe.sv:315` |

---

## Cross-Cutting Themes

### Phase 5 Privilege-Mode Debt
Items H3, C2, plus CSR review Issues 6/7/15/16, trap review Items 5/6/7 — seven findings across three subsystems trace to no privilege-mode state. MRET not privilege-checked, CSR access not privilege-gated, trap entry/exit hardcodes MPP=2'b11, trap priority assumes mutual exclusivity that breaks with privilege-based illegality. Phase 5 planning should explicitly enumerate all integration points.

### Signal-Clearing Discipline
Items M3, M4, Pipeline review Issues 1/2, Trap review Items 3/9 — multiple pipeline register paths clear inconsistent signal subsets on flush/bubble/squash. Functionally safe today (control signals gate usage) but fragile. Consolidate to single "insert bubble" abstraction per pipeline register.

### Documentation Drift
Items H4, H5, L2 — three doc/SPEC divergences from RTL. Code correct in all cases, docs stale. Documentation pass aligned with current RTL state would close these gaps.

---

## Positive Observations

- Comprehensive forwarding coverage with correct priority arbitration and `rd != 0` guards
- CSR write-gating loop avoidance (deliberate `!trap_taken` omission from `csr_wen_gated`)
- Memory front-end protocol correctness (handshake, sub-word, crossing, error handling)
- Complete RV32I decode with correct `alu_op_valid` for loads/stores/AUIPC
- Consistent `unique case` usage throughout
- Counter write-suppress guards for `mcycle`/`minstret`
