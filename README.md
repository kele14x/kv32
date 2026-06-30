# kv32

A minimal RISC-V RV32IMAC soft core written in SystemVerilog, designed to boot Linux on an FPGA.

The core implements a multi-cycle state machine (FETCH/DECODE/EXEC/MEM/WRITEBACK) executing one instruction at a time — single issue, in-order, no forwarding or hazard detection. Phase 5 (RV32IMAC + M/S/U privilege modes) is complete; Phase 6 (Sv32 MMU) is in progress.

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
make unit-tests                       # run all 8 unit tests
make unit-test-alu                    # ALU: all 10 ops, edge cases
make unit-test-regfile                # Regfile: x0, write-during-read, dual-port
make unit-test-decoder                # Decoder: all opcodes, immediates, CSR variants
make unit-test-decompressor           # Decompressor: all RV32C instruction formats
make unit-test-csr                    # CSR: read/write/set/clear, trap, MRET/SRET, counters, privilege
make unit-test-mem_fe                 # Memory FE: store positioning, load extraction, misaligned FSM
make unit-test-m_unit                 # M-unit: MUL/MULH/DIV/REM
make unit-test-amo_unit               # AMO unit: all 9 atomic operations
```

Each testbench prints a summary line (`=== tb_<module>: N tests, M failures ===`) and exits non-zero on failure.

### riscv-tests

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is included as a git submodule at `tests/riscv-tests`.

#### First-time setup

```bash
git submodule update --init --recursive
```

#### Compile the test suite

The tests are compiled to ELF binaries for multiple ISA subsets:

| Suite    | ISA subset       | What it covers                        |
| -------- | ---------------- | ------------------------------------- |
| `rv32ui` | RV32I + Zicsr    | Base integer instructions             |
| `rv32um` | RV32IM + Zicsr   | M extension (multiply/divide)         |
| `rv32uc` | RV32IC + Zicsr   | C extension (compressed instructions) |
| `rv32ua` | RV32IA + Zicsr   | A extension (atomics: LR/SC, AMO)     |
| `rv32mi` | RV32I + Zicsr    | Machine-mode privilege                |

```bash
make riscv-tests-compile
```

This cross-compiles every test in the suites above into `build/riscv-tests/`. The Makefile auto-detects the RISC-V cross-compiler (`riscv64-unknown-elf-gcc` → `riscv32-unknown-elf-gcc` → `riscv64-elf-gcc`). Override with:

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

Use `riscv-test-<name>` for `rv32ui` tests, or `riscv-test-<suite>-<name>` for other suites (`m` = rv32um, `c` = rv32uc, `a` = rv32ua, `mi` = rv32mi), where `<name>` matches a file in `tests/riscv-tests/isa/rv32<suite>/` (without the `.S` extension):

```bash
make riscv-test-add        # rv32ui ADD test
make riscv-test-lui        # rv32ui LUI test
make riscv-test-bne        # rv32ui BNE branch test
make riscv-test-lw         # rv32ui LW load test
make riscv-test-m-mul      # rv32um MUL test
make riscv-test-c-add      # rv32uc C.ADD test
make riscv-test-a-lr_w     # rv32ua LR.W test
make riscv-test-mi-csr     # rv32mi CSR test
make riscv-test-add MEM_RANDOM_LATENCY=1
make riscv-test-add IMEM_LATENCY=1 DMEM_LATENCY=10
```

To list available test names for a given suite:

```bash
ls tests/riscv-tests/isa/rv32ui/*.S | xargs -n1 basename -s .S   # base integer
ls tests/riscv-tests/isa/rv32um/*.S | xargs -n1 basename -s .S   # M extension
ls tests/riscv-tests/isa/rv32uc/*.S | xargs -n1 basename -s .S   # C extension
ls tests/riscv-tests/isa/rv32ua/*.S | xargs -n1 basename -s .S   # A extension
ls tests/riscv-tests/isa/rv32mi/*.S | xargs -n1 basename -s .S   # M-mode privilege
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
  kv32_core.sv        Top-level FSM datapath integration
  kv32_decoder.sv     Instruction decoder and control signals
  kv32_alu.sv         Arithmetic/logic unit
  kv32_regfile.sv     32x32-bit register file
  kv32_csr.sv         M/S/U-mode CSR register file with delegation and privilege gating
  kv32_mem_fe.sv      Data memory front-end: sub-word positioning, load extraction, misalignment FSM
  kv32_m_unit.sv      M extension: multiplier (DSP-inferred) and iterative divider
  kv32_decompressor.sv C extension: 16-bit → 32-bit instruction decompressor
  kv32_amo_unit.sv    A extension: AMO compute unit (used by LR/SC and AMO ops)
  kv32_mmu.sv         Sv32 MMU: TLB and hardware page table walker
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

See [SPEC.md §14 (Implementation Order)](SPEC.md) for the full phase breakdown. Phase 5 (RV32IMAC + M/S/U privilege modes) is complete; Phase 6 (Sv32 MMU) is in progress.

## License

See individual source files for license terms.
