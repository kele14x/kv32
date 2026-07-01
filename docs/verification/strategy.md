# Verification Strategy

This directory documents how the kv32 core is verified. The layered approach
follows the RISC-V Privileged Spec verification flow, moving from unit-level
correctness up to full Linux boot.

For build/run commands see [../../README.md](../../README.md); for Verilator
signal-level debugging see [../../CLAUDE.md](../../CLAUDE.md).

## Layers

1. **Unit tests** — each functional unit (ALU, decoder, regfile, decompressor,
   CSR, mem_fe, M-unit, AMO unit, MMU) with directed test vectors. Isolate
   module-boundary bugs before integration. See [unit-tests.md](unit-tests.md).
2. **Integration tests** — full-core Verilator simulation driven by
   `tb/tb_core.sv` + `tb/tb_core.cpp` with a SystemVerilog BRAM/latency model.
   Two built-in programs cover ALU and sub-word memory paths. See
   [integration-tests.md](integration-tests.md).
3. **`riscv-tests`** — the official ISA test suite compiled to flat binaries and
   run through the integration testbench. Validates base ISA + M/C/A extensions
   + M-mode privilege. See [riscv-tests.md](riscv-tests.md).
4. **`riscv-arch-test`** *(planned)* — compliance tests from RISC-V International.
5. **Co-simulation** *(planned)* — compare RTL trace against Spike or QEMU
   instruction-by-instruction.
6. **Linux boot test** *(planned)* — kernel + busybox initramfs; success = shell
   prompt on UART.

## Bus-latency stress

All integration and `riscv-tests` runs accept `MEM_LATENCY`,
`MEM_RANDOM_LATENCY`, and per-port `IMEM_LATENCY` / `DMEM_LATENCY` knobs. These
exercise the `kv32_mem_fe` misalignment FSM and pipeline stall paths — see
[../impl/memory.md](../impl/memory.md) and [../impl/pipeline.md](../impl/pipeline.md).
Each verification layer's file lists the specific overrides it accepts.
