# Code Review: Outstanding Items

Last updated: 2026-06-30

Phase 5 complete (RV32IMAC + M/S/U privilege modes), 77/78 riscv-tests passing, clean lint.

## Outstanding Low Priority

| # | Issue | Location |
|---|-------|----------|
| L3 | Load stitch runs for stores (unnecessary toggling) — gate with `!we` like non-crossing shift | `rtl/kv32_mem_fe.sv:425-437` |
| L4 | `dmem_wdata`/`dmem_be` not held after gnt in wait states — falls through to defaults instead of holding | `rtl/kv32_mem_fe.sv:273-276,308-312,323-327` |
| L6 | `logic` declaration inside `always_ff` block — legal SV2012 but unconventional (iverilog workaround) | `rtl/kv32_csr.sv:457-460` |
| L8 | Hex/binary literal inconsistency — `imem_be = 4'hF` vs rest using `4'b1111` | `rtl/kv32_core.sv:126` |
| L9 | Redundant default in decoder immediate generation — `default: imm = 32'h0` duplicates init at top of block | `rtl/kv32_decoder.sv:75-108` |
| L10 | Indentation inconsistency in `second_complete` — 2-space vs aligned continuation | `rtl/kv32_mem_fe.sv:256-258` |
| L11 | `dmem_req = req` vs `dmem_req = 1'b1` style inconsistency in mem_fe FSM states | `rtl/kv32_mem_fe.sv:315` |

## Positive Observations

- CSR write-gating loop avoidance (deliberate `!trap_taken` omission from `csr_wen_gated`)
- Memory front-end protocol correctness (handshake, sub-word, crossing, error handling)
- Complete RV32IMAC decode with correct `alu_op_valid` for loads/stores/AUIPC
- Consistent `unique case` usage throughout
- Counter write-suppress guards for `mcycle`/`minstret`
- FSM architecture simplifies control flow and eliminates pipeline hazard complexity
- Instruction-address-misaligned trap (mcause=0) covers all jump/branch/MRET/SRET target paths

---

## Review Pass — 2026-06-30 (follow-up)

Re-review after commit `1756cfb` and the in-flight working-copy formatting tidy. The items raised in the prior architecture review have all been addressed in code, so this pass focuses on verifying the fixes rather than enumerating new findings.

### Items verified as fixed

| Prior finding | Fix observed | Location |
|---|---|---|
| README drift (still described 5-stage pipeline + "Phase 1 complete") | README now accurately describes the multi-cycle FSM and notes Phase 5 complete / Phase 6 in progress | `README.md:5,185` |
| ISA description mismatch (README said RV32GC; implementation is RV32IMAC) | README and SPEC now use `RV32IMAC`; F/D moved to optional future work per commit message | `README.md:3` |
| Unit-test count discrepancy (README said 5, Makefile ran 8) | README updated: `make unit-tests # run all 8 unit tests` | `README.md:51` |
| M2 — unused `mem_req_t`/`mem_resp_t` in `kv32_pkg.sv` | Structs removed; no remaining references in `rtl/`, `tb/` | `rtl/kv32_pkg.sv` |
| MMU TODO above-4GB physical address | `mmu_i_above_4g` / `mmu_d_above_4g` detection added; raises `EXC_INSTR_ACCESS_FAULT` / `EXC_LOAD_ACCESS_FAULT` / `EXC_STORE_ACCESS_FAULT`; gated into `imem_req` and `d_access_ok` | `rtl/kv32_core.sv:121,584-599,912-915`; `rtl/kv32_pkg.sv:55-57` |
| H3 — JAL target instruction-address-misaligned trap | EXEC-state check `branch_taken && branch_target[0] → mcause=0`, `mtval = branch_target` | `rtl/kv32_core.sv:567-575` |

The trap-detection block is now the canonical place all four EXEC-stage exception classes share — illegal/ecall/ebreak, A-extension address misalignment, and instruction-address misalignment — which keeps trap priority consistent with the spec's "one trap per instruction" ordering. The above-4G access fault is checked symmetrically in `ST_FETCH` (for I-side) and `ST_MEM` (for D-side), and ordered ahead of page-fault detection so a translation that hits the TLB but produces an unrepresentable physical address is reported as an access fault rather than silently truncating.

### Notes on the fixes

A few small things worth recording for future reference, none of which need action right now:

- The above-4G detection uses `mmu_*_tlb_hit && |mmu_*_phys_ppn[21:20]`. That correctly excludes the bypass case (M-mode or `satp_mode == Bare`) because `mmu_*_tlb_hit` is meaningful only when translation is active. The trap-detection block additionally gates on `!mmu_bypass`, so the condition is doubly safe — fine, just redundant by one term.
- The PTW path itself still writes its physical address into `dmem_addr` directly without an above-4G check; in practice the PTE PPN field is constrained by Sv32 to be < 4GB only when the root `satp.PPN` and intermediate PTEs are all below 4GB. If a faulty page table contained a high PPN, the PTW would silently read from the truncated address. Not a regression vs the prior state — just noting it as a future hardening item once OpenSBI runs on real hardware.
- The JAL/JALR misalignment trap correctly notes in its inline comment that with C present the trap is a safety net rather than a routinely-fired case (branch immediates have `bit[0]=0`, JALR clears bit 0). Good defensive coding without paying a real cost.
- Working-copy formatting changes (the unstaged whitespace edits to `kv32_core.sv` and `kv32_csr.sv`) look like `verible-verilog-format` output — no logic changes, only alignment of declarations and `case` arms. Safe to commit as a standalone format pass.

### Remaining open items

The Outstanding Low Priority table above is unchanged from the previous pass — L3/L4/L6/L8/L9/L10/L11 are all still cosmetic / micro-optimization in nature. None of them affect correctness or the riscv-tests pass rate, and most could be cleaned up opportunistically when those files are touched for other reasons.

### Verdict

All high-impact items from the architecture review are closed. The codebase is in a good state to continue with the remaining Phase 6 work (MMU integration tests, rv32mi paging tests if available) before moving on to Phase 7 (AXI4 adapter + SoC integration).

