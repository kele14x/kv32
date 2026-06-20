# kv32 Makefile

RTL_DIR = rtl
TB_DIR  = tb

# ---- Help ----

help:
	@echo "kv32 — available make targets"
	@echo ""
	@echo "  Build & Lint:"
	@echo "    verilator              Build and run the integration testbench (default)"
	@echo "    verilator-build        Build only (no run)"
	@echo "    lint                   Verilator lint check (-Wall)"
	@echo "    format                 Format RTL files in-place with verible-verilog-format"
	@echo "    format-check           Verify RTL files are already formatted"
	@echo "    clean                  Remove all build artifacts"
	@echo "    clean-integration      Remove obj_dir/ (integration testbench)"
	@echo "    clean-unit             Remove obj_dir_*/ (unit testbenches)"
	@echo "    clean-riscv-tests      Remove build/riscv-tests/ (compiled ELFs)"
	@echo ""
	@echo "  Integration Tests (full core, sim_main.cpp):"
	@echo "    test-alu               Run the ALU integration test"
	@echo "    test-subword           Run the sub-word memory test"
	@echo "    test-all               Run all built-in integration tests"
	@echo "    test-latency           Built-in tests with 2-cycle memory latency"
	@echo ""
	@echo "  Unit Tests (per-module, isolated testbenches):"
	@echo "    unit-tests             Run all 5 unit tests"
	@echo "    unit-test-alu          ALU: 10 ops, edge cases"
	@echo "    unit-test-regfile      Regfile: x0, write-during-read, dual-port"
	@echo "    unit-test-decoder      Decoder: opcodes, immediates, CSR variants"
	@echo "    unit-test-csr          CSR: read/write, trap, MRET, counters"
	@echo "    unit-test-mem_arbiter  Arbiter: priority, latency, gnt pulse"
	@echo ""
	@echo "  riscv-tests (requires RISC-V toolchain):"
	@echo "    riscv-tests-compile    Cross-compile all rv32ui tests to build/"
	@echo "    riscv-tests            Run all rv32ui tests (zero latency)"
	@echo "    riscv-tests-latency    Run all rv32ui tests (2-cycle latency)"
	@echo "    riscv-test-<name>      Run a single test (e.g. riscv-test-add)"
	@echo ""

RTL_SOURCES = \
    $(RTL_DIR)/kv32_pkg.sv \
    $(RTL_DIR)/kv32_alu.sv \
    $(RTL_DIR)/kv32_regfile.sv \
    $(RTL_DIR)/kv32_csr.sv \
    $(RTL_DIR)/kv32_decoder.sv \
    $(RTL_DIR)/kv32_mem_arbiter.sv \
    $(RTL_DIR)/kv32_core.sv

# Verilator C++ test driver
TB_CPP = $(TB_DIR)/sim_main.cpp

# ---- Verilator ----

verilator: verilator-build
	./obj_dir/Vkv32_core

verilator-build: $(RTL_SOURCES) $(TB_CPP)
	verilator --cc --exe --build -j 1 \
		-Wall -Wno-fatal --trace \
		--top-module kv32_core \
		$(RTL_SOURCES) $(TB_CPP) \
		--Mdir obj_dir

# Run ALU test (default, same as 'verilator')
test-alu: verilator

# Run sub-word memory test
test-subword: verilator-build
	./obj_dir/Vkv32_core --test subword

# Run all built-in tests and check exit code
test-all: test-alu test-subword

# Run built-in tests with multi-cycle memory latency (exercises stall paths)
test-latency: verilator-build
	./obj_dir/Vkv32_core --test alu --latency 2 --notrace
	./obj_dir/Vkv32_core --test subword --latency 2 --notrace

# Run riscv-tests with multi-cycle memory latency
riscv-tests-latency: verilator-build
	@pass=0; fail=0; skip=0; total=0; \
	for test in $(RISCV_TESTS_BUILD)/rv32ui-p-*; do \
		case "$$test" in *.dump) continue;; esac; \
		name=$$(basename $$test); \
		total=$$((total+1)); \
		printf "  %-30s " $$name; \
		if ./obj_dir/Vkv32_core --binary $$test --cycles 100000 --latency 2 --notrace > /tmp/kv32_lat_$${name}.log 2>&1; then \
			printf "PASS\n"; pass=$$((pass+1)); \
		else \
			result=$$?; \
			if grep -q TIMEOUT /tmp/kv32_lat_$${name}.log; then \
				printf "TIMEOUT\n"; skip=$$((skip+1)); \
			else \
				printf "FAIL\n"; fail=$$((fail+1)); \
			fi; \
		fi; \
	done; \
	echo ""; \
	echo "=== riscv-tests-latency Results ==="; \
	echo "  $$pass passed, $$fail failed, $$skip timeout (of $$total total)"; \
	echo "==================================="

# ---- riscv-tests ----

# Auto-detect the RISC-V toolchain: prefer riscv64-unknown-elf-gcc
# (most common), then riscv32-unknown-elf-gcc, then the bare riscv64-elf-gcc
# fallback. Override with: make <target> RISCV_GCC=/path/to/gcc
RISCV_GCC ?= $(shell command -v riscv64-unknown-elf-gcc 2>/dev/null || \
                    command -v riscv32-unknown-elf-gcc 2>/dev/null || \
                    command -v riscv64-elf-gcc 2>/dev/null || \
                    echo riscv64-elf-gcc)
RISCV_TESTS_DIR ?= tests/riscv-tests
RISCV_TESTS_BUILD := build/riscv-tests
RISCV_MARCH   := rv32i_zicsr
RISCV_MABI    := ilp32
RISCV_CFLAGS  := -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles
RISCV_INCLUDES := -I$(RISCV_TESTS_DIR)/env/p -I$(RISCV_TESTS_DIR)/isa/macros/scalar
RISCV_LDFLAGS := -T$(RISCV_TESTS_DIR)/env/p/link.ld

# Compile all rv32ui tests
riscv-tests-compile:
	@if [ ! -e $(RISCV_TESTS_DIR)/.git ]; then \
		echo "Error: riscv-tests submodule not initialized at $(RISCV_TESTS_DIR)"; \
		echo "Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@mkdir -p $(RISCV_TESTS_BUILD)
	@for test in $(RISCV_TESTS_DIR)/isa/rv32ui/*.S; do \
		name=$$(basename $$test .S); \
		target=$(RISCV_TESTS_BUILD)/rv32ui-p-$$name; \
		if [ ! -f $$target ]; then \
			echo "  CC  $$name"; \
			march=$(RISCV_MARCH); \
			[ "$$name" = "fence_i" ] && march=rv32izicsr_zifencei; \
			$(RISCV_GCC) $(RISCV_CFLAGS) -march=$$march -mabi=$(RISCV_MABI) \
				$(RISCV_INCLUDES) $(RISCV_LDFLAGS) $$test -o $$target 2>&1; \
		fi; \
	done
	@echo "riscv-tests compiled in $(RISCV_TESTS_BUILD)/"

# Run a single riscv-test: make riscv-test-TESTNAME
riscv-test-%: verilator-build
	./obj_dir/Vkv32_core --binary $(RISCV_TESTS_BUILD)/rv32ui-p-$*

# Run all rv32ui tests (uses pre-compiled ELF binaries, skips .dump files)
riscv-tests: verilator-build
	@pass=0; fail=0; skip=0; total=0; \
	for test in $(RISCV_TESTS_BUILD)/rv32ui-p-*; do \
		case "$$test" in *.dump) continue;; esac; \
		name=$$(basename $$test); \
		total=$$((total+1)); \
		printf "  %-30s " $$name; \
		if ./obj_dir/Vkv32_core --binary $$test --cycles 50000 --notrace > /tmp/kv32_test_$${name}.log 2>&1; then \
			printf "PASS\n"; pass=$$((pass+1)); \
		else \
			result=$$?; \
			if grep -q TIMEOUT /tmp/kv32_test_$${name}.log; then \
				printf "TIMEOUT\n"; skip=$$((skip+1)); \
			else \
				printf "FAIL\n"; fail=$$((fail+1)); \
			fi; \
		fi; \
	done; \
	echo ""; \
	echo "=== riscv-tests Results ==="; \
	echo "  $$pass passed, $$fail failed, $$skip timeout (of $$total total)"; \
	echo "==========================="

# ---- Unit Tests (per-module Verilator C++ testbenches) ----
# Each target builds and runs an isolated testbench for one submodule.
# This catches RTL bugs at the module boundary before integration.

UNIT_TESTS = alu regfile decoder csr mem_arbiter

unit-test-alu: $(TB_DIR)/tb_alu.cpp $(RTL_DIR)/kv32_alu.sv
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_alu \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_alu.sv $(TB_DIR)/tb_alu.cpp \
		--Mdir obj_dir_alu
	./obj_dir_alu/Vkv32_alu

unit-test-regfile: $(TB_DIR)/tb_regfile.cpp $(RTL_DIR)/kv32_regfile.sv
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_regfile \
		$(RTL_DIR)/kv32_regfile.sv $(TB_DIR)/tb_regfile.cpp \
		--Mdir obj_dir_regfile
	./obj_dir_regfile/Vkv32_regfile

unit-test-decoder: $(TB_DIR)/tb_decoder.cpp $(RTL_DIR)/kv32_decoder.sv
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_decoder \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_decoder.sv $(TB_DIR)/tb_decoder.cpp \
		--Mdir obj_dir_decoder
	./obj_dir_decoder/Vkv32_decoder

unit-test-csr: $(TB_DIR)/tb_csr.cpp $(RTL_DIR)/kv32_csr.sv
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_csr \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_csr.sv $(TB_DIR)/tb_csr.cpp \
		--Mdir obj_dir_csr
	./obj_dir_csr/Vkv32_csr

unit-test-mem_arbiter: $(TB_DIR)/tb_mem_arbiter.cpp $(RTL_DIR)/kv32_mem_arbiter.sv
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_mem_arbiter \
		$(RTL_DIR)/kv32_mem_arbiter.sv $(TB_DIR)/tb_mem_arbiter.cpp \
		--Mdir obj_dir_mem_arbiter
	./obj_dir_mem_arbiter/Vkv32_mem_arbiter

unit-tests: $(addprefix unit-test-,$(UNIT_TESTS))
	@echo ""
	@echo "=== All unit tests passed ==="

# ---- Format ----

# verible-verilog-format path (override with VERIBLE_FORMAT=/path/to/verible-verilog-format)
VERIBLE_FORMAT ?= $(HOME)/tools/verible/bin/verible-verilog-format

# Format all RTL files in-place
format: $(RTL_SOURCES)
	@if ! command -v $(VERIBLE_FORMAT) >/dev/null 2>&1 && [ ! -x $(VERIBLE_FORMAT) ]; then \
		echo "Error: verible-verilog-format not found at $(VERIBLE_FORMAT)"; \
		echo "Override with: make format VERIBLE_FORMAT=/path/to/verible-verilog-format"; \
		exit 1; \
	fi
	$(VERIBLE_FORMAT) --inplace $(RTL_SOURCES)

# Check that all RTL files are already formatted (non-zero exit on drift)
format-check: $(RTL_SOURCES)
	@if ! command -v $(VERIBLE_FORMAT) >/dev/null 2>&1 && [ ! -x $(VERIBLE_FORMAT) ]; then \
		echo "Error: verible-verilog-format not found at $(VERIBLE_FORMAT)"; \
		exit 1; \
	fi
	@ok=1; \
	for f in $(RTL_SOURCES); do \
		if ! $(VERIBLE_FORMAT) $$f | diff -q - $$f >/dev/null 2>&1; then \
			echo "  NOT FORMATTED: $$f"; ok=0; \
		fi; \
	done; \
	if [ $$ok -eq 1 ]; then \
		echo "All RTL files are verible-formatted"; \
	else \
		echo ""; \
		echo "Format drift detected — run 'make format' to fix"; \
		exit 1; \
	fi

# ---- Lint ----

lint: $(RTL_SOURCES)
	verilator --lint-only -Wall --top-module kv32_core $(RTL_SOURCES)

# ---- Clean ----

clean: clean-integration clean-unit clean-riscv-tests
	@echo "Removed all build artifacts"

clean-integration:
	rm -f kv32_core_tb.vcd
	rm -rf obj_dir

clean-unit:
	rm -rf obj_dir_alu obj_dir_regfile obj_dir_decoder obj_dir_csr obj_dir_mem_arbiter

clean-riscv-tests:
	rm -rf $(RISCV_TESTS_BUILD)
	rmdir build 2>/dev/null || true

.PHONY: help verilator verilator-build test-alu test-subword test-all test-latency \
        riscv-tests-compile riscv-test-% riscv-tests riscv-tests-latency \
        unit-test-alu unit-test-regfile unit-test-decoder unit-test-csr \
        unit-test-mem_arbiter unit-tests lint format format-check clean \
        clean-integration clean-unit clean-riscv-tests

.DEFAULT_GOAL := help
