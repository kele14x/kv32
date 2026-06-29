# kv32 Implementation Docs

Topic-oriented documentation of what is implemented in the RTL. For the
architectural specification see [../SPEC.md](../SPEC.md); for build/usage see
[../README.md](../README.md); for agent guidance see [../CLAUDE.md](../CLAUDE.md).

| Doc                                | Topic                                                                        | Primary RTL                                      |
| ---------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------ |
| [pipeline.md](pipeline.md)         | Multi-cycle FSM execution model (FETCH/DECODE/EXEC/MEM/WRITEBACK), state transitions, memory access | `kv32_core.sv`, `kv32_regfile.sv`, `kv32_alu.sv` |
| [decoder.md](decoder.md)           | Instruction decode, control signals, illegal-instruction detection           | `kv32_decoder.sv`                                |
| [memory.md](memory.md)             | Memory interface, sub-word access, misaligned-access handler (`kv32_mem_fe`) | `kv32_mem_fe.sv`, `kv32_core.sv`                 |
| [csr.md](csr.md)                   | CSR file, M/S/U-mode CSRs, privilege-aware access control, delegation, counters | `kv32_csr.sv`                                    |
| [traps.md](traps.md)               | Trap detection, delegation, vectored vectors, MRET/SRET, interrupt taking, privilege gating | `kv32_core.sv`, `kv32_csr.sv`                    |
| [verification.md](verification.md) | Unit tests, integration testbench, riscv-tests, simulator options            | `tb/*.cpp`                                       |
| [code_review.md](code_review.md)   | Outstanding review items (2026-06-25): high/medium/low priority fixes        | All RTL files                                    |

Each doc references the relevant RTL files by name so you can jump straight
into the RTL. Phase/roadmap context lives in [SPEC.md §14](../SPEC.md).
