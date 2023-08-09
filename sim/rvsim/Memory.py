import numpy as np
from numpy import uint32


class Memory:
    mem = {}

    def __init__(self):
        pass

    def clear(self):
        """Clear the memory content."""
        self.mem = {}

    def read_aligned(self, addr: uint32):
        """Aligned read data at specified address."""
        assert isinstance(addr, uint32)
        haddr = (addr & uint32(0xFFFFF000)) >> uint32(12)
        laddr = (addr & uint32(0x00000FFF)) >> uint32(2)
        if haddr in self.mem:
            return self.mem[haddr][laddr]
        else:
            return uint32(0)

    def write_aligned(self, addr: uint32, data: uint32, mask=uint32(0xFFFFFFFF)):
        """Aligned write data to specified address."""
        assert isinstance(addr, uint32)
        assert isinstance(data, uint32)
        assert isinstance(mask, uint32)
        haddr = (addr & uint32(0xFFFFF000)) >> uint32(12)
        laddr = (addr & uint32(0x00000FFF)) >> uint32(2)
        if haddr in self.mem:
            # To support the "maks write" feature, we do a read, modify, write operation
            t = self.mem[haddr][laddr] & ~mask
            t |= data & mask
            self.mem[haddr][laddr] = t
        else:
            self.mem[haddr] = np.zeros(1024, uint32)
            self.mem[haddr][laddr] = data & mask

    def read(self, addr: uint32, nbytes=4):
        """Read data at specified address, support unaligned transfer."""
        assert isinstance(addr, uint32)
        assert nbytes == 1 or nbytes == 2 or nbytes == 4
        offset = addr & uint32(0x00000003)
        if offset + nbytes <= 4:
            # The read operation spans one memory location
            data = self.read_aligned(addr) << uint32((4 - offset - nbytes) * 8)
        else:
            # The read operation spans two memory location
            data = self.read_aligned(addr) >> uint32((offset + nbytes - 4) * 8)
            data |= self.read_aligned(addr + uint32(4)) << uint32((8 - offset - nbytes) * 8)
        # Sign-extended
        data = (data.astype('int32') >> uint32((4 - nbytes) * 8)).astype('uint32')
        return data

    def write(self, addr: uint32, data: uint32, nbytes=4):
        """Write data to specified address, support unaligned transfer."""
        assert isinstance(addr, uint32)
        assert isinstance(data, uint32)
        offset = addr & uint32(0x00000003)
        if nbytes == 1:
            mask = uint32(0x000000FF)
        elif nbytes == 2:
            mask = uint32(0x0000FFFF)
        elif nbytes == 4:
            mask = uint32(0xFFFFFFFF)
        else:
            raise ValueError

        self.write_aligned(addr, data << uint32(offset * 8), mask << uint32(offset * 8))
        if offset + nbytes > 4:
            # The write operation spans two memory location
            self.write_aligned(addr + uint32(4), data >> uint32((8 - offset - nbytes) * 8),
                               mask >> uint32((8 - offset - nbytes) * 8))
