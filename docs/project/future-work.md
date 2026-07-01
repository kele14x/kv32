# Future Work

Items considered but deferred beyond the Phase 8 (Linux boot) milestone in
[roadmap.md](roadmap.md). See [../spec/10-scope.md §10.2](../spec/10-scope.md)
for the v1 out-of-scope list.

## F/D extension (floating-point)

FPU pipeline, `mstatus.FS`, `fcsr`. Would enable hardware FP for Linux
userspace. Not required for Linux boot — the kernel can trap-and-emulate FP
instructions. If added later, `rv32uf` / `rv32ud` tests would verify correctness.

## Physical Memory Protection (PMP)

Useful for M-mode isolation of firmware regions and for hosting untrusted
S-mode payloads. Linux does not require it. Add in v2.

## Caches (I-cache, D-cache)

Relevant once external memory latency dominates and boot time is a concern. On
BRAM-hosted bring-up the win is small.

## Branch predictor

Beyond the trivial next-PC bit. Only a factor once the pipeline is deeper — the
current multi-cycle FSM has zero branch penalty.

## Debug module (JTAG) and trigger module

Useful for silicon or FPGA debug. Optional for a research bring-up.
