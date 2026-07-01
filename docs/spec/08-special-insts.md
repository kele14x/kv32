# 8. Special Instructions

## 8.1 Zifencei — `fence.i`

Synchronize instruction and data streams. Implementation options:

- No I-cache: `fence.i` is a NOP (correct, since data writes go directly to memory).
- With I-cache: flush/invalidate the I-cache pipeline and refetch.

**Recommendation**: start with no I-cache. Add one later if boot time demands it.

## 8.2 A extension — Atomic instructions

LR.W / SC.W and AMO* (SWAP, ADD, AND, OR, XOR, MAX, MIN, MAXU, MINU). See
[02-isa-extensions.md §2.2](02-isa-extensions.md) for the full instruction list
and FSM integration.

- Reservation register: one per hart; stores {valid, address}
- SC.W succeeds only if reservation is valid and address matches; clears reservation on either outcome
- AMO* are read-modify-write, serialized on the bus
- `.aq` / `.rl` bits: implement as ordering fences (conservative, correct)

## 8.3 Fences

- `fence` (general): enforce ordering on memory/IO. Minimum: treat as pipeline drain (correct, conservative).
- `fence.i`: see §8.1.
- `sfence.vma`: TLB invalidation (see [07-mmu-sv32.md §7.4](07-mmu-sv32.md)).

## 8.4 WFI

Wait for interrupt. Can be implemented as NOP (legal per spec). For power savings: halt pipeline until next interrupt.
