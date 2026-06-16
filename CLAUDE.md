# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

kv32 is a minimal RISC-V RV32GC soft core implementation in SystemVerilog, designed to boot Linux on an FPGA. The project uses a 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with forwarding and hazard detection.

**Current Status**: Phase 1 (RV32I base) is complete. RV32I integer instructions, sub-word memory access (LB/LBU/LH/LHU/SB/SH), forwarding, and pipeline hazard handling are all working. Verilator lint passes clean.

## Build and Test Commands

**Prefer Verilator over Icarus Verilog** — Verilator provides stricter lint checking, faster simulation, and does not emit `sorry` warnings for SystemVerilog constructs. Icarus Verilog can be used as a fallback but has known limitations with `unique case` in `always_comb` blocks.

```bash
# Lint check (fast, no simulation) — run this FIRST after any RTL change
make lint

# Compile and run ALU test with Verilator (RECOMMENDED)
make verilator

# Run sub-word memory test
make test-subword

# Run all tests (ALU + sub-word)
make test-all

# Clean build artifacts
make clean

# Icarus Verilog fallback (legacy SV testbenches)
make iverilog              # core ALU test
make iverilog-subword      # sub-word memory test
```

## Architecture

### Pipeline Structure

The core implements a classic 5-stage RISC pipeline:

```
IF (Fetch) → ID (Decode) → EX (Execute) → MEM (Memory) → WB (Writeback)
```

**Key files**:
- `rtl/kv32_core.sv`: Top-level pipeline integration, all pipeline registers, forwarding logic, hazard detection
- `rtl/kv32_decoder.sv`: Instruction decoding and control signal generation
- `rtl/kv32_alu.sv`: ALU operations (ADD, SUB, shifts, comparisons, logical ops)
- `rtl/kv32_regfile.sv`: 32×32-bit register file with 2 read ports, 1 write port
- `rtl/kv32_mem_arbiter.sv`: Multiplexes instruction fetch and data memory requests

### Register File Design

The register file reads from `rs1_ex`/`rs2_ex` (EX stage) rather than `rs1_id`/`rs2_id` (ID stage). This is critical for correct forwarding behavior — the forwarding logic compares against the instruction currently in the EX stage, not the one being decoded.

**Location**: `kv32_core.sv:123-133`

### Memory Interface

The design uses a simple request/response protocol rather than AXI:
- `d_req`: Request valid
- `d_gnt`: Request granted (memory ready to accept)
- `d_valid`: Response valid (data ready)
- `d_addr`: Address
- `d_we`: Write enable
- `d_be`: Byte enables (4 bits for word, 2 for halfword, 1 for byte)
- `d_wdata`: Write data
- `d_rdata`: Read data

The memory arbiter (`kv32_mem_arbiter.sv`) multiplexes instruction fetches and data memory accesses, prioritizing data operations.

### Sub-Word Memory Access

Implemented in `kv32_core.sv`:

**Loads (lines 225-258)**: Byte extraction uses `mem_addr_mem[1:0]` to select the correct byte from the 32-bit word, then sign-extends or zero-extends based on `funct3_mem`.

**Stores (lines 436-476)**: Data positioning places the write data in the correct byte lane(s) using `fwd_b` (forwarded rs2 value, not raw `rs2_data`) and generates appropriate byte enables based on `funct3_ex[1:0]` and `ex_result[1:0]`.

### Forwarding and Hazard Detection

**Forwarding paths** (`kv32_core.sv:272-293`):
- MEM→EX: Highest priority, forwards `mem_result` when `reg_write_mem && rd_mem != 0`
- WB→EX: Lower priority, forwards `wb_data` when `reg_write_wb && rd_wb != 0` (only if MEM isn't already forwarding to the same register)

**Load-use hazard** (`kv32_core.sv:301-302`):
```systemverilog
assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 &&
                        ((rd_ex == rs1_id) || (rd_ex == rs2_id));
```
When detected, a bubble is inserted into the EX stage (control signals cleared, `rd_ex <= 0`).

**Pipeline stall and backpressure** (`kv32_core.sv:305-313`):
```systemverilog
assign if_wait   = i_req && !i_valid;              // IF waiting for instruction
assign mem_stall = (mem_read_mem || mem_write_mem) && !d_valid;  // MEM waiting for response
assign ex_stall  = mem_stall;                       // Backpressure propagates
assign id_stall  = load_use_hazard || mem_stall || if_wait;
assign if_stall  = if_wait || load_use_hazard || mem_stall;
```
- `mem_stall`: MEM stage stalls until `d_valid` arrives (not just `d_gnt`)
- `ex_stall`: Backpressure from MEM freezes ID/EX register
- `if_wait`: Inserts a bubble in EX to prevent double-execution when IF has no valid instruction

**Branch handling**: Branches are resolved in the EX stage. Taken branches flush the IF/ID pipeline register (2-cycle penalty).

### Decoder Control Signals

The decoder (`kv32_decoder.sv`) generates control signals based on instruction type. Critical signals:

- `alu_op_valid`: Must be set for any instruction that uses the ALU result, including loads and stores (which use ALU to calculate addresses)
- `use_imm`: Selects immediate operand vs register operand for ALU
- `mem_read`/`mem_write`: Enables memory operations
- `reg_write`: Enables register writeback

**Important**: Both `OP_LOAD` and `OP_STORE` must set `alu_op_valid = 1'b1` to ensure `ex_result` uses the ALU-calculated address instead of defaulting to `pc_ex + 4`.

## Testing

### Testbench Structure

Tests are written in C++ (`tb/sim_main.cpp`) using the Verilator API. The C++ testbench drives clock/reset, implements a BRAM memory model (req/gnt/valid protocol), loads RISC-V instruction sequences, and checks register file state after execution.

**Key components in `sim_main.cpp`**:
- `bram_write()`/`bram_read()`: 64 KiB memory model with byte-enable write support
- `mem_responder()`: Drives `mem_gnt`/`mem_valid`/`mem_rdata` to match the core's req/gnt/valid protocol
- `read_reg()`: Reads register file via Verilator's `rootp->` internal signal access
- Test programs defined as `TestWord[]` arrays (address + instruction pairs)
- Expected results defined as `RegCheck[]` arrays (register + expected value + label)

**Command-line options**:
```bash
./obj_dir/Vkv32_core              # Run ALU test (default, test 0)
./obj_dir/Vkv32_core --test 1     # Run sub-word memory test (test 1)
./obj_dir/Vkv32_core --notrace    # Disable VCD trace generation
```

**Legacy SV testbenches**: `tb/kv32_core_tb.sv` and `tb/kv32_subword_tb.sv` remain for Icarus Verilog compatibility but are not used by the Verilator flow.

### Known Issues

- **OP_SYSTEM handling incomplete**: The decoder sets `reg_write=1` for all SYSTEM instructions without distinguishing ECALL/EBREAK/CSRR*/MRET. This will cause incorrect register writes until CSR support is implemented in Phase 5.
- **Missing FENCE instruction**: Opcode `7'b0001111` (MISC-MEM) is not decoded and will trigger `illegal`. Required for `riscv-tests` compatibility.
- **ALU operation codes duplicated**: `ALU_ADD`, `ALU_SUB`, etc. are defined independently in both `kv32_alu.sv` and `kv32_decoder.sv`. Should be unified into `kv32_pkg` to avoid maintenance risk.

### Debugging Tips

When debugging pipeline issues, inspect Verilator internal signals via `rootp->` or add `printf` statements in `sim_main.cpp`. Useful signal paths (all accessed via `top->rootp->`):
- Pipeline register values: `pc_if`, `pc_id`, `pc_ex`, `pc_mem`
- Stall signals: `if_stall`, `id_stall`, `ex_stall`, `mem_stall`, `if_wait`
- Forwarding: `fwd_a`, `fwd_b`, `alu_result`, `ex_result`
- Memory: `d_req`, `d_gnt`, `d_valid`, `d_addr`, `d_wdata`, `d_be`
- Control: `mem_read_ex`, `mem_write_ex`, `alu_op_valid_ex`

## Code Style

- SystemVerilog 2012 (`-g2012` flag for iverilog)
- Use `always_comb` for combinational logic
- Use `always_ff @(posedge clk)` for sequential logic
- Use `unique case` for case statements to help with lint
- Pipeline register updates use `if (!stall)` pattern to hold values during stalls
- Suppress Verilator warnings with `/* verilator lint_off */` / `/* verilator lint_on */` pairs around the specific signal, not globally
- Run `make lint` after every RTL change — Verilator catches many common errors before simulation

## Project Phases

1. **Phase 1** (Current — complete): RV32I base integer instruction set
2. **Phase 2**: M extension (multiply/divide)
3. **Phase 3**: C extension (compressed instructions)
4. **Phase 4**: A extension (atomic operations)
5. **Phase 5**: Privilege modes (M/S/U)
6. **Phase 6**: MMU (virtual memory)
7. **Phase 7**: F/D extension (floating point)
8. **Phase 8**: AXI adapter
9. **Phase 9**: Linux boot
