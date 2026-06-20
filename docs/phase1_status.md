# kv32 Phase 1 Implementation Status

**Date**: 2026-06-16  
**Status**: Core implementation complete, sub-word memory access working

## Overview

Phase 1 implements the RV32I base integer instruction set with a 5-stage pipeline (IF/ID/EX/MEM/WB). The design includes forwarding paths, hazard detection, and load-use stall logic.

## Completed Features

### 1. 5-Stage Pipeline Architecture

- **IF Stage**: Instruction fetch with PC management
- **ID Stage**: Instruction decoding and register read
- **EX Stage**: ALU operations and branch comparison
- **MEM Stage**: Data memory access with sub-word support
- **WB Stage**: Register writeback

### 2. Forwarding and Hazard Detection

- **MEM→EX forwarding**: Forwards results from MEM stage directly to EX stage
- **WB→EX forwarding**: Forwards results from WB stage to EX stage
- **Load-use hazard detection**: Stalls pipeline when a load result is needed immediately
- **Control hazard handling**: Flushes pipeline on taken branches

### 3. Sub-Word Memory Access

Implemented full support for byte and halfword memory operations:

**Load Instructions:**

- `LB`: Load byte with sign extension
- `LBU`: Load byte with zero extension
- `LH`: Load halfword with sign extension
- `LHU`: Load halfword with zero extension
- `LW`: Load word (existing)

**Store Instructions:**

- `SB`: Store byte with proper byte enable generation
- `SH`: Store halfword with proper byte enable generation
- `SW`: Store word (existing)

**Implementation Details:**

- Load byte extraction uses address[1:0] to select correct byte from 32-bit word
- Store data positioning places data in correct byte lane(s)
- Byte enables (`d_be`) generated based on address alignment and access size

### 4. Branch Instructions

- BEQ, BNE, BLT, BGE, BLTU, BGEU
- JAL, JALR
- Branch resolution in EX stage with 1-cycle penalty on taken branches

### 5. Memory Interface

- Simple request/response protocol with `d_req`/`d_gnt`/`d_valid`
- Support for word, halfword, and byte accesses
- Memory arbiter for instruction and data port multiplexing

## Bugs Found and Fixed

### 1. Register File Read Port Connection (Critical)

**Issue**: Register file was reading from `rs1_id`/`rs2_id` (ID stage) but forwarding logic compared against `rs1_ex`/`rs2_ex` (EX stage), causing incorrect register values to be used.

**Fix**: Changed register file to read from `rs1_ex`/`rs2_ex` to match the instruction currently in the EX stage.

**Location**: `kv32_core.sv:95-96`

### 2. Decoder `alu_op_valid` Signal (Critical)

**Issue**: Load and store instructions didn't set `alu_op_valid`, causing `ex_result` to default to `pc_ex + 4` instead of using the ALU-calculated address.

**Fix**: Added `alu_op_valid = 1'b1` for both `OP_LOAD` and `OP_STORE` cases in the decoder.

**Location**: `kv32_decoder.sv` (OP_LOAD and OP_STORE sections)

### 3. MEM Stage Address Calculation

**Issue**: Without `alu_op_valid` set for memory operations, the effective address was incorrect.

**Fix**: Resolved by fixing the decoder bug above.

## Test Results

### Main Test (kv32_core_tb)

```text
x1 = 5 ✓
x2 = 10 ✓
x3 = 15 ✓
Test PASSED
```

The test executes:

```assembly
ADDI x1, x0, 5      # x1 = 5
ADDI x2, x0, 10     # x2 = 10
ADD  x3, x1, x2     # x3 = x1 + x2 = 15
```

### Sub-Word Test (kv32_subword_tb)

**Stores**: Working correctly

- Verified with debug output showing correct `d_addr`, `d_wdata`, and `d_be` values
- Byte enables properly generated for SB/SH/SW operations

**Loads**: Working correctly — all sub-word load variants (LB/LBU/LH/LHU/LW) pass both the built-in sub-word test (11/11 checks) and the `rv32ui-p` riscv-tests (`lb`, `lbu`, `lh`, `lhu`, `lw` all PASS).

## Resolved Issues

### Pipeline Stall on Load Instructions (RESOLVED)
The previously-reported load stall issue is fixed. All load instructions execute correctly, verified by the full `rv32ui-p` riscv-tests suite (42/42 PASS). The sub-word load test also passes 11/11 checks.

## File Changes

### Modified Files

1. `rtl/kv32_core.sv`
   - Added `funct3_mem` signal
   - Implemented sub-word load byte extraction (lines 225-253)
   - Implemented sub-word store data positioning (lines 426-464)
   - Fixed register file read port connections (line 95-96)

2. `rtl/kv32_decoder.sv`
   - Added `alu_op_valid` for OP_LOAD instructions
   - Added `alu_op_valid` for OP_STORE instructions

3. `tb/kv32_subword_tb.sv`
   - New testbench for sub-word memory access verification

## Next Steps (all completed)

1. ~~**Investigate Pipeline Stall Issue**: Debug why loads after stores don't execute~~ — **Done**: all loads work correctly.
2. ~~**Implement M-mode CSR Register File**: Add Phase 1 CSR registers~~ — **Done**: `kv32_csr.sv` implements mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval, mip, mstatush, mcycle/h, minstret/h, mcounteren.
3. ~~**Add Exception Handling**: Implement trap mechanism for illegal instructions and memory faults~~ — **Done**: illegal instruction, ECALL, EBREAK traps implemented with mepc/mcause/mtval updates and MRET support.
4. ~~**Run riscv-tests**: Validate against official RISC-V compliance tests~~ — **Done**: 42/42 `rv32ui-p` tests PASS.

## Build and Test Commands

```bash
# Compile main test
iverilog -g2012 -o kv32_core_tb.vvp \
  rtl/kv32_pkg.sv rtl/kv32_alu.sv rtl/kv32_regfile.sv \
  rtl/kv32_decoder.sv rtl/kv32_mem_arbiter.sv rtl/kv32_core.sv \
  tb/kv32_core_tb.sv

# Run main test
vvp kv32_core_tb.vvp

# Compile sub-word test
iverilog -g2012 -o kv32_subword_tb.vvp \
  rtl/kv32_pkg.sv rtl/kv32_alu.sv rtl/kv32_regfile.sv \
  rtl/kv32_decoder.sv rtl/kv32_mem_arbiter.sv rtl/kv32_core.sv \
  tb/kv32_subword_tb.sv

# Run sub-word test
vvp kv32_subword_tb.vvp
```

## Conclusion

Phase 1 core implementation is complete with working sub-word memory access. The main test passes, demonstrating correct execution of arithmetic and register operations. The sub-word store implementation is verified correct. The pipeline stall issue affecting loads requires investigation but is not related to the sub-word memory access implementation itself.

---

## Code Review Issues (2026-06-20)

**Reviewer context**: Full review after Phase 1 completion. Verilator lint passes clean, both built-in tests pass (14/14 checks), and the full `rv32ui-p` riscv-tests suite passes **42/42**. Issues below are ranked by severity. The previously-listed "Known Issues" above (pipeline stall, missing CSR file, missing exception handling, missing riscv-tests run) are all **resolved** — kept above for history.

### Critical / Correctness

#### C1. `instr_retired` undercounts retired instructions

**Location**: `kv32_core.sv:208`

```systemverilog
assign instr_retired = reg_write_wb;
```

**Issue**: `minstret` only increments when an instruction writes a register. This excludes every `SW/SH/SB`, every non-taken `B*`, `FENCE`, `FENCE.I`, `EBREAK`, `ECALL`, and `MRET` — all of which retire without `reg_write_wb=1`. RISC-V requires `minstret` to count *every* retired instruction. `riscv-tests` pass because they don't check `minstret`, but Linux userland profilers and any performance tooling will be wrong.
**Fix**: Track a separate `instr_valid_wb` signal asserted for every non-bubble WB slot, independent of `reg_write_wb`.

#### C2. JALR vs JAL distinguished by a single magic instruction bit

**Location**: `kv32_core.sv:270`

```systemverilog
if (!instr_ex[3]) begin // JALR (opcode bit3=0: 1100111)
    branch_target = (fwd_a + imm_ex) & ~32'h1;
end else begin // JAL (opcode bit3=1: 1101111)
    branch_target = pc_ex + imm_ex;
end
```

**Issue**: Works (JALR `1100111` vs JAL `1101111` differ only in bit 3) but fragile and opaque. A future decoder change (e.g. C-extension compress to JALR variants) could silently break this.
**Fix**: Carry a dedicated `is_jalr_ex`/`is_jal_ex` signal from the decoder, or check the full opcode bits `[6:0]`.

#### C3. `csr_wen` gating on CSRRSI/CSRRCI uses `rs1` field but it holds zimm

**Location**: `kv32_decoder.sv:288,295`

```systemverilog
3'b110: begin // CSRRSI
    csr_wen = (instr[19:15] != 5'h0);   // this field is zimm, not rs1
```

**Issue**: Functionally correct (set/clear with zero is a no-op regardless of whether the field is reg or zimm), but the signal reads `rs1` when it's actually zimm — misleading. A future reader may "fix" it incorrectly.
**Fix**: Gate on `use_zimm ? (instr[19:15] != 0) : (rs1 != 0)` for clarity, or add a comment noting the same zero-check applies to both.

### High — Design / Spec Violations

#### H1. `misa` advertises extensions that don't exist yet

**Location**: `kv32_csr.sv:65-69`

```systemverilog
localparam logic [31:0] MISA_VAL = {
    2'b01, 4'b0000,
    26'b00000001000100101101000101  // claims IMAFDCSU
};
```

**Issue**: Spec §1 says Phase 1 is RV32I only; M/A/C/F/D are Phases 2/3/4/7. Advertising them in `misa` violates the spec and will cause OpenSBI/Linux to probe for nonexistent instructions and trap-loop. The comment trail below it (`"recount"`, `"let us be explicit"`) shows the author struggled to verify the bit packing — decoding the literal yields bits 0, 2, 5, 7, 8, 12, 18, 20, with a stray bit at 7 (reserved) and bit 24.
**Fix**: Set `MISA_VAL = (1 << 8)` for Phase 1 (I only). Update per-phase as extensions land. Use named bit shifts rather than a packed binary literal.

#### H2. `mtvec` MODE field ignored on writes; vectored mode silently unsupported

**Location**: `kv32_csr.sv:226-227` (write), `kv32_core.sv:636` (trap PC)

```systemverilog
// write path stores full 32 bits including MODE[1:0]
mtvec_r <= csr_new_val(mtvec_r, csr_op, csr_wdata);
// trap PC hardwires Direct mode
pc_if <= {mtvec_out[31:2], 2'b00};
```

**Issue**: Spec §7.3 says "Linux typically uses vectored mode." If software writes MODE=1, the core silently ignores it and always does Direct.
**Fix**: Either mask MODE on write and force Direct (return 0 on read of [1:0]), or implement vectored mode (`pc = BASE + 4*cause` for async interrupts). At minimum, document the limitation.

#### H3. Missing `mvendorid` / `marchid` / `mimpid` / `mhartid` / `mconfigptr` CSRs

**Location**: `kv32_csr.sv:45-59` (address constants)
**Issue**: Not in the address list. Reads return 0 from the `default` case (functionally OK for a single-hart soft core) but OpenSBI probes these on boot; `mhartid` (0x0F14) is used to pick the boot hart. They should be explicitly decoded and returned as 0 with a comment, so future readers don't think it's an oversight.
**Fix**: Add explicit `default: csr_rdata = 32'h0` cases for these addresses with comments.

#### H4. `instr_retired` also misses CSR-no-writeback and all system instructions

**Location**: same as C1
**Issue**: `MRET`/`EBREAK`/`ECALL` set `reg_write=0` in the decoder, so they don't count even though they retire. Same fix as C1 — a true `instr_valid_wb` signal.

#### H5. Trap-priority chain may double-count `minstret` on trapping instructions

**Location**: `kv32_csr.sv:189-192` (counters outside the `trap_taken > mret_taken > csr_wen` priority chain)
**Issue**: `mcycle_r` always increments (correct for cycle). `minstret_r` increments whenever `instr_retired` is high — but `instr_retired = reg_write_wb`, and on a trap the trapping instruction's `reg_write_wb` is squashed (EX/MEM register cleared at `kv32_core.sv:767-772`), so the trapping instruction does *not* count. This is actually correct behavior — but worth a comment confirming the intent, since the counter increment is structurally outside the priority chain.

### Medium — Robustness / Maintainability

#### M1. Memory arbiter: `d_gnt` re-asserted every cycle in D_PORT_ACTIVE

**Location**: `kv32_mem_arbiter.sv:150-163`
**Issue**: `d_gnt=1` is asserted every cycle `mem_gnt` is seen, until `mem_valid`. Spec §4.2 rule 3 says one outstanding transaction. With a compliant slave this is harmless, but a slave that interprets `gnt&req` as a new transaction would double-fire.
**Fix**: Track a `granted` flag and assert `d_gnt` only on the first `mem_gnt` seen in D_PORT_ACTIVE.

#### M2. Misalignment handler `MA_WAIT→MA_SECOND` is a blind 1-cycle transition

**Location**: `kv32_core.sv:464-466`

```systemverilog
MA_WAIT: begin
    ma_state <= MA_SECOND;  // no arb_idle check
end
```

**Issue**: Unconditionally advances after one cycle, *assuming* the arbiter returned to IDLE. The `arb_idle` check in `MA_SECOND` (line 468) catches late arrivals, so it's safe — but the comment on line 366 (`"First access done, suppress d_req until arbiter IDLE"`) describes intent, not what MA_WAIT actually does (it doesn't check `arb_idle`).
**Fix**: Either rename MA_WAIT to `MA_DRAIN` and document, or collapse MA_WAIT/MA_SECOND into one state that waits on `arb_idle`.

#### M3. `non_crossing_ma` load path tightly coupled to SH@offset 1

**Location**: `kv32_core.sv:567-569`

```systemverilog
if (non_crossing_ma && !d_we && d_valid_a) begin
    d_rdata = {8'h0, d_rdata_a[31:8]};  // shift right by 8
end
```

**Issue**: Correct only for SH@addr[1:0]=01. The detector (line 386) only ever sets `non_crossing_ma` for that exact case, so it's safe — but a future reader could "generalize" it incorrectly.
**Fix**: Add a comment: "only SH@offset 1 reaches here; any other non-crossing case is naturally aligned."

#### M4. Legacy SV testbenches have missing port connections

**Location**: `tb/kv32_core_tb.sv`, `tb/kv32_subword_tb.sv`
**Issue**: Both instantiate `kv32_core` without connecting `irq_timer_i` or `irq_software_i` (only `irq_external_i`). Would fail Verilator lint with UNCONNECTED if run. `kv32_subword_tb.sv` also has dead code (line 70 sets `bram[1]`, line 71 overwrites it).
**Fix**: Per CLAUDE.md they're "legacy for Icarus" — either delete them, or add the missing port connections and a note that they're maintained for Icarus fallback only.

#### M5. `sim_main.cpp` `mem_responder` is zero-latency only

**Location**: `sim_main.cpp:361-378`
**Issue**: `mem_gnt = mem_req`, `mem_valid = mem_req & mem_gnt` — all combinational. This is spec-legal (§4.2 rule 4) but means the testbench never exercises the arbiter's D_PORT_ACTIVE hold or the misalignment handler's MA_WAIT state. Bugs in those paths could hide.
**Fix**: Add a future test variant with 1+ cycle `mem_valid` latency to exercise stall paths.

### Low — Style / Documentation

#### L1. CLAUDE.md "Known Issues" section is stale

**Location**: `CLAUDE.md` (Known Issues)
**Issue**: Three listed issues are all already fixed:

- "OP_SYSTEM handling incomplete" — **FIXED**: decoder (lines 300-308) handles ECALL/EBREAK/MRET with `reg_write=0`.
- "Missing FENCE instruction" — **FIXED**: `OP_MISC_MEM` decoded (line 254) as NOP.
- "ALU operation codes duplicated in `kv32_alu.sv` and `kv32_decoder.sv`" — **FIXED**: unified in `kv32_pkg.sv`.
**Fix**: Update CLAUDE.md so future agents don't "fix" already-fixed issues.

#### L2. `docs/phase1_summary.md` and this file's "Known Issues" section are stale

**Location**: `docs/phase1_summary.md:37,41`, `docs/phase1_status.md:102-112,133`
**Issue**: `phase1_summary.md` line 37 says "⚠️ Pipeline execution has bugs (PC not incrementing)" — long fixed. This file's "Known Issues" section describes the load-stall bug — long fixed. Line 133 lists CSR file as a "Next Step" — already done.
**Fix**: Either update these to "Phase 1 complete, verified by 42/42 riscv-tests" or move to `docs/archive/` and write a fresh `phase1_final.md`.

#### L3. README "Prerequisites" mentions only `riscv64-elf-gcc`

**Location**: `README.md:13`, `Makefile:55`
**Issue**: The more common toolchain name is `riscv32-unknown-elf-gcc`. README does mention the override (line 56) but the Makefile default could friendlier.
**Fix**: `RISCV_GCC ?= riscv64-unknown-elf-gcc` or auto-detect with `command -v`.

#### L4. `verilator-build` uses `-j 0` (unlimited parallelism)

**Location**: `Makefile:27`
**Issue**: Triggered a parallel-build race on WSL mount (first `make verilator` failed with missing binary / undefined references; clean rebuild succeeded). Build log shows "Clock skew detected".
**Fix**: Use `-j 1` or a fixed `-j 4` for reproducibility on clock-skewed filesystems.

#### L5. `kv32_regfile.sv` has no reset on the register array

**Location**: `kv32_regfile.sv:25-29`
**Issue**: Intentional (regs don't need reset for functional correctness, saves area) but undocumented.
**Fix**: Add a one-line comment noting this is intentional.

#### L6. `csr_wen_gated` / `mret_taken` gating only comments `mem_stall`

**Location**: `kv32_core.sv:205,855`
**Issue**: Gating with `!mem_stall` is correct (load-use bubbles clear `csr_wen_ex`/`is_mret_ex` the next cycle), but the logic is non-obvious.
**Fix**: Add a brief comment explaining why `mem_stall` alone suffices (load-use path clears the EX registers).

### Recommended Fix Priority

1. **C1 + H4** — fix `instr_retired` (one signal, fixes `minstret` for Linux)
2. **H1** — fix `misa` value (one-line change, prevents OpenSBI boot failure in Phase 9)
3. **L1 + L2** — update stale docs so future agents don't waste cycles
4. **H3** — add explicit zero-return CSRs for `mvendorid`/`marchid`/`mimpid`/`mhartid`/`mconfigptr`
5. **H2** — decide `mtvec` vectored mode (implement or document as Direct-only)
6. **C2** — clean up JALR detection (carry real signal from decoder)
7. **M1** — arbiter `d_gnt` re-assertion (add `granted` flag)
8. **M5** — add multi-cycle-latency testbench (exercises stall paths)
9. Everything else is polish.

### What's Done Well

- **Module decomposition**: 7 small files, each with one job. `kv32_alu.sv` is 26 lines, `kv32_regfile.sv` is 31.
- **`unique case` everywhere**: catches missed-branch bugs at lint time.
- **Forwarding logic** (`kv32_core.sv:582-602`): clearly structured with MEM→EX priority and explicit WB→EX override guards.
- **Misalignment handler**: real state machine with named states (MA_IDLE/FIRST/DRAIN/SECOND/HOLD) rather than ad-hoc flags.
- **CSR read-before-write** (`kv32_csr.sv:130-149`): correctly ordered so `CSRRW` reads the old value in the same instruction.
- **Trap priority** (illegal > ecall > ebreak, with `!mem_stall` guard): correct.
- **Testbench ELF loader** (`sim_main.cpp:85-225`): handles program headers, BSS zero-fill, and `.tohost` symbol search via both section name and symtab fallback.
- **42/42 riscv-tests passing**: strongest signal that the core is functionally correct for RV32I.

### Verification Status at Review Time

- `make lint` — passes clean (Verilator 5.048, `-Wall`)
- `make verilator` (ALU test) — 3/3 checks pass
- `make test-subword` — 11/11 checks pass
- `make riscv-tests` — **42/42 PASS, 0 fail, 0 timeout** (with `RISCV_GCC=riscv32-unknown-elf-gcc`)

---

## Second-Round Review (GPT, 2026-06-20) — All Resolved

A second review by GPT identified 7 findings. All were addressed:

| # | Finding | Severity | Status | Resolution |
|---|---------|----------|--------|------------|
| 1 | Arbiter loses/corrupts request on delayed `mem_gnt` | High | **Fixed** | State machine now transitions IDLE→*_ACTIVE only when `mem_gnt` is seen, ensuring latched fields are always valid. |
| 2 | Arbiter drops zero-latency responses (SPEC §4.2 allows `mem_valid` same cycle as `mem_gnt`) | High | **Fixed** | Response demux now handles IDLE state; state machine stays in IDLE when `mem_valid` arrives with `mem_gnt` (zero-latency completion). |
| 3 | `misa` advertises unsupported extensions (A/C/D/F/M/S/U) | High | **Fixed** (first round) | `MISA_VAL` now I-only for Phase 1. |
| 4 | Illegal CSR accesses silently accepted (no trap) | Medium | **Documented** | Phase 5 TODO in CLAUDE.md — fix when trap handling is fully exercised. |
| 5 | Invalid instruction encodings decode as valid (branch/load/store/JALR funct3, OP_MISC_MEM) | Medium | **Documented** | Phase 5 TODO in CLAUDE.md — add funct3 validation in decoder. |
| 6 | `minstret` only counts register-writing instructions | Medium | **Fixed** (first round) | `instr_retired` now tracks `instr_valid_wb` through all pipeline stages. |
| 7 | Test harness doesn't initialize `irq_timer_i`/`irq_software_i` | Low | **Fixed** | Added `top->irq_timer_i = 0` and `top->irq_software_i = 0` in `sim_main.cpp`. |

### Additional Bugs Found While Fixing GPT-1+2

The arbiter state machine fix (GPT-1+2) changed the fetch timing from 2 cycles/instruction to 1 cycle/instruction, which exposed two hidden bugs that the old timing had been masking:

#### A1. Branch flush didn't insert an EX bubble (Critical)
**Location**: `kv32_core.sv:656`
**Issue**: `ex_flush` only covered `trap_taken`, not `branch_taken`. When a branch resolved in EX, the instruction in ID would advance to EX and execute despite being flushed from IF/ID. The old arbiter's 2-cycle fetch meant ID usually held a bubble during branches, hiding this.
**Fix**: Added `branch_taken` to `ex_flush`:
```systemverilog
assign ex_flush = branch_taken || trap_taken;
```
The EX/MEM register still checks `trap_taken` (not `ex_flush`), so the branch instruction itself continues to MEM/WB normally — only the flushed ID instruction is squashed.

#### A2. Testbench missed write→read at same address (Medium)
**Location**: `sim_main.cpp` `mem_responder()`
**Issue**: The `new_txn` detection used address change only. A store followed by a load from the same address (with no i-port fetch in between) wasn't detected as a new transaction — stale read data was returned. The old arbiter's 2-cycle fetch always inserted an i-port fetch between d-port transactions, hiding this.
**Fix**: Also track `txn_we` and detect write→read or read→write transitions at the same address as new transactions.

### Final Verification (after all fixes)

- `make lint` — passes clean
- `make verilator` (ALU test) — 3/3 checks pass
- `make test-subword` — 11/11 checks pass
- `make riscv-tests` — **42/42 PASS, 0 fail, 0 timeout** (zero latency)
- `make riscv-tests-latency` — **42/42 PASS, 0 fail, 0 timeout** (2-cycle memory latency)
