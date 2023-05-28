src_dir := .

RISCV_PREFIX ?= riscv64-unknown-elf-
RISCV_GCC ?= $(RISCV_PREFIX)gcc
RISCV_GCC_OPTS ?= -static -nostdlib -nostartfiles -march=rv32i -mabi=ilp32
RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump --disassemble-all --disassemble-zeroes --section=.text --section=.text.startup --section=.text.init --section=.data
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy -O verilog

.PHONY: all clean

all: boot boot.dump boot.hex

boot: boot.S
	$(RISCV_GCC) $(RISCV_GCC_OPTS) -I$(src_dir) -T$(src_dir)/link.ld $< -o $@

boot.dump: boot
	$(RISCV_OBJDUMP) $< > $@

boot.hex: boot
	$(RISCV_OBJCOPY) $< $@

clean:
	-rm boot boot.dump boot.hex
