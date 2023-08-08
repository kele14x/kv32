"""RV32I register file."""

import numpy as np


class Regfile:
    _reg = np.zeros(32, "uint32")

    def __init__(self):
        pass

    def rst(self):
        self._reg = np.zeros(32, "uint32")

    def get(self, a):
        return self._reg[a]

    def set(self, a, d):
        if not a == 0:
            self._reg[a] = d.astype("uint32")
