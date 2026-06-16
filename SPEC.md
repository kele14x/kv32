# kv32 — Minimal RV32GC Soft Core Specification

**Goal**: A synthesizable RISC-V core as simple as possible while still booting a Linux kernel + initramfs on an FPGA.

**ISA**: RV32GC_Zicsr_Zifencei

---

## 1. Architecture Overview

### 1.1 Pipeline

Five-stage in-order pipeline:

```
IF → ID → EX → MEM → WB
```

- Single issue, in-order
- No out-of-order, no superscalar, no speculative execution
- Branch: resolve in EX, 2-cycle penalty on taken branch (or 1 with simple next-PC predictor)
- Structural hazards: stall on data memory access conflicts; no dual-port register file needed
- Forwarding: EX→EX and MEM→EX paths to avoid most data hazards

**Rationale**: Single-cycle is too slow for acceptable Linux boot times. Deeper pipelines add hazard complexity without proportionate benefit at this scale.

### 1.2 Register File

- 32 × 32-bit general-purpose registers (x0 hardwired to 0)
- Single-read-port is acceptable with stalling; two read ports preferred for clean ID stage
- Synchronous read, write on rising edge of WB stage

### 1.3 FPU (D extension)

- Separate FPU pipeline, loosely coupled to EX stage
- 32 × 32-bit FP registers (f0–f31); D extension treats them as 32×64-bit via register pairing
- Support: FADD, FSUB, FMUL, FDIV, FSQRT, FCVT, FMIN/FMAX, FMADD/FMSUB/FNMADD/FNMSUB
- Rounding modes: RNE, RTZ, RDN, RUP, RMM, dynamic (from frm CSR)
- FCSR: `fflags` (NX/UF/OF/DZ/NV), `frm`, `fcsr` (combined)
- Traps: invalid operation, divide-by-zero, overflow, underflow, inexact → set fflags, no trap by default

**Note**: FPU is the single largest RTL block. Consider deferring if boot-time is acceptable with kernel FPU emulation (Linux can trap-and-emulate FP instructions).

---

## 2. Privilege Modes

Linux requires M, S, and U modes.

| Mode | Level | Purpose                              |
|------|-------|--------------------------------------|
| M    | 3     | Boot, firmware, SBI, trap handling   |
| S    | 1     | Linux kernel                         |
| U    | 0     | Userspace processes                  |

- `mret` / `sret` / `uret` return from respective modes
- Traps from lower modes escalate to the next-higher mode's trap vector (or M if that mode hasn't delegated)
- Delegation: `medeleg` / `mideleg` (M→S); `sedeleg` / `sideleg` (S→U, typically unused under Linux)

---

## 3. CSR Map

### 3.1 Machine-Mode CSRs (mandatory)

| Address | Name       | Purpose                                    |
|---------|------------|--------------------------------------------|
| 0x300   | `mstatus`  | Machine status (MIE, MPIE, MPP, SIE, SPIE, SPP, MPRV, SUM, MXR, FS, etc.) |
| 0x301   | `misa`     | ISA description (read-only: MXL=1, IMAFDCSU bits) |
| 0x304   | `mie`      | Machine interrupt enable                   |
| 0x305   | `mtvec`    | Machine trap vector base + mode (direct/vectored) |
| 0x340   | `mscratch` | Scratch for M-mode trap handler            |
| 0x341   | `mepc`     | Machine exception PC                       |
| 0x342   | `mcause`   | Machine trap cause (interrupt + exception code) |
| 0x343   | `mtval`    | Machine trap value (bad addr / instruction) |
| 0x344   | `mip`      | Machine interrupt pending                  |
| 0x310   | `mstatush` | (RV32 only) high-half of mstatus — MBIGENDIAN, SBE, MBE |

Counters:

| Address | Name        | Purpose                              |
|---------|-------------|--------------------------------------|
| 0xB00   | `mcycle`    | Cycle counter (low 32)               |
| 0xB80   | `mcycleh`   | Cycle counter (high 32)              |
| 0xB02   | `minstret`  | Instructions retired (low 32)        |
| 0xB82   | `minstreth` | Instructions retired (high 32)       |

`mcounteren` (0x306): controls S-mode access to cycle/time/instret.

### 3.2 Supervisor-Mode CSRs

| Address | Name       | Purpose                                    |
|---------|------------|--------------------------------------------|
| 0x100   | `sstatus`  | Supervisor status (view of mstatus subset) |
| 0x104   | `sie`      | Supervisor interrupt enable (view of mie)  |
| 0x105   | `stvec`    | Supervisor trap vector                     |
| 0x140   | `sscratch` | Scratch for S-mode trap handler            |
| 0x141   | `sepc`     | Supervisor exception PC                    |
| 0x142   | `scause`   | Supervisor trap cause                      |
| 0x143   | `stval`    | Supervisor trap value                      |
| 0x144   | `sip`      | Supervisor interrupt pending (view of mip) |
| 0x180   | `satp`     | Supervisor address translation and protection (Sv32 mode + PPN + ASID) |

`scounteren` (0x106): controls U-mode counter access.

### 3.3 User-Mode CSRs (counters only)

| Address | Name       | Purpose                          |
|---------|------------|----------------------------------|
| 0xC00   | `cycle`    | Read-only shadow of `mcycle`     |
| 0xC80   | `cycleh`   | High half                        |
| 0xC01   | `time`     | Wall-clock time — **emulated by M-mode firmware** (reads CLINT `mtime` over AXI) |
| 0xC81   | `timeh`    | High half (emulated)             |
| 0xC02   | `instret`  | Read-only shadow of `minstret`   |
| 0xC82   | `instreth` | High half                        |

**`time` CSR**: The CPU core does **not** implement `time`/`timeh` in hardware.
Reads to addresses 0xC01 / 0xC81 raise an illegal-instruction trap; M-mode
firmware (OpenSBI) handles the trap by reading `mtime` from the CLINT over the
AXI bus and writing the result into the trapped register. This keeps the CPU
core free of any dependency on the CLINT's physical location or clock domain.

### 3.4 FPU CSRs

| Address | Name     | Purpose                      |
|---------|----------|------------------------------|
| 0x001   | `fflags` | FP accrued exception flags   |
| 0x002   | `frm`    | FP rounding mode             |
| 0x003   | `fcsr`   | Combined fflags + frm        |

Access gated by `mstatus.FS`. FS=Off causes illegal-instruction trap.

---

## 4. Memory Interface

The CPU core uses a **simple synchronous memory interface** with handshake-based
flow control. This interface is used for instruction fetches, data loads/stores,
and page-table walks. In Phase 8 (SoC integration), an AXI4 adapter translates
this interface into a standard AXI4 master port for SoC-level integration (§4.7).

### 4.1 Signal list

**Request signals** (master → slave, held stable until `gnt`):

| Signal | Width | Purpose |
|--------|-------|---------|
| `mem_req` | 1 | Master has a transaction pending |
| `mem_addr` | 32 | Byte-aligned address |
| `mem_we` | 1 | 0 = read, 1 = write |
| `mem_size` | 2 | `00` = byte, `01` = half, `10` = word (informational) |
| `mem_wdata` | 32 | Write data, right-aligned per `mem_size` |
| `mem_be` | 4 | Byte enable strobes — **authoritative** for write granularity |
| `mem_excl` | 1 | Exclusive access hint (LR/SC, Phase 4; tied to 0 in Phases 1–3) |

**Handshake signal** (slave → master, request acceptance):

| Signal | Width | Purpose |
|--------|-------|---------|
| `mem_gnt` | 1 | Slave accepts the request this cycle |

**Response signals** (slave → master, 0+ cycles after `gnt`):

| Signal | Width | Purpose |
|--------|-------|---------|
| `mem_valid` | 1 | Response is valid this cycle |
| `mem_rdata` | 32 | Read data (undefined on writes or when `valid=0`) |
| `mem_err` | 1 | Transaction failed — raises load/store access-fault exception |

### 4.2 Protocol rules

1. **Request acceptance**: a transaction begins on any cycle where `mem_req=1` AND
   `mem_gnt=1`. The master must hold all request signals stable from the cycle it
   asserts `mem_req` until `mem_gnt` is seen.

2. **No mid-flight cancellation**: once `mem_req=1`, the master cannot retract.
   The slave will eventually grant it (possibly immediately).

3. **One outstanding transaction**: the master cannot issue a new `mem_req` until
   it has seen `mem_valid` for the previous one. (Pipelining with N outstanding
   transactions is deferred to Phase 8 if needed.)

4. **Variable latency**: `mem_valid` may arrive 0, 1, or many cycles after
   `mem_gnt`. Zero-latency is legal (combinational response — typical for
   BRAM-backed testbench responders).

5. **Write semantics**: writes are committed on `mem_gnt` (the slave has accepted
   responsibility for the data). `mem_valid` still returns to complete the
   transaction from the master's point of view (the CPU needs to know the store
   retired). For writes, `mem_rdata` is undefined.

6. **Error handling**: `mem_err=1` alongside `mem_valid` means the transaction
   failed. The CPU raises a load/store access-fault exception. `mem_rdata` is
   undefined on error.

### 4.3 Alignment invariant

**Rule**: `mem_addr` must be aligned to `mem_size`:
- `mem_size = 00` (byte): any address is valid
- `mem_size = 01` (half): `mem_addr[0] == 0`
- `mem_size = 10` (word): `mem_addr[1:0] == 00`

The responder assumes this invariant and is not required to handle misaligned
word/halfword accesses. Misalignment detection is the CPU pipeline's responsibility
(§7.2: misaligned-address exception, cause 4/6). M-mode firmware emulates misaligned
accesses via multiple aligned byte/halfword operations.

**Rationale**: trap-and-emulate is simpler than hardware splitting in the pipeline.
If profiling later shows misaligned access is a bottleneck, upgrade to hardware
splitting in v1.1 without changing the memory interface contract.

### 4.4 Two internal ports + arbiter

The pipeline uses **two internal memory ports** (Harvard-like structure):

- **Instruction port** (i-port): used by IF stage for instruction fetches
- **Data port** (d-port): used by MEM stage for loads/stores and page-table walks

An **internal arbiter** merges these into a single external memory interface:

**Arbiter priority**:
1. Data port (d-port) — lower latency, on the critical path of load-use
2. Page-table walk (MMU, triggered from d-port) — must complete before MEM can proceed
3. Instruction port (i-port) — stall is cheap (single-cycle bubble)

**Structural hazard**: IF stalls while d-port owns the bus. Pipeline absorbs this
with a bubble; no special forwarding needed.

The arbiter is a trivial module (~50 lines) that multiplexes request signals and
routes response signals back to the requesting port.

### 4.5 Address space

The CPU drives 32-bit physical addresses on `mem_addr`. Address decoding is
performed by the SoC's interconnect (Phase 8), not by the CPU. For compatibility
with standard RISC-V software, the SoC is expected to present the following layout:

| Address range              | Typical use                          |
|----------------------------|--------------------------------------|
| 0x0000_0000 – 0x0FFF_FFFF  | Low devices, boot ROM                |
| 0x1000_0000 – 0x7FFF_FFFF  | Platform MMIO                        |
| 0x8000_0000 – 0xBFFF_FFFF  | Main RAM (kernel, initramfs, pages)  |
| 0xC000_0000 – 0xFFFF_FFFF  | High MMIO (PLIC, etc.)               |

**Reset vector**: 0x0000_0000 (parameterizable). First instruction fetch after
reset targets this address.

### 4.6 Tightly-coupled internal blocks

Two address ranges are **intercepted internally** before reaching the external
memory interface:

- **CLINT** at 0x0200_0000 – 0x0200_FFFF (§5): always integrated. The CLINT
  register block lives inside the core module as an internal memory slave. This
  eliminates per-cycle coupling latency and simplifies SoC integration. The
  core module has an additional `rtc_clk` input for the `mtime` counter,
  synchronized into `core_clk` via a 2-flop CDC stage.

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

### 4.7 Phase 8: AXI4 adapter

In Phase 8 (SoC integration), an **AXI4 adapter module** translates the simple
memory interface into a standard AXI4 master port:

- `mem_req` + `mem_gnt` → AR/AW + W channel handshakes
- `mem_valid` → R/B channel handshakes
- `mem_excl` → AXI exclusive monitor signals (or serialized RMW)
- `mem_err` → translated from AXI `rresp`/`bresp` `SLVERR`/`DECERR`

The adapter is a ~200–400 line module, mostly a state machine. It preserves the
simple memory interface contract while exposing AXI4 to the SoC's interconnect.

**AXI4 signals** (master):

| Channel | Signals                                                |
|---------|--------------------------------------------------------|
| AW      | `awaddr[31:0]`, `awlen[7:0]`, `awsize[2:0]`, `awburst[1:0]`, `awvalid`, `awready` |
| W       | `wdata[31:0]`, `wstrb[3:0]`, `wlast`, `wvalid`, `wready` |
| B       | `bresp[1:0]`, `bvalid`, `bready`                       |
| AR      | `araddr[31:0]`, `arlen[7:0]`, `arsize[2:0]`, `arburst[1:0]`, `arvalid`, `arready` |
| R       | `rdata[31:0]`, `rresp[1:0]`, `rlast`, `rvalid`, `rready` |

- **Bursts**: INCR only. Single-beat (`len=0`) for uncached / MMIO; up to 16-beat
  bursts for cache-line fill / write-back if a cache is added later.
- **Response**: `OKAY` (0b00) expected. `SLVERR`/`DECERR` from a slave raise a
  bus-error exception (load/store access fault).

---

## 5. CLINT (Core-Local Interruptor)

> **Scope**: The CLINT is **integrated inside the CPU core module** as a
> tightly-coupled internal memory slave (§4.6). It is not an external SoC
> component. The register map below is the software-visible contract so that
> standard RISC-V firmware (OpenSBI, Linux) can drive timer and software
> interrupts via the usual memory-mapped writes.

Memory-mapped at 0x0200_0000. Per-hart:

| Offset    | Access | Name       | Purpose                            |
|-----------|--------|------------|------------------------------------|
| 0x0000    | R/W    | `msip`     | Machine software interrupt pending |
| 0x4000    | R/W    | `mtimecmp` (low)  | Timer compare low 32 bits   |
| 0x4004    | R/W    | `mtimecmp` (high) | Timer compare high 32 bits  |
| 0xBFF8    | R      | `mtime` (low)     | Free-running timer low 32   |
| 0xBFFC    | R      | `mtime` (high)    | Free-running timer high 32  |

- `mtime`: free-running 64-bit counter, increments at `rtc_clock` (e.g., 10 MHz).
- Timer interrupt (`MTI`) pending when `mtime >= mtimecmp`.
- Software interrupt (`MSI`) pending when `msip[0] == 1`.

---

## 6. PLIC (Platform-Level Interrupt Controller)

> **Scope**: The PLIC is a **SoC-level component**, not part of the CPU core.
> It sits behind the CPU's AXI4 master port and drives the CPU's external
> interrupt input pin (§7.1). The CPU does not interact with the PLIC directly;
> all PLIC configuration (priority, enable, threshold, claim/complete) is
> performed by software via memory-mapped reads/writes over the AXI bus.

Memory-mapped at 0x0C00_0000. Simplified for single-hart:

- Up to 32 external interrupt sources (configurable; 32 is enough for UART + a few peripherals)
- Source priority registers at 0x0C00_0004 + 4×source
- Pending bits at 0x0C00_1000 (32-bit bitmap)
- Enable bits at 0x0C00_2000 (per-context)
- Threshold at 0x0C20_0000 (per-context)
- Claim/complete at 0x0C20_0004 (read = claim, write = complete)
- Single context (M-mode) sufficient; add S-mode context via delegation through `mideleg`

External interrupt (`MEI`) raised when any pending+enabled source priority > threshold.

---

## 7. Interrupts and Exceptions

### 7.1 Interrupt sources

The CPU core exposes **one external interrupt input pin**, active-high:

| Pin              | Drives `mip` bit | Source (SoC-side)             |
|------------------|------------------|-------------------------------|
| `irq_external_i` | MEIP (bit 11)    | PLIC claim non-zero           |

The other two interrupt sources are **internal to the core**:

| Internal signal | Drives `mip` bit | Source (core-internal)        |
|-----------------|------------------|-------------------------------|
| `msip_i`        | MSIP (bit 3)     | CLINT `msip` register         |
| `mtip_i`        | MTIP (bit 7)     | CLINT `mtime >= mtimecmp`     |

These internal signals are produced by the integrated CLINT (§5) and sampled
every cycle. Supervisor-mode interrupts (SSI/STI/SEI) are not separate pins —
they are derived inside the CPU by delegation through `mideleg` (see §7.1.1).

`mip` bits: `SSIP`(1), `SSIE`(1), `STIP`(5), `STIE`(5), `SEIP`(9), `SEIE`(9), `MSIP`(3), `MTIP`(7), `MEIP`(11).

Interrupt taken when:
1. Corresponding `mip` and `mie` bits set
2. Global enable for the target mode (`mstatus.MIE` for M-mode traps, `mstatus.SIE` for S-mode traps while in S/U)
3. Delegation: if the interrupt's mode ≤ current privilege and `mideleg` delegates it to S, trap to S; else trap to M.

### 7.2 Exceptions (synchronous)

| Cause | Name                        | Trap value                |
|-------|-----------------------------|---------------------------|
| 0     | Instruction address misaligned | Faulting PC            |
| 1     | Instruction access fault    | Faulting PC               |
| 2     | Illegal instruction         | Faulting instruction word |
| 3     | Breakpoint (ebreak)         | PC                        |
| 4     | Load address misaligned     | Faulting address          |
| 5     | Load access fault           | Faulting address          |
| 6     | Store/AMO address misaligned| Faulting address          |
| 7     | Store/AMO access fault      | Faulting address          |
| 8     | Environment call from U     | PC                        |
| 9     | Environment call from S     | PC                        |
| 11    | Environment call from M     | PC                        |
| 12    | Instruction page fault      | Faulting virtual address  |
| 13    | Load page fault             | Faulting virtual address  |
| 15    | Store/AMO page fault        | Faulting virtual address  |

**Misaligned access**: Linux expects misaligned loads/stores to work. Implement in hardware via multiple aligned accesses (simpler to verify) or trap-and-emulate in M-mode firmware.

**Priority**: Traps are precise. Within a single instruction, exception priority per the spec (breakpoint > instruction page fault > instruction access fault > illegal instruction > address misaligned > load/store faults).

### 7.3 Trap vector modes

`mtvec` / `stvec` MODE field:
- 0 (Direct): all traps jump to BASE
- 1 (Vectored): asynchronous interrupts jump to BASE + 4×cause; exceptions still to BASE

Linux typically uses vectored mode.

---

## 8. MMU — Sv32

### 8.1 Page table format

- Two-level page table: 10-bit VPN[1] + 10-bit VPN[0] + 12-bit offset
- PTE is 32 bits:

```
 31        20 19 18 17 16 15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
+-----------+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| PPN[1]    |PPN[0]   |RSW| D | A | G | U | X | W | R | V |
+-----------+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

- V=0: invalid
- R=0,W=1: reserved (fault)
- R=W=X=0: pointer to next-level page table
- Otherwise: leaf PTE

### 8.2 `satp` CSR format (Sv32)

```
 31    30        21 20                         0
+-------+----------+---------------------------+
| MODE  |   ASID   |           PPN             |
+-------+----------+---------------------------+
```

MODE=0: Bare (no translation); MODE=1: Sv32.

### 8.3 Translation algorithm

1. If MODE=Bare or privilege=M (unless `mstatus.MPRV`=1 and `mstatus.MPP`≠M), physical = virtual.
2. Let `a = satp.PPN << 12`; let `i = 1` (level).
3. PTE at address `a + VPN[i] × 4`.
4. If PTE invalid or reserved encoding → page fault.
5. If PTE is leaf: check permissions (R/W/X vs access type; U bit vs privilege; `mstatus.SUM` overrides S-mode U-page access; `mstatus.MXR` makes R-pages readable as executable). Check PPN alignment for superpages (4 MiB: PPN[0] must be 0).
6. If PTE is non-leaf: `a = PTE.PPN << 12`; `i = i - 1`; goto step 3.
7. Update A/D bits in PTE if hardware-managed (recommended; Linux expects this).

### 8.4 TLB

- Small direct-mapped or set-associative TLB (e.g., 16 or 32 entries)
- Tagged by {ASID, VPN}; store PPN + permissions + page size
- `sfence.vma` invalidates matching entries (by address and/or ASID)
- On context switch (satp write), software issues `sfence.vma`

---

## 9. Special Instructions

### 9.1 Zifencei — `fence.i`

Synchronize instruction and data streams. Implementation options:
- No I-cache: `fence.i` is a NOP (correct, since data writes go directly to memory).
- With I-cache: flush/invalidate the I-cache pipeline and refetch.

**Recommendation**: start with no I-cache. Add one later if boot time demands it.

### 9.2 A extension — Atomic instructions

LR.W / SC.W and AMO* (SWAP, ADD, AND, OR, XOR, MAX, MIN, MAXU, MINU).
- Reservation register: one per hart; stores {valid, address}
- SC.W succeeds only if reservation is valid and address matches; clears reservation on either outcome
- AMO* are read-modify-write, serialized on the bus
- `.aq` / `.rl` bits: implement as ordering fences (conservative, correct)

### 9.3 Fences

- `fence` (general): enforce ordering on memory/IO. Minimum: treat as pipeline drain (correct, conservative).
- `fence.i`: see 9.1.
- `sfence.vma`: TLB invalidation (see 8.4).

### 9.4 WFI

Wait for interrupt. Can be implemented as NOP (legal per spec). For power savings: halt pipeline until next interrupt.

---

## 10. Boot Flow

> The CPU core itself has no boot logic beyond starting instruction fetch at
> the reset vector. Everything below is SoC-level behavior observed by the CPU
> as a sequence of instruction fetches and data reads/writes over AXI.

1. **Reset**: CPU core starts in M-mode with `mstatus.MIE=0`, `mtvec`/`satp`/etc.
   at implementation-defined values. First instruction fetch targets the reset
   vector (0x0000_0000 by default), served by the integrated boot ROM (§4.4)
   or an external BRAM if `INTEGRATE_BOOT_ROM=0`.
2. **Boot ROM** (integrated or external): minimal firmware — sets `mtvec`,
   sets up a stack in RAM, copies/decompresses the kernel image from flash
   (or other persistent storage, via AXI) into main RAM at 0x8000_0000+.
3. **OpenSBI / BBL** (runs in M-mode, lives in RAM): provides SBI calls to
   S-mode — console I/O, timer, IPI, RFENCE. Implemented as an M-mode trap
   handler that services `ecall` from S.
4. **Jump to kernel**: M-mode firmware sets `mstatus.MPP=S`, writes kernel
   entry address to `mepc`, executes `mret`. CPU begins fetching from the
   kernel in RAM.
5. **Linux S-mode**: kernel runs, sets up `satp` (Sv32), traps handled via
   `stvec`. Traps needing M-mode (SBI calls, non-delegated interrupts) escalate
   via `ecall` / trap-and-forward.
6. **initramfs**: kernel mounts embedded initramfs as rootfs, runs `/init`.

**Simplification for first bring-up**: skip OpenSBI and provide a minimal
M-mode trap handler in boot ROM that services SBI calls directly. Add full
OpenSBI once the core is stable.

---

## 11. Peripherals (SoC-level, out of CPU core scope)

> **Scope**: The peripherals below are **not part of the CPU core**. They live
> in the SoC wrapper and are reachable via the CPU's AXI4 master port. The CPU
> sees them only as memory-mapped addresses and (for interrupt sources) as
> external input pins. CLINT and boot ROM are integrated inside the core (§4.4).

| Device                  | Purpose                              | Notes                    |
|-------------------------|--------------------------------------|--------------------------|
| Main RAM                | Kernel + initramfs + page frames     | At 0x8000_0000; DDR/SRAM/HyperRAM — CPU-agnostic |
| PLIC                    | External interrupt routing           | See §6                   |
| Minimal 8250 UART       | Console (early printk + shell)       | See §11.1                |
| Block device (optional) | Root filesystem if no initramfs      | VirtIO-blk over MMIO, or simple SPI SD |

With initramfs baked into the kernel image, a block device is not required for boot.

### 11.1 Minimal 8250 UART

v1 implements a minimal 8250-subset UART — no FIFO, no modem control. Linux's
`8250` driver auto-detects FIFO absence (via IIR[7:6]=00) and operates it as a
plain 8250. This is enough for `printk()` and an interactive shell.

**MMIO base**: 0x1000_0000 (conventional; configurable).
**Register stride**: 4 bytes (word-aligned for RV32).
**Interrupt**: one output pin to PLIC (source 10 by convention).

Implemented registers:

| Offset | R/W | Name  | Purpose                                          |
|--------|-----|-------|--------------------------------------------------|
| 0x00   | R   | RBR   | Receive Buffer Register (read incoming byte)     |
| 0x00   | W   | THR   | Transmit Holding Register (write byte to send)   |
| 0x04   | R/W | IER   | Interrupt Enable (bits 0–3: RDA, THRE, RLS, MS) |
| 0x08   | R   | IIR   | Interrupt ID (identifies pending interrupt)      |
| 0x0C   | R/W | LCR   | Line Control (data bits, stop bits, parity, DLAB)|
| 0x14   | R   | LSR   | Line Status (DR, OE, PE, FE, BI, THRE, TEMT)     |
| 0x1C   | R/W | SCR   | Scratch                                          |

**Not implemented** (reads return 0, writes ignored):

- MCR (0x10) / MSR (0x18) — no modem control lines (CTS/RTS/DSR/DTR). Linux tolerates this for a console-only UART.
- DLL (0x00) / DLM (0x04) — baud rate divisor. Accessed when LCR.DLAB=1. In an FPGA the physical baud rate is set by the TX clock divider outside the register block; the divisor registers are write-only dummies so that software probing them does not hang.
- FCR (0x08 write) — no FIFO. Writes ignored.

**Behavior**:

- **Transmit**: writing THR enqueues a byte into a 1-entry transmit register. LSR.THRE goes low immediately, high once the byte has been shifted out by the bit-rate clock. An interrupt is raised on THRE transition if IER bit 1 is set.
- **Receive**: a byte arriving on RX is latched into a 1-entry receive register. LSR.DR goes high. An interrupt is raised if IER bit 0 is set. Reading RBR clears DR.
- **Overrun**: if a second byte arrives before RBR is read, LSR.OE is set. No interrupt by default; Linux reads fast enough that this rarely fires on a quiet console.
- **No parity / framing error generation** for transmit; receive-side error flags (PE, FE, BI) tied to 0.

**Why not 16550 from the start**: FIFOs add a small FIFO RAM block, read/write pointer logic, and trigger-level comparison — ~2× the RTL of the minimal 8250 for a modest interrupt-latency win. Since the FPGA console has near-zero host-side latency, the win is marginal. Upgrade path is straightforward: swap the register block for a 16550-compatible one behind the same MMIO base; Linux will auto-detect.

---

## 12. Out of Scope (for v1)

- Multi-hart (single hart only)
- Hypervisor (H extension)
- Vector (V) extension
- Bit manipulation (B) extension
- I-cache, D-cache (add later if needed)
- Branch predictor beyond simple next-PC bit
- Superscalar / out-of-order
- Physical Memory Protection (PMP) — useful but Linux does not require it; add in v2
- Hardware breakpoint / trigger module
- Debug module (JTAG)
- **SoC-level components** (PLIC, UART, memory controller, AXI interconnect) — these live in the SoC wrapper around the CPU, not in the CPU core itself (§11). CLINT and boot ROM are integrated inside the core (§4.4).

---

## 13. Verification Strategy

1. **Unit tests**: each functional unit (ALU, branch, CSR, multiplier, divider, FPU) with directed test vectors.
2. **riscv-tests**: official ISA test suite (M-mode flat binaries) — validates base ISA + extensions.
3. **riscv-arch-test**: compliance tests from RISC-V International.
4. **Co-simulation**: compare RTL trace against Spike or QEMU instruction-by-instruction.
5. **Linux boot test**: kernel + busybox initramfs; success = shell prompt on UART.

---

## 14. Implementation Order

1. **Phase 1 — RV32I base**: IF/ID/EX/MEM/WB datapath, register file, ALU, branch, load/store, CSR file (M-mode only), simple memory interface (two ports + arbiter). Run `riscv-tests` M-mode binaries.
2. **Phase 2 — M extension**: multiplier (multi-cycle or pipelined), divider. Verify with `rv32mi` tests.
3. **Phase 3 — C extension**: instruction decompressor (16-bit → 32-bit) at IF output. Verify with `rv32uc`.
4. **Phase 4 — A extension**: LR/SC with reservation register; AMO operations. `rv32ua` tests.
5. **Phase 5 — Privilege**: M/S/U modes, trap delegation, `mret`/`sret`, `mideleg`/`medeleg`. Boot a minimal S-mode payload.
6. **Phase 6 — MMU (Sv32)**: page table walker, TLB, `satp`, `sfence.vma`. Run a paging S-mode test.
7. **Phase 7 — F/D extension**: FPU pipeline, `mstatus.FS`, `fcsr`. `rv32uf` / `rv32ud` tests.
8. **Phase 8 — AXI adapter + SoC integration**: add AXI4 adapter module (§4.7) to translate the simple memory interface into AXI4. Wrap the CPU in a SoC with AXI interconnect, main RAM (DDR/SRAM/HyperRAM), PLIC, UART. CLINT and boot ROM are already inside the core (§4.6). Verify with a bare-metal S-mode payload running over real peripherals.
9. **Phase 9 — Linux boot**: integrate OpenSBI, build kernel + initramfs, bring up on FPGA. Success = shell prompt on UART.
