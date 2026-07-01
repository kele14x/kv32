# Memory Subsystem

Implementation of the memory interface, sub-word access, and misaligned-access
handling. The memory front-end lives in `rtl/kv32_mem_fe.sv`; the core's
FSM and dual-port wiring are in `rtl/kv32_core.sv`. For the architectural
memory interface contract (signal list, alignment invariant, AXI adapter plan),
see [../spec/04-memory-interface.md](../spec/04-memory-interface.md).

## Dual memory interfaces

The core exposes two independent memory interfaces using a **req/gnt/ack** protocol:

- **imem_\*** — instruction fetch (FETCH state), read-only, direct from FSM.
- **dmem_\*** — data load/store (MEM state), routed through `kv32_mem_fe`.

Because the FSM executes one instruction at a time, only one port is active at
any given moment. There is no internal arbiter. At SoC integration time, an
external crossbar or interconnect fabric arbitrates between the two ports.

### req/gnt/ack protocol

| Signal   | Direction        | Meaning                                                                                   |
| -------- | ---------------- | ----------------------------------------------------------------------------------------- |
| `req`    | Master → Slave   | Transaction requested. Master holds `req` high and keeps address/data stable until `gnt`. |
| `gnt`    | Slave → Master   | Request accepted this cycle.                                                             |
| `ack`    | Slave → Master   | Accepted transaction completed. For loads, `rdata` is valid on the same cycle as `ack`.  |

A request is accepted when `req && gnt`; the response later arrives with `ack`.
Zero-latency slaves may assert `req && gnt && ack` in the same cycle.

### i-port (instruction fetch)

The FETCH state drives `imem_*` directly (`kv32_core.sv`):

```systemverilog
assign imem_req   = (state == ST_FETCH) && fetch_req && !fetch_wait;
assign imem_addr  = pc_reg;
assign imem_we    = 1'b0;        // read-only
assign imem_size  = 2'b10;       // always word
assign imem_wdata = 32'h0;
assign imem_be    = 4'hF;
assign imem_excl  = 1'b0;
```

On `imem_ack`, the instruction word is latched into `instr_reg` and the FSM
advances to DECODE.

### d-port (data load/store)

The d-port goes through `kv32_mem_fe`, which handles alignment, sub-word
positioning, and load extraction. The FSM drives `dmem_req` only during the MEM
state, gated by `state == ST_MEM && (mem_read || mem_write)`.

## kv32_mem_fe (`rtl/kv32_mem_fe.sv`)

The memory front-end sits between the core's MEM state and the external dmem
bus. It takes a raw memory request (address, size, unpositioned write data,
funct3) and produces correctly aligned, positioned, and byte-enabled bus
transactions. For loads, it returns the extracted and sign/zero-extended value.

### Upstream interface (core side)

| Signal        | Direction   | Description                                                                                        |
| ------------- | ----------- | -------------------------------------------------------------------------------------------------- |
| `req`         | in          | Memory operation request (held until `rdata_valid`)                                                |
| `addr[31:0]`  | in          | Byte address (ALU result / effective address)                                                      |
| `we`          | in          | 0=read, 1=store                                                                                    |
| `size[1:0]`   | in          | 00=B, 01=H, 10=W                                                                                   |
| `wdata[31:0]` | in          | Raw rs2 value (unpositioned)                                                                       |
| `funct3[2:0]` | in          | LB/LH/LW/LBU/LHU/SB/SH/SW                                                                          |
| `rdata[31:0]` | out         | Extracted/sign-extended load result                                                                |
| `rdata_valid` | out         | Pulses for one cycle when the operation completes                                                  |
| `err`         | out         | Bus error (gated by `dmem_ack`, or crossing overflow) — meaningful only when `rdata_valid` is high |

### Downstream interface (bus side)

Standard req/gnt/ack protocol: `dmem_req`/`dmem_addr`/`dmem_we`/`dmem_size`/
`dmem_wdata`/`dmem_be`/`dmem_excl` + `dmem_gnt`/`dmem_ack`/`dmem_rdata`/`dmem_err`.

**Split-beat `dmem_size`**: for word-crossing accesses, each beat carries a
subset of the original bytes. `dmem_size` still reflects the *original* access
size (e.g. `2'b10` for a split `SW`), not the beat width. `dmem_be` is
authoritative — slaves must use it for write granularity and must not
cross-check `dmem_size` against `dmem_addr`/`dmem_be`. See SPEC §4.1.

### Internal structure

Four functional blocks:

1. **Sub-word store logic** — positions byte/halfword write data into the
   correct byte lane and computes byte enables. For aligned accesses, this is
   the final bus output.

2. **Misalignment detector** — `word_crossing` and `non_crossing_ma` flags.
   Only evaluated when `req && ma_state == MA_IDLE`:
   - `word_crossing` — `SH@addr[1:0]=11` or `SW@addr[1:0]≠00`. Triggers the
     two-access FSM.
   - `non_crossing_ma` — **only** `SH@addr[1:0]=01`. Handled inline (single
     access, `BE=0110`, address word-aligned).

3. **Alignment handler FSM** (5-state) — splits crossing accesses into two
   aligned word transactions, with early abort on bus error:

   ```text
   MA_IDLE → MA_SINGLE_WAIT → MA_IDLE
          ↘ MA_FIRST_WAIT → MA_SECOND_REQ → MA_SECOND_WAIT → MA_IDLE
                 ↘ (err) → MA_IDLE
   ```

   - **`MA_IDLE`** — detect crossing:
     - `crossing_overflow` (second beat would wrap past `0xFFFFFFFF`): assert
       `err` + `rdata_valid` inline, no beat issued.
     - `word_crossing && !crossing_overflow`: latch offset/size, suppress
       `dmem_req`, go `MA_FIRST`.
     - Otherwise inline passthrough for `non_crossing_ma` and aligned accesses.
   - **`MA_FIRST_WAIT`** — first crossing beat already granted; wait for its
    `dmem_ack`.
   - **`MA_SECOND_REQ`** — drive the second aligned access (addr+4,
    `second_be`/`second_wdata`) until `dmem_gnt`.
   - **`MA_SECOND_WAIT`** — second beat granted; wait for `dmem_ack`.

4. **Load data extraction** — selects and extends the correct bytes from the
   bus word based on `funct3` and `addr[1:0]`. For crossing loads, stitches
   the two halves; for non-crossing misaligned loads, shifts right by 8.

### Sub-word stores

The core passes raw `rs2_data` (unpositioned rs2) to the mem_fe. The mem_fe
computes byte enables and data positioning:

| `size`   | Insn   | BE / wdata                                                       |
| -------- | ------ | ---------------------------------------------------------------- |
| 00       | SB     | One byte lane by `addr[1:0]`; `wdata[7:0]` shifted into lane     |
| 01       | SH     | Two byte lanes by `addr[1]`; `wdata[15:0]` in low or high half   |
| 10       | SW     | `BE=4'b1111`, `wdata` passthrough                                |

For crossing stores, `raw_hw = wdata[15:0]` (the halfword is always in the low
16 bits since the core passes raw rs2). First access puts the low byte in the
correct lane of the low word; second access puts the high byte in the correct
lane of the high word.

### Sub-word loads

Load data extraction uses the original (unaligned) `addr[1:0]` for byte
selection. The crossing stitch and non-crossing shift pre-position the data so
the standard extraction logic works uniformly:

| `funct3`    | Insn   | Selection           | Extension   |
| ----------- | ------ | ------------------- | ----------- |
| 000         | LB     | byte by `addr[1:0]` | sign        |
| 001         | LH     | half by `addr[1]`   | sign        |
| 010         | LW     | full word           | —           |
| 100         | LBU    | byte by `addr[1:0]` | zero        |
| 101         | LHU    | half by `addr[1]`   | zero        |

### Key gotcha: `non_crossing_ma` invariant

`non_crossing_ma` is **only** the `SH@addr[1:0]=01` case. The load-side shift
(right by 8 so the LH extractor keyed on `addr[1]=0` picks up bytes 1-2)
relies on this exact-case assumption. Do not generalize the detector without
revisiting that shift.

## LR/SC and AMO operations (A extension)

The A extension adds atomic instructions that require special handling in the
memory subsystem. These are decoded by `OpAmo` (opcode `0101111`) and handled
in the MEM state of the FSM.

### Exclusive access hint (`dmem_excl`)

The `dmem_excl` signal is asserted for LR.W and SC.W operations (but not AMO).
It is a hint to the memory subsystem that this transaction requires exclusive
access. In a multi-hart system, this would be used by the cache coherence
protocol or bus interconnect to track reservations. In this single-hart
implementation, the signal is driven but ignored by `kv32_mem_fe` and the
testbench memory model.

### LR.W (Load-Reserved)

LR.W performs a normal word load and sets a reservation:

1. **EXEC**: ALU computes effective address `rs1 + 0`.
2. **MEM**: normal word load via `dmem_req`/`dmem_we=0`/`dmem_excl=1`.
3. **On success** (`fe_rdata_valid && !fe_err`):
   - Latch `load_data_reg = fe_rdata`
   - Set `reservation_valid = 1`, `reservation_addr = ex_result_reg`
4. **WRITEBACK**: write `load_data_reg` to `rd`.

### SC.W (Store-Conditional)

SC.W conditionally stores based on the reservation:

1. **EXEC**: ALU computes effective address `rs1 + 0`.
2. **MEM**: check reservation:
   - If `reservation_valid && reservation_addr == ex_result_reg`:
     - Issue store: `dmem_req=1`, `dmem_we=1`, `dmem_excl=1`, `dmem_wdata=rs2_data_reg`
     - Wait for `fe_rdata_valid`
     - On success: write `rd = 0`, clear reservation
     - On error: trap with cause 7 (Store/AMO access fault)
   - Else (reservation invalid or address mismatch):
     - Skip memory access entirely
     - Write `rd = 1` (failure)
     - Clear reservation
3. **WRITEBACK**: write `sc_result` (0 or 1) to `rd`.

**Reservation invalidation**: any non-SC store to `reservation_addr` clears the
reservation. This is checked in the MEM state after a successful store.

### AMO operations (read-modify-write)

AMO operations (AMOSWAP, AMOADD, AMOAND, AMOOR, AMOXOR, AMOMAX, AMOMIN,
AMOMAXU, AMOMINU) perform atomic read-modify-write in three phases:

1. **EXEC**: ALU computes effective address `rs1 + 0`.
2. **MEM** (multi-phase, controlled by `amo_state` FSM):
   - **`AMO_READ_WAIT`**: issue load, wait for `fe_rdata_valid`
     - Latch `load_data_reg = fe_rdata` (the old value)
     - Advance to `AMO_WRITE_ISSUE`
   - **`AMO_WRITE_ISSUE`**: compute `new_val = kv32_amo_unit.op(load_data_reg, rs2_data_reg)`
     - Issue store: `dmem_req=1`, `dmem_we=1`, `dmem_wdata=new_val`
     - Advance to `AMO_WRITE_WAIT`
   - **`AMO_WRITE_WAIT`**: wait for `fe_rdata_valid`
     - On success: advance to WRITEBACK
     - On error: trap with cause 7 (Store/AMO access fault)
3. **WRITEBACK**: write `load_data_reg` (the old value) to `rd`.

**AMO unit**: `kv32_amo_unit` is a combinational module that computes the
result of the AMO operation based on `funct5` (bits 31:27). It supports all 9
AMO operations: SWAP, ADD, AND, OR, XOR, MAX, MIN, MAXU, MINU.

**Address alignment**: all A-extension instructions require word-aligned
addresses (`addr[1:0] == 00`). Misaligned addresses trap in EXEC with cause 4
(LR) or cause 6 (SC/AMO).

