# kv32

A minimal RISC-V RV32GC soft core written in SystemVerilog, designed to boot Linux on an FPGA.

The core implements a 5-stage in-order pipeline (IF/ID/EX/MEM/WB) with forwarding and hazard detection. Phase 1 (RV32I base integer ISA + M-mode CSRs) is complete.

See [SPEC.md](SPEC.md) for the full architectural specification (pipeline, CSR map, memory interface, privilege modes, MMU, boot flow).

## Prerequisites

- **Verilator** — lint checking and simulation
- **RISC-V cross-compiler** — `riscv64-unknown-elf-gcc`, `riscv32-unknown-elf-gcc`, or `riscv64-elf-gcc` for building riscv-tests binaries (auto-detected by the Makefile)

## Building and Running

### Lint check

Run this first after any RTL change:

```bash
make lint
```

### Built-in tests

The project ships with two C++ testbenches (Verilator) that exercise the ALU and sub-word memory paths:

```bash
make verilator          # compile and run the ALU test (default)
make test-subword       # run the sub-word memory test
make test-all           # run both
```

### Unit tests

Each RTL submodule has an isolated Verilator C++ testbench that exercises it independently of the full core. These catch module-boundary bugs before integration.

```bash
make unit-tests                       # run all 5 unit tests
make unit-test-alu                    # ALU: all 10 ops, edge cases
make unit-test-regfile                # Regfile: x0, write-during-read, dual-port
make unit-test-decoder                # Decoder: all opcodes, immediates, CSR variants
make unit-test-csr                    # CSR: read/write/set/clear, trap, MRET, counters
make unit-test-mem_arbiter            # Arbiter: priority, zero/multi-cycle, gnt pulse
```

Each testbench prints a summary line (`=== tb_<module>: N tests, M failures ===`) and exits non-zero on failure.

### riscv-tests

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is included as a git submodule at `tests/riscv-tests`.

#### First-time setup

```bash
git submodule update --init --recursive
```

#### Compile the test suite

The tests are compiled to ELF binaries targeting the RV32I + Zicsr ISA:

```bash
make riscv-tests-compile
```

This cross-compiles every `rv32ui` test into `build/riscv-tests/`. The Makefile auto-detects the RISC-V cross-compiler (`riscv64-unknown-elf-gcc` → `riscv32-unknown-elf-gcc` → `riscv64-elf-gcc`). Override with:

```bash
make riscv-tests-compile RISCV_GCC=/path/to/riscv-gcc
```

#### Run all tests

```bash
make riscv-tests
```

This runs every compiled binary through the Verilator simulation and reports pass/fail/timeout counts.

#### Run a single test

Use `riscv-test-<name>`, where `<name>` matches a file in `tests/riscv-tests/isa/rv32ui/` (without the `.S` extension):

```bash
make riscv-test-add        # run the ADD test
make riscv-test-lui        # run the LUI test
make riscv-test-bne        # run the BNE branch test
make riscv-test-lw         # run the LW load test
```

To list available test names:

```bash
ls tests/riscv-tests/isa/rv32ui/*.S | xargs -n1 basename -s .S
```

#### Advanced: running a binary directly

The simulator binary accepts an arbitrary ELF (or flat binary) via `--binary`:

```bash
./obj_dir/Vkv32_core --binary tests/riscv-tests/isa/rv32ui-p-add
./obj_dir/Vkv32_core --binary path/to/custom.elf --cycles 100000
./obj_dir/Vkv32_core --binary path/to/firmware.bin --notrace
```

Options:

| Flag              | Description                                                    | Default        |
| ----------------- | -------------------------------------------------------------- | -------------- |
| `--binary <path>` | Load an ELF or flat binary instead of the built-in test        | *(none)*       |
| `--test <name>`   | Run a built-in test: `alu` / `0`, `subword` / `1`              | `alu`          |
| `--cycles <n>`    | Maximum simulation cycles before timeout                       | `50000`        |
| `--notrace`       | Disable VCD trace output                                       | *(tracing on)* |
| `--latency <n>`   | Memory response latency in cycles (0 = combinational)          | `0`            |

## Project Layout

```text
rtl/          SystemVerilog RTL sources
  kv32_core.sv        Top-level pipeline integration
  kv32_decoder.sv     Instruction decoder and control signals
  kv32_alu.sv         Arithmetic/logic unit
  kv32_regfile.sv     32x32-bit register file
  kv32_csr.sv         M-mode CSR register file
  kv32_mem_arbiter.sv Instruction/data memory mux
  kv32_pkg.sv         Shared types and constants
tb/           Testbenches
  sim_main.cpp        Verilator C++ test driver
tests/        External test suites
  riscv-tests/        riscv-tests submodule
docs/         Phase status and summary notes
```

## Roadmap

See [SPEC.md §14 (Implementation Order)](SPEC.md) for the full phase breakdown. Phase 1 (RV32I + M-mode CSRs) is complete.

## License

See individual source files for license terms.
