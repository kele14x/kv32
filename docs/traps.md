# Traps and Exceptions

Implementation of trap detection, delegation, and return paths for M/S/U
privilege modes. For the architectural exception cause table, trap vector modes,
and interrupt plan, see [SPEC.md §7](../SPEC.md). For CSR state updates on
trap/MRET/SRET, see [csr.md](csr.md); for illegal-instruction sources in the
decoder, see [decoder.md](decoder.md).

**Implemented (Phase 5)**: synchronous traps (illegal instruction, ECALL, EBREAK,
access faults), asynchronous interrupt taking, M/S/U privilege modes, trap
delegation via `medeleg`/`mideleg`, vectored trap vectors, MRET/SRET return paths,
WFI/SFENCE.VMA privilege gating. MMU and PMP are Phase 6+.

## Privilege Modes

The processor supports three privilege levels:
- **M-mode** (`PRIV_M = 2'b11`): Machine mode (reset default)
- **S-mode** (`PRIV_S = 2'b01`): Supervisor mode
- **U-mode** (`PRIV_U = 2'b00`): User mode

The current privilege level is tracked in `priv_mode` in `kv32_core.sv`. It is
updated on:
- Trap entry: `priv_mode <= trap_to_smode ? PRIV_S : PRIV_M`
- MRET: `priv_mode <= mstatus.MPP`
- SRET: `priv_mode <= mstatus.SPP ? PRIV_S : PRIV_U`

## Trap Detection

Traps are detected combinationally in `kv32_core.sv`. Only one instruction
exists at a time, so there is no cross-stage priority to resolve.

### EXEC-stage traps

During the EXEC state, the following conditions are checked in priority order:

```systemverilog
if (is_mret_id && priv_mode != PRIV_M) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  // MRET illegal in non-M mode
end else if (is_sret_id && (priv_mode == PRIV_U || (priv_mode == PRIV_S && mstatus_tsr))) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  // SRET illegal in U or S+TSR
end else if (is_wfi_id && priv_mode != PRIV_M && mstatus_tw) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  // WFI illegal in S/U when TW=1
end else if (is_sfence_vma_id && priv_mode == PRIV_S && mstatus_tvm) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  // SFENCE.VMA illegal in S when TVM=1
end else if (is_ebreak) begin
    trap_taken = 1'b1; trap_cause = 32'd3;  trap_val = pc_reg;
end else if (is_ecall) begin
    trap_taken = 1'b1;
    trap_cause = (priv_mode == PRIV_U) ? 32'd8 :    // ECALL from U
                 (priv_mode == PRIV_S) ? 32'd9 :    // ECALL from S
                                         32'd11;    // ECALL from M
end else if (illegal || csr_illegal) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  trap_val = instr_reg;
end
```

`trap_pc = pc_reg` and `trap_val` is the faulting instruction word (for
illegal), the faulting PC (for EBREAK), or 0 (for ECALL). ECALL cause code
varies by privilege level.

The two illegal-instruction sources are OR'd:

- `illegal` — bad encoding, from the decoder (`decoder.md`).
- `csr_illegal` — bad CSR access or insufficient privilege, from the CSR module
  (`csr.md`).

### MEM-stage access faults

During the MEM state, an access fault from the memory slave (`dmem_err`
alongside `fe_rdata_valid`) is detected:

```systemverilog
if (fe_err && fe_rdata_valid) begin
    trap_taken = 1'b1;
    trap_cause = mem_write ? 32'd7 : 32'd5;  // store or load access fault
    trap_val   = ex_result_reg;               // faulting data address
end
```

### Asynchronous interrupts

At the start of `ST_FETCH` (between instructions), the core checks for pending
interrupts:

```systemverilog
if (state == ST_FETCH && irq_pending && !fetch_req && !fetch_wait) begin
    trap_taken = 1'b1;
    trap_cause = irq_cause;  // from CSR module
    trap_val   = 32'h0;
end
```

The CSR module computes `irq_pending` and `irq_cause` based on:
- `mip & mie` (pending and enabled interrupts)
- Global interrupt enables (`mstatus.MIE` in M-mode, `mstatus.SIE` in S/U-mode)
- Delegation registers (`mideleg`)

Priority order: MEI > MSI > MTI > SEI > SSI > STI.

## Trap Routing and Delegation

When a trap is taken, the core determines whether to route to M-mode or S-mode:

```systemverilog
trap_to_smode = (priv_mode <= PRIV_S) && 
                (trap_cause[31] ? mideleg[cause] : medeleg[cause]);
```

- **M-mode trap** (`trap_to_smode=0`): updates `mepc`/`mcause`/`mtval`,
  redirects to `mtvec`, sets `priv_mode=PRIV_M`
- **S-mode trap** (`trap_to_smode=1`): updates `sepc`/`scause`/`stval`,
  redirects to `stvec`, sets `priv_mode=PRIV_S`

### Vectored trap vectors

Both `mtvec` and `stvec` support Direct (MODE=0) and Vectored (MODE=1) modes:

- **Direct**: `pc = {tvec[31:2], 2'b00}` (BASE address)
- **Vectored** (interrupts only): `pc = {tvec[31:2], 2'b00} + (cause << 2)`

Exceptions always use Direct mode, even if MODE=1.

## Trap Action

On `trap_taken`:

1. **CSR update**: the CSR module updates `mepc`/`sepc`, `mcause`/`scause`,
   `mtval`/`stval`, and `mstatus` fields based on `trap_to_smode`. See
   [csr.md](csr.md).
2. **PC redirect**: `pc_reg` is set to the computed trap vector (direct or
   vectored).
3. **Privilege update**: `priv_mode` is set to M or S based on `trap_to_smode`.
4. **Skip writeback**: the faulting instruction's result is not written to the
   register file. The FSM returns to FETCH.

No pipeline flush is needed — only one instruction exists at a time.

## CSR State Update on Trap

At the top of the CSR write priority chain in `kv32_csr.sv` (see
[csr.md](csr.md#write-priority-chain)):

**M-mode trap**:
- `mepc <- {trap_pc[31:1], 1'b0}` (bit0 cleared)
- `mcause <- trap_cause`
- `mtval <- trap_val`
- `mstatus.MPIE <- MIE`, `MIE <- 0`, `MPP <- priv_mode`

**S-mode trap**:
- `sepc <- {trap_pc[31:1], 1'b0}`
- `scause <- trap_cause`
- `stval <- trap_val`
- `mstatus.SPIE <- SIE`, `SIE <- 0`, `SPP <- priv_mode[0]`

## MRET and SRET

### MRET

`is_mret` is decoded by the decoder ([decoder.md](decoder.md#system-instructions)).
In the EXEC state it is treated as an unconditional branch to `mepc_out`:
`branch_taken = 1`, `branch_target = mepc_out`. The FSM redirects PC and
returns to FETCH.

MRET is only legal in M-mode. If executed in S or U-mode, it traps as an illegal
instruction (mcause=2).

The CSR module's `mret_taken` input is gated in `kv32_core.sv`:

```systemverilog
.mret_taken (is_mret && (state == ST_EXEC))
```

so MRET only fires once per instruction execution. On `mret_taken` the CSR
module restores `MIE <- MPIE`, `MPIE <- 1`, `MPP <- 2'b11`, and clears `MPRV`
if MPP != M. The core updates `priv_mode <= mstatus.MPP`.

### SRET

`is_sret` is decoded by the decoder. In the EXEC state it is treated as an
unconditional branch to `sepc_out`: `branch_taken = 1`, `branch_target = sepc_out`.

SRET is legal in M-mode or S-mode (if `mstatus.TSR=0`). If executed in U-mode
or in S-mode with TSR=1, it traps as an illegal instruction (mcause=2).

On `sret_taken` the CSR module restores `SIE <- SPIE`, `SPIE <- 1`, `SPP <- 0`.
The core updates `priv_mode <= mstatus.SPP ? PRIV_S : PRIV_U`.

## WFI and SFENCE.VMA

### WFI (Wait for Interrupt)

`is_wfi` is decoded by the decoder. Implemented as a NOP (no actual waiting).

WFI is legal in all modes when `mstatus.TW=0`. If executed in S or U-mode with
TW=1, it traps as an illegal instruction (mcause=2).

### SFENCE.VMA (Supervisor Fence for Virtual Memory)

`is_sfence_vma` is decoded by the decoder. Implemented as a NOP (no TLB to flush
in Phase 5).

SFENCE.VMA is legal in M-mode or S-mode (if `mstatus.TVM=0`). If executed in
S-mode with TVM=1, it traps as an illegal instruction (mcause=2). U-mode execution
traps as illegal.

## CSR Write Gating

`csr_wen_gated = csr_wen && (state == ST_EXEC)` in `kv32_core.sv`. The FSM
state qualification ensures a CSR instruction writes only once during its EXEC
state.

`!trap_taken` is **deliberately not** included in `csr_wen_gated`. The CSR
module's write priority chain (`trap > mret > sret > csr write`,
[csr.md](csr.md#write-priority-chain)) already suppresses the CSR write when a
trap is taken. Omitting `!trap_taken` avoids a combinational loop through
`csr_illegal` → `trap_taken` → `csr_wen_gated` → CSR write. The same reasoning
applies to `mret_taken` and `sret_taken` above.

## `instr_retired` and `minstret`

`instr_retired = (state == ST_WRITEBACK) && !trap_pending` in `kv32_core.sv`. A
trapping instruction never reaches the WRITEBACK state (trap redirects from EXEC
or MEM), so trapping instructions do not count toward `minstret`. See
[csr.md](csr.md#counters).

## Interrupt Taking Flow

1. At `ST_FETCH` entry, CSR module computes `irq_pending` and `irq_cause`
2. If pending, core sets `trap_taken=1`, `trap_cause=irq_cause`, `trap_val=0`
3. Trap routing logic determines `trap_to_smode` based on delegation
4. FSM redirects PC to appropriate trap vector (direct or vectored)
5. CSR module updates `mepc`/`sepc`, `mcause`/`scause`, `mtval`/`stval`, and
   `mstatus` fields
6. `priv_mode` updated to M or S
7. FSM returns to FETCH to fetch trap handler

## Trap-and-skip Pattern

The riscv-tests `env/p` startup probes optional CSRs (`pmpaddr0`, `satp`,
`medeleg`, etc.) by first setting `mtvec` to the next instruction, then
executing the probe. An unimplemented-CSR access traps to that next instruction,
effectively skipping the probe. This is why all `rv32ui-p` tests pass despite
some CSRs being unimplemented (e.g., PMP) — the trap-and-skip turns
"unimplemented" into a controlled NOP from the test's perspective. See
[csr.md](csr.md#legality-check-csr_illegal) for the `csr_illegal` logic that
drives this.

With Phase 5, most CSRs are now implemented, so trap-and-skip is no longer
needed for S-mode CSRs. However, PMP CSRs remain unimplemented and will still
trap-and-skip.
