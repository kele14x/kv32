# CLAUDE.md

Agent-facing operating manual for the kv32 repository. Provides guidance to Claude Code (claude.ai/code) and human contributors alike.

- **Architectural spec**: [docs/spec/](docs/spec/index.md)
- **Implementation notes**: [docs/impl/](docs/index.md)
- **Verification**: [docs/verification/](docs/verification/strategy.md)
- **Build and usage**: [README.md](README.md)
- **Roadmap**: [docs/project/roadmap.md](docs/project/roadmap.md)

## Project overview

kv32 is a minimal RISC-V RV32IMAC soft core in SystemVerilog, targeting Linux boot on an FPGA. Multi-cycle FSM (FETCH/DECODE/EXEC/MEM/WRITEBACK), single-issue, in-order, no forwarding. Phase 5 (RV32IMAC + M/S/U privilege modes) complete; Phase 6 (Sv32 MMU) in progress.

## Before every RTL change

1. Read the relevant spec file under [docs/spec/](docs/spec/index.md) and the matching implementation note under [docs/impl/](docs/index.md).
2. `make lint` — Verilator catches most errors before simulation.
3. `make format` — runs `verible-verilog-format` on `rtl/*.sv`. Both enforces style and doubles as a syntax check. Use `make format-check` to detect drift; override the binary with `make format VERIBLE_FORMAT=/path/to/verible-verilog-format` (default `~/tools/verible/bin/verible-verilog-format`).
4. `make unit-tests` — catches module-boundary bugs before integration.
5. Where relevant, extend `tb/tb_<module>.sv` and update the coverage matrix in [docs/verification/unit-tests.md](docs/verification/unit-tests.md).

For the full command list see [README.md](README.md#building-and-running).

## Where to look

Each impl doc calls out non-obvious behavior and points to the relevant RTL files.

- [docs/impl/pipeline.md](docs/impl/pipeline.md) — FSM, state transitions, memory access
- [docs/impl/decoder.md](docs/impl/decoder.md) — decode, control signals, illegal-instruction detection
- [docs/impl/memory.md](docs/impl/memory.md) — `kv32_mem_fe` sub-word access, misaligned-access state machine
- [docs/impl/csr.md](docs/impl/csr.md) — CSR file, M/S/U-mode, delegation, counters
- [docs/impl/traps.md](docs/impl/traps.md) — trap detection, delegation, vectored vectors, MRET/SRET, interrupt taking
- [docs/impl/mmu.md](docs/impl/mmu.md) — Sv32 TLB, PTW, PTW bus muxing, `sfence.vma`

## Cross-cutting gotchas

- **`alu_op_valid` must be set for loads/stores** (ALU computes the effective address) or `ex_result` falls through to `pc_reg + 4`. See [docs/impl/decoder.md](docs/impl/decoder.md#alu_op_valid-gotcha).
- **CSR write gating deliberately omits `!trap_taken`** to avoid a combinational loop through `csr_illegal → trap_taken`. See [docs/impl/traps.md](docs/impl/traps.md#csr-write-gating).
- **Misaligned-access `non_crossing_ma` is only the `SH@addr[1:0]=01` case** — the load-side shift assumes this. See [docs/impl/memory.md](docs/impl/memory.md#misalignment-detection).
- **LR/SC/AMO use multi-phase MEM state** — AMO reads, computes, then writes; SC checks reservation before storing. See [docs/impl/memory.md](docs/impl/memory.md#lrsc-and-amo-operations-a-extension).
- **Privilege mode transitions** — `priv_mode` updates on trap entry, MRET, and SRET. Trap delegation uses `medeleg`/`mideleg`. See [docs/impl/traps.md](docs/impl/traps.md#trap-routing-and-delegation).
- **Interrupt taking at ST_FETCH entry** — checked between instructions before the fetch request is issued. `irq_pending`/`irq_cause` come from the CSR module. See [docs/impl/traps.md](docs/impl/traps.md#interrupt-taking-flow).

## Debugging tips

Inspect Verilator internal signals via `top->rootp->` or add `printf` in `tb_core.cpp`. Useful signal paths:

- FSM state: `state`, `pc_reg`, `instr_reg`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Misaligned handler: `ma_state`, `ma_offset`, `ma_size`, `ma_first_rdata`
- Control: `mem_read`, `mem_write`, `alu_op_valid`, `trap_taken`, `csr_illegal`
- Privilege: `priv_mode`, `trap_to_smode`, `irq_pending`, `irq_cause`

For test infrastructure (BRAM model, `mem_responder`, `--latency`, `--binary`) see [docs/verification/integration-tests.md](docs/verification/integration-tests.md).

## Code style

- SystemVerilog 2012.
- `always_comb` for combinational, `always_ff @(posedge clk)` for sequential.
- `unique case` for case statements (helps lint).
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* lint_on */` pairs around the specific signal, not globally.
- Run `make lint` and `make format` after every RTL change.

## Code review log

Outstanding review items and dated review passes live in [docs/project/code_review.md](docs/project/code_review.md). Append new review passes as `## Review Pass — YYYY-MM-DD` sections; do not create separate review files.
