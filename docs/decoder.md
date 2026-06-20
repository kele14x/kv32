# Decoder

Combinational instruction decoder in `rtl/kv32_decoder.sv`. Takes a 32-bit
instruction and produces decoded fields plus control signals for the rest of the
pipeline. For CSR instruction behavior see [csr.md](csr.md); for the illegal
trap path see [traps.md](traps.md).

## Handled opcodes

| Opcode | Name | Instructions |
|--------|------|--------------|
| `0110111` | `OpLui` | LUI |
| `0010111` | `OpAuipc` | AUIPC |
| `1101111` | `OpJal` | JAL |
| `1100111` | `OpJalr` | JALR |
| `1100011` | `OpBranch` | BEQ/BNE/BLT/BGE/BLTU/BGEU |
| `0000011` | `OpLoad` | LB/LH/LW/LBU/LHU |
| `0100011` | `OpStore` | SB/SH/SW |
| `0010011` | `OpImm` | ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI |
| `0110011` | `OpReg` | ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND |
| `0001111` | `OpMiscMem` | FENCE/FENCE.I (NOPs) |
| `1110011` | `OpSystem` | CSRRW/S/C/I, ECALL, EBREAK, MRET |

Any other opcode sets `illegal=1` (`kv32_decoder.sv:354-356`).

## Immediate generation

`kv32_decoder.sv:62-93`, selected by opcode:

| Type | Opcodes | Format |
|------|---------|--------|
| U | LUI, AUIPC | `{instr[31:12], 12'h0}` |
| J | JAL | `{12{instr[31]}, instr[19:12], instr[20], instr[30:21], 1'b0}` |
| B | Branch | `{20{instr[31]}, instr[7], instr[30:25], instr[11:8], 1'b0}` |
| I | Load, JALR, OpImm | `{21{instr[31]}, instr[30:20]}` |
| S | Store | `{21{instr[31]}, instr[30:25], instr[11:7]}` |

## Control signals

| Signal | Meaning |
|--------|---------|
| `use_imm` | ALU `b` input uses `imm` instead of `rs2` |
| `alu_op_valid` | this instruction uses the ALU result (see below) |
| `alu_op` | ALU op code (see `kv32_pkg.sv:18-27`) |
| `mem_read` / `mem_write` | MEM stage performs a data access |
| `reg_write` | writeback to `rd` |
| `branch` / `jump` / `is_jalr` | branch / JAL-or-JALR / JALR |
| `lui` / `auipc` | select `ex_result` source |
| `csr_op` / `csr_wen` / `is_csr` / `use_zimm` | CSR access (see [csr.md](csr.md)) |
| `is_mret` / `is_ecall` / `is_ebreak` | system instructions |
| `illegal` | raises illegal-instruction trap (see [traps.md](traps.md)) |

## ALU op selection

For `OpImm`/`OpReg`, `alu_op` is selected by `funct3` and (for shifts and
ADD/SUB) `funct7` (`kv32_decoder.sv:181-274`). `SLLI`/`SRLI`/`SRAI` require
`funct7[5]==0` (i.e. `0000000` or `0100000`); any other `funct7` is illegal.

### `alu_op_valid` gotcha

`alu_op_valid` must be set for **any** instruction whose `ex_result` should come
from the ALU — including loads and stores, which use the ALU to compute the
effective address. Both `OpLoad` and `OpStore` set
`alu_op_valid = 1'b1` (`kv32_decoder.sv:157`, `kv32_decoder.sv:171`). Without
this, `ex_result` falls through to the `pc_ex + 4` link-address branch
(`kv32_core.sv:307-311`) and the effective address is wrong. AUIPC also sets it
(`kv32_core.sv:124-125`).

LUI sets `lui=1` instead and `ex_result = imm_ex` (`kv32_core.sv:305-306`); it
does not need `alu_op_valid`.

## CSR instructions

`OpSystem` with `funct3 != 0` (`kv32_decoder.sv:288-352`):

| funct3 | Insn | `csr_op` | `csr_wen` | `use_zimm` |
|--------|------|----------|-----------|------------|
| 001 | CSRRW | WRITE | 1 | 0 |
| 010 | CSRRS | SET | `rs1 != x0` | 0 |
| 011 | CSRRC | CLEAR | `rs1 != x0` | 0 |
| 101 | CSRRWI | WRITE | 1 | 1 |
| 110 | CSRRSI | SET | `zimm != 0` | 1 |
| 111 | CSRRCI | CLEAR | `zimm != 0` | 1 |

`csr_wen` is suppressed for CSRRS/CSRRC with `rs1=x0` (pure read, no side
effects) and for the immediate variants with `zimm=0` (set/clear is a no-op).
All CSR instructions set `reg_write=1` so `rd` receives the old CSR value.

## System instructions

`OpSystem` with `funct3 = 0` (`kv32_decoder.sv:341-349`), keyed on `instr[31:20]`:

- `0x000` → `is_ecall`
- `0x001` → `is_ebreak`
- `0x302` → `is_mret`
- anything else → `illegal`

These do not set `reg_write`; their effect is handled in the trap/MRET logic
(see [traps.md](traps.md)).

## FENCE / FENCE.I

`OpMiscMem` (`kv32_decoder.sv:276-286`): `funct3=000` (FENCE) and `funct3=001`
(FENCE.I) are treated as NOPs — correct for this in-order single-hart pipeline
with no separate I-cache against the unified BRAM in simulation. Any other
`funct3` is illegal.

## Illegal-instruction detection

The decoder sets `illegal=1` for:

- any unrecognized opcode (`kv32_decoder.sv:354-356`),
- `JALR` with `funct3 != 000` (`kv32_decoder.sv:142`),
- branch `funct3` of `010`/`011` (reserved) (`kv32_decoder.sv:150`),
- load `funct3` of `011`/`110`/`111` (`kv32_decoder.sv:163-166`),
- store `funct3` other than `000`/`001`/`010` (`kv32_decoder.sv:175-178`),
- `OpImm`/`OpReg` shift or ADD/SUB with bad `funct7` (`kv32_decoder.sv:197`,
  `217`, etc.),
- `OpMiscMem` with `funct3` other than `000`/`001` (`kv32_decoder.sv:284`),
- `OpSystem` with `funct3` other than the CSR/system set, or an unrecognized
  system immediate (`kv32_decoder.sv:347`, `350`).

`illegal` feeds the EX-stage trap detector (see [traps.md](traps.md)). CSR
*access* legality (unimplemented/read-only) is checked separately in the CSR
module via `csr_illegal` — see [csr.md](csr.md#legality-check-csr_illegal).
