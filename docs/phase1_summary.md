# kv32 Phase 1 — Implementation Summary

**Date**: 2026-06-16  
**Status**: RTL written, simulation infrastructure in place, debugging in progress

## What Was Accomplished

### 1. Specification (SPEC.md)
Complete specification for kv32 soft core:
- RV32GC_Zicsr_Zifencei ISA
- 5-stage pipeline (IF/ID/EX/MEM/WB)
- Simple memory interface (req/gnt/valid handshake)
- Two internal ports (i-port for IF, d-port for MEM) + arbiter
- AXI4 adapter deferred to Phase 8
- M/S/U privilege modes with Sv32 MMU
- Integrated CLINT (always) and boot ROM (parameterized)
- FPU (D extension)

### 2. RTL Implementation (Phase 1: RV32I base)
All modules written in SystemVerilog:

**kv32_pkg.sv** — Package with memory interface types  
**kv32_mem_arbiter.sv** — Merges i-port/d-port into single external memory interface  
**kv32_regfile.sv** — 32×32-bit register file (2 read ports, 1 write port)  
**kv32_alu.sv** — ALU operations (ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND)  
**kv32_decoder.sv** — RV32I instruction decoder with immediate generation  
**kv32_core.sv** — 5-stage pipeline with branch/jump logic  

### 3. Simulation Infrastructure
**tb/kv32_core_tb.sv** — Testbench with BRAM memory model  
**tb/sim_main.cpp** — C++ wrapper for Verilator  
**Makefile** — Build scripts for lint and simulation  

### 4. Verification Status
- ✅ Verilator lint passes (no errors, only suppressed warnings)
- ✅ Simulation builds and runs
- ⚠️ Pipeline execution has bugs (PC not incrementing correctly)

## Known Issues (Debugging Required)

1. **PC not incrementing**: Simulation shows PC stuck at 0x00000000, instructions not executing
2. **Memory interface timing**: Arbiter state machine may have timing issues with grant signals
3. **Pipeline stalls**: Hazard detection and forwarding not fully implemented
4. **LUI/AUIPC**: Data paths need verification
5. **JAL/JALR**: Link address (PC+4) writeback needs verification

## Design Decisions Made

### Memory Interface
- Simple handshake protocol (req/gnt/valid) instead of AXI4
- One outstanding transaction (no pipelining)
- Alignment invariant (addr must be aligned to size)
- Misaligned access handled via trap-and-emulate in M-mode

### Tight Coupling
- CLINT integrated inside core (per-hart, per-cycle coupling)
- Boot ROM optionally integrated (INTEGRATE_BOOT_ROM parameter)
- Both intercept address ranges before external memory interface

### Pipeline
- Harvard-like structure (separate i-port and d-port internally)
- Arbiter priority: d-port > i-port
- Structural hazards handled via stalling

## Files Created

```
kv32/
├── SPEC.md                          # Complete specification
├── Makefile                         # Build scripts
├── docs/
│   └── phase1_status.md            # This file
├── rtl/
│   ├── kv32_pkg.sv                 # Package definitions
│   ├── kv32_alu.sv                 # ALU
│   ├── kv32_regfile.sv             # Register file
│   ├── kv32_decoder.sv             # Instruction decoder
│   ├── kv32_mem_arbiter.sv         # Memory arbiter
│   └── kv32_core.sv                # Top-level pipeline
└── tb/
    ├── kv32_core_tb.sv             # Testbench
    └── sim_main.cpp                # Verilator C++ wrapper
```

## Next Steps

### Immediate (Phase 1 completion)
1. **Debug pipeline execution**: Fix PC increment and instruction fetch issues
2. **Add forwarding**: Implement EX→EX and MEM→EX forwarding paths
3. **Add hazard detection**: Load-use stall logic
4. **Fix sub-word memory**: Proper byte-enable handling for LB/LH/SB/SH
5. **Run riscv-tests**: Validate against official ISA test suite

### Phase 2-7 (Extensions)
- Phase 2: M extension (multiplier, divider)
- Phase 3: C extension (16-bit instruction decompressor)
- Phase 4: A extension (LR/SC, AMO)
- Phase 5: Privilege (M/S/U modes, trap delegation)
- Phase 6: MMU (Sv32 page table walker, TLB)
- Phase 7: F/D extension (FPU)

### Phase 8-9 (SoC + Linux)
- Phase 8: AXI adapter + SoC integration
- Phase 9: Linux boot with OpenSBI + initramfs

## Build and Test Commands

```bash
# Lint check
make lint

# Build and run simulation
make verilator

# View VCD trace (requires GTKWave or similar)
gtkwave kv32_core_tb.vcd
```

## Lessons Learned

1. **Arbiter timing**: Grant signals must be set in the correct state machine state
2. **Pipeline complexity**: Even a "simple" 5-stage pipeline has many edge cases
3. **Verification**: VCD tracing is essential for debugging pipeline issues
4. **Incremental development**: Testing each stage independently would have caught bugs earlier

## Resources

- RISC-V ISA Specification: https://riscv.org/specifications/
- Verilator documentation: https://verilator.org/guide/latest/
- SystemVerilog reference: IEEE 1800-2017 standard
