# Memory Subsystem

Implementation of the memory interface, arbiter, sub-word access, and the
misaligned-access handler. All in `rtl/kv32_core.sv` and
`rtl/kv32_mem_arbiter.sv`. For the architectural memory interface contract
(signal list, protocol rules, alignment invariant, AXI adapter plan), see
[SPEC.md §4](../SPEC.md).

## Internal vs external ports

The core exposes a single external memory interface (`mem_req`/`mem_addr`/
`mem_we`/`mem_size`/`mem_wdata`/`mem_be`/`mem_excl` + `mem_gnt`/`mem_valid`/
`mem_rdata`/`mem_err`, `kv32_core.sv:11-21`). Internally there are two ports:

- **i-port** — instruction fetch (IF stage), read-only.
- **d-port** — data load/store (MEM stage) + page-table walks (future).

A misaligned-access handler sits between the MEM stage and the arbiter's d-port,
producing the `_a`-suffixed signals (`d_req_a`, `d_addr_a`, … `d_valid_a`,
`d_rdata_a`) consumed by `kv32_mem_arbiter` (`kv32_core.sv:42-90`).

## Arbiter

Three-state FSM in `rtl/kv32_mem_arbiter.sv` (`IDLE`, `D_PORT_ACTIVE`,
`I_PORT_ACTIVE`, lines 41-45) with **d-port > i-port** priority.

**Zero-latency handling**: `IDLE` only transitions to `*_ACTIVE` when
`mem_gnt && !mem_valid` (lines 73-77). If a slave returns `mem_valid` in the
same cycle as `mem_gnt` (allowed by SPEC §4.2 rule 4 — combinational BRAM
responder), the whole transaction completes in `IDLE` with no state transition
and no double-response risk.

**`granted` flag** (lines 52, 109-113): tracks whether the current transaction
has been accepted. This makes `d_gnt`/`i_gnt` a one-cycle pulse rather than
re-asserting every cycle while waiting for `mem_valid`.

**Latched d-port request** (lines 54-60, 114-122): when a data access is
accepted out of `IDLE`, `d_addr`/`d_we`/`d_size`/`d_wdata`/`d_be`/`d_excl` are
latched and held stable in `D_PORT_ACTIVE` (the pipeline may drop `d_req` or
change `d_addr` while waiting for `mem_valid`). The i-port does not need
latching — `i_addr` (= `pc_if`) is held stable by the IF stage until `i_valid`.

**Response demux** (lines 207-247): routes `mem_rdata`/`mem_err` to the port
that owns the transaction. In `IDLE` with a zero-latency response, routing
follows d-port priority (`d_req && mem_gnt` wins over `i_req && mem_gnt`).

`arb_idle` (line 205) is asserted in `IDLE`; the misaligned-access handler uses
it as a safety net before issuing its second access.

## Sub-word loads

MEM stage, `kv32_core.sv:323-372`. After `d_valid`, the relevant bytes are
extracted from `d_rdata` based on `funct3_mem` and the low address bits, then
sign- or zero-extended:

| `funct3_mem` | Insn | Selection | Extension |
|--------------|------|-----------|-----------|
| 000 | LB | `d_rdata[8*offset +: 8]` by `mem_addr_mem[1:0]` | sign |
| 001 | LH | low/high half by `mem_addr_mem[1]` | sign |
| 010 | LW | `d_rdata` | — |
| 100 | LBU | byte by `mem_addr_mem[1:0]` | zero |
| 101 | LHU | half by `mem_addr_mem[1]` | zero |

For non-load instructions `mem_result` defaults to `mem_addr_mem` (the ALU
result, already the effective address), so non-memory instructions pass through
MEM unchanged.

## Sub-word stores

Store data positioning and byte-enable generation happen in the **EX/MEM
pipeline register** (`kv32_core.sv:838-877`), not in MEM. This uses `fwd_b` (the
forwarded `rs2`) — not raw `rs2_data` — so a forwarded store value is written
correctly.

| `funct3_ex[1:0]` | Insn | BE / wdata logic |
|------------------|------|-------------------|
| 00 | SB | one byte lane selected by `ex_result[1:0]`; `fwd_b[7:0]` shifted into lane |
| 01 | SH | two byte lanes selected by `ex_result[1]`; `fwd_b[15:0]` in low or high half |
| 10 | SW | `mem_be_mem = 4'b1111`, `mem_wdata_mem = fwd_b` |

`mem_size_mem <= funct3_ex[1:0]` (line 878) carries the access size to the
arbiter/external interface.

## Misaligned access handler

`kv32_core.sv:374-603`. Splits a misaligned load/store that **crosses a word
boundary** into two aligned word accesses, adding ~4 cycles of latency. This
implements the "work in hardware via multiple aligned accesses" option from
SPEC §7.2 rather than trapping to M-mode firmware.

### Misalignment detection

`kv32_core.sv:399-419`. Only evaluated when `d_req && ma_state == MA_IDLE`:

- `word_crossing` — set for `SH` at `addr[1:0]=11` (halfword straddles the word
  boundary) and any `SW` with `addr[1:0] != 00`. Triggers the two-access FSM.
- `non_crossing_ma` — set **only** for `SH` at `addr[1:0]=01` (halfword in
  bytes 1-2 of a single word). Handled inline without the FSM (single access,
  `d_be = 4'b0110`, address word-aligned).

> **Invariant**: `non_crossing_ma` is *only* the `SH@addr[1:0]=01` case. The
> load-side shift at `kv32_core.sv:600-602` relies on this exact-case
> assumption. Do not generalize the detector without revisiting that shift.

### Misalignment state machine

`kv32_core.sv:381-508`. The FSM steps through:

```
MA_IDLE -> MA_FIRST -> MA_DRAIN -> MA_SECOND -> MA_HOLD -> MA_IDLE
```

| State | Action |
|-------|--------|
| `MA_IDLE` | detect crossing; if `word_crossing`, latch `ma_offset`/`ma_size`, go `MA_FIRST`. Inline path for `non_crossing_ma`. |
| `MA_FIRST` | drive first aligned access (low word, `first_be`/`first_wdata`); on `d_valid_a` latch `ma_first_rdata`, go `MA_DRAIN`. |
| `MA_DRAIN` | one-cycle pause: suppress `d_req_a` so the arbiter returns to `IDLE` before the second access. |
| `MA_SECOND` | wait for `arb_idle`, then drive second aligned access (low word + 4, `second_be`/`second_wdata`), go `MA_HOLD`. |
| `MA_HOLD` | wait for `d_valid_a`, combine with `ma_first_rdata`, go `MA_IDLE`. |

`MA_DRAIN` + the `arb_idle` re-check in `MA_SECOND` are a safety net for slaves
that hold `mem_valid` for more than one cycle.

### First/second access BE and wdata

Computed combinationally (`kv32_core.sv:426-468`):

- **First access** (`first_be`/`first_wdata`): the bytes that belong in the low
  word, positioned in the correct lanes. `SH` crossing (offset 3) puts the low
  byte in lane 3; `SW` crossing shifts the appropriate number of low bytes into
  the high lanes (e.g. offset 1 → `BE=1110`, offset 2 → `BE=1100`,
  offset 3 → `BE=1000`).
- **Second access** (`second_be`/`second_wdata`): the remaining bytes positioned
  in the low lanes of the high word. `SH` crossing puts the high byte in lane 0
  (`BE=0001`); `SW` puts 1/2/3 remaining bytes in lanes 0/0-1/0-1-2.

`raw_hw` (`kv32_core.sv:423-424`) extracts the halfword from the
pipeline-positioned `d_wdata` (bytes 0-1 or bytes 2-3 based on `d_addr[1]`).

### Load data combination

`kv32_core.sv:568-603`. While the FSM is active, `d_valid` is suppressed except
in `MA_HOLD && d_valid_a`, where the two word reads are stitched:

- `SH` (offset 3): `{d_rdata_a[7:0], ma_first_rdata[31:24], 16'h0}`.
- `SW`: shift the second word's low bytes against the first word's high bytes
  per `ma_offset` (offset 1 → 8 bits, offset 2 → 16 bits, offset 3 → 24 bits).

The `non_crossing_ma` load path (`kv32_core.sv:600-602`) shifts `d_rdata_a`
right by 8 so the existing LH extractor (keyed on `mem_addr_mem[1]=0`) picks up
bytes 1-2 as the low halfword.

### Arbiter-facing mux

`kv32_core.sv:510-566` selects the d-port signals driven to the arbiter per FSM
state (pass-through in `MA_IDLE` for aligned accesses; first/second access
fields otherwise). `d_valid_a`/`d_rdata_a` from the arbiter are gated/combined
in `kv32_core.sv:568-603` before reaching the MEM stage as `d_valid`/`d_rdata`.
