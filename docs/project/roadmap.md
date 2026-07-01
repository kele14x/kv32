# Roadmap — Implementation Phases

Phase-by-phase plan for the kv32 core. Each phase completes when its named
test suite passes.

Current status: Phase 5 complete; Phase 6 (Sv32 MMU) in progress.

1. **Phase 1 — RV32I base**: Multi-cycle FSM datapath (FETCH/DECODE/EXEC/MEM/WRITEBACK states),
   register file, ALU, branch, load/store, CSR file (M-mode only), dual `imem_*`/`dmem_*`
   memory ports with `kv32_mem_fe` handling sub-word and misaligned data access
   (see [../spec/04-memory-interface.md](../spec/04-memory-interface.md)). Run
   `riscv-tests` M-mode binaries.
2. **Phase 2 — M extension** (`kv32_m_unit`): multiplier (FPGA DSP-inferred, 2–3 cycles) and
   iterative divider (radix-2, 32–33 cycles). Integrates by holding the FSM in EXEC state
   while `m_busy` — no new states or forwarding paths needed
   (see [../spec/02-isa-extensions.md §2.1](../spec/02-isa-extensions.md)). Verify with `rv32um` tests.
3. **Phase 3 — C extension**: instruction decompressor (16-bit → 32-bit) at IF output.
   Verify with `rv32uc`.
4. **Phase 4 — A extension**: LR/SC with reservation register; AMO operations. `rv32ua` tests.
5. **Phase 5 — Privilege** ✅: M/S/U modes with `priv_mode` register tracking current privilege.
   Extended `mstatus` (SIE, SPIE, SPP, SUM, MXR, TSR, TW, TVM). S-mode CSRs as restricted views
   of M-mode state (`sstatus`, `sie`, `sip`) plus independent S-mode trap CSRs
   (`stvec`, `sepc`, `scause`, `stval`, `sscratch`). Delegation via `medeleg`/`mideleg`.
   `mret`/`sret` with privilege restoration. `wfi`/`sfence.vma` with privilege gating.
   Vectored trap vectors (`mtvec`/`stvec` MODE=1). Asynchronous interrupt taking at
   ST_FETCH entry with priority (MEI>MSI>MTI>SEI>SSI>STI). U-mode counter access gated
   by `mcounteren`/`scounteren`. Boot a minimal S-mode payload.
6. **Phase 6 — MMU (Sv32)**: page table walker, TLB, `satp`, `sfence.vma`. Run a paging
   S-mode test. See [../spec/07-mmu-sv32.md](../spec/07-mmu-sv32.md) and
   [../impl/mmu.md](../impl/mmu.md).
7. **Phase 7 — AXI adapter + SoC integration**: add AXI4 adapter module
   (see [../spec/04-memory-interface.md §4.7](../spec/04-memory-interface.md)) to translate
   the simple memory interface into AXI4. Wrap the CPU in a SoC with AXI interconnect,
   main RAM (DDR/SRAM/HyperRAM), PLIC, UART. CLINT and boot ROM are already inside the core
   (see [../spec/04-memory-interface.md §4.6](../spec/04-memory-interface.md)). Verify with
   a bare-metal S-mode payload running over real peripherals.
8. **Phase 8 — Linux boot**: integrate OpenSBI, build kernel + initramfs, bring up on FPGA.
   Success = shell prompt on UART.
