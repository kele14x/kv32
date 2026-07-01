# kv32 Documentation

kv32 is a minimal RISC-V RV32IMAC soft core in SystemVerilog, designed to boot
Linux on an FPGA. The documentation is organized around three axes.

- **[spec/](spec/)** — Architectural specification. What the core must do:
  execution model, CSR map, memory interface, MMU, boot flow, scope. This is
  the normative reference.
- **[impl/](impl/)** — Implementation notes. How each RTL module realizes the
  spec, plus the non-obvious behaviors and gotchas contributors need to know
  before editing.
- **[verification/](verification/)** — How the core is tested: unit tests,
  integration testbench, `riscv-tests` suite, and the Linux boot goal.
- **[project/](project/)** — Roadmap, future work, and the code-review log.

## Quick jump

| I want to…                                                       | Read                                                                    |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Understand the pipeline / execution model                        | [spec/01-overview.md](spec/01-overview.md), [impl/pipeline.md](impl/pipeline.md) |
| Change the decoder / add an instruction                          | [impl/decoder.md](impl/decoder.md), [spec/02-isa-extensions.md](spec/02-isa-extensions.md) |
| Add or debug a CSR                                               | [spec/03-csr-map.md](spec/03-csr-map.md), [impl/csr.md](impl/csr.md)    |
| Touch the memory interface / misaligned access                   | [spec/04-memory-interface.md](spec/04-memory-interface.md), [impl/memory.md](impl/memory.md) |
| Work on trap handling, delegation, or interrupts                 | [spec/06-traps.md](spec/06-traps.md), [impl/traps.md](impl/traps.md)    |
| Work on the MMU / TLB / page-table walker                        | [spec/07-mmu-sv32.md](spec/07-mmu-sv32.md), [impl/mmu.md](impl/mmu.md)  |
| Run tests                                                        | [verification/strategy.md](verification/strategy.md)                    |
| See what phase we're on                                          | [project/roadmap.md](project/roadmap.md)                                |
| Contribute an RTL change                                         | [../CLAUDE.md](../CLAUDE.md)                                            |

## RTL map

Each `impl/*.md` doc calls out the RTL files it covers.

| RTL file                | Impl doc                          |
| ----------------------- | --------------------------------- |
| `kv32_core.sv`          | [impl/pipeline.md](impl/pipeline.md), [impl/traps.md](impl/traps.md) |
| `kv32_decoder.sv`       | [impl/decoder.md](impl/decoder.md) |
| `kv32_csr.sv`           | [impl/csr.md](impl/csr.md)        |
| `kv32_mem_fe.sv`        | [impl/memory.md](impl/memory.md)  |
| `kv32_mmu.sv`           | [impl/mmu.md](impl/mmu.md)        |
| `kv32_regfile.sv`, `kv32_alu.sv`, `kv32_m_unit.sv`, `kv32_amo_unit.sv`, `kv32_decompressor.sv` | [impl/pipeline.md](impl/pipeline.md) |
| `kv32_pkg.sv`           | (shared types and constants)      |
