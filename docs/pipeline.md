# Pipeline

Implementation details of the 5-stage in-order pipeline. For the architectural
specification (rationale, privilege modes, MMU), see [SPEC.md §1](../SPEC.md).
For trap/flush interaction see [traps.md](traps.md); for memory access see
[memory.md](memory.md).

```
IF -> ID -> EX -> MEM -> WB
```

Single issue, in-order, no speculation. Branches resolve in EX (2-cycle penalty
on taken branch). All pipeline registers live in `rtl/kv32_core.sv`.

## Stage responsibilities

| Stage | Role | Key signals |
|-------|------|-------------|
| IF | PC management, instruction fetch via i-port | `pc_if`, `i_req`, `i_addr` |
| ID | Decode (`kv32_decoder`), read source registers | `instr_id`, `rs1_id`/`rs2_id`, decode control outputs |
| EX | ALU, branch compare, CSR read, trap detect | `alu_result`, `ex_result`, `branch_taken`, `trap_taken` |
| MEM | Data memory access via d-port, sub-word extract | `mem_result`, `d_req`, `d_valid` |
| WB | Register writeback | `regfile_we`, `regfile_rd`, `regfile_wdata` |

## Instruction-valid tracking

A separate `instr_valid_*` chain (`kv32_core.sv:102`) distinguishes real
instructions from bubbles (flushed slots, load-use bubbles, reset state). This
is what lets `minstret` count retired instructions correctly rather than
counting every slot that reaches WB. A bubble has `instr_valid_*=0` and cleared
write/control signals, so it neither writes the register file nor retires.

## Register file design

`kv32_regfile.sv` — 32×32-bit, 2 read ports, 1 write port, combinational read,
synchronous write. `x0` is hardwired to 0 in the read-port mux; the write port
also gates on `rd_addr != 0`. The array is **intentionally not reset** (saves
FPGA/ASIC resources; software initializes registers before use).

**Reads are taken from `rs1_ex`/`rs2_ex` (EX stage), not `rs1_id`/`rs2_id`**
(`kv32_core.sv:157-166`). This is critical for forwarding: the forwarding logic
compares against the instruction currently in EX, so the regfile must read the
operands for that same instruction. Reading in ID would desync the operands from
the forwarding comparisons.

## Forwarding

`kv32_core.sv:614-635`. Two paths, both feed the EX stage:

- **MEM→EX (highest priority)**: forwards `mem_result` when
  `reg_write_mem && rd_mem != 0`.
- **WB→EX (lower priority)**: forwards `wb_data` when
  `reg_write_wb && rd_wb != 0`, but only if MEM isn't already forwarding to the
  same register (the `!(reg_write_mem && rd_mem == rsN_ex)` guard).

`fwd_a`/`fwd_b` default to the regfile read values and are used by the ALU input
mux, the branch comparator, and the sub-word store data positioning (so a
forwarded `rs2` becomes the stored value — see [memory.md](memory.md)).

ALU input mux (`kv32_core.sv:297-299`):

```systemverilog
assign alu_a = auipc_ex ? pc_ex : fwd_a;
assign alu_b = use_imm_ex ? imm_ex : fwd_b;
```

`ex_result` mux (`kv32_core.sv:301-312`) selects CSR read data → LUI immediate
→ ALU result (`alu_op_valid_ex || auipc_ex`) → `pc_ex + 4` (JAL/JALR link).

## Hazard detection and stalls

**Load-use hazard** (`kv32_core.sv:643-644`):

```systemverilog
assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 &&
                        ((rd_ex == rs1_id) || (rd_ex == rs2_id));
```

When detected, the ID/EX register inserts a bubble (control signals cleared,
`rd_ex <= 0`, `instr_valid_ex <= 0`) — see `kv32_core.sv:757-775`.

**Stall/backpressure network** (`kv32_core.sv:647-655`):

```systemverilog
assign if_wait   = i_req && !i_valid;
assign mem_stall = (mem_read_mem || mem_write_mem) && !d_valid;
assign ex_stall  = mem_stall;
assign id_stall  = load_use_hazard || mem_stall || if_wait;
assign if_stall  = if_wait || load_use_hazard || mem_stall;
```

- `mem_stall`: MEM stalls until `d_valid` (not just `d_gnt`).
- `ex_stall`: backpressure from MEM freezes the ID/EX register.
- `if_wait`: IF has an outstanding fetch with no response yet; inserts a bubble
  in EX to prevent double-execution once the instruction arrives.
- All pipeline registers use the `if (!stall)` pattern to hold values during
  stalls (e.g. `kv32_core.sv:739`, `kv32_core.sv:828`, `kv32_core.sv:889`).

## Branch and jump resolution

Resolved combinationally in EX (`kv32_core.sv:260-295`). `branch_taken` and
`branch_target` are computed from `fwd_a`/`fwd_b` (forwarded operands):

- `MRET`: target = `mepc_out`.
- Branches (`funct3_ex`): BEQ/BNE/BLT/BGE/BLTU/BGEU; target = `pc_ex + imm_ex`.
- JAL: target = `pc_ex + imm_ex`.
- JALR: target = `(fwd_a + imm_ex) & ~1`.

A taken branch flushes IF and ID (2-cycle penalty). The flush signals are shared
with trap handling — see [traps.md](traps.md) for the combined flush logic.

## Pipeline register summary

| Register | Location | Reset / flush behavior |
|----------|----------|------------------------|
| IF (PC, i_req) | `kv32_core.sv:672-687` | reset → `pc_if=0`, `i_req=1`; trap → `mtvec`; flush → `branch_target`; stall → hold |
| IF/ID | `kv32_core.sv:692-707` | reset/flush → NOP (`0x13`), `instr_valid_id=0`; stall → hold |
| ID/EX | `kv32_core.sv:710-805` | reset → all zero; `ex_stall` → freeze; `ex_flush` → bubble; load_use/if_wait → bubble; else latch decoded fields |
| EX/MEM | `kv32_core.sv:808-880` | reset → all zero; `trap_taken` → bubble (squash faulting insn); `!mem_stall` → latch + compute store BE/wdata |
| MEM/WB | `kv32_core.sv:883-895` | reset → all zero; `!mem_stall` → latch `mem_result` |

The EX/MEM register also performs store data positioning and byte-enable
generation for sub-word stores (see [memory.md](memory.md#sub-word-stores)).
