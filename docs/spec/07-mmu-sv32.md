# 7. MMU — Sv32

For RTL implementation notes see [../impl/mmu.md](../impl/mmu.md).

## 7.1 Page table format

- Two-level page table: 10-bit VPN[1] + 10-bit VPN[0] + 12-bit offset
- PTE is 32 bits:

```text
 31                  20 19          10 9  8 7   6   5   4   3   2   1   0
+----------------------+--------------+----+---+---+---+---+---+---+---+---+
| PPN[1]               | PPN[0]       |RSW | D | A | G | U | X | W | R | V |
+----------------------+--------------+----+---+---+---+---+---+---+---+---+
```

- V=0: invalid
- R=0,W=1: reserved (fault)
- R=W=X=0: pointer to next-level page table
- Otherwise: leaf PTE

## 7.2 `satp` CSR format (Sv32)

```text
 31    30        21 20                         0
+-------+----------+---------------------------+
| MODE  |   ASID   |           PPN             |
+-------+----------+---------------------------+
```

MODE=0: Bare (no translation); MODE=1: Sv32.

## 7.3 Translation algorithm

1. If MODE=Bare or privilege=M (unless `mstatus.MPRV`=1 and `mstatus.MPP`≠M), physical = virtual.
2. Let `a = satp.PPN << 12`; let `i = 1` (level).
3. PTE at address `a + VPN[i] × 4`.
4. If PTE invalid or reserved encoding → page fault.
5. If PTE is leaf: check permissions (R/W/X vs access type; U bit vs privilege; `mstatus.SUM` overrides S-mode U-page access; `mstatus.MXR` makes R-pages readable as executable). Check PPN alignment for superpages (4 MiB: PPN[0] must be 0).
6. If PTE is non-leaf: `a = PTE.PPN << 12`; `i = i - 1`; goto step 3.
7. Update A/D bits in PTE if hardware-managed (recommended; Linux expects this).

## 7.4 TLB

- Small direct-mapped or set-associative TLB (e.g., 16 or 32 entries)
- Tagged by {ASID, VPN}; store PPN + permissions + page size
- `sfence.vma` invalidates matching entries (by address and/or ASID)
- On context switch (satp write), software issues `sfence.vma`
