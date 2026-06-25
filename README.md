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

The project ships with a Verilator integration testbench (`tb/tb_core.sv` +
`tb/tb_core.cpp`) that exercises two built-in programs covering the ALU and
sub-word memory paths:

```bash
make verilator          # compile and run the ALU test (default)
make test-subword       # run the sub-word memory test
make test-all           # run both
make test-all MEM_LATENCY=2
make test-all MEM_RANDOM_LATENCY=1
make test-all IMEM_LATENCY=10 DMEM_LATENCY=1
make test-all IMEM_LATENCY=1 DMEM_LATENCY=10
```

Integration tests use the simulator's default fixed 1-cycle memory latency.
Override with `MEM_LATENCY=<n>` for a deterministic latency or
`MEM_RANDOM_LATENCY=1` to enable randomized bus stress. To isolate failures,
override `IMEM_LATENCY`, `DMEM_LATENCY`, `IMEM_RANDOM_LATENCY`, and
`DMEM_RANDOM_LATENCY` per port.

### Unit tests

Each RTL submodule has an isolated Verilator C++ testbench that exercises it independently of the full core. These catch module-boundary bugs before integration.

```bash
make unit-tests                       # run all 5 unit tests
make unit-test-alu                    # ALU: all 10 ops, edge cases
make unit-test-regfile                # Regfile: x0, write-during-read, dual-port
make unit-test-decoder                # Decoder: all opcodes, immediates, CSR variants
make unit-test-csr                    # CSR: read/write/set/clear, trap, MRET, counters
make unit-test-mem_fe                 # Memory FE: store positioning, load extraction, misaligned FSM
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
make riscv-tests MEM_LATENCY=2
make riscv-tests MEM_RANDOM_LATENCY=1
make riscv-tests IMEM_LATENCY=10 DMEM_LATENCY=1
```

This runs every compiled binary through the Verilator simulation and reports pass/fail/timeout counts.

#### Run a single test

Use `riscv-test-<name>`, where `<name>` matches a file in `tests/riscv-tests/isa/rv32ui/` (without the `.S` extension):

```bash
make riscv-test-add        # run the ADD test
make riscv-test-lui        # run the LUI test
make riscv-test-bne        # run the BNE branch test
make riscv-test-lw         # run the LW load test
make riscv-test-add MEM_RANDOM_LATENCY=1
make riscv-test-add IMEM_LATENCY=1 DMEM_LATENCY=10
```

To list available test names:

```bash
ls tests/riscv-tests/isa/rv32ui/*.S | xargs -n1 basename -s .S
```

#### Advanced: running a binary directly

The simulator binary accepts an arbitrary ELF (or flat binary) via `--binary`:

```bash
./build/obj_dir/Vtb_core --binary tests/riscv-tests/isa/rv32ui-p-add
./build/obj_dir/Vtb_core --binary path/to/custom.elf --cycles 100000
./build/obj_dir/Vtb_core --binary path/to/firmware.bin --notrace
```

Options:

| Flag              | Description                                                    | Default        |
| ----------------- | -------------------------------------------------------------- | -------------- |
| `--binary <path>` | Load an ELF or flat binary instead of the built-in test        | *(none)*       |
| `--test <name>`   | Run a built-in test: `alu` / `0`, `subword` / `1`              | `alu`          |
| `--cycles <n>`    | Maximum simulation cycles before timeout                       | `50000`        |
| `--notrace`       | Disable VCD trace output                                       | *(tracing on)* |
| `--latency <n>`   | Fixed memory response latency in cycles (0 = combinational)    | `1`            |
| `--random-latency`| Randomize each accepted request latency for bus stress testing | `off`          |
| `--imem-latency <n>` | Fixed instruction-memory latency override                   | uses `--latency` |
| `--dmem-latency <n>` | Fixed data-memory latency override                          | uses `--latency` |
| `--imem-random-latency` | Randomize instruction-memory latency                    | `off`          |
| `--dmem-random-latency` | Randomize data-memory latency                           | `off`          |

## Project Layout

```text
rtl/          SystemVerilog RTL sources
  kv32_core.sv        Top-level pipeline integration
  kv32_decoder.sv     Instruction decoder and control signals
  kv32_alu.sv         Arithmetic/logic unit
  kv32_regfile.sv     32x32-bit register file
  kv32_csr.sv         M-mode CSR register file
  kv32_mem_fe.sv      Data memory front-end: sub-word positioning, load extraction, misalignment FSM
  kv32_pkg.sv         Shared types and constants
tb/           Testbenches
  tb_core.cpp         Full-core Verilator C++ harness
  tb_core.sv          Full-core SystemVerilog testbench top
  tb_core_mem.sv      Full-core SV BRAM + latency model
tests/        External test suites
  riscv-tests/        riscv-tests submodule
docs/         Topic-oriented implementation docs (pipeline, decoder, memory, csr, traps, verification)
```

## Roadmap

See [SPEC.md §14 (Implementation Order)](SPEC.md) for the full phase breakdown. Phase 1 (RV32I + M-mode CSRs) is complete.

## License

See individual source files for license terms.
