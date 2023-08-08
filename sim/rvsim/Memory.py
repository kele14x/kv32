import numpy as np


class Memory:
    mem = {}

    def __init__(self):
        pass

    def clear(self):
        """Clear the memory content."""
        self.mem = {}

    def read_aligned(self, addr):
        """Aligned read data at specified address."""
        haddr = addr.astype("uint32") & np.uint32(0xFFFFF000)
        laddr = (addr.astype("uint32") & np.uint32(0x00000FFF)) >> 2
        if haddr in self.mem:
            return self.mem[haddr][laddr]
        else:
            return np.uint32(0)

    def write_aligned(self, addr, data, mask=np.uint32(0xFFFFFFFF)):
        """Aligned write data to specified address."""
        haddr = addr.astype("uint32") & np.uint32(0xFFFFF000)
        laddr = (addr.astype("uint32") & np.uint32(0x00000FFF)) >> 2
        if haddr in self.mem:
            t = self.mem[haddr][laddr] & ~mask
            t |= data & mask
            self.mem[haddr][laddr] = t
        else:
            self.mem[haddr] = np.zeros(1024, "uint32")
            self.mem[haddr][laddr] = data & mask

    def read(self, addr, nbyte=4):
        """Read data at specified address, support unaligned transfer."""
        offset = addr.astype("uint32") & np.uint32(0x00000003)
        if offset + nbyte <= 4:
            # The read operation spans one memory location
            data = self.read_aligned(addr) << (4 - offset - nbyte) * 8
        else:
            # The read operation spans two memory location
            data = self.read_aligned(addr) >> (offset + nbyte - 4) * 8
            data |= self.read_aligned(addr + 4) << (8 - offset - nbyte) * 8
        # Sign-extended
        data = data >> (4 - nbyte) * 8
        return data

    def write(self, addr, data, nbyte=4):
        """Write data to specified address, support unaligned transfer."""
        offset = addr.astype("uint32") & np.uint32(0x00000003)
        if nbyte == 1:
            mask = np.uint32(0x000000FF)
        elif nbyte == 2:
            mask = np.uint32(0x0000FFFF)
        elif nbyte == 4:
            mask = np.uint32(0xFFFFFFFF)
        else:
            raise ValueError

        self.write_aligned(addr, data << offset * 8, mask << offset * 8)
        if offset + nbyte > 4:
            # The write operation spans two memory location
            self.write_aligned(addr + 4, data >> (8 - offset - nbyte) * 8, mask >> (8 - offset - nbyte) * 8)
