# kv32 Makefile

RTL_DIR = rtl
TB_DIR  = tb

RTL_SOURCES = \
    $(RTL_DIR)/kv32_pkg.sv \
    $(RTL_DIR)/kv32_alu.sv \
    $(RTL_DIR)/kv32_regfile.sv \
    $(RTL_DIR)/kv32_decoder.sv \
    $(RTL_DIR)/kv32_mem_arbiter.sv \
    $(RTL_DIR)/kv32_core.sv

# Icarus Verilog (fallback — SV testbenches)
TB_SV = $(TB_DIR)/kv32_core_tb.sv

# Verilator C++ test driver
TB_CPP = $(TB_DIR)/sim_main.cpp

# ---- Verilator (recommended) ----

verilator: $(RTL_SOURCES) $(TB_CPP)
	verilator --cc --exe --build -j 0 \
		-Wall -Wno-fatal --trace \
		--top-module kv32_core \
		$(RTL_SOURCES) $(TB_CPP) \
		--Mdir obj_dir
	./obj_dir/Vkv32_core

# Run ALU test (default, same as 'verilator')
test-alu: verilator

# Run sub-word memory test
test-subword: $(RTL_SOURCES) $(TB_CPP)
	verilator --cc --exe --build -j 0 \
		-Wall -Wno-fatal --trace \
		--top-module kv32_core \
		$(RTL_SOURCES) $(TB_CPP) \
		--Mdir obj_dir
	./obj_dir/Vkv32_core --test 1

# Run all tests and check exit code
test-all: test-alu test-subword

# ---- Icarus Verilog (fallback) ----

iverilog: $(RTL_SOURCES) $(TB_SV)
	iverilog -g2012 -o kv32_core_tb.vvp $(RTL_SOURCES) $(TB_SV)
	vvp kv32_core_tb.vvp

iverilog-subword: $(RTL_SOURCES) $(TB_DIR)/kv32_subword_tb.sv
	iverilog -g2012 -o kv32_subword_tb.vvp $(RTL_SOURCES) $(TB_DIR)/kv32_subword_tb.sv
	vvp kv32_subword_tb.vvp

# ---- Lint ----

lint: $(RTL_SOURCES)
	verilator --lint-only -Wall $(RTL_SOURCES)

# ---- Clean ----

clean:
	rm -f kv32_core_tb.vvp kv32_subword_tb.vvp kv32_core_tb.vcd
	rm -rf obj_dir

.PHONY: verilator test-alu test-subword test-all iverilog iverilog-subword lint clean
