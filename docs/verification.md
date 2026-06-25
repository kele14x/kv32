# Verification

Test infrastructure and what each suite covers. For build/run commands see
[README.md](../README.md#building-and-running); for Verilator signal-level
debugging see [CLAUDE.md](../CLAUDE.md#debugging-tips).

## Unit tests

Each RTL submodule has an isolated Verilator C++ testbench in `tb/`, compiled
with that module as the Verilator top (`--top-module kv32_<module>`) in a
separate `build/obj_dir_<module>/`. Each prints
`=== tb_<module>: N tests, M failures ===` and exits non-zero on failure.

| Testbench        | Module         | Coverage                                                                                                                                           |
| ---------------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tb_alu.cpp`     | `kv32_alu`     | all 10 ALU ops, edge cases (overflow, signed/unsigned, shifts)                                                                                     |
| `tb_regfile.cpp` | `kv32_regfile` | x0 hardwire, write-then-read, write-during-read, dual-port, `we` gating                                                                            |
| `tb_decoder.cpp` | `kv32_decoder` | all opcodes, immediate types, control signals, CSR variants, illegal instructions (bad funct7, invalid funct3 for branch/load/store/JALR/misc-mem) |
| `tb_csr.cpp`     | `kv32_csr`     | read/write/set/clear, read-before-write, trap/MRET, counters, `mtvec` MODE masking, write priority chain, `csr_illegal` (unimplemented/read-only)  |
| `tb_mem_fe.cpp`  | `kv32_mem_fe`  | store positioning, load extraction (sign/zero-extend), aligned/misaligned access flows, crossing FSM transitions, reset, error abort               |

Run all: `make unit-tests`. Run one: `make unit-test-<module>`.

## Integration tests

`tb/tb_core.sv` is the Verilator top for full-core testing. It instantiates
`kv32_core` plus `tb/tb_core_mem.sv`, a SystemVerilog memory model that:

- stores the 64 KiB BRAM contents directly in SV (`mem[]`),
- models the req/gnt/ack handshake for both IMEM and DMEM,
- supports fixed and randomized per-port latency, and
- synthesizes the reset-vector trampoline when the BRAM is mapped at
  `0x80000000` for riscv-tests binaries.

`tb/tb_core.cpp` is now a thin harness around that SV testbench. Key roles:

- **Clock/reset + trace driver** — advances the SV testbench and writes the VCD.
- **Backdoor memory initialization** — parses built-in programs, ELF files, or
  flat binaries in C++ and writes the flashed bytes directly into the SV BRAM
  array before reset.
- **Register / tohost inspection** — reads the DUT register file via `rootp->`
  for built-in checks and reads `tohost_word_o` for riscv-tests pass/fail.

### Simulator options

| Flag              | Description                                             | Default        |
| ----------------- | ------------------------------------------------------- | -------------- |
| `--binary <path>` | load an ELF or flat binary instead of the built-in test | *(none)*       |
| `--test <name>`   | built-in test: `alu`/`0`, `subword`/`1`                 | `alu`          |
| `--cycles <n>`    | max simulation cycles before timeout                    | `50000`        |
| `--notrace`       | disable VCD trace output                                | *(tracing on)* |
| `--latency <n>`   | fixed memory response latency in cycles (0 = combinational) | `1`        |
| `--random-latency`| randomize per-request latency (90%: 1-3 cycles, 10%: 4-10 cycles) | `off` |
| `--imem-latency <n>` | fixed instruction-memory latency override            | uses `--latency` |
| `--dmem-latency <n>` | fixed data-memory latency override                   | uses `--latency` |
| `--imem-random-latency` | randomize instruction-memory latency             | `off` |
| `--dmem-random-latency` | randomize data-memory latency                    | `off` |

`--latency` is the deterministic knob for exercising the `kv32_mem_fe`
misalignment FSM hold states and the pipeline `mem_stall` paths (see
[memory.md](memory.md) and [pipeline.md](pipeline.md)). `--random-latency`
switches the SV memory model into a stress mode that keeps most transactions in
the 1-3 cycle range while occasionally stretching them as far as 10 cycles.
`--imem-*` and `--dmem-*` allow isolating instruction-side vs data-side latency
when debugging failures.

The Makefile forwards these settings into the integration simulator and
`riscv-tests` runs:

```bash
make test-all MEM_LATENCY=2
make test-all MEM_RANDOM_LATENCY=1
make test-all IMEM_LATENCY=10 DMEM_LATENCY=1
make test-all IMEM_LATENCY=1 DMEM_LATENCY=10
make riscv-tests MEM_LATENCY=2
make riscv-tests MEM_RANDOM_LATENCY=1
make riscv-tests IMEM_LATENCY=10 DMEM_LATENCY=1
```

## riscv-tests

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is a git
submodule at `tests/riscv-tests`. First-time setup:

```bash
git submodule update --init --recursive
```

Compiled to ELF targeting RV32I + Zicsr into `build/riscv-tests/` via
`make riscv-tests-compile` (auto-detects the RISC-V cross-compiler; override
with `RISCV_GCC=/path/to/riscv-gcc`). Run all with `make riscv-tests`, or a
single test with `make riscv-test-<name>` (e.g. `riscv-test-add`,
`riscv-test-lw`).

The env/p startup uses a trap-and-skip pattern for optional CSRs — see
[traps.md](traps.md#trap-and-skip-pattern).

## Built-in tests

- **ALU test** (`--test alu`): arithmetic + register operations. Default
  `make verilator` target.
- **Sub-word test** (`--test subword`, `make test-subword`): 11/11 checks across
  LB/LBU/LH/LHU/LW and SB/SH/SW, including byte-enable verification.

Run both: `make test-all`. Unit tests do not use these latency controls because
they do not drive the full integration memory model in `tb/tb_core.sv`.
