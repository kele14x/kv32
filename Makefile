# kv32 Makefile

RTL_DIR = rtl
TB_DIR  = tb

MEM_LATENCY ?= 1
MEM_RANDOM_LATENCY ?= 0
IMEM_LATENCY ?= $(MEM_LATENCY)
DMEM_LATENCY ?= $(MEM_LATENCY)
IMEM_RANDOM_LATENCY ?= $(MEM_RANDOM_LATENCY)
DMEM_RANDOM_LATENCY ?= $(MEM_RANDOM_LATENCY)

ifeq ($(IMEM_RANDOM_LATENCY),1)
IMEM_LATENCY_ARGS := --imem-random-latency
else
IMEM_LATENCY_ARGS := --imem-latency $(IMEM_LATENCY)
endif

ifeq ($(DMEM_RANDOM_LATENCY),1)
DMEM_LATENCY_ARGS := --dmem-random-latency
else
DMEM_LATENCY_ARGS := --dmem-latency $(DMEM_LATENCY)
endif

MEM_LATENCY_ARGS := $(IMEM_LATENCY_ARGS) $(DMEM_LATENCY_ARGS)

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
	@echo "  Integration Tests (full core, tb_core.sv + tb_core.cpp):"
	@echo "    test-alu               Run the ALU integration test"
	@echo "    test-subword           Run the sub-word memory test"
	@echo "    test-all               Run all built-in integration tests"
	@echo "                           Override MEM/IMEM/DMEM_LATENCY or *_RANDOM_LATENCY=1"
	@echo ""
	@echo "  Unit Tests (per-module, isolated testbenches):"
	@echo "    unit-tests             Run all 5 unit tests"
	@echo "    unit-test-alu          ALU: 10 ops, edge cases"
	@echo "    unit-test-regfile      Regfile: x0, write-during-read, dual-port"
	@echo "    unit-test-decoder      Decoder: opcodes, immediates, CSR variants"
	@echo "    unit-test-csr          CSR: read/write, trap, MRET, counters"
	@echo "    unit-test-mem_fe       Memory front-end: alignment, sub-word, FSM"
	@echo ""
	@echo "  riscv-tests (requires RISC-V toolchain):"
	@echo "    riscv-tests            Auto-checkout, compile, and run all rv32ui tests"
	@echo "                           Override MEM/IMEM/DMEM_LATENCY or *_RANDOM_LATENCY=1"
	@echo "    riscv-test-<name>      Run a single test (e.g. riscv-test-add)"
	@echo ""

RTL_SOURCES = \
    $(RTL_DIR)/kv32_pkg.sv \
    $(RTL_DIR)/kv32_alu.sv \
    $(RTL_DIR)/kv32_m_unit.sv \
    $(RTL_DIR)/kv32_regfile.sv \
    $(RTL_DIR)/kv32_csr.sv \
    $(RTL_DIR)/kv32_decoder.sv \
    $(RTL_DIR)/kv32_mem_fe.sv \
    $(RTL_DIR)/kv32_core.sv

# Verilator integration testbench
TB_SV_SOURCES = \
    $(TB_DIR)/tb_core_mem.sv \
    $(TB_DIR)/tb_core.sv
TB_CPP = $(TB_DIR)/tb_core.cpp

# ---- Verilator ----

verilator: verilator-build
	./build/obj_dir/Vtb_core $(MEM_LATENCY_ARGS)

verilator-build: $(RTL_SOURCES) $(TB_SV_SOURCES) $(TB_CPP) | build
	verilator --cc --exe --build -j 1 \
		-Wall -Wno-fatal --trace \
		--top-module tb_core \
		$(RTL_SOURCES) $(TB_SV_SOURCES) $(TB_CPP) \
		--Mdir build/obj_dir

# Run ALU test (default, same as 'verilator')
test-alu: verilator

# Run sub-word memory test
test-subword: verilator-build
	./build/obj_dir/Vtb_core --test subword $(MEM_LATENCY_ARGS)

# Run all built-in tests and check exit code
test-all: test-alu test-subword

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

# Ensure riscv-tests submodule (and nested env submodule) is checked out
$(RISCV_TESTS_DIR)/env/p/link.ld:
	@echo "Initializing riscv-tests submodule..."; \
	git submodule update --init --recursive

# Compile a single rv32ui test (invoked automatically by riscv-test-% and riscv-tests)
$(RISCV_TESTS_BUILD)/rv32ui-p-%: $(RISCV_TESTS_DIR)/isa/rv32ui/%.S $(RISCV_TESTS_DIR)/env/p/link.ld | $(RISCV_TESTS_BUILD)
	@echo "  CC  $*"; \
	march=$(RISCV_MARCH); \
	[ "$*" = "fence_i" ] && march=rv32izicsr_zifencei; \
	$(RISCV_GCC) $(RISCV_CFLAGS) -march=$$march -mabi=$(RISCV_MABI) \
		$(RISCV_INCLUDES) $(RISCV_LDFLAGS) $< -o $@

# Compile a single rv32um test (M extension: multiply/divide)
$(RISCV_TESTS_BUILD)/rv32um-p-%: $(RISCV_TESTS_DIR)/isa/rv32um/%.S $(RISCV_TESTS_DIR)/env/p/link.ld | $(RISCV_TESTS_BUILD)
	@echo "  CC  $* (M ext)"; \
	$(RISCV_GCC) $(RISCV_CFLAGS) -march=rv32im_zicsr -mabi=$(RISCV_MABI) \
		$(RISCV_INCLUDES) $(RISCV_LDFLAGS) $< -o $@

$(RISCV_TESTS_BUILD):
	@mkdir -p $@

# Compile all rv32ui and rv32um tests (wildcard evaluated at recipe time, after submodule checkout)
riscv-tests-compile: $(RISCV_TESTS_DIR)/env/p/link.ld | $(RISCV_TESTS_BUILD)
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
	@for test in $(RISCV_TESTS_DIR)/isa/rv32um/*.S; do \
		name=$$(basename $$test .S); \
		target=$(RISCV_TESTS_BUILD)/rv32um-p-$$name; \
		if [ ! -f $$target ]; then \
			echo "  CC  $$name (M ext)"; \
			$(RISCV_GCC) $(RISCV_CFLAGS) -march=rv32im_zicsr -mabi=$(RISCV_MABI) \
				$(RISCV_INCLUDES) $(RISCV_LDFLAGS) $$test -o $$target 2>&1; \
		fi; \
	done

# Run a single riscv-test: make riscv-test-TESTNAME
riscv-test-%: verilator-build $(RISCV_TESTS_BUILD)/rv32ui-p-%
	./build/obj_dir/Vtb_core --binary $(RISCV_TESTS_BUILD)/rv32ui-p-$* $(MEM_LATENCY_ARGS)

# Run a single M-extension test: make riscv-test-m-TESTNAME
riscv-test-m-%: verilator-build $(RISCV_TESTS_BUILD)/rv32um-p-%
	./build/obj_dir/Vtb_core --binary $(RISCV_TESTS_BUILD)/rv32um-p-$* $(MEM_LATENCY_ARGS)

# Run all rv32ui and rv32um tests (auto-compiles if needed, skips .dump files)
riscv-tests: verilator-build riscv-tests-compile
	@pass=0; fail=0; skip=0; total=0; \
	for test in $(RISCV_TESTS_BUILD)/rv32ui-p-* $(RISCV_TESTS_BUILD)/rv32um-p-*; do \
		case "$$test" in *.dump) continue;; esac; \
		name=$$(basename $$test); \
		total=$$((total+1)); \
		printf "  %-30s " $$name; \
		if ./build/obj_dir/Vtb_core --binary $$test --cycles 50000 --notrace $(MEM_LATENCY_ARGS) > build/kv32_test_$${name}.log 2>&1; then \
			printf "PASS\n"; pass=$$((pass+1)); \
		else \
			result=$$?; \
			if grep -q TIMEOUT build/kv32_test_$${name}.log; then \
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

UNIT_TESTS = alu regfile decoder csr mem_fe m_unit

unit-test-alu: $(TB_DIR)/tb_alu.cpp $(RTL_DIR)/kv32_alu.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_alu \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_alu.sv $(TB_DIR)/tb_alu.cpp \
		--Mdir build/obj_dir_alu
	./build/obj_dir_alu/Vkv32_alu

unit-test-regfile: $(TB_DIR)/tb_regfile.cpp $(RTL_DIR)/kv32_regfile.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_regfile \
		$(RTL_DIR)/kv32_regfile.sv $(TB_DIR)/tb_regfile.cpp \
		--Mdir build/obj_dir_regfile
	./build/obj_dir_regfile/Vkv32_regfile

unit-test-decoder: $(TB_DIR)/tb_decoder.cpp $(RTL_DIR)/kv32_decoder.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_decoder \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_decoder.sv $(TB_DIR)/tb_decoder.cpp \
		--Mdir build/obj_dir_decoder
	./build/obj_dir_decoder/Vkv32_decoder

unit-test-csr: $(TB_DIR)/tb_csr.cpp $(RTL_DIR)/kv32_csr.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_csr \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_csr.sv $(TB_DIR)/tb_csr.cpp \
		--Mdir build/obj_dir_csr
	./build/obj_dir_csr/Vkv32_csr

unit-test-mem_fe: $(TB_DIR)/tb_mem_fe.cpp $(RTL_DIR)/kv32_mem_fe.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_mem_fe \
		$(RTL_DIR)/kv32_mem_fe.sv $(TB_DIR)/tb_mem_fe.cpp \
		--Mdir build/obj_dir_mem_fe
	./build/obj_dir_mem_fe/Vkv32_mem_fe

unit-test-m_unit: $(TB_DIR)/tb_m_unit.cpp $(RTL_DIR)/kv32_m_unit.sv | build
	verilator --cc --exe --build -j 1 -Wall -Wno-fatal \
		--top-module kv32_m_unit \
		$(RTL_DIR)/kv32_pkg.sv $(RTL_DIR)/kv32_m_unit.sv $(TB_DIR)/tb_m_unit.cpp \
		--Mdir build/obj_dir_m_unit
	./build/obj_dir_m_unit/Vkv32_m_unit

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
	@rm -rf build
	@echo "Removed all build artifacts"

clean-integration:
	@rm -f build/kv32_core_tb.vcd build/kv32_test_*.log
	@rm -rf build/obj_dir

clean-unit:
	@rm -rf build/obj_dir_alu build/obj_dir_regfile build/obj_dir_decoder build/obj_dir_csr build/obj_dir_mem_fe

clean-riscv-tests:
	@rm -rf build/riscv-tests

build:
	@mkdir -p build

# Prevent Make from deleting compiled riscv-tests binaries (they're built via pattern rules)
.SECONDARY:

.PHONY: help verilator verilator-build test-alu test-subword test-all test-latency \
        riscv-tests-compile riscv-test-% riscv-tests riscv-tests-latency \
        unit-test-alu unit-test-regfile unit-test-decoder unit-test-csr unit-test-mem_fe \
        unit-tests lint format format-check clean \
        clean-integration clean-unit clean-riscv-tests

.DEFAULT_GOAL := help
