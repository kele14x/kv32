# Unit Tests

Each RTL submodule has an isolated Verilator C++ or SystemVerilog testbench in
`tb/`, compiled with that module as the Verilator top
(`--top-module kv32_<module>`) in a separate `build/obj_dir_<module>/`. Each
prints `=== tb_<module>: N tests, M failures ===` and exits non-zero on failure.

## Coverage matrix

| Testbench             | Module            | Coverage                                                                                                                                           |
| --------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tb_alu.sv`           | `kv32_alu`        | all 10 ALU ops, edge cases (overflow, signed/unsigned, shifts)                                                                                     |
| `tb_regfile.sv`       | `kv32_regfile`    | x0 hardwire, write-then-read, write-during-read, dual-port, `we` gating                                                                            |
| `tb_decoder.sv`       | `kv32_decoder`    | all opcodes, immediate types, control signals, CSR variants, illegal instructions (bad funct7, invalid funct3 for branch/load/store/JALR/misc-mem) |
| `tb_decompressor.sv`  | `kv32_decompressor` | all RV32C instruction formats, illegal encodings                                                                                                  |
| `tb_csr.sv`           | `kv32_csr`        | read/write/set/clear, read-before-write, trap/MRET/SRET, counters, `mtvec` MODE masking, write priority chain, `csr_illegal` (unimplemented/read-only), M/S-mode delegation |
| `tb_mem_fe.sv`        | `kv32_mem_fe`     | store positioning, load extraction (sign/zero-extend), aligned/misaligned access flows, crossing FSM transitions, reset, error abort               |
| `tb_m_unit.sv`        | `kv32_m_unit`     | MUL/MULH/MULHSU/MULHU signed/unsigned corners, DIV/DIVU/REM/REMU including divide-by-zero and INT_MIN/-1                                           |
| `tb_amo_unit.sv`      | `kv32_amo_unit`   | all 9 atomic operations (SWAP, ADD, AND, OR, XOR, MAX, MIN, MAXU, MINU) with signed/unsigned corners                                               |
| `tb_mmu.sv`           | `kv32_mmu`        | Sv32 TLB fill, page faults, `sfence.vma` invalidation, hardware A/D bit update                                                                     |

Run all: `make unit-tests`. Run one: `make unit-test-<module>` — e.g.
`make unit-test-alu`, `make unit-test-mem_fe`, `make unit-test-m_unit`.

Unit tests do not use the integration-level latency controls because they do
not drive the full `tb/tb_core.sv` memory model. Each testbench provides its
own directed stimulus at the module boundary.
