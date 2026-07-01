# Integration Tests

`tb/tb_core.sv` is the Verilator top for full-core testing. It instantiates
`kv32_core` plus `tb/tb_core_mem.sv`, a SystemVerilog memory model that:

- stores the 64 KiB BRAM contents directly in SV (`mem[]`),
- models the req/gnt/ack handshake for both IMEM and DMEM,
- supports fixed and randomized per-port latency, and
- synthesizes the reset-vector trampoline when the BRAM is mapped at
  `0x80000000` for riscv-tests binaries.

`tb/tb_core.cpp` is a thin C++ harness around that SV testbench. Key roles:

- **Clock/reset + trace driver** — advances the SV testbench and writes the VCD.
- **Backdoor memory initialization** — parses built-in programs, ELF files, or
  flat binaries in C++ and writes the flashed bytes directly into the SV BRAM
  array before reset.
- **Register / tohost inspection** — reads the DUT register file via `rootp->`
  for built-in checks and reads `tohost_word_o` for riscv-tests pass/fail.

## Built-in programs

- **ALU test** (`--test alu`): arithmetic + register operations. Default
  `make verilator` target.
- **Sub-word test** (`--test subword`, `make test-subword`): 11/11 checks across
  LB/LBU/LH/LHU/LW and SB/SH/SW, including byte-enable verification.

Run both with `make test-all`.

## Simulator options

| Flag                    | Description                                                       | Default          |
| ----------------------- | ----------------------------------------------------------------- | ---------------- |
| `--binary <path>`       | load an ELF or flat binary instead of the built-in test           | *(none)*         |
| `--test <name>`         | built-in test: `alu`/`0`, `subword`/`1`                           | `alu`            |
| `--cycles <n>`          | max simulation cycles before timeout                              | `50000`          |
| `--notrace`             | disable VCD trace output                                          | *(tracing on)*   |
| `--latency <n>`         | fixed memory response latency in cycles (0 = combinational)       | `1`              |
| `--random-latency`      | randomize per-request latency (90%: 1-3 cycles, 10%: 4-10 cycles) | `off`            |
| `--imem-latency <n>`    | fixed instruction-memory latency override                         | uses `--latency` |
| `--dmem-latency <n>`    | fixed data-memory latency override                                | uses `--latency` |
| `--imem-random-latency` | randomize instruction-memory latency                              | `off`            |
| `--dmem-random-latency` | randomize data-memory latency                                     | `off`            |

`--latency` is the deterministic knob for exercising the `kv32_mem_fe`
misalignment FSM hold states and the pipeline `mem_stall` paths (see
[../impl/memory.md](../impl/memory.md) and [../impl/pipeline.md](../impl/pipeline.md)).
`--random-latency` switches the SV memory model into a stress mode that keeps
most transactions in the 1-3 cycle range while occasionally stretching them as
far as 10 cycles. `--imem-*` and `--dmem-*` allow isolating instruction-side vs
data-side latency when debugging failures.

The Makefile forwards these settings into the integration simulator and
`riscv-tests` runs:

```bash
make test-all MEM_LATENCY=2
make test-all MEM_RANDOM_LATENCY=1
make test-all IMEM_LATENCY=10 DMEM_LATENCY=1
make test-all IMEM_LATENCY=1 DMEM_LATENCY=10
```
