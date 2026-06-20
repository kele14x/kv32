# kv32 Makefile

RTL_DIR = rtl
TB_DIR  = tb

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

# ---- Lint ----

lint: $(RTL_SOURCES)
	verilator --lint-only -Wall --top-module kv32_core $(RTL_SOURCES)

# ---- Clean ----

clean:
	rm -f kv32_core_tb.vcd
	rm -rf obj_dir

.PHONY: verilator verilator-build test-alu test-subword test-all test-latency \
        riscv-tests-compile riscv-test-% riscv-tests riscv-tests-latency \
        lint clean
