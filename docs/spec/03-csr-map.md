# 3. CSR Map

For RTL details on the CSR file (privilege gating, delegation logic, write chain) see [../impl/csr.md](../impl/csr.md).

## 3.1 Machine-Mode CSRs (mandatory)

| Address | Name       | Purpose                                                                          |
| ------- | ---------- | -------------------------------------------------------------------------------- |
| 0x300   | `mstatus`  | Machine status (MIE, MPIE, MPP, SIE, SPIE, SPP, MPRV, SUM, MXR, etc.)        |
| 0x301   | `misa`     | ISA description (read-only: MXL=1, IMACSU bits)                                |
| 0x304   | `mie`      | Machine interrupt enable                                                         |
| 0x305   | `mtvec`    | Machine trap vector base + mode (direct/vectored)                                |
| 0x340   | `mscratch` | Scratch for M-mode trap handler                                                  |
| 0x341   | `mepc`     | Machine exception PC                                                             |
| 0x342   | `mcause`   | Machine trap cause (interrupt + exception code)                                  |
| 0x343   | `mtval`    | Machine trap value (bad addr / instruction)                                      |
| 0x344   | `mip`      | Machine interrupt pending                                                        |
| 0x310   | `mstatush` | (RV32 only) high-half of mstatus — MBIGENDIAN, SBE, MBE                          |

Counters:

| Address   | Name          | Purpose                                |
| --------- | ------------- | -------------------------------------- |
| 0xB00     | `mcycle`      | Cycle counter (low 32)                 |
| 0xB80     | `mcycleh`     | Cycle counter (high 32)                |
| 0xB02     | `minstret`    | Instructions retired (low 32)          |
| 0xB82     | `minstreth`   | Instructions retired (high 32)         |

`mcounteren` (0x306): controls S-mode access to cycle/time/instret.

## 3.2 Supervisor-Mode CSRs

| Address | Name       | Purpose                                                                |
| ------- | ---------- | ---------------------------------------------------------------------- |
| 0x100   | `sstatus`  | Supervisor status (view of mstatus subset)                             |
| 0x104   | `sie`      | Supervisor interrupt enable (view of mie)                              |
| 0x105   | `stvec`    | Supervisor trap vector                                                 |
| 0x140   | `sscratch` | Scratch for S-mode trap handler                                        |
| 0x141   | `sepc`     | Supervisor exception PC                                                |
| 0x142   | `scause`   | Supervisor trap cause                                                  |
| 0x143   | `stval`    | Supervisor trap value                                                  |
| 0x144   | `sip`      | Supervisor interrupt pending (view of mip)                             |
| 0x180   | `satp`     | Supervisor address translation and protection (Sv32 mode + PPN + ASID) |

`scounteren` (0x106): controls U-mode counter access.

## 3.3 User-Mode CSRs (counters only)

| Address   | Name         | Purpose                                                                           |
| --------- | ------------ | --------------------------------------------------------------------------------- |
| 0xC00     | `cycle`      | Read-only shadow of `mcycle`                                                      |
| 0xC80     | `cycleh`     | High half                                                                         |
| 0xC01     | `time`       | Wall-clock time — **emulated by M-mode firmware** (reads CLINT `mtime` over AXI)  |
| 0xC81     | `timeh`      | High half (emulated)                                                              |
| 0xC02     | `instret`    | Read-only shadow of `minstret`                                                    |
| 0xC82     | `instreth`   | High half                                                                         |

**`time` CSR**: The CPU core does **not** implement `time`/`timeh` in hardware.
Reads to addresses 0xC01 / 0xC81 raise an illegal-instruction trap; M-mode
firmware (OpenSBI) handles the trap by reading `mtime` from the CLINT over the
AXI bus and writing the result into the trapped register. This keeps the CPU
core free of any dependency on the CLINT's physical location or clock domain.
