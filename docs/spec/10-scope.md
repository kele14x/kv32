# 10. Scope

## 10.1 SoC-level peripherals (out of CPU core scope)

> The peripherals below are **not part of the CPU core**. They live in the SoC
> wrapper and are reachable via the CPU's AXI4 master port. The CPU sees them
> only as memory-mapped addresses and (for interrupt sources) as external
> input pins. CLINT and boot ROM are integrated inside the core (see
> [04-memory-interface.md §4.6](04-memory-interface.md)).

| Device                  | Purpose                          | Notes                                                           |
| ----------------------- | -------------------------------- | --------------------------------------------------------------- |
| Main RAM                | Kernel + initramfs + page frames | At 0x8000_0000; DDR/SRAM/HyperRAM — CPU-agnostic                |
| PLIC                    | External interrupt routing       | See [05-clint-plic.md §5.2](05-clint-plic.md)                   |
| Minimal 8250 UART       | Console (early printk + shell)   | See §10.1.1                                                     |
| Block device (optional) | Root filesystem if no initramfs  | VirtIO-blk over MMIO, or simple SPI SD                          |

With initramfs baked into the kernel image, a block device is not required for boot.

### 10.1.1 Minimal 8250 UART

v1 implements a minimal 8250-subset UART — no FIFO, no modem control. Linux's
`8250` driver auto-detects FIFO absence (via IIR[7:6]=00) and operates it as a
plain 8250. This is enough for `printk()` and an interactive shell.

**MMIO base**: 0x1000_0000 (conventional; configurable).
**Register stride**: 4 bytes (word-aligned for RV32).
**Interrupt**: one output pin to PLIC (source 10 by convention).

Implemented registers:

| Offset | R/W | Name | Purpose                                           |
| ------ | --- | ---- | ------------------------------------------------- |
| 0x00   | R   | RBR  | Receive Buffer Register (read incoming byte)      |
| 0x00   | W   | THR  | Transmit Holding Register (write byte to send)    |
| 0x04   | R/W | IER  | Interrupt Enable (bits 0–3: RDA, THRE, RLS, MS)   |
| 0x08   | R   | IIR  | Interrupt ID (identifies pending interrupt)       |
| 0x0C   | R/W | LCR  | Line Control (data bits, stop bits, parity, DLAB) |
| 0x14   | R   | LSR  | Line Status (DR, OE, PE, FE, BI, THRE, TEMT)      |
| 0x1C   | R/W | SCR  | Scratch                                           |

**Not implemented** (reads return 0, writes ignored):

- MCR (0x10) / MSR (0x18) — no modem control lines (CTS/RTS/DSR/DTR). Linux tolerates this for a console-only UART.
- DLL (0x00) / DLM (0x04) — baud rate divisor. Accessed when LCR.DLAB=1. In an FPGA the physical baud rate is set by the TX clock divider outside the register block; the divisor registers are write-only dummies so that software probing them does not hang.
- FCR (0x08 write) — no FIFO. Writes ignored.

**Behavior**:

- **Transmit**: writing THR enqueues a byte into a 1-entry transmit register. LSR.THRE goes low immediately, high once the byte has been shifted out by the bit-rate clock. An interrupt is raised on THRE transition if IER bit 1 is set.
- **Receive**: a byte arriving on RX is latched into a 1-entry receive register. LSR.DR goes high. An interrupt is raised if IER bit 0 is set. Reading RBR clears DR.
- **Overrun**: if a second byte arrives before RBR is read, LSR.OE is set. No interrupt by default; Linux reads fast enough that this rarely fires on a quiet console.
- **No parity / framing error generation** for transmit; receive-side error flags (PE, FE, BI) tied to 0.

**Why not 16550 from the start**: FIFOs add a small FIFO RAM block, read/write pointer logic, and trigger-level comparison — ~2× the RTL of the minimal 8250 for a modest interrupt-latency win. Since the FPGA console has near-zero host-side latency, the win is marginal. Upgrade path is straightforward: swap the register block for a 16550-compatible one behind the same MMIO base; Linux will auto-detect.

## 10.2 Out of scope for v1

- Multi-hart (single hart only)
- Hypervisor (H extension)
- Vector (V) extension
- Bit manipulation (B) extension
- I-cache, D-cache (add later if needed)
- Branch predictor beyond simple next-PC bit
- Superscalar / out-of-order
- Physical Memory Protection (PMP) — useful but Linux does not require it; add in v2
- Hardware breakpoint / trigger module
- Debug module (JTAG)
- **SoC-level components** (PLIC, UART, memory controller, AXI interconnect) — these live in the SoC wrapper around the CPU, not in the CPU core itself (§10.1). CLINT and boot ROM are integrated inside the core (see [04-memory-interface.md §4.6](04-memory-interface.md)).

Speculative additions (F/D floating-point etc.) are tracked under [../project/future-work.md](../project/future-work.md).
