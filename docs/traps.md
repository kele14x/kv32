# Traps and Exceptions

Implementation of synchronous trap detection and the MRET return path. For the
architectural exception cause table, trap vector modes, and interrupt plan, see
[SPEC.md §7](../SPEC.md). For CSR state updates on trap/MRET, see
[csr.md](csr.md); for illegal-instruction sources in the decoder, see
[decoder.md](decoder.md).

**Implemented (synchronous, M-mode only)**: illegal instruction (mcause=2),
ECALL from M-mode (mcause=11), EBREAK (mcause=3). Interrupt-taking, S/U-mode
traps, and delegation are Phase 5 work (SPEC §14).

## Trap detection

Traps are detected combinationally in `kv32_core.sv`. Only one instruction
exists at a time, so there is no cross-stage priority to resolve.

### EXEC-stage traps

During the EXEC state, the following conditions are checked:

```systemverilog
if (is_ebreak) begin
    trap_taken = 1'b1; trap_cause = 32'd3;  trap_val = pc_reg;
end else if (is_ecall) begin
    trap_taken = 1'b1; trap_cause = 32'd11; trap_val = 32'h0;
end else if (illegal || csr_illegal) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  trap_val = instr_reg;
end
```

`trap_pc = pc_reg` and `trap_val` is the faulting instruction word (for
illegal) or the faulting PC (for EBREAK). ECALL uses `mtval=0`.

The two illegal-instruction sources are OR'd:

- `illegal` — bad encoding, from the decoder (`decoder.md`).
- `csr_illegal` — bad CSR access, from the CSR module (`csr.md`). The `is_csr`
  input in the CSR module gates this so non-CSR instructions never report
  illegal.

### MEM-stage access faults

During the MEM state, an access fault from the memory slave (`dmem_err`
alongside `fe_rdata_valid`) is detected:

```systemverilog
if (fe_err && fe_rdata_valid) begin
    trap_taken = 1'b1;
    trap_cause = mem_write ? 32'd7 : 32'd5;  // store or load access fault
    trap_val   = mem_addr;                     // faulting data address
end
```

## Trap action

On `trap_taken`:

1. **CSR update**: the CSR module updates `mepc`, `mcause`, `mtval`, and
   `mstatus` (MPIE ← MIE, MIE ← 0, MPP ← M-mode). See [csr.md](csr.md).
2. **PC redirect**: `pc_reg` is set to `{mtvec_out[31:2], 2'b00}` (Direct mode
   BASE).
3. **Skip writeback**: the faulting instruction's result is not written to the
   register file. The FSM returns to FETCH.

No pipeline flush is needed — only one instruction exists at a time.

`mtvec` MODE is forced to Direct (`csr.md`#mtvec-mode-masking), so the target is
always `mtvec.BASE`. Vectored mode (interrupt dispatch to `BASE + 4*cause`) is
deferred until async interrupt-taking is added.

## CSR state update on trap

At the top of the CSR write priority chain in `kv32_csr.sv` (see
[csr.md](csr.md#write-priority-chain)):

- `mepc <- {trap_pc[31:1], 1'b0}` (bit0 cleared),
- `mcause <- trap_cause`,
- `mtval <- trap_val`,
- `mstatus.MPIE <- MIE`, `MIE <- 0`, `MPP <- 2'b11` (M-mode).

## MRET

`is_mret` is decoded by the decoder ([decoder.md](decoder.md#system-instructions)).
In the EXEC state it is treated as an unconditional branch to `mepc_out`:
`branch_taken = 1`, `branch_target = mepc_out`. The FSM redirects PC and
returns to FETCH.

The CSR module's `mret_taken` input is gated in `kv32_core.sv`:

```systemverilog
.mret_taken (is_mret && (state == ST_EXEC))
```

so MRET only fires once per instruction execution. On `mret_taken` the CSR
module restores `MIE <- MPIE`, `MPIE <- 1`, `MPP <- 2'b11` in `kv32_csr.sv`.

## CSR write gating

`csr_wen_gated = csr_wen && (state == ST_EXEC)` in `kv32_core.sv`. The FSM
state qualification ensures a CSR instruction writes only once during its EXEC
state.

`!trap_taken` is **deliberately not** included in `csr_wen_gated`. The CSR
module's write priority chain (`trap > mret > csr write`,
[csr.md](csr.md#write-priority-chain)) already suppresses the CSR write when a
trap is taken. Omitting `!trap_taken` avoids a combinational loop through
`csr_illegal` → `trap_taken` → `csr_wen_gated` → CSR write. The same reasoning
applies to `mret_taken` above.

## `instr_retired` and `minstret`

`instr_retired = (state == ST_WRITEBACK) && !trap_pending` in `kv32_core.sv`. A
trapping instruction never reaches the WRITEBACK state (trap redirects from EXEC
or MEM), so trapping instructions do not count toward `minstret`. See
[csr.md](csr.md#counters).

## Trap-and-skip pattern

The riscv-tests `env/p` startup probes optional CSRs (`pmpaddr0`, `satp`,
`medeleg`, etc.) by first setting `mtvec` to the next instruction, then
executing the probe. An unimplemented-CSR access traps to that next instruction,
effectively skipping the probe. This is why all 42 `rv32ui-p` tests pass despite
S/U-mode CSRs being unimplemented — the trap-and-skip turns "unimplemented" into
a controlled NOP from the test's perspective. See [csr.md](csr.md#legality-check-csr_illegal)
for the `csr_illegal` logic that drives this.
