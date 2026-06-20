// tb_decoder.cpp — unit test for kv32_decoder
// Verifies all opcodes, immediate types, control signals, and CSR variants.
// Combinational DUT: set instr, eval, check outputs.
//
// Note: rd/funct3/rs1/rs2 are raw bit extractions from instr[11:7]/[14:12]/
// [19:15]/[24:20] regardless of instruction type. We pre-fill them from the
// instruction word via fields() and focus assertions on the derived control
// signals and immediate generation.

#include "Vkv32_decoder.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>

static int tests = 0, failures = 0;

// ---- Instruction encoders ------------------------------------------------
static uint32_t r(uint8_t f7, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t rd, uint8_t op) {
    return ((uint32_t)f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
static uint32_t i_type(int32_t imm, uint8_t rs1, uint8_t f3, uint8_t rd, uint8_t op) {
    return ((uint32_t)(imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
static uint32_t s_type(int32_t imm, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t op) {
    uint32_t im = (uint32_t)imm & 0xFFF;
    return ((im & 0xFE0) << 20) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((im & 0x1F) << 7) | op;
}
static uint32_t b_type(int32_t imm, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t op) {
    uint32_t im = (uint32_t)imm & 0x1FFE;  // bits [12:1], bit 0 always 0
    return ((im & 0x1000) << 19)          // imm[12]   -> instr[31]
         | ((im & 0x7E0) << 20)           // imm[10:5] -> instr[30:25]
         | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
         | ((im & 0x1E) << 7)             // imm[4:1]  -> instr[11:8]
         | ((im & 0x800) >> 4)            // imm[11]   -> instr[7]
         | op;
}
static uint32_t u_type(int32_t imm, uint8_t rd, uint8_t op) {
    return ((uint32_t)imm & 0xFFFFF000) | (rd << 7) | op;
}
static uint32_t j_type(int32_t imm, uint8_t rd, uint8_t op) {
    uint32_t im = (uint32_t)imm & 0x1FFFFE;  // bits [20:1], bit 0 always 0
    return ((im & 0x100000) << 11)    // imm[20]    -> instr[31]
         | (im & 0xFF000)             // imm[19:12] -> instr[19:12]
         | ((im & 0x800) << 9)        // imm[11]    -> instr[20]
         | ((im & 0x7FE) << 20)       // imm[10:1]  -> instr[30:21]
         | (rd << 7) | op;
}

// Opcodes
enum { OP_LUI=0x37, OP_AUIPC=0x17, OP_JAL=0x6F, OP_JALR=0x67, OP_BRANCH=0x63,
       OP_LOAD=0x03, OP_STORE=0x23, OP_IMM=0x13, OP_REG=0x33,
       OP_MISC_MEM=0x0F, OP_SYSTEM=0x73 };

// ALU op codes (from kv32_pkg)
enum { ALU_ADD=0, ALU_SUB=1, ALU_SLL=2, ALU_SLT=3, ALU_SLTU=4,
       ALU_XOR=5, ALU_SRL=6, ALU_SRA=7, ALU_OR=8, ALU_AND=9 };

// CSR op codes
enum { CSR_NONE=0, CSR_WRITE=1, CSR_SET=2, CSR_CLEAR=3 };

// ---- Expected-values struct with safe defaults (all-zero / inactive) -----
struct Exp {
    uint8_t  rd=0, funct3=0, rs1=0, rs2=0, alu_op=0;
    uint32_t imm=0;
    bool use_imm=false, alu_op_valid=false, mem_read=false, mem_write=false;
    bool reg_write=false, branch=false, jump=false, is_jalr=false;
    bool illegal=false, lui=false, auipc=false;
    uint8_t csr_op=0; bool csr_wen=false, is_csr=false, is_mret=false;
    bool use_zimm=false, is_ecall=false, is_ebreak=false;
};

// Pre-fill raw bit-extraction fields from the instruction word
static Exp fields(uint32_t instr) {
    Exp e;
    e.rd     = (instr >> 7)  & 0x1F;
    e.funct3 = (instr >> 12) & 0x7;
    e.rs1    = (instr >> 15) & 0x1F;
    e.rs2    = (instr >> 20) & 0x1F;
    return e;
}

static void check(Vkv32_decoder* d, const char* name, uint32_t instr, Exp e) {
    // Fill in raw bit-extraction fields from the instruction word
    Exp raw = fields(instr);
    e.rd = raw.rd; e.funct3 = raw.funct3; e.rs1 = raw.rs1; e.rs2 = raw.rs2;

    d->instr = instr;
    d->eval();
    tests++;
    int before = failures;
#define CMP(field) do { \
    if (d->field != e.field) { \
        fprintf(stderr, "FAIL  %-18s ." #field " got=%u want=%u\n", \
                name, (unsigned)d->field, (unsigned)e.field); \
        failures++; \
    } } while(0)
    CMP(rd); CMP(funct3); CMP(rs1); CMP(rs2); CMP(alu_op); CMP(imm);
    CMP(use_imm); CMP(alu_op_valid); CMP(mem_read); CMP(mem_write);
    CMP(reg_write); CMP(branch); CMP(jump); CMP(is_jalr);
    CMP(illegal); CMP(lui); CMP(auipc);
    CMP(csr_op); CMP(csr_wen); CMP(is_csr); CMP(is_mret);
    CMP(use_zimm); CMP(is_ecall); CMP(is_ebreak);
#undef CMP
    if (failures != before)
        fprintf(stderr, "  (instr=0x%08X)\n", instr);
}

int main() {
    Verilated::traceEverOn(false);
    Vkv32_decoder* d = new Vkv32_decoder;

    // ---- LUI ----
    { uint32_t i = u_type(0x12345000, 5, OP_LUI);
      Exp e = fields(i); e.imm=0x12345000; e.reg_write=true; e.lui=true;
      check(d, "LUI", i, e); }

    // ---- AUIPC ----
    { uint32_t i = u_type(0xABCDE000, 6, OP_AUIPC);
      Exp e = fields(i); e.imm=0xABCDE000; e.use_imm=true; e.alu_op_valid=true;
      e.alu_op=ALU_ADD; e.reg_write=true; e.auipc=true;
      check(d, "AUIPC", i, e); }

    // ---- JAL ----
    { uint32_t i = j_type(0x100, 1, OP_JAL);
      Exp e = fields(i); e.imm=0x100; e.jump=true; e.reg_write=true;
      check(d, "JAL +0x100", i, e); }

    // ---- JAL with negative immediate ----
    { uint32_t i = j_type(-4, 1, OP_JAL);
      Exp e = fields(i); e.imm=(uint32_t)(-4); e.jump=true; e.reg_write=true;
      check(d, "JAL -4", i, e); }

    // ---- JALR ----
    { uint32_t i = i_type(4, 2, 0, 1, OP_JALR);
      Exp e = fields(i); e.imm=4; e.use_imm=true;
      e.jump=true; e.is_jalr=true; e.reg_write=true;
      check(d, "JALR", i, e); }

    // ---- BEQ ----
    { uint32_t i = b_type(8, 2, 1, 0, OP_BRANCH);
      Exp e = fields(i); e.imm=8; e.branch=true;
      check(d, "BEQ +8", i, e); }

    // ---- BNE negative offset ----
    { uint32_t i = b_type(-16, 2, 1, 1, OP_BRANCH);
      Exp e = fields(i); e.imm=(uint32_t)(-16); e.branch=true;
      check(d, "BNE -16", i, e); }

    // ---- LW ----
    { uint32_t i = i_type(16, 4, 2, 3, OP_LOAD);
      Exp e = fields(i); e.imm=16; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_ADD; e.mem_read=true; e.reg_write=true;
      check(d, "LW", i, e); }

    // ---- LH (funct3=1) ----
    { uint32_t i = i_type(0, 4, 1, 3, OP_LOAD);
      Exp e = fields(i); e.imm=0; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_ADD; e.mem_read=true; e.reg_write=true;
      check(d, "LH", i, e); }

    // ---- SW ----
    { uint32_t i = s_type(8, 2, 3, 2, OP_STORE);
      Exp e = fields(i); e.imm=8; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_ADD; e.mem_write=true;
      check(d, "SW", i, e); }

    // ---- SB negative offset ----
    { uint32_t i = s_type(-4, 2, 3, 0, OP_STORE);
      Exp e = fields(i); e.imm=(uint32_t)(-4); e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_ADD; e.mem_write=true;
      check(d, "SB -4", i, e); }

    // ---- OP-IMM family ----
    { uint32_t i = i_type(5, 2, 0, 1, OP_IMM);
      Exp e = fields(i); e.imm=5; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_ADD; e.reg_write=true;
      check(d, "ADDI", i, e); }

    { uint32_t i = i_type(4, 2, 1, 1, OP_IMM);
      Exp e = fields(i); e.imm=4; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_SLL; e.reg_write=true;
      check(d, "SLLI", i, e); }

    { uint32_t i = i_type(-1, 2, 2, 1, OP_IMM);
      Exp e = fields(i); e.imm=(uint32_t)(-1); e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_SLT; e.reg_write=true;
      check(d, "SLTI -1", i, e); }

    { uint32_t i = i_type(1, 2, 3, 1, OP_IMM);
      Exp e = fields(i); e.imm=1; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_SLTU; e.reg_write=true;
      check(d, "SLTIU", i, e); }

    { uint32_t i = i_type(0xFF, 2, 4, 1, OP_IMM);
      Exp e = fields(i); e.imm=0xFF; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_XOR; e.reg_write=true;
      check(d, "XORI", i, e); }

    { uint32_t i = i_type(4, 2, 5, 1, OP_IMM);
      Exp e = fields(i); e.imm=4; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_SRL; e.reg_write=true;
      check(d, "SRLI", i, e); }

    { uint32_t i = i_type(0x404, 2, 5, 1, OP_IMM);
      Exp e = fields(i); e.imm=0x404; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_SRA; e.reg_write=true;
      check(d, "SRAI", i, e); }  // funct7=0x20

    { uint32_t i = i_type(0xF0, 2, 6, 1, OP_IMM);
      Exp e = fields(i); e.imm=0xF0; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_OR; e.reg_write=true;
      check(d, "ORI", i, e); }

    { uint32_t i = i_type(0xFF, 2, 7, 1, OP_IMM);
      Exp e = fields(i); e.imm=0xFF; e.use_imm=true;
      e.alu_op_valid=true; e.alu_op=ALU_AND; e.reg_write=true;
      check(d, "ANDI", i, e); }

    // ---- OP-REG family ----
    { uint32_t i = r(0, 3, 2, 0, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_ADD; e.reg_write=true;
      check(d, "ADD", i, e); }

    { uint32_t i = r(0x20, 3, 2, 0, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SUB; e.reg_write=true;
      check(d, "SUB", i, e); }

    { uint32_t i = r(0, 3, 2, 1, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SLL; e.reg_write=true;
      check(d, "SLL", i, e); }

    { uint32_t i = r(0, 3, 2, 2, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SLT; e.reg_write=true;
      check(d, "SLT", i, e); }

    { uint32_t i = r(0, 3, 2, 3, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SLTU; e.reg_write=true;
      check(d, "SLTU", i, e); }

    { uint32_t i = r(0, 3, 2, 4, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_XOR; e.reg_write=true;
      check(d, "XOR", i, e); }

    { uint32_t i = r(0, 3, 2, 5, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SRL; e.reg_write=true;
      check(d, "SRL", i, e); }

    { uint32_t i = r(0x20, 3, 2, 5, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_SRA; e.reg_write=true;
      check(d, "SRA", i, e); }

    { uint32_t i = r(0, 3, 2, 6, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_OR; e.reg_write=true;
      check(d, "OR", i, e); }

    { uint32_t i = r(0, 3, 2, 7, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.alu_op=ALU_AND; e.reg_write=true;
      check(d, "AND", i, e); }

    // ---- FENCE (NOP in this pipeline) ----
    { Exp e; check(d, "FENCE", 0x0000000F, e); }

    // ---- CSR instructions ----
    { uint32_t i = i_type(0x340, 2, 1, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_WRITE; e.csr_wen=true;
      e.is_csr=true; e.reg_write=true;
      check(d, "CSRRW", i, e); }

    { uint32_t i = i_type(0x340, 2, 2, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_SET; e.csr_wen=true;
      e.is_csr=true; e.reg_write=true;
      check(d, "CSRRS rs1!=0", i, e); }

    { uint32_t i = i_type(0x340, 0, 2, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_SET; e.csr_wen=false;
      e.is_csr=true; e.reg_write=true;
      check(d, "CSRRS rs1=x0", i, e); }

    { uint32_t i = i_type(0x340, 2, 3, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_CLEAR; e.csr_wen=true;
      e.is_csr=true; e.reg_write=true;
      check(d, "CSRRC", i, e); }

    { uint32_t i = i_type(0x340, 5, 5, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_WRITE; e.csr_wen=true;
      e.is_csr=true; e.use_zimm=true; e.reg_write=true;
      check(d, "CSRRWI", i, e); }

    { uint32_t i = i_type(0x340, 5, 6, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_SET; e.csr_wen=true;
      e.is_csr=true; e.use_zimm=true; e.reg_write=true;
      check(d, "CSRRSI zimm!=0", i, e); }

    { uint32_t i = i_type(0x340, 0, 6, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_SET; e.csr_wen=false;
      e.is_csr=true; e.use_zimm=true; e.reg_write=true;
      check(d, "CSRRSI zimm=0", i, e); }

    { uint32_t i = i_type(0x340, 5, 7, 1, OP_SYSTEM);
      Exp e = fields(i); e.csr_op=CSR_CLEAR; e.csr_wen=true;
      e.is_csr=true; e.use_zimm=true; e.reg_write=true;
      check(d, "CSRRCI", i, e); }

    // ---- System instructions ----
    { uint32_t i = i_type(0x000, 0, 0, 0, OP_SYSTEM);
      Exp e = fields(i); e.is_ecall=true;
      check(d, "ECALL", i, e); }

    { uint32_t i = i_type(0x001, 0, 0, 0, OP_SYSTEM);
      Exp e = fields(i); e.is_ebreak=true;
      check(d, "EBREAK", i, e); }

    { uint32_t i = i_type(0x302, 0, 0, 0, OP_SYSTEM);
      Exp e = fields(i); e.is_mret=true;
      check(d, "MRET", i, e); }

    // ---- Illegal instructions ----
    // Unknown opcode: only illegal=1, all other signals 0
    { Exp e; e.illegal=true;
      check(d, "illegal opcode", 0x0000007F, e); }

    // Illegal funct7 in OP_REG: decoder still sets alu_op_valid/reg_write
    // (they're set in the OP_REG case before the funct7 check), plus illegal=1.
    // The pipeline's trap handling suppresses execution when illegal=1.
    { uint32_t i = r(0x10, 3, 2, 0, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.reg_write=true; e.illegal=true;
      check(d, "illegal ADD funct7", i, e); }

    { uint32_t i = r(0x20, 3, 2, 1, 1, OP_REG);
      Exp e = fields(i); e.alu_op_valid=true; e.reg_write=true; e.illegal=true;
      check(d, "illegal SLL funct7", i, e); }

    delete d;
    printf("\n=== tb_decoder: %d tests, %d failures ===\n", tests, failures);
    return failures ? 1 : 0;
}
