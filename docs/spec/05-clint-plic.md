# 5. Interrupt Controllers

## 5.1 CLINT (Core-Local Interruptor)

> **Scope**: The CLINT is **integrated inside the CPU core module** as a
> tightly-coupled internal memory slave (see [04-memory-interface.md §4.6](04-memory-interface.md)).
> It is not an external SoC component. The register map below is the
> software-visible contract so that standard RISC-V firmware (OpenSBI, Linux)
> can drive timer and software interrupts via the usual memory-mapped writes.

Memory-mapped at 0x0200_0000. Per-hart:

| Offset | Access | Name              | Purpose                            |
| ------ | ------ | ----------------- | ---------------------------------- |
| 0x0000 | R/W    | `msip`            | Machine software interrupt pending |
| 0x4000 | R/W    | `mtimecmp` (low)  | Timer compare low 32 bits          |
| 0x4004 | R/W    | `mtimecmp` (high) | Timer compare high 32 bits         |
| 0xBFF8 | R      | `mtime` (low)     | Free-running timer low 32          |
| 0xBFFC | R      | `mtime` (high)    | Free-running timer high 32         |

- `mtime`: free-running 64-bit counter, increments at `rtc_clock` (e.g., 10 MHz).
- Timer interrupt (`MTI`) pending when `mtime >= mtimecmp`.
- Software interrupt (`MSI`) pending when `msip[0] == 1`.

## 5.2 PLIC (Platform-Level Interrupt Controller)

> **Scope**: The PLIC is a **SoC-level component**, not part of the CPU core.
> It sits behind the CPU's AXI4 master port and drives the CPU's external
> interrupt input pin (see [06-traps.md §6.1](06-traps.md)). The CPU does not
> interact with the PLIC directly; all PLIC configuration (priority, enable,
> threshold, claim/complete) is performed by software via memory-mapped
> reads/writes over the AXI bus.

Memory-mapped at 0x0C00_0000. Simplified for single-hart:

- Up to 32 external interrupt sources (configurable; 32 is enough for UART + a few peripherals)
- Source priority registers at 0x0C00_0004 + 4×source
- Pending bits at 0x0C00_1000 (32-bit bitmap)
- Enable bits at 0x0C00_2000 (per-context)
- Threshold at 0x0C20_0000 (per-context)
- Claim/complete at 0x0C20_0004 (read = claim, write = complete)
- Single context (M-mode) sufficient; add S-mode context via delegation through `mideleg`

External interrupt (`MEI`) raised when any pending+enabled source priority > threshold.
