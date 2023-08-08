import numpy as np
from rvsim.Memory import Memory
from rvsim.Core import Core

def test_mem():
    mem = Memory()
    addr = np.uint32(1)
    d = mem.read(addr)
    assert d == 0
    mem.write(addr, np.uint32(0x12345678))
    d = mem.read(addr)
    assert d == 0x12345678


def test_imm():
    (imm_i, _, _, _, _) = Core.imm_decode(np.uint32(0xFFF00000))
    assert imm_i == -1

    (_, imm_s, imm_b, _, _) = Core.imm_decode(np.uint32(0xFE000F80))
    assert imm_s == -1
    assert imm_b == -2

    (_, _, _, imm_j, imm_u) = Core.imm_decode(np.uint32(0xFFFFF000))
    assert imm_j == -2
    assert imm_u == -4096


def test_core():
    core = Core()
    core.mem.write(0, np.uint32(0x00000013))
    core.run()
