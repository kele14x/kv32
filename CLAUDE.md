# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For the full architectural specification (pipeline, CSR map, memory interface, privilege modes, MMU, boot flow), see [SPEC.md](SPEC.md). For build commands and user-facing usage, see [README.md](README.md).

## Project Overview

kv32 is a minimal RISC-V RV32GC soft core in SystemVerilog, targeting Linux boot on an FPGA. 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with forwarding and hazard detection. Phase 1 (RV32I base + M-mode CSRs) is complete.

**Canonical spec**: SPEC.md is the single source of truth for architectural decisions. CLAUDE.md supplements it with agent-actionable guidance: where to look, what gotchas to avoid, how to debug.

## Build and Test

**Always run `make lint` first** after any RTL change. Verilator catches most errors before simulation.

**Run `make unit-tests` after submodule changes** to catch bugs at module boundaries before integration. Each submodule has an isolated Verilator C++ testbench (`tb/tb_<module>.cpp`).

For the full command list (`make verilator`, `make test-subword`, `make unit-tests`, `make riscv-tests`, `make riscv-test-<name>`, etc.), see [README.md](README.md#building-and-running).

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

### Unit Tests

Each RTL submodule has an isolated Verilator C++ testbench (`tb/tb_<module>.cpp`):

- `tb_alu.cpp`: all 10 ALU operations, edge cases (overflow, signed/unsigned, shifts)
- `tb_regfile.cpp`: x0 hardwire, write-then-read, write-during-read, dual-port, we gating
- `tb_decoder.cpp`: all opcodes, immediate types, control signals, CSR variants, illegal instructions
- `tb_csr.cpp`: read/write/set/clear, read-before-write, trap/MRET, counters, mtvec MODE masking, priority chain
- `tb_mem_arbiter.cpp`: d-port priority, zero-latency response, multi-cycle latency, one-cycle gnt pulse, latched fields

Run with `make unit-tests` (aggregate) or `make unit-test-<module>` (individual). Each testbench is compiled with its module as the Verilator top (`--top-module kv32_<module>`) in a separate `obj_dir_<module>/` directory.

### Integration Tests

Tests are C++ (`tb/sim_main.cpp`) using the Verilator API. The testbench drives clock/reset, implements a 64 KiB BRAM model (req/gnt/valid protocol), loads RISC-V instruction sequences, and checks register file state.

**Key components in `sim_main.cpp`**:

- `bram_write()`/`bram_read()`: memory model with byte-enable write support
- `mem_responder()`: drives `mem_gnt`/`mem_valid`/`mem_rdata` to match the req/gnt/valid protocol
- `read_reg()`: reads register file via `rootp->` internal signal access
- Test programs: `TestWord[]` arrays (address + instruction pairs)
- Expected results: `RegCheck[]` arrays (register + expected value + label)
- `--latency <n>` option: delays `mem_valid` by N cycles to exercise arbiter hold, misalignment wait states, and pipeline `mem_stall` paths

### Debugging Tips

Inspect Verilator internal signals via `rootp->` or add `printf` in `sim_main.cpp`. Useful signal paths (all via `top->rootp->`):

- Pipeline registers: `pc_if`, `pc_id`, `pc_ex`, `pc_mem`
- Stall signals: `if_stall`, `id_stall`, `ex_stall`, `mem_stall`, `if_wait`
- Forwarding: `fwd_a`, `fwd_b`, `alu_result`, `ex_result`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Control: `mem_read_ex`, `mem_write_ex`, `alu_op_valid_ex`

### Phase 5 TODO (not bugs in Phase 1, but needed for compliance)

- **Illegal CSR accesses should trap**: Unimplemented CSR reads return 0 and writes are ignored (`kv32_csr.sv` `default` cases), instead of raising an illegal-instruction exception. This is non-compliant with the RISC-V privileged spec but doesn't affect riscv-tests. Fix in Phase 5 when trap handling is fully exercised.
- **Invalid instruction encodings should trap**: Invalid branch funct3 (010, 011), invalid load/store funct3, invalid JALR funct3 (non-zero), and broad OP_MISC_MEM handling all decode as valid/NOP instead of illegal. Fix in Phase 5 by adding funct3 validation in the decoder.

## Code Style

- SystemVerilog 2012
- `always_comb` for combinational, `always_ff @(posedge clk)` for sequential
- `unique case` for case statements (helps lint)
- Pipeline register updates use `if (!stall)` pattern to hold values during stalls
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* lint_on */` pairs around the specific signal, not globally
- Run `make lint` after every RTL change

## Project Phases

See SPEC.md §14 for the full implementation order and phase definitions.
