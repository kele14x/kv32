# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For the full architectural specification (pipeline, CSR map, memory interface, privilege modes, MMU, boot flow), see [SPEC.md](SPEC.md). For build commands and user-facing usage, see [README.md](README.md).

## Project Overview

kv32 is a minimal RISC-V RV32GC soft core in SystemVerilog, targeting Linux boot on an FPGA. 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with forwarding and hazard detection. Phase 1 (RV32I base + M-mode CSRs) is complete.

**Canonical spec**: SPEC.md is the single source of truth for architectural decisions. CLAUDE.md supplements it with agent-actionable guidance: where to look, what gotchas to avoid, how to debug.

## Build and Test

**Prefer Verilator over Icarus Verilog** — stricter lint, faster simulation, no `sorry` warnings on `unique case` in `always_comb`. Icarus is a fallback only.

**Always run `make lint` first** after any RTL change. Verilator catches most errors before simulation.

For the full command list (`make verilator`, `make test-subword`, `make riscv-tests`, `make riscv-test-<name>`, etc.), see [README.md](README.md#building-and-running).

## Architecture — Agent Notes

See SPEC.md §1 for the pipeline structure. The notes below highlight non-obvious implementation details an agent should know before editing RTL.

### Register File Design

Reads from `rs1_ex`/`rs2_ex` (EX stage) rather than `rs1_id`/`rs2_id` (ID stage). Critical for correct forwarding — the forwarding logic compares against the instruction currently in EX, not the one being decoded.

**Location**: `kv32_core.sv:123-133`

### Forwarding and Hazard Detection

**Forwarding paths** (`kv32_core.sv:272-293`):

- MEM→EX: highest priority, forwards `mem_result` when `reg_write_mem && rd_mem != 0`
- WB→EX: lower priority, forwards `wb_data` when `reg_write_wb && rd_wb != 0` (only if MEM isn't already forwarding to the same register)

**Load-use hazard** (`kv32_core.sv:301-302`):

```systemverilog
assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 &&
                        ((rd_ex == rs1_id) || (rd_ex == rs2_id));
```

When detected, a bubble is inserted into EX (control signals cleared, `rd_ex <= 0`).

**Pipeline stall and backpressure** (`kv32_core.sv:305-313`):

```systemverilog
assign if_wait   = i_req && !i_valid;
assign mem_stall = (mem_read_mem || mem_write_mem) && !d_valid;
assign ex_stall  = mem_stall;
assign id_stall  = load_use_hazard || mem_stall || if_wait;
assign if_stall  = if_wait || load_use_hazard || mem_stall;
```

- `mem_stall`: MEM stalls until `d_valid` (not just `d_gnt`)
- `ex_stall`: backpressure from MEM freezes ID/EX register
- `if_wait`: inserts bubble in EX to prevent double-execution when IF has no valid instruction

**Branch handling**: resolved in EX. Taken branches flush IF/ID (2-cycle penalty).

### Decoder Control Signals

`alu_op_valid` must be set for any instruction that uses the ALU result — including loads and stores (which use ALU to calculate addresses). Both `OP_LOAD` and `OP_STORE` must set `alu_op_valid = 1'b1`, otherwise `ex_result` defaults to `pc_ex + 4`.

### Sub-Word Memory Access

Implemented in `kv32_core.sv`:

- **Loads** (lines 225-258): byte extraction uses `mem_addr_mem[1:0]`, sign/zero-extends per `funct3_mem`
- **Stores** (lines 436-476): data positioning uses `fwd_b` (forwarded rs2, not raw `rs2_data`) and generates byte enables from `funct3_ex[1:0]` and `ex_result[1:0]`

## Testing

Tests are C++ (`tb/sim_main.cpp`) using the Verilator API. The testbench drives clock/reset, implements a 64 KiB BRAM model (req/gnt/valid protocol), loads RISC-V instruction sequences, and checks register file state.

**Key components in `sim_main.cpp`**:

- `bram_write()`/`bram_read()`: memory model with byte-enable write support
- `mem_responder()`: drives `mem_gnt`/`mem_valid`/`mem_rdata` to match the req/gnt/valid protocol
- `read_reg()`: reads register file via `rootp->` internal signal access
- Test programs: `TestWord[]` arrays (address + instruction pairs)
- Expected results: `RegCheck[]` arrays (register + expected value + label)

**Legacy SV testbenches**: `tb/kv32_core_tb.sv` and `tb/kv32_subword_tb.sv` remain for Icarus Verilog compatibility but are not used by the Verilator flow.

### Debugging Tips

Inspect Verilator internal signals via `rootp->` or add `printf` in `sim_main.cpp`. Useful signal paths (all via `top->rootp->`):

- Pipeline registers: `pc_if`, `pc_id`, `pc_ex`, `pc_mem`
- Stall signals: `if_stall`, `id_stall`, `ex_stall`, `mem_stall`, `if_wait`
- Forwarding: `fwd_a`, `fwd_b`, `alu_result`, `ex_result`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Control: `mem_read_ex`, `mem_write_ex`, `alu_op_valid_ex`

### Known Issues

- **OP_SYSTEM handling incomplete**: decoder sets `reg_write=1` for all SYSTEM instructions without distinguishing ECALL/EBREAK/CSRR*/MRET. Will cause incorrect register writes until M-mode CSR file is fully wired. Full privilege mode system (M/S/U switching, trap delegation) is a Phase 5 target.
- **Missing FENCE instruction**: opcode `7'b0001111` (MISC-MEM) is not decoded and triggers `illegal`. Required for `riscv-tests` compatibility.
- **ALU operation codes duplicated**: `ALU_ADD`, `ALU_SUB`, etc. defined independently in both `kv32_alu.sv` and `kv32_decoder.sv`. Should be unified into `kv32_pkg` to avoid maintenance risk.

## Code Style

- SystemVerilog 2012 (`-g2012` for iverilog)
- `always_comb` for combinational, `always_ff @(posedge clk)` for sequential
- `unique case` for case statements (helps lint)
- Pipeline register updates use `if (!stall)` pattern to hold values during stalls
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* lint_on */` pairs around the specific signal, not globally
- Run `make lint` after every RTL change

## Project Phases

See SPEC.md §14 for the full implementation order and phase definitions.
