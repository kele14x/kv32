# Pipeline

Implementation details of the 5-stage in-order pipeline. For the architectural
specification (rationale, privilege modes, MMU), see [SPEC.md §1](../SPEC.md).
For trap/flush interaction see [traps.md](traps.md); for memory access see
[memory.md](memory.md).

```text
IF -> ID -> EX -> MEM -> WB
```

Single issue, in-order, no speculation. Branches resolve in EX (2-cycle penalty
on taken branch). All pipeline registers live in `rtl/kv32_core.sv`.

## Stage responsibilities

| Stage   | Role                                              | Key signals                                               |
| ------- | ------------------------------------------------- | --------------------------------------------------------- |
| IF      | PC management, instruction fetch via i-port       | `pc_if`, `i_req`, `i_addr`                                |
| ID      | Decode (`kv32_decoder`), read source registers    | `instr_id`, `rs1_id`/`rs2_id`, decode control outputs     |
| EX      | ALU, branch compare, CSR read, trap detect        | `alu_result`, `ex_result`, `branch_taken`, `trap_taken`   |
| MEM     | Data memory access via d-port, sub-word extract   | `mem_result`, `d_req`, `d_valid`                          |
| WB      | Register writeback                                | `regfile_we`, `regfile_rd`, `regfile_wdata`               |

## Instruction-valid tracking

A separate `instr_valid_*` chain in `kv32_core.sv` distinguishes real
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
in `kv32_core.sv`. This is critical for forwarding: the forwarding logic
compares against the instruction currently in EX, so the regfile must read the
operands for that same instruction. Reading in ID would desync the operands from
the forwarding comparisons.

## Forwarding

Forwarding logic in `kv32_core.sv`. Two paths, both feed the EX stage:

- **MEM→EX (highest priority)**: forwards `mem_result` when
  `reg_write_mem && rd_mem != 0`.
- **WB→EX (lower priority)**: forwards `wb_data` when
  `reg_write_wb && rd_wb != 0`, but only if MEM isn't already forwarding to the
  same register (the `!(reg_write_mem && rd_mem == rsN_ex)` guard).

`fwd_a`/`fwd_b` default to the regfile read values and are used by the ALU input
mux, the branch comparator, and the sub-word store data positioning (so a
forwarded `rs2` becomes the stored value — see [memory.md](memory.md)).

ALU input mux in `kv32_core.sv`:

```systemverilog
assign alu_a = auipc_ex ? pc_ex : fwd_a;
assign alu_b = use_imm_ex ? imm_ex : fwd_b;
```

`ex_result` mux in `kv32_core.sv` selects CSR read data → LUI immediate
→ ALU result (`alu_op_valid_ex || auipc_ex`) → `pc_ex + 4` (JAL/JALR link).

## Hazard detection and stalls

**Load-use hazard** in `kv32_core.sv`:

```systemverilog
assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 &&
                        ((rd_ex == rs1_id) || (rd_ex == rs2_id));
```

When detected, the ID/EX register inserts a bubble (control signals cleared,
`rd_ex <= 0`, `instr_valid_ex <= 0`).

**Stall/backpressure network** in `kv32_core.sv`:

```systemverilog
assign if_wait   = i_req && !i_valid;
assign mem_stall = (mem_read_mem || mem_write_mem) && !d_valid;
assign ex_stall  = mem_stall;
assign id_stall  = load_use_hazard || mem_stall || if_wait;
assign if_stall  = if_wait || load_use_hazard || mem_stall;
```

- `mem_stall`: MEM stalls until `d_valid` (not just `d_gnt`).
- `ex_stall`: backpressure from MEM freezes the ID/EX register.
- `if_wait`: IF has a fetch request or response in flight with no buffered
  instruction available yet; inserts a bubble in EX to prevent double-execution
  once the instruction arrives.
- All pipeline registers use the `if (!stall)` pattern to hold values during
  stalls.

## Branch and jump resolution

Resolved combinationally in EX in `kv32_core.sv`. `branch_taken` and
`branch_target` are computed from `fwd_a`/`fwd_b` (forwarded operands):

- `MRET`: target = `mepc_out`.
- Branches (`funct3_ex`): BEQ/BNE/BLT/BGE/BLTU/BGEU; target = `pc_ex + imm_ex`.
- JAL: target = `pc_ex + imm_ex`.
- JALR: target = `(fwd_a + imm_ex) & ~1`.

A taken branch flushes IF and ID (2-cycle penalty). The flush signals are shared
with trap handling — see [traps.md](traps.md) for the combined flush logic.

## Pipeline register summary

| Register         | Reset / flush behavior                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------ |
| IF (PC, i_req)   | reset → `pc_if=0`, `i_req=1`; trap → `mtvec`; flush → `branch_target`; stall → hold                                |
| IF/ID            | reset/flush → NOP (`0x13`), `instr_valid_id=0`; stall → hold                                                       |
| ID/EX            | reset → all zero; `ex_stall` → freeze; `ex_flush` → bubble; load_use/if_wait → bubble; else latch decoded fields   |
| EX/MEM           | reset → all zero; `trap_taken` → bubble (squash faulting insn); `!mem_stall` → latch + compute store BE/wdata      |
| MEM/WB           | reset → all zero; `!mem_stall` → latch `mem_result`                                                                |

The EX/MEM register also performs store data positioning and byte-enable
generation for sub-word stores (see [memory.md](memory.md#sub-word-stores)).
