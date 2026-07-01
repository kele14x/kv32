# Decoder

Combinational instruction decoder in `rtl/kv32_decoder.sv`. Takes a 32-bit
instruction and produces decoded fields plus control signals for the rest of the
core. For CSR instruction behavior see [csr.md](csr.md); for the illegal
trap path see [traps.md](traps.md).

## Handled opcodes

| Opcode    | Name        | Instructions                                 |
| --------- | ----------- | -------------------------------------------- |
| `0110111` | `OpLui`     | LUI                                          |
| `0010111` | `OpAuipc`   | AUIPC                                        |
| `1101111` | `OpJal`     | JAL                                          |
| `1100111` | `OpJalr`    | JALR                                         |
| `1100011` | `OpBranch`  | BEQ/BNE/BLT/BGE/BLTU/BGEU                    |
| `0000011` | `OpLoad`    | LB/LH/LW/LBU/LHU                             |
| `0100011` | `OpStore`   | SB/SH/SW                                     |
| `0010011` | `OpImm`     | ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI |
| `0110011` | `OpReg`     | ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND      |
| `0001111` | `OpMiscMem` | FENCE/FENCE.I (NOPs)                         |
| `1110011` | `OpSystem`  | CSRRW/S/C/I, ECALL, EBREAK, MRET             |
| `0101111` | `OpAmo`     | LR.W, SC.W, AMO* (A extension)               |

Any other opcode sets `illegal=1`.

## Immediate generation

In `kv32_decoder.sv`, selected by opcode:

| Type   | Opcodes           | Format                                                         |
| ------ | ----------------- | -------------------------------------------------------------- |
| U      | LUI, AUIPC        | `{instr[31:12], 12'h0}`                                        |
| J      | JAL               | `{12{instr[31]}, instr[19:12], instr[20], instr[30:21], 1'b0}` |
| B      | Branch            | `{20{instr[31]}, instr[7], instr[30:25], instr[11:8], 1'b0}`   |
| I      | Load, JALR, OpImm | `{21{instr[31]}, instr[30:20]}`                                |
| S      | Store             | `{21{instr[31]}, instr[30:25], instr[11:7]}`                   |

## Control signals

| Signal                                       | Meaning                                                    |
| -------------------------------------------- | ---------------------------------------------------------- |
| `use_imm`                                    | ALU `b` input uses `imm` instead of `rs2`                  |
| `alu_op_valid`                               | this instruction uses the ALU result (see below)           |
| `alu_op`                                     | ALU op code (see `kv32_pkg.sv`)                            |
| `mem_read` / `mem_write`                     | MEM state performs a data access                           |
| `reg_write`                                  | writeback to `rd`                                          |
| `branch` / `jump` / `is_jalr`                | branch / JAL-or-JALR / JALR                                |
| `lui` / `auipc`                              | select `ex_result` source                                  |
| `csr_op` / `csr_wen` / `is_csr` / `use_zimm` | CSR access (see [csr.md](csr.md))                          |
| `is_mret` / `is_ecall` / `is_ebreak`         | system instructions                                        |
| `illegal`                                    | raises illegal-instruction trap (see [traps.md](traps.md)) |

## ALU op selection

For `OpImm`/`OpReg`, `alu_op` is selected by `funct3` and (for shifts and
ADD/SUB) `funct7` in `kv32_decoder.sv`. `SLLI`/`SRLI`/`SRAI` require
`funct7[5]==0` (i.e. `0000000` or `0100000`); any other `funct7` is illegal.

### `alu_op_valid` gotcha

`alu_op_valid` must be set for **any** instruction whose `ex_result` should come
from the ALU — including loads and stores, which use the ALU to compute the
effective address. Both `OpLoad` and `OpStore` set `alu_op_valid = 1'b1` in
`kv32_decoder.sv`. Without this, `ex_result` falls through to the `pc_reg + 4`
link-address branch in `kv32_core.sv` and the effective address is wrong. AUIPC
also sets it in `kv32_core.sv`.

LUI sets `lui=1` instead and `ex_result = imm` in `kv32_core.sv`; it
does not need `alu_op_valid`.

## CSR instructions

`OpSystem` with `funct3 != 0` in `kv32_decoder.sv`:

| funct3   | Insn   | `csr_op`   | `csr_wen`   | `use_zimm`   |
| -------- | ------ | ---------- | ----------- | ------------ |
| 001      | CSRRW  | WRITE      | 1           | 0            |
| 010      | CSRRS  | SET        | `rs1 != x0` | 0            |
| 011      | CSRRC  | CLEAR      | `rs1 != x0` | 0            |
| 101      | CSRRWI | WRITE      | 1           | 1            |
| 110      | CSRRSI | SET        | `zimm != 0` | 1            |
| 111      | CSRRCI | CLEAR      | `zimm != 0` | 1            |

`csr_wen` is suppressed for CSRRS/CSRRC with `rs1=x0` (pure read, no side
effects) and for the immediate variants with `zimm=0` (set/clear is a no-op).
All CSR instructions set `reg_write=1` so `rd` receives the old CSR value.

## System instructions

`OpSystem` with `funct3 = 0` in `kv32_decoder.sv`, keyed on `instr[31:20]`:

- `0x000` → `is_ecall`
- `0x001` → `is_ebreak`
- `0x302` → `is_mret`
- anything else → `illegal`

These do not set `reg_write`; their effect is handled in the trap/MRET logic
(see [traps.md](traps.md)).

## A extension (atomic instructions)

`OpAmo` in `kv32_decoder.sv`, keyed on `funct5` (bits 31:27):

| funct5  | Instruction | `is_lr` | `is_sc` | `is_amo` | `mem_read` | `mem_write` |
| ------- | ----------- | ------- | ------- | -------- | ---------- | ----------- |
| `00010` | LR.W        | 1       | 0       | 0        | 1          | 0           |
| `00011` | SC.W        | 0       | 1       | 0        | 0          | 1           |
| `00001` | AMOSWAP.W   | 0       | 0       | 1        | 1          | 1           |
| `00000` | AMOADD.W    | 0       | 0       | 1        | 1          | 1           |
| `01100` | AMOAND.W    | 0       | 0       | 1        | 1          | 1           |
| `01000` | AMOOR.W     | 0       | 0       | 1        | 1          | 1           |
| `00100` | AMOXOR.W    | 0       | 0       | 1        | 1          | 1           |
| `10100` | AMOMAX.W    | 0       | 0       | 1        | 1          | 1           |
| `10000` | AMOMIN.W    | 0       | 0       | 1        | 1          | 1           |
| `11100` | AMOMAXU.W   | 0       | 0       | 1        | 1          | 1           |
| `11000` | AMOMINU.W   | 0       | 0       | 1        | 1          | 1           |

All A-extension instructions require `funct3 = 010` (word width); any other
`funct3` is illegal. The `.aq` and `.rl` bits (bits 26:25) are decoded but
ignored in this single-hart implementation.

All A-extension instructions set `alu_op_valid = 1` and `alu_op = AluAdd` to
compute the effective address `rs1 + 0` (no offset). The `rs2` field holds the
source register for SC.W and AMO operations.

**Control signals**:

- `is_lr`: load-reserved (sets reservation on success)
- `is_sc`: store-conditional (checks reservation, writes 0/1 to `rd`)
- `is_amo`: read-modify-write (multi-phase in MEM state)

See [memory.md](memory.md#lrsc-and-amo-operations) for FSM integration details.

## FENCE / FENCE.I

`OpMiscMem` in `kv32_decoder.sv`: `funct3=000` (FENCE) and `funct3=001`
(FENCE.I) are treated as NOPs — correct for this in-order single-hart FSM
with no separate I-cache against the unified BRAM in simulation. Any other
`funct3` is illegal.

## Illegal-instruction detection

The decoder sets `illegal=1` for:

- any unrecognized opcode,
- `JALR` with `funct3 != 000`,
- branch `funct3` of `010`/`011` (reserved),
- load `funct3` of `011`/`110`/`111`,
- store `funct3` other than `000`/`001`/`010`,
- `OpImm`/`OpReg` shift or ADD/SUB with bad `funct7`,
- `OpMiscMem` with `funct3` other than `000`/`001`,
- `OpSystem` with `funct3` other than the CSR/system set, or an unrecognized
  system immediate.

`illegal` feeds the EXEC-state trap detector (see [traps.md](traps.md)). CSR
*access* legality (unimplemented/read-only) is checked separately in the CSR
module via `csr_illegal` — see [csr.md](csr.md#legality-check-csr_illegal).
