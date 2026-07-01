# 9. Boot Flow

> The CPU core itself has no boot logic beyond starting instruction fetch at
> the reset vector. Everything below is SoC-level behavior observed by the CPU
> as a sequence of instruction fetches and data reads/writes over AXI.

1. **Reset**: CPU core starts in M-mode with `mstatus.MIE=0`, `mtvec`/`satp`/etc.
   at implementation-defined values. First instruction fetch targets the reset
   vector (0x0000_0000 by default), served by the integrated boot ROM
   (see [04-memory-interface.md §4.6](04-memory-interface.md)) or an external
   BRAM if `INTEGRATE_BOOT_ROM=0`.
2. **Boot ROM** (integrated or external): minimal firmware — sets `mtvec`,
   sets up a stack in RAM, copies/decompresses the kernel image from flash
   (or other persistent storage, via AXI) into main RAM at 0x8000_0000+.
3. **OpenSBI / BBL** (runs in M-mode, lives in RAM): provides SBI calls to
   S-mode — console I/O, timer, IPI, RFENCE. Implemented as an M-mode trap
   handler that services `ecall` from S.
4. **Jump to kernel**: M-mode firmware sets `mstatus.MPP=S`, writes kernel
   entry address to `mepc`, executes `mret`. CPU begins fetching from the
   kernel in RAM.
5. **Linux S-mode**: kernel runs, sets up `satp` (Sv32), traps handled via
   `stvec`. Traps needing M-mode (SBI calls, non-delegated interrupts) escalate
   via `ecall` / trap-and-forward.
6. **initramfs**: kernel mounts embedded initramfs as rootfs, runs `/init`.

**Simplification for first bring-up**: skip OpenSBI and provide a minimal
M-mode trap handler in boot ROM that services SBI calls directly. Add full
OpenSBI once the core is stable.
