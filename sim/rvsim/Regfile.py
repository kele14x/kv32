"""RV32I register file."""
import numpy as np
from numpy import uint32


class Regfile:
    _reg = np.zeros(32, "uint32")

    def __init__(self):
        pass

    def rst(self):
        """Reset all registers."""
        self._reg = np.zeros(32, "uint32")

    def read(self, addr: uint32):
        """Read a register."""
        assert isinstance(addr, uint32)
        return self._reg[addr]

    def write(self, addr: uint32, data: uint32):
        """Write a register."""
        assert isinstance(addr, uint32)
        assert isinstance(data, uint32)
        if addr:
            # x0 is always 0
            self._reg[addr] = data
