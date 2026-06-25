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

`tb/sim_main.cpp` drives `kv32_core` via the Verilator API. Key components:

- **`bram_write()` / `bram_read()`** — 64 KiB BRAM model (word-addressed) with
  byte-enable write support. `bram_base` selects legacy mode (BRAM at
  `0x00000000`) or riscv-tests mode (BRAM at `0x80000000` with a trampoline at
  `0x00000000` that does `LUI`+`JALR` to `bram_entry`).
- **`imem_responder()` / `dmem_responder()`** — drive `*_gnt`/`*_ack`/`*_rdata`
  per port to match the req/gnt/ack protocol (SPEC §4.2). Each port has
  independent latency state; both share the same BRAM model.
- **`read_reg()`** — reads register file state via `rootp->` internal signal
  access.
- **Built-in test programs** — `TestWord[]` arrays (address + instruction
  pairs) and `RegCheck[]` arrays (register + expected value + label).
- **ELF32 loader** — loads an arbitrary ELF (or flat binary) for riscv-tests
  and custom firmware.

### Simulator options

| Flag              | Description                                             | Default        |
| ----------------- | ------------------------------------------------------- | -------------- |
| `--binary <path>` | load an ELF or flat binary instead of the built-in test | *(none)*       |
| `--test <name>`   | built-in test: `alu`/`0`, `subword`/`1`                 | `alu`          |
| `--cycles <n>`    | max simulation cycles before timeout                    | `50000`        |
| `--notrace`       | disable VCD trace output                                | *(tracing on)* |
| `--latency <n>`   | memory response latency in cycles (0 = combinational)   | `0`            |

`--latency` is the main knob for exercising the `kv32_mem_fe` misalignment FSM
hold states and the pipeline `mem_stall` paths (see [memory.md](memory.md) and
[pipeline.md](pipeline.md)).

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

**Status**: all 42 `rv32ui-p` tests PASS at zero latency. The 2-cycle latency
suite currently passes 41/42, with `rv32ui-p-ma_data` still under investigation
after the req/gnt/ack transition. The env/p startup uses a trap-and-skip pattern
for optional CSRs — see [traps.md](traps.md#trap-and-skip-pattern).

## Built-in tests

- **ALU test** (`--test alu`): arithmetic + register operations. Default
  `make verilator` target.
- **Sub-word test** (`--test subword`, `make test-subword`): 11/11 checks across
  LB/LBU/LH/LHU/LW and SB/SH/SW, including byte-enable verification.

Run both: `make test-all`.
