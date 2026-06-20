# Traps and Exceptions

Implementation of synchronous trap detection, pipeline flush, and the MRET
return path. For the architectural exception cause table, trap vector modes, and
interrupt plan, see [SPEC.md §7](../SPEC.md). For CSR state updates on
trap/MRET, see [csr.md](csr.md); for illegal-instruction sources in the decoder,
see [decoder.md](decoder.md).

**Implemented (synchronous, M-mode only)**: illegal instruction (mcause=2),
ECALL from M-mode (mcause=11), EBREAK (mcause=3). Interrupt-taking, S/U-mode
traps, and delegation are Phase 5 work (SPEC §14).

## Trap detection (EX stage)

`kv32_core.sv:229-258`, combinational, gated by `!mem_stall` so a stalled
instruction is not re-evaluated every cycle:

```systemverilog
if (illegal_ex || csr_illegal) begin
    trap_taken = 1'b1; trap_cause = 32'd2;  trap_val = instr_ex;
end else if (is_ecall_ex) begin
    trap_taken = 1'b1; trap_cause = 32'd11; trap_val = 32'h0;
end else if (is_ebreak_ex) begin
    trap_taken = 1'b1; trap_cause = 32'd3;  trap_val = pc_ex;
end
```

`trap_pc = pc_ex` and `trap_val` is the faulting instruction word (for illegal)
or the faulting PC (for EBREAK). ECALL uses `mtval=0`.

The two illegal-instruction sources are OR'd:

- `illegal_ex` — bad encoding, from the decoder (`decoder.md`).
- `csr_illegal` — bad CSR access, from the CSR module (`csr.md`). The `is_csr`
  input in the CSR module gates this so non-CSR instructions never report
  illegal.

## Pipeline flush on trap

Trap and taken-branch share the same flush path (`kv32_core.sv:657-669`):

```systemverilog
assign if_flush = branch_taken || trap_taken;
assign id_flush = branch_taken || trap_taken;
assign ex_flush = branch_taken || trap_taken;
```

- `if_flush`/`id_flush` clear IF/ID to NOP (`instr_id <= 0x13`,
  `instr_valid_id <= 0`) — 2-cycle penalty.
- `ex_flush` inserts a bubble into EX (clears all control signals and
  `instr_valid_ex`, `kv32_core.sv:741-755`). For a trap, this squashes the
  faulting instruction so it does not write back. For a branch, it squashes the
  instruction in ID that would have advanced to EX.

**EX/MEM squash** (`kv32_core.sv:821-827`): on `trap_taken` the EX/MEM register
additionally clears `reg_write_mem`/`mem_read_mem`/`mem_write_mem`/`rd_mem` and
`instr_valid_mem`. This is checked against `trap_taken` (not `ex_flush`) so the
branch in EX can still propagate its own `reg_write` to MEM/WB normally while
only the trap case squashes the EX→MEM transition.

## IF redirect

`kv32_core.sv:672-687`. Trap redirect has **highest priority** (above
branch-flush and PC increment):

```systemverilog
if (trap_taken) begin
    pc_if <= {mtvec_out[31:2], 2'b00};  // Direct mode: jump to BASE
    i_req <= 1'b1;
end else if (if_flush) begin ... end
```

`mtvec` MODE is forced to Direct (`csr.md`#mtvec-mode-masking), so the target is
always `mtvec.BASE`. Vectored mode (interrupt dispatch to `BASE + 4*cause`) is
deferred until async interrupt-taking is added.

## CSR state update on trap

In `kv32_csr.sv:253-259` (top of the write priority chain, see
[csr.md](csr.md#write-priority-chain)):

- `mepc <- {trap_pc[31:1], 1'b0}` (bit0 cleared),
- `mcause <- trap_cause`,
- `mtval <- trap_val`,
- `mstatus.MPIE <- MIE`, `MIE <- 0`, `MPP <- 2'b11` (M-mode).

## MRET

`is_mret_ex` is decoded by the decoder ([decoder.md](decoder.md#system-instructions)). In
the EX stage it is treated as a "branch to `mepc_out`"
(`kv32_core.sv:268-270`), so it reuses the branch flush path
(`branch_taken=1`, `if_flush`/`id_flush`/`ex_flush`).

The CSR module's `mret_taken` input is gated in `kv32_core.sv:918`:

```systemverilog
.mret_taken (is_mret_ex && !mem_stall)
```

so a stalled MRET does not fire repeatedly. Load-use bubbles clear `is_mret_ex`
via the ID/EX register, so no extra gate is needed for that path. On `mret_taken`
the CSR module restores `MIE <- MPIE`, `MPIE <- 1`, `MPP <- 2'b11`
(`kv32_csr.sv:264-267`).

## CSR write gating

`csr_wen_gated = csr_wen_ex && !mem_stall` (`kv32_core.sv:222`). The `!mem_stall`
gate prevents a CSR instruction stuck behind a stalled MEM from re-writing every
cycle.

`!trap_taken` is **deliberately not** included in `csr_wen_gated`. The CSR
module's write priority chain (`trap > mret > csr write`,
[csr.md](csr.md#write-priority-chain)) already suppresses the CSR write when a
trap is taken. Omitting `!trap_taken` avoids a combinational loop through
`csr_illegal` → `trap_taken` → `csr_wen_gated` → CSR write. The same reasoning
applies to `mret_taken` above.

## `instr_retired` and `minstret`

`instr_retired = instr_valid_wb && !mem_stall` (`kv32_core.sv:227`). A trapping
instruction is squashed in the EX/MEM register (above), so `instr_valid_mem` and
thus `instr_valid_wb` are low that cycle — the trapping instruction does not
count toward `minstret`. See [csr.md](csr.md#counters).

## Trap-and-skip pattern

The riscv-tests `env/p` startup probes optional CSRs (`pmpaddr0`, `satp`,
`medeleg`, etc.) by first setting `mtvec` to the next instruction, then
executing the probe. An unimplemented-CSR access traps to that next instruction,
effectively skipping the probe. This is why all 42 `rv32ui-p` tests pass despite
S/U-mode CSRs being unimplemented — the trap-and-skip turns "unimplemented" into
a controlled NOP from the test's perspective. See [csr.md](csr.md#legality-check-csr_illegal)
for the `csr_illegal` logic that drives this.
