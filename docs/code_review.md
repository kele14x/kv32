# Code Review: Outstanding Items

Last updated: 2026-06-27

All 50 riscv-tests passing (42 rv32ui + 8 rv32um), clean lint.

## Resolved by FSM Conversion

The following items from the original pipeline-based review are no longer applicable after the conversion to a multi-cycle FSM architecture (commits 779ecd5, 8f6038d):

- **M1** (dead signals `if_stall`, `if_flush`) — pipeline control signals removed
- **M3** (inconsistent signal clearing in `ex_flush` vs bubble) — no pipeline flush logic
- **M4** (duplicated bubble insertion) — no pipeline bubbles needed
- **M5** (IF/ID register bubble on `!id_stall && !i_valid`) — no IF/ID register
- **M7** (dense IF-stage redirect logic) — no IF stage redirect; branches handled in EXEC
- **L7** (confusing `_mem_mem` suffix) — pipeline register naming removed

## Completed This Session

| # | Item | Fix |
|---|------|-----|
| H1 | `misa`/`mstatush` writes silently ignored | Moved to read-only legality group; writes now trap as illegal instruction |
| H2 | ECALL `mtval` contradicts SPEC | Updated SPEC.md line 534 to state "0" (matching RISC-V spec and implementation) |
| H4 | `imem_req` gating diverges from docs | Updated docs/memory.md to include `fetch_req` in the gating expression |
| H5 | FSM state name mismatch (`MA_BETWEEN` vs `MA_SECOND_REQ`) | Updated tb_mem_fe.cpp comments to use RTL state names |
| M2 | Unused `mem_req_t`/`mem_resp_t` structs | Removed from `kv32_pkg.sv` — incomplete (missing req/gnt/ack), and bundling fights the signal-muxing architecture |

## Outstanding High Priority

### H3. JAL target has no instruction-address-misaligned trap
**File**: `rtl/kv32_core.sv:315`

JAL sets `branch_target = pc_ex + imm_ex` without misalignment check. No mcause=0 trap anywhere in design. SPEC.md lines 446-448 require this for misaligned jump targets. Will manifest when C extension is added.

**Status**: Deferred to Phase 3 (C extension work). Trap infrastructure should be designed as part of that phase.

## Outstanding Medium Priority

### M6. Repetitive OpReg decoder logic
**File**: `rtl/kv32_decoder.sv:213-280`

Every `funct3` case checks `funct7 == 7'b0000000` or `funct7 == 7'b0100000` individually. Block could be reduced by ~40 lines by extracting common `funct7` checks.

**Fix**: Extract `funct7_valid` and `funct7_sub` signals and simplify case logic.

## Outstanding Low Priority

| # | Issue | Location |
|---|-------|----------|
| L1 | FENCE/FENCE.I don't validate reserved fields — non-standard encodings silently accepted as NOPs | `rtl/kv32_decoder.sv:282-292` |
| L2 | RO detection comment mismatch — comment says `addr[11:10]==2'b11` but code uses explicit enumeration | `rtl/kv32_csr.sv:133-134,149-150` |
| L3 | Load stitch runs for stores (unnecessary toggling) — gate with `!we` like non-crossing shift | `rtl/kv32_mem_fe.sv:427-442` |
| L4 | `dmem_wdata`/`dmem_be` not held after gnt in wait states — falls through to defaults instead of holding | `rtl/kv32_mem_fe.sv:275-276,308-312,323-327` |
| L5 | `dmem_addr` set on overflow with no request — harmless but unnecessary | `rtl/kv32_mem_fe.sv:284-285` |
| L6 | `logic` declaration inside `always_ff` block — legal SV2012 but unconventional (iverilog workaround) | `rtl/kv32_csr.sv:211` |
| L8 | Hex/binary literal inconsistency — `imem_be = 4'hF` vs rest using `4'b1111` | `rtl/kv32_core.sv:71` |
| L9 | Redundant default in decoder immediate generation — `default: imm = 32'h0` duplicates init at line 63 | `rtl/kv32_decoder.sv:91` |
| L10 | Indentation inconsistency in `second_complete` — 2-space vs 6-space continuation | `rtl/kv32_mem_fe.sv:257-258` |
| L11 | `dmem_req = req` vs `dmem_req = 1'b1` style inconsistency in mem_fe FSM states | `rtl/kv32_mem_fe.sv:315` |

## Cross-Cutting Themes

### Phase 5 Privilege-Mode Debt
H3 (deferred), plus CSR review Issues 6/7/15/16, trap review Items 5/6/7 — seven findings across three subsystems trace to no privilege-mode state. MRET not privilege-checked, CSR access not privilege-gated, trap entry/exit hardcodes MPP=2'b11, trap priority assumes mutual exclusivity that breaks with privilege-based illegality. Phase 5 planning should explicitly enumerate all integration points.

### Documentation Drift (Resolved)
H4, H5 — two doc/SPEC divergences from RTL. Fixed in this session. Code was correct in all cases; docs were stale. Documentation pass aligned with FSM conversion is now complete.

## Positive Observations

- CSR write-gating loop avoidance (deliberate `!trap_taken` omission from `csr_wen_gated`)
- Memory front-end protocol correctness (handshake, sub-word, crossing, error handling)
- Complete RV32I decode with correct `alu_op_valid` for loads/stores/AUIPC
- Consistent `unique case` usage throughout
- Counter write-suppress guards for `mcycle`/`minstret`
- FSM architecture simplifies control flow and eliminates pipeline hazard complexity
