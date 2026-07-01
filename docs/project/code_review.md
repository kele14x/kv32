# Code Review

Phase 5 complete (RV32IMAC + M/S/U privilege modes), 77/78 riscv-tests passing, clean lint.

## Outstanding Low Priority

- L3:
  - Load stitch runs for stores (unnecessary toggling) — gate with `!we` like non-crossing shift | `rtl/kv32_mem_fe.sv:425-437` |
- L4:
  - `dmem_wdata`/`dmem_be` not held after gnt in wait states — falls through to defaults instead of holding | `rtl/kv32_mem_fe.sv:273-276,308-312,323-327` |
- L6
  - `logic` declaration inside `always_ff` block — legal SV2012 but unconventional (iverilog workaround) | `rtl/kv32_csr.sv:457-460` |
- L8
  - Hex/binary literal inconsistency — `imem_be = 4'hF` vs rest using `4'b1111` | `rtl/kv32_core.sv:126` |
- L9
  - Redundant default in decoder immediate generation — `default: imm = 32'h0` duplicates init at top of block | `rtl/kv32_decoder.sv:75-108` |
- L10
  - Indentation inconsistency in `second_complete` — 2-space vs aligned continuation | `rtl/kv32_mem_fe.sv:256-258` |
- L11
  - `dmem_req = req` vs `dmem_req = 1'b1` style inconsistency in mem_fe FSM states | `rtl/kv32_mem_fe.sv:315` |

A few small things worth recording for future reference, none of which need action right now:

- The above-4G detection uses `mmu_*_tlb_hit && |mmu_*_phys_ppn[21:20]`. That correctly excludes the bypass case (M-mode or `satp_mode == Bare`) because `mmu_*_tlb_hit` is meaningful only when translation is active. The trap-detection block additionally gates on `!mmu_bypass`, so the condition is doubly safe — fine, just redundant by one term.
- The PTW path itself still writes its physical address into `dmem_addr` directly without an above-4G check; in practice the PTE PPN field is constrained by Sv32 to be < 4GB only when the root `satp.PPN` and intermediate PTEs are all below 4GB. If a faulty page table contained a high PPN, the PTW would silently read from the truncated address. Not a regression vs the prior state — just noting it as a future hardening item once OpenSBI runs on real hardware.
- The JAL/JALR misalignment trap correctly notes in its inline comment that with C present the trap is a safety net rather than a routinely-fired case (branch immediates have `bit[0]=0`, JALR clears bit 0). Good defensive coding without paying a real cost.
- Working-copy formatting changes (the unstaged whitespace edits to `kv32_core.sv` and `kv32_csr.sv`) look like `verible-verilog-format` output — no logic changes, only alignment of declarations and `case` arms. Safe to commit as a standalone format pass.

## Positive Observations

- CSR write-gating loop avoidance (deliberate `!trap_taken` omission from `csr_wen_gated`)
- Memory front-end protocol correctness (handshake, sub-word, crossing, error handling)
- Complete RV32IMAC decode with correct `alu_op_valid` for loads/stores/AUIPC
- Consistent `unique case` usage throughout
- Counter write-suppress guards for `mcycle`/`minstret`
- FSM architecture simplifies control flow and eliminates pipeline hazard complexity
- Instruction-address-misaligned trap (mcause=0) covers all jump/branch/MRET/SRET target paths
