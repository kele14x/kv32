# riscv-tests

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is the RISC-V
Foundation's directed ISA test suite. It is included as a git submodule at
`tests/riscv-tests`.

## First-time setup

```bash
git submodule update --init --recursive
```

## Compiling the suite

The tests are cross-compiled to ELF binaries for multiple ISA subsets:

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

The Makefile auto-detects the RISC-V cross-compiler (`riscv64-unknown-elf-gcc`
→ `riscv32-unknown-elf-gcc` → `riscv64-elf-gcc`). Override with
`RISCV_GCC=/path/to/riscv-gcc`.

The env/p startup uses a trap-and-skip pattern for optional CSRs — see
[../impl/traps.md](../impl/traps.md).

## Running

Run all with `make riscv-tests`, or a single test with
`make riscv-test-<name>` for `rv32ui` and
`make riscv-test-<suite>-<name>` for other suites (`m` = rv32um, `c` = rv32uc,
`a` = rv32ua, `mi` = rv32mi):

```bash
make riscv-tests
make riscv-test-add        # rv32ui ADD test
make riscv-test-m-mul      # rv32um MUL test
make riscv-test-c-add      # rv32uc C.ADD test
make riscv-test-a-lr_w     # rv32ua LR.W test
make riscv-test-mi-csr     # rv32mi CSR test
```

Bus-latency stress modes are inherited from the integration testbench
(see [integration-tests.md](integration-tests.md)):

```bash
make riscv-tests MEM_LATENCY=2
make riscv-tests MEM_RANDOM_LATENCY=1
make riscv-tests IMEM_LATENCY=10 DMEM_LATENCY=1
```

To list available test names for a given suite:

```bash
ls tests/riscv-tests/isa/rv32ui/*.S | xargs -n1 basename -s .S
ls tests/riscv-tests/isa/rv32um/*.S | xargs -n1 basename -s .S
ls tests/riscv-tests/isa/rv32uc/*.S | xargs -n1 basename -s .S
ls tests/riscv-tests/isa/rv32ua/*.S | xargs -n1 basename -s .S
ls tests/riscv-tests/isa/rv32mi/*.S | xargs -n1 basename -s .S
```

## Running a binary directly

The simulator binary accepts an arbitrary ELF (or flat binary) via `--binary`:

```bash
./build/obj_dir/Vtb_core --binary tests/riscv-tests/isa/rv32ui-p-add
./build/obj_dir/Vtb_core --binary path/to/custom.elf --cycles 100000
./build/obj_dir/Vtb_core --binary path/to/firmware.bin --notrace
```

Full flag reference is in [integration-tests.md](integration-tests.md).
