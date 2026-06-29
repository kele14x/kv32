# M-mode CSR File

Implementation of the CSR register file in `rtl/kv32_csr.sv`. For the
architectural CSR map and privilege-mode plans, see [SPEC.md §3](../SPEC.md).
For the trap mechanism that drives `mepc`/`mcause`/`mtval` updates, see
[traps.md](traps.md). For CSR instruction decoding, see [decoder.md](decoder.md).

**Scope**: M/S/U-mode support with privilege-aware access control, trap
delegation, and vectored interrupt vectors (Phase 5). S-mode CSRs are implemented
as restricted views of M-mode state. MMU (`satp` translation) is Phase 6.

## Implemented CSR address map

### M-mode CSRs (require M-mode privilege)

| Address   | Name         | Access         | Notes                                              |
| --------- | ------------ | -------------- | -------------------------------------------------- |
| 0x300     | `mstatus`    | RW             | full mstatus with SIE/MIE/SPIE/MPIE/SPP/MPP/MPRV/SUM/MXR/TSR/TW/TVM |
| 0x301     | `misa`       | RO             | fixed `MisaVal`; writes ignored                    |
| 0x302     | `medeleg`    | RW             | exception delegation bitmap (bit 11 hardwired 0)   |
| 0x303     | `mideleg`    | RW             | interrupt delegation bitmap (bits 3,7,11 hardwired 0) |
| 0x304     | `mie`        | RW             |                                                    |
| 0x305     | `mtvec`      | RW             | MODE[1:0] supports Direct (00) and Vectored (01)   |
| 0x306     | `mcounteren` | RW             | gates S-mode access to cycle/instret               |
| 0x310     | `mstatush`   | RO             | reads 0 (no big-endian); writes ignored            |
| 0x340     | `mscratch`   | RW             |                                                    |
| 0x341     | `mepc`       | RW             | bit0 forced to 0 on write                          |
| 0x342     | `mcause`     | RW             |                                                    |
| 0x343     | `mtval`      | RW             |                                                    |
| 0x344     | `mip`        | RW (partial)   | SSIP writable; MSIP/MTIP/MEIP HW-driven            |
| 0xB00     | `mcycle`     | RW             | low 32 of 64-bit counter                           |
| 0xB02     | `minstret`   | RW             | low 32 of 64-bit counter                           |
| 0xB80     | `mcycleh`    | RW             | high 32 of `mcycle`                                |
| 0xB82     | `minstreth`  | RW             | high 32 of `minstret`                              |
| 0xF11     | `mvendorid`  | RO             | reads 0                                            |
| 0xF12     | `marchid`    | RO             | reads 0                                            |
| 0xF13     | `mimpid`     | RO             | reads 0                                            |
| 0xF14     | `mhartid`    | RO             | reads 0 (single-hart)                              |
| 0xF15     | `mconfigptr` | RO             | reads 0                                            |

### S-mode CSRs (require S-mode or higher)

| Address   | Name          | Access | Notes                                                |
| --------- | ------------- | ------ | ---------------------------------------------------- |
| 0x100     | `sstatus`     | RW     | masked view of `mstatus` (mask 0x000C_0122)          |
| 0x104     | `sie`         | RW     | masked view of `mie` (masked by `mideleg`)           |
| 0x105     | `stvec`       | RW     | S-mode trap vector (supports Direct and Vectored)    |
| 0x106     | `scounteren`  | RW     | gates U-mode access to cycle/instret                 |
| 0x140     | `sscratch`    | RW     |                                                      |
| 0x141     | `sepc`        | RW     | bit0 forced to 0 on write                            |
| 0x142     | `scause`      | RW     |                                                      |
| 0x143     | `stval`       | RW     |                                                      |
| 0x144     | `sip`         | RW (partial) | SSIP writable if delegated; others read-only     |
| 0x180     | `satp`        | RW     | storage only; translation is Phase 6                 |

### U-mode CSRs (require U-mode or higher)

| Address   | Name       | Access | Notes                                                |
| --------- | ---------- | ------ | ---------------------------------------------------- |
| 0xC00     | `cycle`    | RO     | shadow of `mcycle`; gated by `mcounteren`/`scounteren` |
| 0xC02     | `instret`  | RO     | shadow of `minstret`; gated by `mcounteren`/`scounteren` |
| 0xC80     | `cycleh`   | RO     | high 32 of `cycle`                                   |
| 0xC82     | `instreth` | RO     | high 32 of `instret`                                 |

Note: `time` (0xC01) and `timeh` (0xC81) are always illegal (not implemented).

Constants defined in `kv32_pkg.sv` (package) and `kv32_csr.sv` (local).

## `misa`

Fixed value in `kv32_csr.sv`: `MXL=01` (32-bit) with I, M, C, A, S, U extensions
enabled:

```systemverilog
localparam logic [31:0] MisaVal = {2'b01, 4'b0000, 26'b00_0101_0001_0001_0000_0101};
```

## Reconstructed read values

Several CSRs are not stored as full 32-bit words; only the implemented fields
are stored and the read value is reassembled:

- **`mstatus`**: stores SIE, MIE, SPIE, MPIE, SPP, MPP, MPRV, SUM, MXR, TSR, TW, TVM.
  All other fields (SD, XS, FS) read as 0.
- **`mip`**: MSIP (bit 3) = `irq_software`, MTIP (bit 7) = `irq_timer`,
  MEIP (bit 11) = `irq_external`, SSIP (bit 1) = `mip_ssip` (software-writable).
  The `irq_*` inputs come from the integrated CLINT / external PLIC pin
  (see SPEC §5/§7.1).
- **`sstatus`**: reads `mstatus & 0x000C_0122` (only SIE, SPIE, SPP, SUM, MXR visible).
- **`sie`**: reads `mie & mideleg` (only delegated interrupts visible).
- **`sip`**: reads `mip & mideleg` (only delegated interrupts visible).

## CSR operations and read-before-write

The decoder emits a `csr_op_t` (see `kv32_pkg.sv`):

| `csr_op`       | Instruction   | Effect                |
| -------------- | ------------- | --------------------- |
| `CSR_OP_NONE`  | —             | no-op                 |
| `CSR_OP_WRITE` | CSRRW/CSRRWI  | `csr <- wdata`        |
| `CSR_OP_SET`   | CSRRS/CSRRSI  | `csr <- old \| wdata` |
| `CSR_OP_CLEAR` | CSRRC/CSRRCI  | `csr <- old & ~wdata` |

Reads are combinational and return the **old** value before any write this cycle
in `kv32_csr.sv`, so `rd` always gets the prior CSR contents. The new
value is computed by `csr_new_val()` in `kv32_csr.sv`.

`csr_wdata` is selected in `kv32_core.sv`: zimm-extended
(`{27'b0, instr_reg[19:15]}`) for the immediate CSR variants, else the
`rs1` value (`rs1_data`).

## Write priority chain

Write priority chain in `kv32_csr.sv`, evaluated every clock:

1. **`trap_taken`**: writes `mepc`/`sepc` (bit0 cleared), `mcause`/`scause`,
   `mtval`/`stval`; saves interrupt enable into previous IE, clears current IE,
   sets previous privilege. Updates M-mode or S-mode CSRs based on `trap_to_smode`.
2. **`mret_taken`**: restores `MIE <- MPIE`, sets `MPIE <- 1`, `MPP <- 2'b11`,
   clears `MPRV` if MPP != M.
3. **`sret_taken`**: restores `SIE <- SPIE`, sets `SPIE <- 1`, `SPP <- 0`.
4. **CSR write instruction**: per-address writes via `csr_new_val`. Read-only
   writes are ignored. `mip` only allows writing SSIP.

Because trap and MRET/SRET already sit above the CSR-write case in this chain,
the FSM does **not** need to gate `csr_wen` on `!trap_taken` — see
[traps.md](traps.md#csr-write-gating) for why this matters (combinational-loop
avoidance).

## Counters

`mcycle_r`/`minstret_r` are 64-bit in `kv32_csr.sv`.

- `mcycle_r` increments every cycle.
- `minstret_r` increments when `instr_retired` is high (`state == ST_WRITEBACK`
  and no trap pending — see `kv32_core.sv`).

**Write-suppress guard** in `kv32_csr.sv`: when a CSR write targets
`mcycle`/`mcycleh`/`minstret`/`minstreth` this cycle, the corresponding
free-running increment is suppressed. Without this, the 64-bit non-blocking
increment and the 32-bit non-blocking CSR write would both fire on the same edge
and the increment would clobber the written value.

A trapping instruction never reaches the WRITEBACK state (trap redirects from
EXEC or MEM), so `instr_retired` is low and the trapping instruction does
**not** count toward `minstret` — the RISC-V-preferred behavior.

## Legality check (`csr_illegal`)

Combinational check in `kv32_csr.sv`. An access is illegal when:

- the CSR address is not in the implemented set (any access — read or write), or
- the CSR is read-only (`addr[11:10]==2'b11`, i.e. the 0xF11–0xF15 identity CSRs)
  and a write is attempted, or
- the current privilege mode is insufficient:
  - M-mode CSRs require `priv_mode == PRIV_M`
  - S-mode CSRs require `priv_mode >= PRIV_S` (S or M)
  - U-mode CSRs require `priv_mode >= PRIV_U` (U, S, or M)
  - `satp` access from S-mode traps if `mstatus.TVM=1`
  - `cycle`/`instret` from S-mode gated by `mcounteren`
  - `cycle`/`instret` from U-mode gated by both `mcounteren` and `scounteren`

The check is gated by `is_csr` so non-CSR instructions never report illegal.
`CSRRS`/`CSRRC` with `rs1=x0` suppress `csr_wen` in the decoder, so a read of a
read-only CSR is legal.

`csr_illegal` feeds the trap detector as a source of the illegal-instruction
trap (mcause=2) — see [traps.md](traps.md).

## `mtvec`/`stvec` MODE masking

Both Direct (MODE=0) and Vectored (MODE=1) modes are supported. On write,
`mtvec_r[1:0]` and `stvec_r[1:0]` are validated and forced to `2'b00` if the
mode is invalid (not 0 or 1). The FETCH-state redirect uses the appropriate
vector based on `trap_to_smode` and the MODE field — see [traps.md](traps.md).

## Delegation

Exception and interrupt delegation allow M-mode to forward traps to S-mode:

- `medeleg`: bitmap of exception causes to delegate to S-mode. Bit 11 (ECALL
  from M-mode) is hardwired to 0 (cannot delegate M-mode ECALLs).
- `mideleg`: bitmap of interrupt causes to delegate to S-mode. Bits 3, 7, 11
  (M-mode interrupts) are hardwired to 0 (cannot delegate M-mode interrupts).

When a trap occurs, `kv32_core.sv` computes `trap_to_smode` based on:
- Current privilege mode (`priv_mode <= PRIV_S`)
- Delegation register (`medeleg[cause]` for exceptions, `mideleg[cause]` for interrupts)

If `trap_to_smode=1`, the trap updates S-mode CSRs and redirects to `stvec`;
otherwise it updates M-mode CSRs and redirects to `mtvec`.

## Interrupt pending

The CSR module computes `irq_pending` and `irq_cause` combinationally:

```systemverilog
logic mie_enabled;  // mstatus.MIE if priv_mode==M, else 1'b1
logic sie_enabled;  // mstatus.SIE if priv_mode<=S, else 1'b0

// Priority: MEI > MSI > MTI > SEI > SSI > STI
// Check M-mode interrupts (not delegated) first
// Then check S-mode interrupts (delegated)
```

The core checks `irq_pending` at `ST_FETCH` entry (between instructions) and
takes the interrupt via the existing trap path.
