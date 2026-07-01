# 2. ISA Extensions

## 2.1 M Extension (Integer Multiply/Divide)

RV32M adds 8 instructions in two groups, all sharing `funct7 = 7'b0000001`:

| Instruction | funct3 | Type   | Result          |
| ----------- | ------ | ------ | --------------- |
| `MUL`       | 000    | Mul    | `result[31:0]`  |
| `MULH`      | 001    | Mul    | `result[63:32]` |
| `MULHSU`    | 010    | Mul    | `result[63:32]` |
| `MULHU`     | 011    | Mul    | `result[63:32]` |
| `DIV`       | 100    | Div    | quotient        |
| `DIVU`      | 101    | Div    | quotient        |
| `REM`       | 110    | Div    | remainder       |
| `REMU`      | 111    | Div    | remainder       |

**Architecture**: a dedicated M-unit (`kv32_m_unit`) is instantiated alongside the ALU. The M-unit is multi-cycle and holds the FSM in the EXEC state until completion.

**FSM integration**:

1. **Decode**: the decoder asserts `is_m_mul` or `is_m_div` based on `funct7`/`funct3`.
2. **EXEC entry**: when an M-extension instruction reaches EXEC, the M-unit begins computation using the register file operands (`rs1_data`, `rs2_data`). `m_busy` is asserted, holding the FSM in EXEC.
3. **Completion**: after N cycles the M-unit asserts `m_done` and presents the result. The FSM latches `m_result` and advances to MEM.
4. **Result selection**: the `ex_result` mux selects `m_result` for M-extension instructions.

**`ex_result` mux** priority:

```text
ex_result = is_m_op   ? m_result    :
            is_csr     ? csr_rdata   :
            lui        ? imm         :
            (alu_op_valid || auipc) ? alu_result :
            pc + 4;
```

**No hazard concerns**: only one instruction exists at a time. A dependent instruction fetches fresh operands from the register file after the M-unit result is written back.

**Gating**: M-unit activation is gated by `state == ST_EXEC` to prevent spurious starts.

### 2.1.1 Multiplication semantics

- **MUL**: returns the lower 32 bits of the 64-bit product. Identical for signed and unsigned inputs.
- **MULH**: returns the upper 32 bits of `signed(rs1) × signed(rs2)`.
- **MULHSU**: returns the upper 32 bits of `signed(rs1) × unsigned(rs2)`.
- **MULHU**: returns the upper 32 bits of `unsigned(rs1) × unsigned(rs2)`.

The full 64-bit product is computed internally; the `funct3` selects which half is written to `rd`.

### 2.1.2 Division semantics

**Division by zero** (per RISC-V spec — no trap):

| Instruction | Result when `rs2 == 0`     |
| ----------- | -------------------------- |
| `DIV`       | `-1` (`0xFFFFFFFF`)       |
| `DIVU`      | `2^32 - 1` (`0xFFFFFFFF`)|
| `REM`       | `rs1` (the dividend)      |
| `REMU`      | `rs1` (the dividend)      |

**Signed overflow** (`DIV`/`REM` only, when `rs1 == INT_MIN` and `rs2 == -1`):

| Instruction | Result                     |
| ----------- | -------------------------- |
| `DIV`       | `INT_MIN` (`0x80000000`)  |
| `REM`       | `0`                        |

Both special cases are detected combinationally at M-unit entry and resolved without running the iterative divider (0-cycle latency for these cases).

### 2.1.3 Hardware implementation

**Multiplier**:

- 32×32 → 64-bit multiplication.
- Target latency: **2–3 cycles** (registered output stages).
- On FPGA: write as a registered `a * b` expression and let synthesis infer DSP blocks (Xilinx DSP48E2, Intel DSP Block). DSP blocks are internally pipelined, giving 1 result per 2–3 cycles with 1-cycle throughput once the pipeline is full — though the stall-based approach means we don't exploit throughput across back-to-back multiplies.
- Alternative: a pure combinational `a * b` followed by a single output register (1-cycle latency), but this will likely fail timing closure at high Fmax on a 32×32 multiply.

**Divider**:

- 32-bit division (signed and unsigned variants).
- **Iterative non-restoring division**: 1 bit per cycle → 32 cycles + 1 cycle for sign correction (signed variants only) = 32–33 cycles total.
- **Radix-4 variant** (optional): 2 bits per cycle → 16 cycles + 1 sign correction. More complex per-cycle logic but halves latency.
- Default: radix-2 for simplicity; radix-4 can be added later if division latency is a bottleneck.
- Division by zero and signed overflow (§2.1.2) are detected before the iterative loop starts and short-circuit to the result immediately.

**Signed magnitude conversion**: for signed DIV/REM, the operands are converted to magnitude (absolute value) before the unsigned divider, and the result signs are applied afterward:
- Quotient sign = `rs1_sign XOR rs2_sign`
- Remainder sign = `rs1_sign`

## 2.2 A Extension (Atomic Instructions)

RV32A adds atomic memory operations for multiprocessor synchronization:

| Instruction | funct5  | Type   | Description                                      |
| ----------- | ------- | ------ | ------------------------------------------------ |
| `LR.W`      | 00010   | Load   | Load-Reserved: `rd = [rs1]`, set reservation     |
| `SC.W`      | 00011   | Store  | Store-Conditional: if reserved, `[rs1] = rs2`, `rd = 0`; else `rd = 1` |
| `AMOSWAP.W` | 00001   | AMO    | `[rd] = rs2`, `[rs1] = rs2`                     |
| `AMOADD.W`  | 00000   | AMO    | `rd = [rs1]`, `[rs1] = [rs1] + rs2`             |
| `AMOAND.W`  | 01100   | AMO    | `rd = [rs1]`, `[rs1] = [rs1] & rs2`             |
| `AMOOR.W`   | 01000   | AMO    | `rd = [rs1]`, `[rs1] = [rs1] \| rs2`            |
| `AMOXOR.W`  | 00100   | AMO    | `rd = [rs1]`, `[rs1] = [rs1] ^ rs2`             |
| `AMOMAX.W`  | 10100   | AMO    | `rd = [rs1]`, `[rs1] = smax([rs1], rs2)`        |
| `AMOMIN.W`  | 10000   | AMO    | `rd = [rs1]`, `[rs1] = smin([rs1], rs2)`        |
| `AMOMAXU.W` | 11100   | AMO    | `rd = [rs1]`, `[rs1] = umax([rs1], rs2)`        |
| `AMOMINU.W` | 11000   | AMO    | `rd = [rs1]`, `[rs1] = umin([rs1], rs2)`        |

**Architecture**: a dedicated AMO unit (`kv32_amo_unit`) performs the read-modify-write computation combinationally. LR/SC use a reservation register to track exclusive access.

**Reservation register**:
- Set by successful `LR.W`: stores `{valid=1, addr=rs1}`
- Cleared by `SC.W` (success or failure) or by any non-SC store to the same address
- Single-hart implementation: one reservation register per hart

**FSM integration**:

1. **Decode**: the decoder asserts `is_lr`, `is_sc`, or `is_amo` based on `funct5` (bits 31:27).
2. **EXEC**: the ALU computes the effective address `rs1 + 0` (no offset for atomics).
3. **MEM state**:
   - **LR.W**: performs a normal load, sets reservation on success
   - **SC.W**: checks reservation; if valid and address matches, performs store and writes `rd = 0`; else writes `rd = 1` (no memory access)
   - **AMO**: multi-phase operation:
     - Phase 1: read `old_val = [rs1]`
     - Phase 2: compute `new_val = op(old_val, rs2)` using `kv32_amo_unit`
     - Phase 3: write `[rs1] = new_val`
4. **WRITEBACK**: writes result to `rd` (load value for LR, success/failure for SC, old value for AMO).

**Address alignment**: all atomic instructions require word-aligned addresses (`addr[1:0] == 00`). Misaligned addresses trap with cause 4 (LR) or cause 6 (SC/AMO).

**Memory ordering**: `.aq` and `.rl` bits (bits 26:25) are decoded but ignored in this single-hart implementation. A future multi-hart version would need to enforce acquire/release semantics via memory barriers.

## 2.3 C Extension (Compressed Instructions)

RV32C adds 16-bit compressed instruction encodings that are decompressed to their 32-bit RV32I equivalents at fetch. The decompressor (`kv32_decompressor`) sits between the fetch buffer and the decoder; the rest of the datapath is unchanged. Verified with the `rv32uc` suite.

Fence, `fence.i`, and `sfence.vma` semantics are covered in [08-special-insts.md](08-special-insts.md).
