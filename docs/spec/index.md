# kv32 Architectural Specification

**Goal**: A synthesizable RISC-V core as simple as possible while still booting a Linux kernel + initramfs on an FPGA.

**ISA**: RV32IMAC_Zicsr_Zifencei

This directory is the normative architectural specification. Implementation notes on the RTL that realizes the spec live under [../impl/](../impl/); verification strategy and per-suite coverage live under [../verification/](../verification/); the phase-by-phase roadmap and future work live under [../project/](../project/).

| Section | File | Topic |
| ------- | ---- | ----- |
| 1 | [01-overview.md](01-overview.md) | Execution model, register file, privilege modes |
| 2 | [02-isa-extensions.md](02-isa-extensions.md) | M and A extension semantics and hardware |
| 3 | [03-csr-map.md](03-csr-map.md) | Machine / Supervisor / User-mode CSRs |
| 4 | [04-memory-interface.md](04-memory-interface.md) | `imem_*` / `dmem_*` protocol, alignment, address space, AXI4 adapter |
| 5 | [05-clint-plic.md](05-clint-plic.md) | CLINT (integrated) and PLIC (SoC-level) register maps |
| 6 | [06-traps.md](06-traps.md) | Interrupts, exceptions, trap vectors, delegation |
| 7 | [07-mmu-sv32.md](07-mmu-sv32.md) | Sv32 page tables, `satp`, translation algorithm, TLB |
| 8 | [08-special-insts.md](08-special-insts.md) | Zifencei, atomics, fences, WFI |
| 9 | [09-boot-flow.md](09-boot-flow.md) | Reset, boot ROM, OpenSBI/BBL, kernel entry |
| 10 | [10-scope.md](10-scope.md) | SoC-level peripherals and out-of-scope features |
