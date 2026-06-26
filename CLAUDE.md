# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

- **Architectural spec** (execution model, CSR map, memory interface, privilege modes, MMU, boot flow): [SPEC.md](SPEC.md)
- **Build commands and user-facing usage**: [README.md](README.md)
- **Implementation details by topic** (with RTL file references): [docs/index.md](docs/index.md)

## Project Overview

kv32 is a minimal RISC-V RV32IMAC soft core in SystemVerilog, targeting Linux boot on an FPGA. Multi-cycle state machine (FETCH/DECODE/EXEC/MEM/WRITEBACK) executing one instruction at a time. Phase 4 (RV32I + M extension + C extension + A extension) is complete.

**Canonical spec**: SPEC.md is the single source of truth for architectural decisions. CLAUDE.md supplements it with agent-actionable guidance: where to look, what gotchas to avoid, how to debug. Implementation prose lives in [docs/](docs/index.md) so it can be maintained alongside the RTL.

## Build and Test

**Always run `make lint` first** after any RTL change. Verilator catches most errors before simulation.

**Run `make format` after editing RTL files.** This runs `verible-verilog-format` in-place on `rtl/*.sv`, which both enforces a consistent style and acts as a secondary syntax check (verible parses the source, so malformed SV will fail to format). Verify with `make format-check` if you only want to detect drift. Override the formatter path with `make format VERIBLE_FORMAT=/path/to/verible-verilog-format` (default: `~/tools/verible/bin/verible-verilog-format`).

**Run `make unit-tests` after submodule changes** to catch bugs at module boundaries before integration.

For the full command list (`make verilator`, `make test-subword`, `make unit-tests`, `make riscv-tests`, `make riscv-test-<name>`, etc.), see [README.md](README.md#building-and-running). Test infrastructure and per-suite coverage are documented in [docs/verification.md](docs/verification.md).

## Where to Look (implementation topics)

Before editing RTL, read the relevant topic doc — each calls out non-obvious behavior and points to the relevant RTL files:

- [docs/pipeline.md](docs/pipeline.md) — FSM execution model, state transitions, memory access
- [docs/decoder.md](docs/decoder.md) — decode, control signals, illegal-instruction detection
- [docs/memory.md](docs/memory.md) — interface, `kv32_mem_fe` sub-word access, **misaligned-access state machine**
- [docs/csr.md](docs/csr.md) — M-mode CSR file, address map, legality, MRET, counters
- [docs/traps.md](docs/traps.md) — trap detection, PC redirect to mtvec, MRET, CSR write-gating loop avoidance

A few cross-cutting gotchas worth flagging up front:

- **`alu_op_valid` must be set for loads/stores** (ALU computes the effective address) or `ex_result` falls through to `pc_reg + 4`. See [docs/decoder.md](docs/decoder.md#alu_op_valid-gotcha).
- **CSR write gating deliberately omits `!trap_taken`** to avoid a combinational loop through `csr_illegal → trap_taken`. See [docs/traps.md](docs/traps.md#csr-write-gating).
- **Misaligned-access `non_crossing_ma` is only the `SH@addr[1:0]=01` case** — the load-side shift assumes this. See [docs/memory.md](docs/memory.md#misalignment-detection).
- **LR/SC/AMO use multi-phase MEM state** — AMO reads, computes, then writes; SC checks reservation before storing. See [docs/memory.md](docs/memory.md#lrsc-and-amo-operations-a-extension).

## Debugging Tips

Inspect Verilator internal signals via `rootp->` or add `printf` in `tb_core.cpp`. Useful signal paths (all via `top->rootp->`):

- FSM state: `state`, `pc_reg`, `instr_reg`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Misaligned handler: `ma_state`, `ma_offset`, `ma_size`, `ma_first_rdata`
- Control: `mem_read`, `mem_write`, `alu_op_valid`, `trap_taken`, `csr_illegal`

For test infrastructure details (BRAM model, `mem_responder`, `--latency`, `--binary`) see [docs/verification.md](docs/verification.md).

## Code Style

- SystemVerilog 2012
- `always_comb` for combinational, `always_ff @(posedge clk)` for sequential
- `unique case` for case statements (helps lint)
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* lint_on */` pairs around the specific signal, not globally
- Run `make lint` after every RTL change
- Run `make format` after every RTL change (also catches syntax errors — verible parses the source before formatting)

## Project Phases

See [SPEC.md §14](SPEC.md) for the full implementation order and phase definitions.
