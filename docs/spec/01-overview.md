# 1. Architecture Overview

## 1.1 Execution Model

Multi-cycle state machine executing one instruction at a time:

```text
FETCH → DECODE → EXEC → MEM → WRITEBACK → FETCH → ...
```

- Single issue, in-order, one instruction completes before the next begins
- No out-of-order, no superscalar, no speculative execution
- No forwarding, no hazard detection, no pipeline flush — only one instruction exists at a time
- Branches/jumps resolve in EXEC with zero penalty (redirect PC and fetch next)
- Multi-cycle operations (memory access, M-extension) hold the FSM in their respective state until complete

**Rationale**: Prioritizes simplicity and correctness over throughput. Adequate for Linux boot on FPGA. Dramatically simpler RTL than a pipelined design — no forwarding paths, no stall cascades, no pipeline flush logic. Easy to understand, debug, and extend.

For the RTL realization see [../impl/pipeline.md](../impl/pipeline.md).

## 1.2 Register File

- 32 × 32-bit general-purpose registers (x0 hardwired to 0)
- Two read ports, one write port
- Combinational read, synchronous write on rising edge during WRITEBACK state

## 1.3 Privilege Modes

Linux requires M, S, and U modes.

| Mode   | Level   | Purpose                                |
| ------ | ------- | -------------------------------------- |
| M      | 3       | Boot, firmware, SBI, trap handling     |
| S      | 1       | Linux kernel                           |
| U      | 0       | Userspace processes                    |

- `mret` / `sret` / `uret` return from respective modes
- Traps from lower modes escalate to the next-higher mode's trap vector (or M if that mode hasn't delegated)
- Delegation: `medeleg` / `mideleg` (M→S); `sedeleg` / `sideleg` (S→U, typically unused under Linux)

The CSR map for each mode is enumerated in [03-csr-map.md](03-csr-map.md); trap-taking behavior is covered in [06-traps.md](06-traps.md).
