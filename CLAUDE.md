# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

- **Architectural spec** (pipeline, CSR map, memory interface, privilege modes, MMU, boot flow): [SPEC.md](SPEC.md)
- **Build commands and user-facing usage**: [README.md](README.md)
- **Implementation details by topic** (file:line references into the RTL): [docs/index.md](docs/index.md)

## Project Overview

kv32 is a minimal RISC-V RV32GC soft core in SystemVerilog, targeting Linux boot on an FPGA. 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with forwarding and hazard detection. Phase 1 (RV32I base + M-mode CSRs) is complete.

**Canonical spec**: SPEC.md is the single source of truth for architectural decisions. CLAUDE.md supplements it with agent-actionable guidance: where to look, what gotchas to avoid, how to debug. Implementation prose lives in [docs/](docs/index.md) so it can be maintained alongside the RTL.

## Build and Test

**Always run `make lint` first** after any RTL change. Verilator catches most errors before simulation.

**Run `make unit-tests` after submodule changes** to catch bugs at module boundaries before integration.

For the full command list (`make verilator`, `make test-subword`, `make unit-tests`, `make riscv-tests`, `make riscv-test-<name>`, etc.), see [README.md](README.md#building-and-running). Test infrastructure and per-suite coverage are documented in [docs/verification.md](docs/verification.md).

## Where to Look (implementation topics)

Before editing RTL, read the relevant topic doc — each calls out non-obvious behavior and exact `file:line` locations:

- [docs/pipeline.md](docs/pipeline.md) — datapath, forwarding, hazards/stalls, branch/jump
- [docs/decoder.md](docs/decoder.md) — decode, control signals, illegal-instruction detection
- [docs/memory.md](docs/memory.md) — interface, arbiter, sub-word access, **misaligned-access state machine**
- [docs/csr.md](docs/csr.md) — M-mode CSR file, address map, legality, MRET, counters
- [docs/traps.md](docs/traps.md) — trap detection, pipeline flush, mtvec redirect, MRET, CSR write-gating loop avoidance

A few cross-cutting gotchas worth flagging up front:

- **Regfile reads from `rs1_ex`/`rs2_ex` (EX stage)**, not ID — required for forwarding to compare against the right instruction. See [docs/pipeline.md](docs/pipeline.md#register-file-design).
- **`alu_op_valid` must be set for loads/stores** (ALU computes the effective address) or `ex_result` falls through to `pc_ex + 4`. See [docs/decoder.md](docs/decoder.md#alu_op_valid-gotcha).
- **CSR write gating deliberately omits `!trap_taken`** to avoid a combinational loop through `csr_illegal → trap_taken`. See [docs/traps.md](docs/traps.md#csr-write-gating).
- **Misaligned-access `non_crossing_ma` is only the `SH@addr[1:0]=01` case** — the load-side shift assumes this. See [docs/memory.md](docs/memory.md#misalignment-detection).

## Debugging Tips

Inspect Verilator internal signals via `rootp->` or add `printf` in `sim_main.cpp`. Useful signal paths (all via `top->rootp->`):

- Pipeline registers: `pc_if`, `pc_id`, `pc_ex`, `pc_mem`
- Stall signals: `if_stall`, `id_stall`, `ex_stall`, `mem_stall`, `if_wait`
- Forwarding: `fwd_a`, `fwd_b`, `alu_result`, `ex_result`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Misaligned handler: `ma_state`, `ma_offset`, `ma_size`, `ma_first_rdata`
- Control: `mem_read_ex`, `mem_write_ex`, `alu_op_valid_ex`, `trap_taken`, `csr_illegal`

For test infrastructure details (BRAM model, `mem_responder`, `--latency`, `--binary`) see [docs/verification.md](docs/verification.md).

## Code Style

- SystemVerilog 2012
- `always_comb` for combinational, `always_ff @(posedge clk)` for sequential
- `unique case` for case statements (helps lint)
- Pipeline register updates use `if (!stall)` pattern to hold values during stalls
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* lint_on */` pairs around the specific signal, not globally
- Run `make lint` after every RTL change

## Project Phases

See [SPEC.md §14](SPEC.md) for the full implementation order and phase definitions.
