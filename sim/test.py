from numpy import uint32, int32

from rvsim.Core import Core
from rvsim.Memory import Memory
from rvsim.Regfile import Regfile


def test_mem_aligned():
    mem = Memory()

    addr = uint32(1)
    d = mem.read_aligned(addr)
    assert isinstance(d, uint32)
    assert d == 0

    mem.write_aligned(addr, uint32(0x12345678))
    d = mem.read_aligned(addr)
    assert isinstance(d, uint32)
    assert d == 0x12345678

    mem.write_aligned(addr, uint32(0x5A5A5678), mask=uint32(0xFFFF0000))
    d = mem.read_aligned(addr)
    assert d == 0x5A5A5678


def test_mem():
    mem = Memory()

    addr = uint32(1)
    d = mem.read(addr)
    assert d == 0
    assert isinstance(d, uint32)

    mem.write(addr, uint32(0x12345678))
    d = mem.read(addr)
    assert d == 0x12345678
    assert isinstance(d, uint32)

    addr = uint32(2)
    mem.write(addr, uint32(0x5A5A), 2)
    d = mem.read(addr, 2)
    assert d == 0x5A5A


def test_regfile():
    regfile = Regfile()

    regfile.write(uint32(0), uint32(0x5A5A5A5A))
    data = regfile.read(uint32(0))
    assert isinstance(data, uint32)
    assert data == 0

    regfile.write(uint32(1), uint32(0x12345678))
    regfile.write(uint32(31), uint32(0x87654321))
    data = regfile.read(uint32(1))
    assert isinstance(data, uint32)
    assert data == 0x12345678

    data = regfile.read(uint32(31))
    assert data == 0x87654321


def test_alu():
    assert Core.alu(uint32(0), False, int32(1), int32(1)) == 2
    assert Core.alu(uint32(0), True, int32(0), int32(1)) == -1
    assert Core.alu(uint32(1), False, int32(1), int32(31)) == -2 ** 31
    assert Core.alu(uint32(2), False, int32(-1), int32(1)) == 1
    assert Core.alu(uint32(3), False, int32(-1), int32(1)) == 0
    assert Core.alu(uint32(4), False, int32(-1), int32(1)) == -2
    assert Core.alu(uint32(5), False, int32(-1), int32(1)) == 2 ** 31 - 1
    assert Core.alu(uint32(5), True, int32(-1), int32(1)) == -1
    assert Core.alu(uint32(6), False, int32(-1), int32(1)) == -1
    assert Core.alu(uint32(7), False, int32(-1), int32(1)) == 1


def test_imm():
    (imm_i, _, _, _, _) = Core.imm_decode(uint32(0xFFF00000))
    assert isinstance(imm_i, int32)
    assert imm_i == -1

    (_, imm_s, imm_b, _, _) = Core.imm_decode(uint32(0xFE000F80))
    assert isinstance(imm_s, int32)
    assert isinstance(imm_b, int32)
    assert imm_s == -1
    assert imm_b == -2

    (_, _, _, imm_j, imm_u) = Core.imm_decode(uint32(0xFFFFF000))
    assert isinstance(imm_j, int32)
    assert isinstance(imm_u, int32)
    assert imm_j == -2
    assert imm_u == -4096


def test_core():
    core = Core()
    core.mem.write(0, uint32(0x00000013))
    core.run()


def test_op_decode():
    (opcode, rd, rs1, rs2, funct3, funct7) = Core.op_decode(uint32(0xcbc18193))
    assert opcode == 0b0010011
    assert isinstance(opcode, uint32)


def test_load():
    core = Core()
    core.load('test.hex')
    core.rst(0x100DC)
    core.run(1000)
