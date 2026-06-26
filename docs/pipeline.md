# Execution Model

Implementation details of the multi-cycle FSM that executes one instruction at a
time. For the architectural specification (rationale, privilege modes, MMU), see
[SPEC.md §1](../SPEC.md). For trap handling see [traps.md](traps.md); for memory
access see [memory.md](memory.md).

```text
FETCH → DECODE → EXEC → MEM → WRITEBACK → FETCH → ...
```

Single issue, in-order. One instruction completes (or traps) before the next
begins. No forwarding, no hazard detection, no pipeline flush.

## State responsibilities

| State      | Role                                                  | Key signals                                  |
| ---------- | ----------------------------------------------------- | -------------------------------------------- |
| FETCH      | Drive `imem_req` with `pc_reg`, wait for `imem_ack`   | `pc_reg`, `imem_req`, `imem_ack`             |
| DECODE     | Combinational decode (`kv32_decoder`), regfile read   | `instr_reg`, decode control outputs           |
| EXEC       | ALU, branch compare, CSR read/write, trap detect, M-unit | `alu_result`, `ex_result`, `branch_taken`, `trap_taken` |
| MEM        | Data memory access via `dmem_*` through `kv32_mem_fe` | `dmem_req`, `fe_rdata_valid`, `fe_rdata`      |
| WRITEBACK  | Register writeback, `minstret` increment, PC += 4     | `regfile_we`, `regfile_rd`, `regfile_wdata`   |

All state transitions are in `rtl/kv32_core.sv`.

## FSM state enum

```systemverilog
typedef enum logic [2:0] {
  ST_FETCH,
  ST_DECODE,
  ST_EXEC,
  ST_MEM,
  ST_WRITEBACK
} state_t;
```

## Per-state behavior

### FETCH

Drive `imem_req` with `pc_reg`. Wait for the `imem_ack` handshake (may be
zero-latency or multi-cycle depending on the memory slave). On `imem_ack`, latch
`imem_rdata` into `instr_reg` and advance to DECODE.

### DECODE

The decoder (`kv32_decoder`) is combinational — it produces all control signals
and the immediate from `instr_reg` in the same cycle. The register file
(`kv32_regfile`) is also combinational-read, so `rs1_data` and `rs2_data` are
available immediately. This state advances to EXEC in one cycle.

### EXEC

Compute the result of the instruction:

- **ALU ops**: `alu_result` from `kv32_alu` using `rs1_data`/`rs2_data`.
- **AUIPC**: ALU with `pc_reg` as operand A.
- **LUI**: result = `imm`.
- **CSR**: result = `csr_rdata`; CSR write gated by `state == ST_EXEC`.
- **M-extension**: start `kv32_m_unit`, hold in EXEC while `m_busy`, latch
  `m_result` on `m_done`.
- **Branch/jump**: evaluate condition, compute target.
- **Trap**: detect illegal/ecall/ebreak, set `trap_taken`.

On branch taken or trap: redirect `pc_reg` to the target (or `mtvec` for traps)
and return to FETCH. Otherwise: latch `ex_result` and advance to MEM.

### MEM

For loads and stores: drive `dmem_req` through `kv32_mem_fe`, wait for
`fe_rdata_valid`. For all other instructions: pass through in one cycle.

On completion: advance to WRITEBACK.

### WRITEBACK

Write result to register file (if `reg_write` is set for this instruction).
Increment `minstret` via `instr_retired`. Advance `pc_reg` by 4. Return to
FETCH.

If an access fault was detected in MEM (`fe_err && fe_rdata_valid`), the FSM
redirects to `mtvec` instead of advancing PC — see [traps.md](traps.md).

## Register file design

`kv32_regfile.sv` — 32×32-bit, 2 read ports, 1 write port, combinational read,
synchronous write. `x0` is hardwired to 0 in the read-port mux; the write port
also gates on `rd_addr != 0`. The array is **intentionally not reset** (saves
FPGA/ASIC resources; software initializes registers before use).

Read ports are addressed by the decoded `rs1`/`rs2` fields from `instr_reg`.
Since reads are combinational and the FSM holds the instruction stable through
EXEC, operands are available without latching.

## Result selection

The `ex_result` mux in `kv32_core.sv` selects the writeback value:

```systemverilog
ex_result = is_csr       ? csr_rdata   :
            lui          ? imm         :
            is_m_op      ? m_result    :
            (alu_op_valid || auipc) ? alu_result :
            pc_reg + 4;
```

For loads, the writeback data is `fe_rdata` (from `kv32_mem_fe`) instead of
`ex_result`.

## Branch and jump resolution

Resolved combinationally in EXEC. `branch_taken` and `branch_target` are
computed from `rs1_data`/`rs2_data`:

- `MRET`: target = `mepc_out`.
- Branches (`funct3`): BEQ/BNE/BLT/BGE/BLTU/BGEU; target = `pc_reg + imm`.
- JAL: target = `pc_reg + imm`.
- JALR: target = `(rs1_data + imm) & ~1`.

A taken branch or jump redirects `pc_reg` and returns to FETCH. No flush is
needed — only one instruction exists at a time.

## `instr_retired` and `minstret`

`instr_retired = (state == ST_WRITEBACK) && !trap_pending`. A trapping
instruction never reaches WRITEBACK (trap redirects from EXEC or MEM), so
trapping instructions do not count toward `minstret`.
