# 4. Memory Interface

The CPU core exposes **two independent memory ports** using a **req/gnt/ack**
handshake: `imem_*` for instruction fetch and `dmem_*` for data load/store. The
two ports share no internal resource — at SoC integration time an external
crossbar or interconnect fabric arbitrates between them. In Phase 7, an AXI4
adapter translates each port into a standard AXI4 master (§4.7).

The data port is routed through `kv32_mem_fe` (`rtl/kv32_mem_fe.sv`), which owns
all data-memory complexity: sub-word store positioning, byte-enable generation,
load data extraction with sign/zero extension, and misaligned-access splitting
(§4.3). The instruction port is driven directly by the FETCH state — the
core never issues a sub-word or misaligned fetch (§7.2 in [06-traps.md](06-traps.md):
instruction-address misaligned traps cause 0).

For RTL details on `kv32_mem_fe` and the misaligned-access FSM see
[../impl/memory.md](../impl/memory.md).

## 4.1 Signal list

Each port uses the same signal set, prefixed `imem_` or `dmem_`.

**Request signals** (master → slave, held stable from `req` assertion until acceptance):

| Signal    | Width | Purpose                                                         |
| --------- | ----- | --------------------------------------------------------------- |
| `*_req`   | 1     | Transaction pending; held high until `gnt` accepts the request  |
| `*_addr`  | 32    | Byte address                                                    |
| `*_we`    | 1     | 0 = read, 1 = write                                             |
| `*_size`  | 2     | `00` = byte, `01` = half, `10` = word (informational)           |
| `*_wdata` | 32    | Write data, positioned per `*_be`                               |
| `*_be`    | 4     | Byte enable strobes (**authoritative** for write granularity)   |
| `*_excl`  | 1     | Exclusive access hint (LR/SC, Phase 4; tied to 0 in Phases 1–3) |
| `*_gnt`   | 1     | Slave accepts the currently presented request this cycle         |

Notes on request signals:

- **`*_addr`**: the slave must word-align externally if it requires word-addressed access; the core may drive unaligned addresses on `dmem_*` (see §4.3).
- **`*_size`**: informational only — `*_be` is authoritative. On `dmem_*` split beats from a misaligned access, `*_size` reflects the original access size, not the beat width; the slave must use `*_be` for write granularity.

**Response signals** (slave → master, on the cycle the accepted request completes):

| Signal    | Width | Purpose                                                                         |
| --------- | ----- | ------------------------------------------------------------------------------- |
| `*_ack`   | 1     | Transaction complete this cycle                                                 |
| `*_rdata` | 32    | Read data (undefined on writes or when `ack=0`)                                 |
| `*_err`   | 1     | Transaction failed — raises load/store access-fault exception (§7.2, cause 5/7) |

Note on response signals:

- **`*_ack`**: for loads, `*_rdata` is valid on the same cycle as `*_ack`.

## 4.2 Protocol rules

1. **Request acceptance**: a request is accepted on any cycle where `*_req=1`
   AND `*_gnt=1`. The master must hold all request signals stable from the cycle
   it asserts `*_req` until the acceptance edge.

2. **No mid-flight cancellation**: once `*_req=1`, the master cannot retract.
   The slave may delay `*_gnt`, but once the request is accepted it must
   eventually return exactly one `*_ack` pulse for that request.

3. **One outstanding transaction per port (master-enforced)**: the response
   path has only `*_ack` — no ready/backpressure signal — so the master must
   always accept a response when it arrives. To avoid needing an internal
   response buffer, the master is designed to issue at most one outstanding
   request at a time: it waits for `*_ack` before sending the next request.
   This is a deliberate design simplification of the interface.

   The slave is **not** responsible for enforcing this limit. If the slave has
   its own internal buffer constraints, it simply deasserts `*_gnt` to reject
   new requests until it is ready. Because the master guarantees at most one
   outstanding request, the slave never needs to track outstanding counts or
   manage response ordering.

4. **Variable latency**: `*_ack` may arrive 0, 1, or many cycles after the
   request is accepted. Zero-latency is legal: `*_req && *_gnt && *_ack` may all
   occur in the same cycle.

5. **Write semantics**: writes are committed on `*_ack` (the slave has accepted
   responsibility for the data). For writes, `*_rdata` is undefined.

6. **Error handling**: `*_err=1` alongside `*_ack` means the transaction failed.
   The CPU raises a load/store access-fault exception. `*_rdata` is undefined on
   error. For `dmem_*` misaligned accesses split into two beats (§4.3), an `*_err`
   on either beat aborts the operation — the core reports the error on the
   failing beat and does not issue the remaining beat.

## 4.3 Alignment invariant and misaligned handling

**Bus-side invariant**: the `imem_*` port only issues word-aligned addresses
(`imem_addr[1:0]==00`, `imem_size=2'b10`, `imem_be=4'b1111`). The `dmem_*` port
issues word-aligned addresses for any access with `dmem_size > 0`; byte accesses
may use any address. A slave that requires word-aligned addresses can therefore
ignore `dmem_addr[1:0]` for `dmem_size > 0` beats.

**Misaligned access handling** (data port only): unaligned `LH`/`LW`/`SH`/`SW`
emitted by the pipeline are handled in hardware by `kv32_mem_fe`, not by
trap-and-emulate:

- **Naturally aligned**: single bus transaction, passthrough.
- **Non-crossing misaligned** (`SH@addr[1:0]=01` only — both bytes within one
  word): single bus transaction with `dmem_addr` word-aligned, `dmem_be=0110`,
  and the load result shifted right by 8 bits.
- **Word-crossing misaligned** (`SH@addr[1:0]=11`, `SW@addr[1:0]!=00`): two
  sequential bus transactions, driven by a 4-state FSM
  (`IDLE→FIRST→BETWEEN→SECOND→IDLE`). The first beat carries the high bytes of
  the word at `addr[31:2]`; the second beat carries the low bytes of the next
  word at `addr[31:2]+4`. `dmem_be` is authoritative on each beat; `dmem_size`
  still reflects the original access size and must not be used by the slave to
  determine beat width. For loads, the two beats' data are stitched and then
  sign/zero-extended per `funct3`.

**Address-overflow case**: a crossing access whose second beat would wrap past
`0xFFFFFFFF` (i.e. `aligned_base == 0xFFFFFFFC`) is detected by `kv32_mem_fe`,
which asserts `dmem_err` with `rdata_valid` without issuing either beat.

**Rationale**: hardware splitting was chosen over trap-and-emulate because it
keeps misaligned access latency predictable and avoids trapping for an event
Linux expects to succeed. Cause 4/6 (load/store address misaligned) is therefore
never raised for data accesses in this implementation; cause 5/7 (load/store
access fault) is raised only on `dmem_err` from the slave or on the address
overflow above. The instruction-address misaligned trap (cause 0) is still
raised for misaligned jumps, since `imem_*` never performs a split fetch.

## 4.4 Dual memory ports

The core uses **two independent memory ports** (Harvard-style):

- **Instruction port** (`imem_*`): driven directly by the FETCH state, read-only.
  The FSM issues one request at a time and waits for the response before
  advancing to DECODE.
- **Data port** (`dmem_*`): driven by the MEM state through `kv32_mem_fe`
  (§4.3). `dmem_req` is asserted until each beat is granted; completion is
  reported later with `dmem_ack`.

Because the FSM executes one instruction at a time, only one port is active at
any given moment — the instruction port during FETCH, the data port during MEM.

There is no internal arbiter. The two ports may be backed by a single memory
(with an external crossbar that arbitrates between them) or by two independent
memories (Harvard layout). At SoC integration time, the interconnect is
responsible for:

- Arbitrating concurrent `imem_*` and `dmem_*` requests. A reasonable priority
  is `dmem_*` > `imem_*` — the data port is on the critical path of load-use
  latency, while an IF stall costs only a single-cycle bubble.
- Routing the winning port's request to the addressed slave and the response
  back. The core's `*_gnt`/`*_ack`/`*_rdata`/`*_err` inputs are per-port, so the
  interconnect must not cross-couple them.
- Forwarding `*_err` from the addressed slave to the port that owns the
  transaction. The core does not retry on error (§4.2 rule 6).

## 4.5 Address space

The CPU drives 32-bit physical addresses on `mem_addr`. Address decoding is
performed by the SoC's interconnect (Phase 7), not by the CPU. For compatibility
with standard RISC-V software, the SoC is expected to present the following layout:

| Address range                | Typical use                            |
| ---------------------------- | -------------------------------------- |
| 0x0000_0000 – 0x0FFF_FFFF    | Low devices, boot ROM                  |
| 0x1000_0000 – 0x7FFF_FFFF    | Platform MMIO                          |
| 0x8000_0000 – 0xBFFF_FFFF    | Main RAM (kernel, initramfs, pages)    |
| 0xC000_0000 – 0xFFFF_FFFF    | High MMIO (PLIC, etc.)                 |

**Reset vector**: 0x0000_0000 (parameterizable). First instruction fetch after
reset targets this address.

## 4.6 Tightly-coupled internal blocks

Two address ranges are **intercepted internally** before reaching the external
memory interface:

- **CLINT** at 0x0200_0000 – 0x0200_FFFF (see [05-clint-plic.md](05-clint-plic.md)):
  always integrated. The CLINT register block lives inside the core module as an
  internal memory slave. This eliminates per-cycle coupling latency and simplifies
  SoC integration. The core module has an additional `rtc_clk` input for the
  `mtime` counter, synchronized into `core_clk` via a 2-flop CDC stage.

- **Boot ROM** at 0x0000_0000 – 0x0000_FFFF (parameterizable): optionally
  integrated. Controlled by the `INTEGRATE_BOOT_ROM` parameter:
  - `INTEGRATE_BOOT_ROM = 1` (default for production): a 64 KiB BRAM inside the
    core serves the reset vector. Firmware contents are a module parameter or
    `initial` block, easy to swap without re-architecting the SoC.
  - `INTEGRATE_BOOT_ROM = 0` (for bring-up / development): the address range
    passes through to the external memory interface, allowing the SoC to provide
    boot ROM externally (e.g., for rapid iteration on OpenSBI / bootloader
    without re-synthesizing the core).

All other addresses pass through to the external memory interface.

## 4.7 Phase 7: AXI4 adapter

In Phase 7 (SoC integration), an **AXI4 adapter module** translates each of the
two simple memory ports (§4.1) into a standard AXI4 master port. The two ports
are typically adapted separately and merged by an AXI interconnect downstream,
though a single adapter that muxes both into one AXI master is also acceptable
(in that case the adapter absorbs the §4.4 arbitration role).

- `*_req` + `*_gnt` → AR/AW + W channel handshakes (address/data acceptance)
- `*_ack` → B/R channel response (completion for the accepted beat)
- `*_excl` → AXI exclusive monitor signals (or serialized RMW)
- `*_err` → translated from AXI `rresp`/`bresp` `SLVERR`/`DECERR`

The adapter is a ~200–400 line module, mostly a state machine. It preserves the
simple memory interface contract while exposing AXI4 to the SoC's interconnect.

**AXI4 signals** (master):

| Channel | Signals                                                                                     |
| ------- | ------------------------------------------------------------------------------------------- |
| AW      | `awaddr[31:0]`, `awlen[7:0]`, `awsize[2:0]`, `awburst[1:0]`, `awvalid`, `awready`           |
| W       | `wdata[31:0]`, `wstrb[3:0]`, `wlast`, `wvalid`, `wready`                                    |
| B       | `bresp[1:0]`, `bvalid`, `bready`                                                            |
| AR      | `araddr[31:0]`, `arlen[7:0]`, `arsize[2:0]`, `arburst[1:0]`, `arvalid`, `arready`           |
| R       | `rdata[31:0]`, `rresp[1:0]`, `rlast`, `rvalid`, `rready`                                    |

- **Bursts**: INCR only. Single-beat (`len=0`) for uncached / MMIO; up to 16-beat
  bursts for cache-line fill / write-back if a cache is added later.
- **Response**: `OKAY` (0b00) expected. `SLVERR`/`DECERR` from a slave raise a
  bus-error exception (load/store access fault).
