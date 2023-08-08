import numpy as np

from rvsim.Memory import Memory
from rvsim.Regfile import Regfile


class Core:
    pc = np.uint32(0)
    regfile = Regfile()
    mem = Memory()

    def __init__(self):
        pass

    def rst(self):
        """Reset the core."""
        self.pc = np.uint32(0)
        self.regfile.rst()

    def load(self, fn):
        """Load data file into memory."""
        raise NotImplementedError

    def step(self):
        inst = self.fetch()
        print('[0x%08x]0x%08x: ' % (self.pc, inst), end='')

        (con, pc_next, asm) = self.exec(inst)
        print('%s' % asm)

        self.pc = pc_next
        return con

    def run(self):
        con = True
        while con:
            con = self.step()
        print('Core pause at 0x%08x' % self.pc)

    def fetch(self):
        """Instruction fetch."""
        inst = self.mem.read(self.pc)
        return inst

    def exec(self, inst):
        """Execute an instruction, program counter (PC) is returned."""

        # Instruction decode
        # ------------------

        [opcode, rd, rs1, rs2, funct3, funct7] = Core.op_decode(inst)

        # OPCODE map (11)
        # opcode[4:2] = 0b000
        is_load = (opcode == 0b0000011)
        is_store = (opcode == 0b0100011)
        is_branch = (opcode == 0b1100011)
        # opcode[4:2] = 0b001
        is_jalr = (opcode == 0b1100111)
        # opcode[4:2] = 0b011
        is_misc_mem = (opcode == 0b0001111)
        is_jal = (opcode == 0b1101111)
        # opcode[4:2] = 0b100
        is_op_imm = (opcode == 0b0010011)
        is_op = (opcode == 0b0110011)
        is_system = (opcode == 0b1110011)
        # opcode[4:2] = 0b101
        is_auipc = (opcode == 0b0010111)
        is_lui = (opcode == 0b0110111)

        # All we support opcode
        is_legal = (is_load | is_store | is_branch | is_jalr | is_misc_mem | is_jal
                    | is_op_imm | is_op | is_system | is_auipc | is_lui)

        con = is_legal
        pc_next = self.pc + 4
        asm = 'Illegal instruction'

        # Register lookup
        rs1d = self.regfile.get(rs1)
        rs2d = self.regfile.get(rs2)

        # Immediate unite
        [imm_i, imm_s, imm_b, imm_j, imm_u] = Core.imm_decode(inst)

        # Immediate type
        is_i_type = is_load | is_jalr | is_op_imm
        is_s_type = is_store
        is_b_type = is_branch
        is_j_type = is_jal
        is_r_type = is_op
        is_sys_type = is_system
        is_u_type = is_auipc | is_lui

        # Immediate select
        if is_i_type:
            imm = imm_i
        elif is_s_type:
            imm = imm_s
        elif is_b_type:
            imm = imm_b
        elif is_j_type:
            imm = imm_j
        elif is_u_type:
            imm = imm_u
        else:
            imm = 0

        # Instruction execution
        # ---------------------

        # LOAD
        if is_load:
            addr = rs1d + imm.astype('uint32')
            if funct3 == 0:  # LB
                asm = 'lb x%d, %d(x%d)' % (rd, imm, rs1)
                self.regfile.set(rd, self.mem.read(addr, 1))
            elif funct3 == 1:  # LH
                asm = 'lh x%d, %d(x%d)' % (rd, imm, rs1)
                self.regfile.set(rd, self.mem.read(addr, 2))
            elif funct3 == 2:  # LW
                asm = 'lw x%d, %d(x%d)' % (rd, imm, rs1)
                self.regfile.set(rd, self.mem.read(addr, 4))
            elif funct3 == 4:  # LBU
                asm = 'lbu x%d, %d(x%d)' % (rd, imm, rs1)
                self.regfile.set(rd, self.mem.read(addr, 1) & np.uint32(0x000000FF))
            elif funct3 == 5:  # LHU
                asm = 'lhu x%d, %d(x%d)' % (rd, imm, rs1)
                self.regfile.set(rd, self.mem.read(addr, 1) & np.uint32(0x0000FFFF))
            else:
                con = False

        # STORE
        elif is_store:
            addr = rs1d + imm.astype('uint32')
            if funct3 == 0:  # SB
                asm = 'sb x%d, %d(x%d)' % (rs2, imm, rs1)
                self.mem.write(addr, rs2d, 1)
            elif funct3 == 1:  # SH
                asm = 'sh x%d, %d(x%d)' % (rs2, imm, rs1)
                self.mem.write(addr, rs2d, 2)
            elif funct3 == 2:  # SW
                asm = 'sw x%d, %d(x%d)' % (rs2, imm, rs1)
                self.mem.write(addr, rs2d, 4)
            else:
                con = False

        # BRANCH
        elif is_branch:
            if funct3 == 0:
                asm = 'beq x%d, x%d, %d' % (rs1, rs2, imm)
            elif funct3 == 1:
                asm = 'bne x%d, x%d, %d' % (rs1, rs2, imm)
            elif funct3 == 4:
                asm = 'blt x%d, x%d, %d' % (rs1, rs2, imm)
            elif funct3 == 5:
                asm = 'bge x%d, x%d, %d' % (rs1, rs2, imm)
            elif funct3 == 6:
                asm = 'bltu x%d, x%d, %d' % (rs1, rs2, imm)
            elif funct3 == 7:
                asm = 'bgeu x%d, x%d, %d' % (rs1, rs2, imm)
            else:
                con = False
            b = Core.bru(funct3, rs1d, rs2d)
            if b:
                pc_next = Core.alu(0, 0, self.pc, imm)

        # JALR
        elif is_jalr:
            asm = 'jarl x%d, x%d, %d' % (rd, rs1, imm)
            self.regfile.set(rd, pc_next)
            pc_next = rs1d + imm.astype('uint32')

        # MISC-MEM
        elif is_misc_mem:
            asm = 'fetch'
            # TODO: check other fields

        # JAL
        elif is_jal:
            asm = 'jar x%d, %d' % (rd, imm)
            self.regfile.set(rd, pc_next)
            pc_next = self.pc + imm.astype('uint32')

        # OP-IMM
        elif is_op_imm:
            if funct7 == np.uint32(0):
                alt = False
            elif funct7 == np.uint32(0x20):
                alt = True
            else:
                alt = False
                con = False

            if funct3 == 0:
                asm = 'addi x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 1:
                asm = 'slli x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 2:
                asm = 'slti x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 3:
                asm = 'sltiu x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 4:
                asm = 'xori x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 5:
                if not alt:
                    asm = 'srli x%d, x%d, %d' % (rd, rs1, imm)
                else:
                    asm = 'srai x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 6:
                asm = 'ori x%d, x%d, %d' % (rd, rs1, imm)
            elif funct3 == 7:
                asm = 'andi x%d, x%d, %d' % (rd, rs1, imm)
            else:
                con = False
            self.regfile.set(rd, Core.alu(funct3, alt, rs1d, imm))

        # OP
        elif is_op:
            if funct7 == np.uint32(0):
                alt = False
            elif funct7 == np.uint32(0x20):
                alt = True
            else:
                alt = False
                con = False

            if funct3 == 0:
                if not alt:
                    asm = 'add x%d, x%d, x%d' % (rd, rs1, rs2)
                else:
                    asm = 'sub x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 1:
                asm = 'sll x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 2:
                asm = 'slt x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 3:
                asm = 'sltu x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 4:
                asm = 'xor x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 5:
                if not alt:
                    asm = 'srl x%d, x%d, x%d' % (rd, rs1, rs2)
                else:
                    asm = 'sra x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 6:
                asm = 'or x%d, x%d, x%d' % (rd, rs1, rs2)
            elif funct3 == 7:
                asm = 'and x%d, x%d, x%d' % (rd, rs1, rs2)
            else:
                con = False
            self.regfile.set(rd, Core.alu(funct3, alt, rs1d, rs2d))

        # SYSTEM
        elif is_system:
            con = False
            if funct3 == 0 and funct7 == 0:  # ECALL
                asm = f'ecall'
            elif funct3 == 0 and funct7 == 1:  # EBREAK
                asm = f'ebreak'

        # AUIPC
        elif is_auipc:
            asm = 'auipc x%d, %d' % (rd, imm)
            self.regfile.set(rd, self.pc + imm.astype('uint32'))

        # LUI
        elif is_lui:
            asm = 'lui x%d, %d' % (rd, imm)
            self.regfile.set(rd, imm)

        return con, pc_next, asm

    @staticmethod
    def op_decode(inst):
        """Operation decode. Note: based on the opcode, not all fields are valid."""
        opcode = inst.astype('uint32') & np.uint32(0x7F)
        rd = (inst.astype('uint32') >> 7) & np.uint32(0x1F)
        rs1 = (inst.astype('uint32') >> 15) & np.uint32(0x1F)
        rs2 = (inst.astype('uint32') >> 20) & np.uint32(0x1F)
        funct3 = (inst.astype('uint32') >> 12) & np.uint32(0x7)
        funct7 = (inst.astype('uint32') >> 25) & np.uint32(0x7F)

        return opcode, rd, rs1, rs2, funct3, funct7

    @staticmethod
    def imm_decode(inst):
        """Immediate decode. Note: based on the opcode, only one or none of them is valid."""
        # I-immediate
        # inst[31:20] -> imm[11:0]
        imm_i = inst & np.uint32(0xFFF00000)
        # Sign-extended imm[11]
        imm_i = imm_i.astype('int32') >> 20

        # S-immediate
        # inst[31:25] -> imm[11:5]
        imm_s = inst & np.uint32(0xFE000000)
        # inst[11:7] -> imm[4:0]
        imm_s |= (inst & np.uint32(0x00000F80)) << 13
        # Sign-extended imm[11]
        imm_s = imm_s.astype('int32') >> 20

        # B-immediate
        # inst[31] -> imm[12]
        imm_b = inst & np.uint32(0x80000000)
        # inst[30:25] -> imm[10:5]
        imm_b |= (inst & np.uint32(0x7E000000)) >> 1
        # inst[11:8] -> imm[4:1]
        imm_b |= (inst & np.uint32(0x00000F00)) << 12
        # inst[7] -> imm[11]
        imm_b |= (inst & np.uint32(0x00000080)) << 23
        # Sign-extended imm[12]
        imm_b = imm_b.astype('int32') >> 19

        # J - immediate
        # inst[31] -> imm[20]
        imm_j = inst & np.uint32(0x80000000)
        # inst[30:21] -> imm[10:1]
        imm_j |= (inst & np.uint32(0x7FE00000)) >> 9
        # inst[20] -> imm[11]
        imm_j |= (inst & np.uint32(0x00100000)) << 2
        # inst[19:12] -> imm[19:12]
        imm_j |= (inst & np.uint32(0x000FF000)) << 11
        # Sign-extended imm[20]
        imm_j = imm_j.astype('int32') >> 11

        # U-immediate
        # inst[31:12] -> imm[31:12]
        imm_u = inst & np.uint32(0xFFFFF000)
        imm_u = imm_u.astype('int32')

        return imm_i, imm_s, imm_b, imm_j, imm_u

    @staticmethod
    def alu(funct, alt, op1, op2):
        """ALU, funct select the ALU operation, alt select the alternative version of operation."""
        if funct == 0:
            if alt == 0:  # ADD/ADDI
                res = op1.astype('int32') + op2.astype('int32')
            else:  # SUB
                res = op1.astype('int32') - op2.astype('int32')
        elif funct == 1:  # SLL/SLLI
            res = op1.astype('int32') << (op2.astype('uint32') & np.uint32(0x3F))
        elif funct == 2:  # SLT/SLTI
            res = np.int32(op1.astype('int32') < op2.astype('int32'))
        elif funct == 3:  # SLTU/SLTIU
            res = np.int32(op1.astype('uint32') < op2.astype('uint32'))
        elif funct == 4:  # XOR/XORI
            res = op1.astype('int32') ^ op2.astype('int32')
        elif funct == 5:
            if alt == 0:  # SRL
                res = (op1.astype('uint32') >> (op2.astype('uint32') & np.uint32(0x3F))).astype('int32')
            else:  # SRA
                res = op1.astype('int32') >> (op2.astype('uint32') & np.uint32(0x3F))
        elif funct == 6:  # OR/ORI
            res = op1.astype('int32') | op2.astype('int32')
        elif funct == 7:  # AND/ANDI
            res = op1.astype('int32') & op2.astype('int32')
        else:
            res = np.int32(0)
        return res

    @staticmethod
    def bru(funct, op1, op2):
        # Branch or not
        if funct == 0:  # BEQ
            res = op1.astype('int32') == op2.astype('int32')
        elif funct == 1:  # BNE
            res = op1.astype('int32') != op2.astype('int32')
        elif funct == 4:  # BLT
            res = op1.astype('int32') < op2.astype('int32')
        elif funct == 5:  # BGE
            res = op1.astype('int32') >= op2.astype('int32')
        elif funct == 6:  # BLTU
            res = op1.astype('uint32') < op2.astype('uint32')
        elif funct == 7:  # BGEU
            res = op1.astype('uint32') >= op2.astype('uint32')
        else:
            res = False
        return res