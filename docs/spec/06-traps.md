# 6. Interrupts and Exceptions

For RTL details on trap detection, delegation, vectored dispatch, MRET/SRET, and
interrupt taking see [../impl/traps.md](../impl/traps.md).

## 6.1 Interrupt sources

The CPU core exposes **one external interrupt input pin**, active-high:

| Pin                | Drives `mip` bit   | Source (SoC-side)               |
| ------------------ | ------------------ | ------------------------------- |
| `irq_external_i`   | MEIP (bit 11)      | PLIC claim non-zero             |

The other two interrupt sources are **internal to the core**:

| Internal signal   | Drives `mip` bit   | Source (core-internal)          |
| ----------------- | ------------------ | ------------------------------- |
| `msip_i`          | MSIP (bit 3)       | CLINT `msip` register           |
| `mtip_i`          | MTIP (bit 7)       | CLINT `mtime >= mtimecmp`       |

These internal signals are produced by the integrated CLINT (see
[05-clint-plic.md](05-clint-plic.md)) and sampled every cycle. Supervisor-mode
interrupts (SSI/STI/SEI) are not separate pins — they are derived inside the
CPU by delegation through `mideleg`.

`mip` bits: `SSIP`(1), `SSIE`(1), `STIP`(5), `STIE`(5), `SEIP`(9), `SEIE`(9), `MSIP`(3), `MTIP`(7), `MEIP`(11).

Interrupt taken when:

1. Corresponding `mip` and `mie` bits set
2. Global enable for the target mode (`mstatus.MIE` for M-mode traps, `mstatus.SIE` for S-mode traps while in S/U)
3. Delegation: if the interrupt's mode ≤ current privilege and `mideleg` delegates it to S, trap to S; else trap to M.

## 6.2 Exceptions (synchronous)

| Cause | Name                           | Trap value                |
| ----- | ------------------------------ | ------------------------- |
| 0     | Instruction address misaligned | Faulting PC               |
| 1     | Instruction access fault       | Faulting PC               |
| 2     | Illegal instruction            | Faulting instruction word |
| 3     | Breakpoint (ebreak)            | PC                        |
| 4     | Load address misaligned        | Faulting address          |
| 5     | Load access fault              | Faulting address          |
| 6     | Store/AMO address misaligned   | Faulting address          |
| 7     | Store/AMO access fault         | Faulting address          |
| 8     | Environment call from U        | 0                         |
| 9     | Environment call from S        | 0                         |
| 11    | Environment call from M        | 0                         |
| 12    | Instruction page fault         | Faulting virtual address  |
| 13    | Load page fault                | Faulting virtual address  |
| 15    | Store/AMO page fault           | Faulting virtual address  |

**Misaligned access**: Linux expects misaligned loads/stores to work. This
implementation handles them in hardware via `kv32_mem_fe`
(see [04-memory-interface.md §4.3](04-memory-interface.md)) — cause 4/6
(load/store address misaligned) is never raised for data accesses. Cause 5/7
(load/store access fault) is raised only on `dmem_err` from the slave, or on
the §4.3 address-overflow case. The instruction-address misaligned trap
(cause 0) is still raised for misaligned jump targets, since `imem_*` never
performs a split fetch.

**Priority**: Traps are precise. Within a single instruction, exception priority per the spec (breakpoint > instruction page fault > instruction access fault > illegal instruction > address misaligned > load/store faults).

## 6.3 Trap vector modes

`mtvec` / `stvec` MODE field:

- 0 (Direct): all traps jump to BASE
- 1 (Vectored): asynchronous interrupts jump to BASE + 4×cause; exceptions still to BASE

Linux typically uses vectored mode.
