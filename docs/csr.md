# M-mode CSR File

Implementation of the Machine-mode CSR register file in `rtl/kv32_csr.sv`. For
the architectural CSR map and privilege-mode plans, see
[SPEC.md §3](../SPEC.md). For the trap mechanism that drives `mepc`/`mcause`/
`mtval` updates, see [traps.md](traps.md). For CSR instruction decoding, see
[decoder.md](decoder.md).

**Scope**: M-mode only. S/U-mode CSRs (`sstatus`, `satp`, `medeleg`/`mideleg`,
etc.) are not implemented; accesses to them trap as illegal (unimplemented CSR).
This is sufficient for the `rv32ui-p` riscv-tests, which use a trap-and-skip
pattern for optional CSRs (see [traps.md](traps.md#trap-and-skip-pattern)).

## Implemented CSR address map

| Address | Name | Access | Notes |
|---------|------|--------|-------|
| 0x300 | `mstatus` | RW | only MIE/MPIE/MPP stored; rest read as 0 |
| 0x301 | `misa` | RO | fixed `MisaVal`; writes ignored |
| 0x304 | `mie` | RW | |
| 0x305 | `mtvec` | RW | MODE[1:0] forced to `00` (Direct-only) |
| 0x306 | `mcounteren` | RW | |
| 0x310 | `mstatush` | RO | reads 0 (no big-endian); writes ignored |
| 0x340 | `mscratch` | RW | |
| 0x341 | `mepc` | RW | bit0 forced to 0 on write |
| 0x342 | `mcause` | RW | |
| 0x343 | `mtval` | RW | |
| 0x344 | `mip` | RO (HW-driven) | MSIP/MTIP/MEIP from `irq_*` inputs; writes ignored |
| 0xB00 | `mcycle` | RW | low 32 of 64-bit counter |
| 0xB02 | `minstret` | RW | low 32 of 64-bit counter |
| 0xB80 | `mcycleh` | RW | high 32 of `mcycle` |
| 0xB82 | `minstreth` | RW | high 32 of `minstret` |
| 0xF11 | `mvendorid` | RO | reads 0 |
| 0xF12 | `marchid` | RO | reads 0 |
| 0xF13 | `mimpid` | RO | reads 0 |
| 0xF14 | `mhartid` | RO | reads 0 (single-hart) |
| 0xF15 | `mconfigptr` | RO | reads 0 |

Constants in `kv32_csr.sv:48-67`.

## `misa`

Fixed value (`kv32_csr.sv:75`): `MXL=01` (32-bit) with only the **I** bit set in
the extensions bitmap. Update `MisaVal` as each extension (M/C/A/F/D) lands:

```systemverilog
localparam logic [31:0] MisaVal = {2'b01, 4'b0000, 26'b00_0000_0000_0000_0001_0000_0000};
```

## Reconstructed read values

Several CSRs are not stored as full 32-bit words; only the implemented fields
are stored and the read value is reassembled:

- **`mstatus`** (`kv32_csr.sv:107-115`): only `mstatus_mie` (bit 3),
  `mstatus_mpie` (bit 7), `mstatus_mpp` (bits 12:11) are stored. All other
  fields (SD, MXR, SUM, MPRV, XS, FS, MPP high, SPP, TSR, TW, TVM) read as 0.
- **`mip`** (`kv32_csr.sv:118-126`): MSIP (bit 3) = `irq_software`, MTIP (bit 7)
  = `irq_timer`, MEIP (bit 11) = `irq_external`. The three `irq_*` inputs come
  from the integrated CLINT / external PLIC pin (see SPEC §5/§7.1).

## CSR operations and read-before-write

The decoder emits a `csr_op_t` (`kv32_pkg.sv:30-35`):

| `csr_op` | Instruction | Effect |
|----------|-------------|--------|
| `CSR_OP_NONE` | — | no-op |
| `CSR_OP_WRITE` | CSRRW/CSRRWI | `csr <- wdata` |
| `CSR_OP_SET` | CSRRS/CSRRSI | `csr <- old | wdata` |
| `CSR_OP_CLEAR` | CSRRC/CSRRCI | `csr <- old & ~wdata` |

Reads are combinational and return the **old** value before any write this cycle
(`kv32_csr.sv:160-185`), so `rd` always gets the prior CSR contents. The new
value is computed by `csr_new_val()` (`kv32_csr.sv:190-201`).

`csr_wdata` is selected in `kv32_core.sv:212`: zimm-extended
(`{27'b0, instr_ex[19:15]}`) for the immediate CSR variants, else the forwarded
`rs1` value (`fwd_a`).

## Write priority chain

`kv32_csr.sv:207-316`, evaluated every clock:

1. **`trap_taken`** (`kv32_csr.sv:253-259`): writes `mepc` (bit0 cleared),
   `mcause`, `mtval`; saves `mstatus.MIE` into `MPIE`, clears `MIE`, sets
   `MPP=2'b11` (M-mode).
2. **`mret_taken`** (`kv32_csr.sv:264-267`): restores `MIE <- MPIE`, sets
   `MPIE <- 1`, `MPP <- 2'b11`.
3. **CSR write instruction** (`csr32_csr.sv:272-313`): per-address writes via
   `csr_new_val`. Read-only and `mip` writes are ignored.

Because trap and MRET already sit above the CSR-write case in this chain, the
pipeline does **not** need to gate `csr_wen` on `!trap_taken` — see
[traps.md](traps.md#csr-write-gating) for why this matters (combinational-loop
avoidance).

## Counters

`mcycle_r`/`minstret_r` are 64-bit (`kv32_csr.sv:95-97`).

- `mcycle_r` increments every cycle.
- `minstret_r` increments when `instr_retired` is high (a real, non-bubble
  instruction is leaving WB and MEM is not stalled — see
  `kv32_core.sv:227`).

**Write-suppress guard** (`kv32_csr.sv:241-248`): when a CSR write targets
`mcycle`/`mcycleh`/`minstret`/`minstreth` this cycle, the corresponding
free-running increment is suppressed. Without this, the 64-bit non-blocking
increment and the 32-bit non-blocking CSR write would both fire on the same edge
and the increment would clobber the written value.

A trapping instruction is squashed in the EX/MEM register, so `instr_retired`
is low that cycle and the trapping instruction does **not** count toward
`minstret` — the RISC-V-preferred behavior.

## Legality check (`csr_illegal`)

`kv32_csr.sv:140-155`, combinational. An access is illegal when:

- the CSR address is not in the implemented set (any access — read or write), or
- the CSR is read-only (`addr[11:10]==2'b11`, i.e. the 0xF11–0xF15 identity CSRs)
  and a write is attempted.

The check is gated by `is_csr` so non-CSR instructions never report illegal.
`CSRRS`/`CSRRC` with `rs1=x0` suppress `csr_wen` in the decoder, so a read of a
read-only CSR is legal. Unimplemented CSRs trap on any access — software is
expected to use the trap-and-skip pattern (set `mtvec` to the next instruction
before probing).

`csr_illegal` feeds the trap detector as a source of the illegal-instruction
trap (mcause=2) — see [traps.md](traps.md).

## `mtvec` MODE masking

Only Direct mode is supported. On write, `mtvec_r[1:0]` is forced to `2'b00`
(`kv32_csr.sv:286`). Vectored mode (MODE=1) is deferred until async
interrupt-taking is added. The IF-stage redirect uses `{mtvec_out[31:2], 2'b00}`
(`kv32_core.sv:678`).
