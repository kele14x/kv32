# kv32 Implementation Docs

Topic-oriented documentation of what is implemented in the RTL. For the
architectural specification see [../SPEC.md](../SPEC.md); for build/usage see
[../README.md](../README.md); for agent guidance see [../CLAUDE.md](../CLAUDE.md).

| Doc | Topic | Primary RTL |
|-----|-------|-------------|
| [pipeline.md](pipeline.md) | 5-stage datapath, forwarding, hazards/stalls, branch/jump resolution | `kv32_core.sv`, `kv32_regfile.sv`, `kv32_alu.sv` |
| [decoder.md](decoder.md) | Instruction decode, control signals, illegal-instruction detection | `kv32_decoder.sv` |
| [memory.md](memory.md) | Memory interface, arbiter, sub-word access, misaligned-access handler | `kv32_mem_arbiter.sv`, `kv32_core.sv` |
| [csr.md](csr.md) | M-mode CSR file, address map, read/write/set/clear, legality, MRET, counters | `kv32_csr.sv` |
| [traps.md](traps.md) | Trap detection (illegal/ECALL/EBREAK), pipeline flush, mtvec redirect, MRET | `kv32_core.sv`, `kv32_csr.sv` |
| [verification.md](verification.md) | Unit tests, integration testbench, riscv-tests, simulator options | `tb/*.cpp` |

Each doc references exact `file:line` locations so you can jump straight into
the RTL. Phase/roadmap context lives in [SPEC.md §14](../SPEC.md).
