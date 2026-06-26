// tb_decompressor.cpp — unit test for kv32_decompressor
// Verifies all RV32C instruction formats expand to correct 32-bit equivalents.
// Combinational DUT: set 16-bit instr, eval, check expanded + illegal.

#include "Vkv32_decompressor.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>

static int tests = 0, failures = 0;

static Vkv32_decompressor *dut;

static void check(const char *name, uint16_t instr, uint32_t exp_expanded, bool exp_illegal) {
    dut->instr = instr;
    dut->eval();

    bool pass = true;
    if (exp_illegal) {
        if (!dut->illegal) {
            printf("FAIL %s: instr=0x%04x expected illegal but got expanded=0x%08x\n",
                   name, instr, (uint32_t)dut->expanded);
            pass = false;
        }
    } else {
        if (dut->illegal) {
            printf("FAIL %s: instr=0x%04x unexpected illegal\n", name, instr);
            pass = false;
        } else if ((uint32_t)dut->expanded != exp_expanded) {
            printf("FAIL %s: instr=0x%04x expanded=0x%08x expected=0x%08x\n",
                   name, instr, (uint32_t)dut->expanded, exp_expanded);
            pass = false;
        }
    }

    tests++;
    if (!pass) failures++;
}

// ---- Instruction encoding helpers ----------------------------------------

// 32-bit I-type: imm[11:0] | rs1 | funct3 | rd | opcode
static uint32_t i_type(uint32_t imm12, uint8_t rs1, uint8_t f3, uint8_t rd, uint8_t op) {
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}

// 32-bit S-type: imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
static uint32_t s_type(uint32_t imm12, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t op) {
    uint32_t im = imm12 & 0xFFF;
    return ((im & 0xFE0) << 20) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
           ((im & 0x1F) << 7) | op;
}

// 32-bit B-type
static uint32_t b_type(uint32_t imm13, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t op) {
    uint32_t im = imm13 & 0x1FFE;
    return ((im & 0x1000) << 19) | ((im & 0x7E0) << 20) |
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
           ((im & 0x1E) << 7) | ((im & 0x800) >> 4) | op;
}

// 32-bit U-type: imm[31:12] | rd | opcode
static uint32_t u_type(uint32_t imm20, uint8_t rd, uint8_t op) {
    return (imm20 & 0xFFFFF000) | (rd << 7) | op;
}

// 32-bit J-type
static uint32_t j_type(uint32_t imm21, uint8_t rd, uint8_t op) {
    uint32_t im = imm21 & 0x1FFFFE;
    return ((im & 0x100000) << 11) | (im & 0xFF000) |
           ((im & 0x800) << 9) | ((im & 0x7FE) << 20) |
           (rd << 7) | op;
}

// 32-bit R-type: funct7 | rs2 | rs1 | funct3 | rd | opcode
static uint32_t r_type(uint8_t f7, uint8_t rs2, uint8_t rs1, uint8_t f3, uint8_t rd, uint8_t op) {
    return ((uint32_t)f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}

// Opcodes
enum { OP_LUI=0x37, OP_JAL=0x6F, OP_JALR=0x67, OP_BRANCH=0x63,
       OP_LOAD=0x03, OP_STORE=0x23, OP_IMM=0x13, OP_REG=0x33 };

// Compressed register fields: x8 + bits[4:2] or x8 + bits[9:7]
static uint8_t rp(uint8_t bits3) { return 8 + bits3; }  // 3-bit field -> register number

// ---- Compressed instruction encoders --------------------------------------

// C.ADDI4SPN: rd', nzuimm (nzuimm is multiple of 4, nonzero, 10-bit max)
// Encoding: [15:13]=000, [12:5]=nzuimm bits, [4:2]=rd', [1:0]=00
static uint16_t c_addi4spn(uint8_t rd3, uint32_t nzuimm) {
    // nzuimm[5:4|9:6|2|3] = bits[12:5]
    // bits[12:11] = nzuimm[5:4]
    // bits[10:7]  = nzuimm[9:6]
    // bit[6]      = nzuimm[2]
    // bit[5]      = nzuimm[3]
    uint16_t enc = 0;
    enc |= ((nzuimm >> 4) & 3) << 11;   // nzuimm[5:4] -> bits[12:11]
    enc |= ((nzuimm >> 6) & 0xF) << 7;  // nzuimm[9:6] -> bits[10:7]
    enc |= ((nzuimm >> 2) & 1) << 6;    // nzuimm[2]   -> bit[6]
    enc |= ((nzuimm >> 3) & 1) << 5;    // nzuimm[3]   -> bit[5]
    enc |= (rd3 & 7) << 2;              // rd'         -> bits[4:2]
    enc |= 0x00;                        // quadrant 0
    return enc;
}

// C.LW: rd', offset(rs1')
// Encoding: [15:13]=010, [12:10]=offset[5:3], [9:7]=rs1', [6]=offset[2], [5]=offset[6], [4:2]=rd', [1:0]=00
static uint16_t c_lw(uint8_t rd3, uint8_t rs1_3, uint32_t offset) {
    uint16_t enc = 0;
    enc |= (0b010) << 13;              // funct3
    enc |= ((offset >> 3) & 7) << 10;  // offset[5:3] -> bits[12:10]
    enc |= (rs1_3 & 7) << 7;           // rs1'        -> bits[9:7]
    enc |= ((offset >> 2) & 1) << 6;   // offset[2]   -> bit[6]
    enc |= ((offset >> 6) & 1) << 5;   // offset[6]   -> bit[5]
    enc |= (rd3 & 7) << 2;             // rd'         -> bits[4:2]
    enc |= 0x00;                       // quadrant 0
    return enc;
}

// C.SW: rs2', offset(rs1')
// Encoding: [15:13]=110, [12:10]=offset[5:3], [9:7]=rs1', [6]=offset[2], [5]=offset[6], [4:2]=rs2', [1:0]=00
static uint16_t c_sw(uint8_t rs2_3, uint8_t rs1_3, uint32_t offset) {
    uint16_t enc = 0;
    enc |= (0b110) << 13;
    enc |= ((offset >> 3) & 7) << 10;
    enc |= (rs1_3 & 7) << 7;
    enc |= ((offset >> 2) & 1) << 6;
    enc |= ((offset >> 6) & 1) << 5;
    enc |= (rs2_3 & 7) << 2;
    enc |= 0x00;
    return enc;
}

// C.ADDI / C.NOP: rd, nzimm
// Encoding: [15:13]=000, [12]=imm[5], [11:7]=rd, [6:2]=imm[4:0], [1:0]=01
static uint16_t c_addi(uint8_t rd, int32_t imm) {
    uint16_t enc = 0;
    enc |= (0b000) << 13;
    enc |= ((imm >> 5) & 1) << 12;     // imm[5] -> bit[12]
    enc |= (rd & 0x1F) << 7;           // rd     -> bits[11:7]
    enc |= (imm & 0x1F) << 2;          // imm[4:0] -> bits[6:2]
    enc |= 0x01;                       // quadrant 1
    return enc;
}

// C.JAL (RV32): offset
// Encoding: [15:13]=001, [12:2]=offset bits, [1:0]=01
static uint16_t c_jal(int32_t offset) {
    // offset[11|4|9:8|10|6|7|3:1|5] = bits[12:2]
    // bits[12]   = offset[11]
    // bits[11]   = offset[4]
    // bits[10:9] = offset[9:8]
    // bits[8]    = offset[10]
    // bits[7]    = offset[6]
    // bits[6]    = offset[7]
    // bits[5:3]  = offset[3:1]
    // bits[2]    = offset[5]
    uint16_t enc = 0;
    enc |= (0b001) << 13;
    enc |= ((offset >> 11) & 1) << 12;
    enc |= ((offset >> 4) & 1) << 11;
    enc |= ((offset >> 8) & 3) << 9;
    enc |= ((offset >> 10) & 1) << 8;
    enc |= ((offset >> 6) & 1) << 7;
    enc |= ((offset >> 7) & 1) << 6;
    enc |= ((offset >> 1) & 7) << 3;
    enc |= ((offset >> 5) & 1) << 2;
    enc |= 0x01;
    return enc;
}

// C.LI: rd, imm
// Encoding: [15:13]=010, [12]=imm[5], [11:7]=rd, [6:2]=imm[4:0], [1:0]=01
static uint16_t c_li(uint8_t rd, int32_t imm) {
    uint16_t enc = 0;
    enc |= (0b010) << 13;
    enc |= ((imm >> 5) & 1) << 12;
    enc |= (rd & 0x1F) << 7;
    enc |= (imm & 0x1F) << 2;
    enc |= 0x01;
    return enc;
}

// C.ADDI16SP: nzimm (multiple of 16, nonzero)
// Encoding: [15:13]=011, [12]=nzimm[9], [11:7]=2(x2), [6:2]=nzimm bits, [1:0]=01
static uint16_t c_addi16sp(int32_t nzimm) {
    // bits[12]   = nzimm[9]
    // bits[6]    = nzimm[4]
    // bits[5]    = nzimm[6]
    // bits[4:3]  = nzimm[8:7]
    // bits[2]    = nzimm[5]
    uint16_t enc = 0;
    enc |= (0b011) << 13;
    enc |= ((nzimm >> 9) & 1) << 12;
    enc |= 2 << 7;                     // rd = x2
    enc |= ((nzimm >> 4) & 1) << 6;    // nzimm[4]
    enc |= ((nzimm >> 6) & 1) << 5;    // nzimm[6]
    enc |= ((nzimm >> 7) & 3) << 3;    // nzimm[8:7]
    enc |= ((nzimm >> 5) & 1) << 2;    // nzimm[5]
    enc |= 0x01;
    return enc;
}

// C.LUI: rd, nzimm
// Encoding: [15:13]=011, [12]=nzimm[17], [11:7]=rd, [6:2]=nzimm[16:12], [1:0]=01
static uint16_t c_lui(uint8_t rd, int32_t nzimm) {
    uint16_t enc = 0;
    enc |= (0b011) << 13;
    enc |= ((nzimm >> 17) & 1) << 12;
    enc |= (rd & 0x1F) << 7;
    enc |= ((nzimm >> 12) & 0x1F) << 2;
    enc |= 0x01;
    return enc;
}

// C.SRLI: rd', shamt
// Encoding: [15:13]=100, [12]=0(shamt[5]), [11:10]=00, [9:7]=rd', [6:2]=shamt[4:0], [1:0]=01
static uint16_t c_srli(uint8_t rd3, uint8_t shamt) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= 0b00 << 10;                // bits[11:10] = 00
    enc |= (rd3 & 7) << 7;
    enc |= (shamt & 0x1F) << 2;
    enc |= 0x01;
    return enc;
}

// C.SRAI: rd', shamt
// Encoding: [15:13]=100, [12]=0, [11:10]=01, [9:7]=rd', [6:2]=shamt[4:0], [1:0]=01
static uint16_t c_srai(uint8_t rd3, uint8_t shamt) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= 0b01 << 10;
    enc |= (rd3 & 7) << 7;
    enc |= (shamt & 0x1F) << 2;
    enc |= 0x01;
    return enc;
}

// C.ANDI: rd', imm
// Encoding: [15:13]=100, [12]=imm[5], [11:10]=10, [9:7]=rd', [6:2]=imm[4:0], [1:0]=01
static uint16_t c_andi(uint8_t rd3, int32_t imm) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= ((imm >> 5) & 1) << 12;
    enc |= 0b10 << 10;
    enc |= (rd3 & 7) << 7;
    enc |= (imm & 0x1F) << 2;
    enc |= 0x01;
    return enc;
}

// C.SUB/C.XOR/C.OR/C.AND: rd', rs2'
// Encoding: [15:13]=100, [12]=0, [11:10]=11, [6:5]=funct, [9:7]=rd', [4:2]=rs2', [1:0]=01
static uint16_t c_alu(uint8_t funct2, uint8_t rd3, uint8_t rs2_3) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= 0b11 << 10;
    enc |= (0b0) << 12;               // bit[12] = 0 for RV32
    enc |= (funct2 & 3) << 5;
    enc |= (rd3 & 7) << 7;
    enc |= (rs2_3 & 7) << 2;
    enc |= 0x01;
    return enc;
}

// C.J: offset
// Same encoding as C.JAL but funct3=101
static uint16_t c_j(int32_t offset) {
    uint16_t enc = 0;
    enc |= (0b101) << 13;
    enc |= ((offset >> 11) & 1) << 12;
    enc |= ((offset >> 4) & 1) << 11;
    enc |= ((offset >> 8) & 3) << 9;
    enc |= ((offset >> 10) & 1) << 8;
    enc |= ((offset >> 6) & 1) << 7;
    enc |= ((offset >> 7) & 1) << 6;
    enc |= ((offset >> 1) & 7) << 3;
    enc |= ((offset >> 5) & 1) << 2;
    enc |= 0x01;
    return enc;
}

// C.BEQZ: rs1', offset
// Encoding: [15:13]=110, [12:10]=offset bits, [9:7]=rs1', [6:2]=offset bits, [1:0]=01
static uint16_t c_beqz(uint8_t rs1_3, int32_t offset) {
    // bits[12]   = offset[8]
    // bits[11:10] = offset[4:3]
    // bits[6:5]  = offset[7:6]
    // bits[4:3]  = offset[2:1]
    // bits[2]    = offset[5]
    uint16_t enc = 0;
    enc |= (0b110) << 13;
    enc |= ((offset >> 8) & 1) << 12;
    enc |= ((offset >> 3) & 3) << 10;
    enc |= (rs1_3 & 7) << 7;
    enc |= ((offset >> 6) & 3) << 5;
    enc |= ((offset >> 1) & 3) << 3;
    enc |= ((offset >> 5) & 1) << 2;
    enc |= 0x01;
    return enc;
}

// C.BNEZ: rs1', offset
// Same as C.BEQZ but funct3=111
static uint16_t c_bnez(uint8_t rs1_3, int32_t offset) {
    uint16_t enc = c_beqz(rs1_3, offset);
    enc = (enc & ~(0b111 << 13)) | (0b111 << 13);
    return enc;
}

// C.SLLI: rd, shamt
// Encoding: [15:13]=000, [12]=0, [11:7]=rd, [6:2]=shamt[4:0], [1:0]=10
static uint16_t c_slli(uint8_t rd, uint8_t shamt) {
    uint16_t enc = 0;
    enc |= (0b000) << 13;
    enc |= (rd & 0x1F) << 7;
    enc |= (shamt & 0x1F) << 2;
    enc |= 0x02;
    return enc;
}

// C.LWSP: rd, offset
// Encoding: [15:13]=010, [12]=offset[5], [11:7]=rd, [6:2]=offset bits, [1:0]=10
static uint16_t c_lwsp(uint8_t rd, uint32_t offset) {
    // bits[12]   = offset[5]
    // bits[6:4]  = offset[4:2]
    // bits[3:2]  = offset[7:6]
    uint16_t enc = 0;
    enc |= (0b010) << 13;
    enc |= ((offset >> 5) & 1) << 12;
    enc |= (rd & 0x1F) << 7;
    enc |= ((offset >> 2) & 7) << 4;
    enc |= ((offset >> 6) & 3) << 2;
    enc |= 0x02;
    return enc;
}

// C.JR: rs1
// Encoding: [15:13]=100, [12]=0, [11:7]=rs1, [6:2]=0, [1:0]=10
static uint16_t c_jr(uint8_t rs1) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= (rs1 & 0x1F) << 7;
    enc |= 0x02;
    return enc;
}

// C.MV: rd, rs2
// Encoding: [15:13]=100, [12]=0, [11:7]=rd, [6:2]=rs2, [1:0]=10
static uint16_t c_mv(uint8_t rd, uint8_t rs2) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= (rd & 0x1F) << 7;
    enc |= (rs2 & 0x1F) << 2;
    enc |= 0x02;
    return enc;
}

// C.JALR: rs1
// Encoding: [15:13]=100, [12]=1, [11:7]=rs1, [6:2]=0, [1:0]=10
static uint16_t c_jalr(uint8_t rs1) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= 1 << 12;
    enc |= (rs1 & 0x1F) << 7;
    enc |= 0x02;
    return enc;
}

// C.ADD: rd, rs2
// Encoding: [15:13]=100, [12]=1, [11:7]=rd, [6:2]=rs2, [1:0]=10
static uint16_t c_add(uint8_t rd, uint8_t rs2) {
    uint16_t enc = 0;
    enc |= (0b100) << 13;
    enc |= 1 << 12;
    enc |= (rd & 0x1F) << 7;
    enc |= (rs2 & 0x1F) << 2;
    enc |= 0x02;
    return enc;
}

// C.SWSP: rs2, offset
// Encoding: [15:13]=110, [12:7]=offset bits, [6:2]=rs2, [1:0]=10
static uint16_t c_swsp(uint8_t rs2, uint32_t offset) {
    // bits[12:9] = offset[5:2]
    // bits[8:7]  = offset[7:6]
    uint16_t enc = 0;
    enc |= (0b110) << 13;
    enc |= ((offset >> 2) & 0xF) << 9;
    enc |= ((offset >> 6) & 3) << 7;
    enc |= (rs2 & 0x1F) << 2;
    enc |= 0x02;
    return enc;
}

int main(int argc, char **argv) {
    dut = new Vkv32_decompressor;

    // =====================================================================
    // Quadrant 0 tests
    // =====================================================================

    // C.ADDI4SPN: addi x10, x2, 24
    // nzuimm=24: bits[5:4]=00, bits[9:6]=0000, bits[2]=0, bits[3]=1 -> 00_0000_0_1
    // 24 = 11000 binary: bits[5:4]=01, bits[9:6]=0000, bits[3]=0, bits[2]=0
    // Actually 24 = 0b11000: bit[4]=1, bit[3]=1 -> nzuimm[5:4]=01, nzuimm[9:6]=0000, nzuimm[3]=1, nzuimm[2]=0
    // Hmm, let me just compute: 24 in binary is 11000
    // nzuimm[9:6] = 0000 (bits 9-6 of 24)
    // nzuimm[5:4] = 01 (bit 5=0, bit 4=1 of 24)
    // nzuimm[3] = 1 (bit 3 of 24)
    // nzuimm[2] = 0 (bit 2 of 24)
    // Expected expanded: addi x10, x2, 24 = i_type(24, 2, 0, 10, OP_IMM)
    check("C.ADDI4SPN x10,x2,24",
          c_addi4spn(2, 24),   // rd'=x10 (2), nzuimm=24
          i_type(24, 2, 0, rp(2), OP_IMM),
          false);

    // C.ADDI4SPN with nzuimm=0 should be illegal
    check("C.ADDI4SPN nzuimm=0 (illegal)",
          c_addi4spn(0, 0),
          0, true);

    // C.LW: lw x10, 4(x12)
    // offset=4: offset[5:3]=000, offset[2]=1, offset[6]=0
    // Expected: lw x10, 4(x12) = i_type(4, 12, 2, 10, OP_LOAD)
    check("C.LW x10,4(x12)",
          c_lw(2, 4, 4),  // rd'=x10(2), rs1'=x12(4), offset=4
          i_type(4, rp(4), 2, rp(2), OP_LOAD),
          false);

    // C.LW: lw x8, 20(x15)
    // offset=20=10100: offset[6]=0, offset[5]=1, offset[4]=0, offset[3]=1, offset[2]=0
    check("C.LW x8,20(x15)",
          c_lw(0, 7, 20),
          i_type(20, rp(7), 2, rp(0), OP_LOAD),
          false);

    // C.SW: sw x10, 8(x12)
    // Expected: sw x10, 8(x12) = s_type(8, 10, 12, 2, OP_STORE)
    check("C.SW x10,8(x12)",
          c_sw(2, 4, 8),  // rs2'=x10(2), rs1'=x12(4), offset=8
          s_type(8, rp(2), rp(4), 2, OP_STORE),
          false);

    // C.FLD (RV64 only) — should be illegal in RV32
    // Encoding: [15:13]=001, quadrant=00
    check("C.FLD (illegal in RV32)",
          (uint16_t)((0b001 << 13) | 0x00),
          0, true);

    // C.FLW (RV32, but F ext not implemented) — should be illegal
    // Encoding: [15:13]=011, quadrant=00
    check("C.FLW (illegal, no F ext)",
          (uint16_t)((0b011 << 13) | 0x00),
          0, true);

    // Reserved Q0 funct3=100
    check("Q0 reserved funct3=100",
          (uint16_t)((0b100 << 13) | 0x00),
          0, true);

    // =====================================================================
    // Quadrant 1 tests
    // =====================================================================

    // C.NOP: addi x0, x0, 0
    check("C.NOP",
          c_addi(0, 0),
          i_type(0, 0, 0, 0, OP_IMM),
          false);

    // C.ADDI: addi x15, x15, -3
    check("C.ADDI x15,-3",
          c_addi(15, -3),
          i_type((uint32_t)(-3) & 0xFFF, 15, 0, 15, OP_IMM),
          false);

    // C.JAL (RV32): jal x1, offset
    // Test with offset = 10 (0xA)
    check("C.JAL offset=10",
          c_jal(10),
          j_type(10, 1, OP_JAL),
          false);

    // C.JAL with negative offset
    check("C.JAL offset=-16",
          c_jal(-16),
          j_type((uint32_t)(-16) & 0x1FFFFE, 1, OP_JAL),
          false);

    // C.LI: addi x5, x0, 7
    check("C.LI x5,7",
          c_li(5, 7),
          i_type(7, 0, 0, 5, OP_IMM),
          false);

    // C.LI with negative immediate
    check("C.LI x5,-1",
          c_li(5, -1),
          i_type((uint32_t)(-1) & 0xFFF, 0, 0, 5, OP_IMM),
          false);

    // C.ADDI16SP: addi x2, x2, 16
    check("C.ADDI16SP 16",
          c_addi16sp(16),
          i_type(16, 2, 0, 2, OP_IMM),
          false);

    // C.ADDI16SP with nzimm=0 should be illegal
    check("C.ADDI16SP nzimm=0 (illegal)",
          (uint16_t)((0b011 << 13) | (2 << 7) | 0x01),  // rd=x2, imm=0
          0, true);

    // C.LUI: lui x5, 0x1000
    // nzimm = 0x1000 (bit 12 set)
    check("C.LUI x5,0x1000",
          c_lui(5, 0x1000),
          u_type(0x1000, 5, OP_LUI),
          false);

    // C.LUI with rd=0 should be illegal
    check("C.LUI rd=0 (illegal)",
          c_lui(0, 0x1000),
          0, true);

    // C.LUI with nzimm=0 should be illegal
    check("C.LUI nzimm=0 (illegal)",
          c_lui(5, 0),
          0, true);

    // C.SRLI: srli x8, x8, 3
    check("C.SRLI x8,3",
          c_srli(0, 3),  // rd'=x8(0)
          i_type(3, rp(0), 5, rp(0), OP_IMM),  // funct3=101, funct7=0000000
          false);

    // C.SRAI: srai x9, x9, 5
    check("C.SRAI x9,5",
          c_srai(1, 5),  // rd'=x9(1)
          r_type(0b0100000, 5, rp(1), 5, rp(1), OP_IMM),
          false);

    // C.SRLI with shamt[5]=1 should be illegal in RV32
    check("C.SRLI shamt[5]=1 (illegal)",
          (uint16_t)((0b100 << 13) | (0b00 << 10) | (0 << 7) | (1 << 12) | 0x01),
          0, true);

    // C.ANDI: andi x10, x10, -5
    check("C.ANDI x10,-5",
          c_andi(2, -5),
          i_type((uint32_t)(-5) & 0xFFF, rp(2), 7, rp(2), OP_IMM),
          false);

    // C.SUB: sub x8, x8, x9
    check("C.SUB x8,x9",
          c_alu(0b00, 0, 1),  // funct2=00 (SUB), rd'=x8(0), rs2'=x9(1)
          r_type(0b0100000, rp(1), rp(0), 0, rp(0), OP_REG),
          false);

    // C.XOR: xor x8, x8, x9
    check("C.XOR x8,x9",
          c_alu(0b01, 0, 1),
          r_type(0b0000000, rp(1), rp(0), 4, rp(0), OP_REG),
          false);

    // C.OR: or x8, x8, x9
    check("C.OR x8,x9",
          c_alu(0b10, 0, 1),
          r_type(0b0000000, rp(1), rp(0), 6, rp(0), OP_REG),
          false);

    // C.AND: and x8, x8, x9
    check("C.AND x8,x9",
          c_alu(0b11, 0, 1),
          r_type(0b0000000, rp(1), rp(0), 7, rp(0), OP_REG),
          false);

    // C.SUBW (RV64 only) — should be illegal
    // Encoding: [15:13]=100, [12]=1, [11:10]=11, [6:5]=00
    check("C.SUBW (illegal in RV32)",
          (uint16_t)((0b100 << 13) | (1 << 12) | (0b11 << 10) | (0b00 << 5) | (0 << 7) | (0 << 2) | 0x01),
          0, true);

    // C.J: jal x0, offset
    check("C.J offset=8",
          c_j(8),
          j_type(8, 0, OP_JAL),
          false);

    // C.BEQZ: beq x8, x0, offset
    check("C.BEQZ x8,offset=6",
          c_beqz(0, 6),  // rs1'=x8(0), offset=6
          b_type(6, 0, rp(0), 0, OP_BRANCH),
          false);

    // C.BNEZ: bne x8, x0, offset
    check("C.BNEZ x8,offset=10",
          c_bnez(0, 10),
          b_type(10, 0, rp(0), 1, OP_BRANCH),
          false);

    // C.BEQZ with negative offset
    check("C.BEQZ x8,offset=-8",
          c_beqz(0, -8),
          b_type((uint32_t)(-8) & 0x1FFE, 0, rp(0), 0, OP_BRANCH),
          false);

    // =====================================================================
    // Quadrant 2 tests
    // =====================================================================

    // C.SLLI: slli x5, x5, 3
    check("C.SLLI x5,3",
          c_slli(5, 3),
          i_type(3, 5, 1, 5, OP_IMM),  // funct3=001, funct7=0000000
          false);

    // C.SLLI with shamt[5]=1 should be illegal in RV32
    check("C.SLLI shamt[5]=1 (illegal)",
          (uint16_t)((0b000 << 13) | (1 << 12) | (5 << 7) | 0x02),
          0, true);

    // C.SLLI with rd=0 should be illegal
    check("C.SLLI rd=0 (illegal)",
          c_slli(0, 3),
          0, true);

    // C.LWSP: lw x5, 12(x2)
    // offset=12: offset[5]=0, offset[4:2]=011, offset[7:6]=00
    check("C.LWSP x5,12(x2)",
          c_lwsp(5, 12),
          i_type(12, 2, 2, 5, OP_LOAD),
          false);

    // C.LWSP with rd=0 should be illegal
    check("C.LWSP rd=0 (illegal)",
          c_lwsp(0, 12),
          0, true);

    // C.FLDSP (RV64 only) — should be illegal
    check("C.FLDSP (illegal in RV32)",
          (uint16_t)((0b001 << 13) | 0x02),
          0, true);

    // C.JR: jalr x0, x5, 0
    check("C.JR x5",
          c_jr(5),
          i_type(0, 5, 0, 0, OP_JALR),
          false);

    // C.JR with rs1=0 should be illegal
    check("C.JR rs1=0 (illegal)",
          c_jr(0),
          0, true);

    // C.MV: add x5, x0, x10
    check("C.MV x5,x10",
          c_mv(5, 10),
          r_type(0, 10, 0, 0, 5, OP_REG),
          false);

    // C.EBREAK: ebreak
    check("C.EBREAK",
          (uint16_t)((0b100 << 13) | (1 << 12) | 0x02),  // bit[12]=1, rs2=0, rd=0
          0x00100073,
          false);

    // C.JALR: jalr x1, x5, 0
    check("C.JALR x5",
          c_jalr(5),
          i_type(0, 5, 0, 1, OP_JALR),
          false);

    // C.ADD: add x5, x5, x10
    check("C.ADD x5,x10",
          c_add(5, 10),
          r_type(0, 10, 5, 0, 5, OP_REG),
          false);

    // C.SWSP: sw x10, 16(x2)
    // offset=16: offset[5:2]=0100, offset[7:6]=00
    check("C.SWSP x10,16(x2)",
          c_swsp(10, 16),
          s_type(16, 10, 2, 2, OP_STORE),
          false);

    // C.FSDSP (RV64 only) — should be illegal
    check("C.FSDSP (illegal in RV32)",
          (uint16_t)((0b101 << 13) | 0x02),
          0, true);

    // C.FSWSP (RV32, but F ext not implemented) — should be illegal
    check("C.FSWSP (illegal, no F ext)",
          (uint16_t)((0b111 << 13) | 0x02),
          0, true);

    // =====================================================================
    // Quadrant 3 (bits[1:0] = 11) — not compressed, should signal illegal
    // =====================================================================
    check("Q3 (not compressed)",
          (uint16_t)0x0003,
          0, true);

    // =====================================================================
    // Edge cases
    // =====================================================================

    // C.ADDI with maximum positive immediate (31)
    check("C.ADDI x1,31",
          c_addi(1, 31),
          i_type(31, 1, 0, 1, OP_IMM),
          false);

    // C.ADDI with maximum negative immediate (-32)
    check("C.ADDI x1,-32",
          c_addi(1, -32),
          i_type((uint32_t)(-32) & 0xFFF, 1, 0, 1, OP_IMM),
          false);

    // C.LUI with negative nzimm (bit 17 set)
    // nzimm = -4096 (0xFFFFF000 in 32-bit)
    // In compressed: bit[12]=1 (sign), bits[6:2]=11111 (bits 16:12 = 0x1F)
    check("C.LUI x5,-4096",
          c_lui(5, (int32_t)0xFFFFF000),
          u_type(0xFFFFF000, 5, OP_LUI),
          false);

    // =====================================================================
    // Results
    // =====================================================================

    printf("\n=== Decompressor Unit Test Results ===\n");
    printf("  %d tests, %d passed, %d failed\n", tests, tests - failures, failures);
    printf("======================================\n");

    delete dut;
    return failures ? 1 : 0;
}
