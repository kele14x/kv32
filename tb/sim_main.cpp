#include "Vkv32_core.h"
#include "Vkv32_core___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <sys/stat.h>
#include <sys/types.h>
#include <vector>

// ============================================================================
// ELF32 Loader
// ============================================================================
static uint16_t elf16(const uint8_t* p) { return p[0] | (p[1] << 8); }
static uint32_t elf32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
}

#define EM_RISCV 243
#define PT_LOAD  1
#define SHT_SYMTAB 2
#define SHT_STRTAB 3

struct ElfInfo {
    uint32_t entry;
    uint32_t tohost;
    bool     valid;
};

// ============================================================================
// BRAM Memory Model (64 KiB, word-addressed, byte-enable writes)
//   - bram_base=0: legacy mode, BRAM at 0x00000000 (existing tests)
//   - bram_base=0x80000000: riscv-tests mode, BRAM at 0x80000000
//     with trampoline at 0x00000000 (LUI+JALR to jump to bram_entry)
// ============================================================================

static const int BRAM_WORDS = 16384; // 64 KiB / 4
static uint32_t bram[BRAM_WORDS];
static uint32_t bram_base  = 0;          // Set before loading
static uint32_t bram_entry = 0x80000000; // Trampoline jump target

static void bram_write(uint32_t addr, uint32_t wdata, uint8_t be) {
    if (addr < bram_base) return;
    uint32_t off = addr - bram_base;
    int idx = (int)(off >> 2) & (BRAM_WORDS - 1);
    if (be & 1) bram[idx] = (bram[idx] & 0xFFFFFF00) | (wdata & 0x000000FF);
    if (be & 2) bram[idx] = (bram[idx] & 0xFFFF00FF) | (wdata & 0x0000FF00);
    if (be & 4) bram[idx] = (bram[idx] & 0xFF00FFFF) | (wdata & 0x00FF0000);
    if (be & 8) bram[idx] = (bram[idx] & 0x00FFFFFF) | (wdata & 0xFF000000);
}

static uint32_t bram_read(uint32_t addr) {
    // Trampoline: boot code at 0x00000000 jumps to bram_entry
    if (bram_base != 0 && addr < bram_base) {
        uint32_t offset = addr >> 2;
        if (offset == 0) {
            // LUI x5, %hi(bram_entry)
            uint32_t upper = (bram_entry + 0x800) >> 12;
            return (upper << 12) | (5 << 7) | 0x37;
        }
        if (offset == 1) {
            // JALR x0, x5, %lo(bram_entry)
            return ((bram_entry & 0xFFF) << 20) | (5 << 15) | (0 << 7) | 0x67;
        }
        return 0x00000013; // NOP
    }
    uint32_t off = addr - bram_base;
    return bram[(off >> 2) & (BRAM_WORDS - 1)];
}

// Byte-level write for ELF loading
static void bram_write_byte(uint32_t addr, uint8_t data) {
    if (addr < bram_base) return;
    uint32_t off = addr - bram_base;
    int idx  = (int)(off >> 2) & (BRAM_WORDS - 1);
    int byte_pos = addr & 3;
    int shift = byte_pos * 8;
    bram[idx] = (bram[idx] & ~(0xFFu << shift)) | ((uint32_t)data << shift);
}

// ============================================================================
// ELF Loader — parse ELF32, load PT_LOAD segments into BRAM
// ============================================================================
static ElfInfo load_elf(const char* path) {
    ElfInfo result = {0, 0, false};

    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open ELF file: %s\n", path);
        return result;
    }

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (fsize < 52) {
        fprintf(stderr, "Error: file too small to be ELF: %s\n", path);
        fclose(f);
        return result;
    }

    std::vector<uint8_t> buf(fsize);
    if ((long)fread(buf.data(), 1, fsize, f) != fsize) {
        fprintf(stderr, "Error: failed to read ELF file: %s\n", path);
        fclose(f);
        return result;
    }
    fclose(f);

    // Validate ELF magic
    if (buf[0] != 0x7F || buf[1] != 'E' || buf[2] != 'L' || buf[3] != 'F') {
        fprintf(stderr, "Error: not an ELF file: %s\n", path);
        return result;
    }
    if (buf[4] != 1) { fprintf(stderr, "Error: not 32-bit ELF\n"); return result; }
    if (buf[5] != 1) { fprintf(stderr, "Error: not little-endian ELF\n"); return result; }

    uint16_t e_machine = elf16(&buf[18]);
    if (e_machine != EM_RISCV) {
        fprintf(stderr, "Warning: ELF machine=%d (expected %d RISC-V)\n",
                e_machine, EM_RISCV);
    }

    uint32_t e_entry     = elf32(&buf[24]);
    uint32_t e_phoff     = elf32(&buf[28]);
    uint32_t e_shoff     = elf32(&buf[32]);
    uint16_t e_phentsize = elf16(&buf[42]);
    uint16_t e_phnum     = elf16(&buf[44]);
    uint16_t e_shentsize = elf16(&buf[46]);
    uint16_t e_shnum     = elf16(&buf[48]);
    uint16_t e_shstrndx  = elf16(&buf[50]);

    printf("ELF: entry=0x%08X, %d program headers, %d sections\n",
           e_entry, e_phnum, e_shnum);

    for (int i = 0; i < e_phnum; i++) {
        uint32_t ph_off = e_phoff + i * e_phentsize;
        if (ph_off + e_phentsize > (uint32_t)fsize) break;

        uint32_t p_type   = elf32(&buf[ph_off + 0]);
        uint32_t p_offset = elf32(&buf[ph_off + 4]);
        uint32_t p_vaddr  = elf32(&buf[ph_off + 8]);
        uint32_t p_filesz = elf32(&buf[ph_off + 16]);
        uint32_t p_memsz  = elf32(&buf[ph_off + 20]);

        if (p_type != PT_LOAD) continue;

        printf("  LOAD: vaddr=0x%08X, filesz=%u, memsz=%u\n",
               p_vaddr, p_filesz, p_memsz);

        // Load file data
        for (uint32_t j = 0; j < p_filesz; j++) {
            if (p_offset + j >= (uint32_t)fsize) break;
            bram_write_byte(p_vaddr + j, buf[p_offset + j]);
        }
        // Zero-fill BSS
        for (uint32_t j = p_filesz; j < p_memsz; j++) {
            bram_write_byte(p_vaddr + j, 0);
        }
    }

    // Find tohost address from .tohost section or symtab
    uint32_t tohost_addr = 0;
    if (e_shoff > 0 && e_shnum > 0 && e_shstrndx < e_shnum) {
        // Get shstrtab section
        uint32_t shstr_off = e_shoff + e_shstrndx * e_shentsize;
        uint32_t shstr_fileoff = elf32(&buf[shstr_off + 16]);
        uint32_t shstr_size    = elf32(&buf[shstr_off + 20]);

        // Scan sections for .tohost or symtab
        for (int i = 0; i < e_shnum; i++) {
            uint32_t sh_off = e_shoff + i * e_shentsize;
            if (sh_off + e_shentsize > (uint32_t)fsize) break;

            uint32_t sh_name_idx = elf32(&buf[sh_off + 0]);
            uint32_t sh_type     = elf32(&buf[sh_off + 4]);
            uint32_t sh_addr     = elf32(&buf[sh_off + 12]);
            uint32_t sh_fileoff  = elf32(&buf[sh_off + 16]);
            uint32_t sh_size     = elf32(&buf[sh_off + 20]);
            uint32_t sh_link     = elf32(&buf[sh_off + 24]);

            if (sh_name_idx < shstr_size &&
                shstr_fileoff + sh_name_idx < (uint32_t)fsize) {
                const char* name = (const char*)&buf[shstr_fileoff + sh_name_idx];
                if (strcmp(name, ".tohost") == 0) {
                    tohost_addr = sh_addr;
                    printf("  .tohost section at 0x%08X\n", tohost_addr);
                }
            }

            // Fallback: search symtab for 'tohost' symbol
            if (tohost_addr == 0 && sh_type == SHT_SYMTAB && sh_link < e_shnum) {
                uint32_t str_off = e_shoff + sh_link * e_shentsize;
                uint32_t str_fileoff = elf32(&buf[str_off + 16]);
                uint32_t str_size    = elf32(&buf[str_off + 20]);

                uint32_t entsize = elf32(&buf[sh_off + 36]);
                if (entsize == 0) entsize = 16; // ELF32 sym entry size

                for (uint32_t s = 0; s < sh_size; s += entsize) {
                    if (sh_fileoff + s + entsize > (uint32_t)fsize) break;
                    uint32_t st_name  = elf32(&buf[sh_fileoff + s + 0]);
                    uint32_t st_value = elf32(&buf[sh_fileoff + s + 4]);

                    if (st_name < str_size &&
                        str_fileoff + st_name < (uint32_t)fsize) {
                        const char* sym = (const char*)&buf[str_fileoff + st_name];
                        if (strcmp(sym, "tohost") == 0) {
                            tohost_addr = st_value;
                            printf("  tohost symbol at 0x%08X\n", tohost_addr);
                            break;
                        }
                    }
                }
            }
        }
    }

    result.entry = e_entry;
    result.tohost = tohost_addr;
    result.valid = true;
    return result;
}

// ============================================================================
// Flat binary loader (fallback, loads at bram_base)
// ============================================================================
static bool load_flat_binary(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open binary: %s\n", path);
        return false;
    }

    uint8_t rbuf[4096];
    uint32_t offset = 0;
    size_t n;
    while ((n = fread(rbuf, 1, sizeof(rbuf), f)) > 0) {
        for (size_t i = 0; i < n; i++) {
            bram_write_byte(bram_base + offset + (uint32_t)i, rbuf[i]);
        }
        offset += (uint32_t)n;
    }
    fclose(f);
    printf("Loaded flat binary: %u bytes at 0x%08X\n", offset, bram_base);
    return true;
}

// Smart loader: detects ELF by magic, falls back to flat binary
static ElfInfo load_binary(const char* path) {
    memset(bram, 0, sizeof(bram));

    // Peek at first 4 bytes to detect ELF
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open %s\n", path);
        return {0, false};
    }
    uint8_t magic[4];
    size_t n = fread(magic, 1, 4, f);
    fclose(f);

    if (n >= 4 && magic[0] == 0x7F && magic[1] == 'E' &&
        magic[2] == 'L'  && magic[3] == 'F') {
        return load_elf(path);
    }

    // Flat binary — entry is bram_base, no tohost
    if (load_flat_binary(path)) {
        return {bram_base, 0, true};
    }
    return {0, 0, false};
}

// ============================================================================
// Test Program Definitions (existing hard-coded tests)
// ============================================================================
struct TestWord {
    int addr_word;
    uint32_t data;
};

static const TestWord prog_alu[] = {
    {0, 0x00500093}, // ADDI x1, x0, 5
    {1, 0x00A00113}, // ADDI x2, x0, 10
    {2, 0x002081B3}, // ADD  x3, x1, x2
    {3, 0x00000013}, // NOP
};

static const TestWord prog_subword[] = {
    {0,  0x05500093}, {1,  0x05500113}, {2,  0x00102023},
    {3,  0x00202223}, {4,  0x00000183}, {5,  0x00100203},
    {6,  0x00004283}, {7,  0x00401303}, {8,  0x00405383},
    {9,  0x0FF00413}, {10, 0x00800123}, {11, 0x00204483},
    {12, 0x23400513}, {13, 0x00A01323}, {14, 0x00605583},
    {15, 0x00000013},
};

struct RegCheck {
    int       reg;
    uint32_t  expected;
    const char* label;
};

static const RegCheck check_alu[] = {
    {1,  0x00000005, "x1 (ADDI 5)"},
    {2,  0x0000000A, "x2 (ADDI 10)"},
    {3,  0x0000000F, "x3 (ADD x1+x2)"},
    {0,  0, nullptr}
};

static const RegCheck check_subword[] = {
    {1,  0x00000055, "x1  (0x55)"},
    {2,  0x00000055, "x2  (0x55)"},
    {3,  0x00000055, "x3  (LB 0x55)"},
    {4,  0x00000000, "x4  (LB 0x00)"},
    {5,  0x00000055, "x5  (LBU 0x55)"},
    {6,  0x00000055, "x6  (LH 0x55)"},
    {7,  0x00000055, "x7  (LHU 0x55)"},
    {8,  0x000000FF, "x8  (0xFF)"},
    {9,  0x000000FF, "x9  (LBU 0xFF)"},
    {10, 0x00000234, "x10 (0x234)"},
    {11, 0x00000234, "x11 (LHU 0x234)"},
    {0,  0, nullptr}
};

// ============================================================================
// Simulation Framework
// ============================================================================
static vluint64_t sim_time = 0;
static int fail_count = 0;

// Forward declarations — defined after tick()
static void imem_responder(Vkv32_core* top);
static void dmem_responder(Vkv32_core* top);

static void tick(Vkv32_core* top, VerilatedVcdC* tfp) {
    top->clk = 0;
    top->eval();  // Evaluate combinational: outputs reflect current state
    if (tfp) tfp->dump(sim_time++);

    // Drive memory responders with fresh outputs, get ack
    imem_responder(top);
    dmem_responder(top);

    // Re-evaluate so ack propagates through combinational logic
    // (rdata_valid, mem_stall, etc.) before the rising edge captures state.
    top->eval();

    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(sim_time++);
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(sim_time++);
}

static void reset(Vkv32_core* top, VerilatedVcdC* tfp) {
    top->rst_n = 0;
    tick(top, tfp);
    tick(top, tfp);
    top->rst_n = 1;
}

// Memory responder: implements req/ack protocol for both ports.
// When mem_latency=0, behaves as zero-latency (combinational ack).
// When mem_latency>0, delays ack by N cycles, exercising the
// misalignment handler's FSM states and pipeline mem_stall paths.
//
// The master holds req until ack. For loads, rdata accompanies ack.
// Each port has independent state — they share the same BRAM.
struct MemPortState {
    uint32_t rdata;
    bool     pending;
    int      latency_count;
    uint32_t txn_addr;
    bool     txn_we;
};

static int mem_latency = 0;  // cycles between req and ack (0 = combinational)

static MemPortState imem_state = {0, false, 0, 0xFFFFFFFF, false};
static MemPortState dmem_state = {0, false, 0, 0xFFFFFFFF, false};

static void port_responder(MemPortState& state,
                           bool req, uint32_t addr, bool we,
                           uint32_t wdata, uint8_t be,
                           uint8_t& ack, uint32_t& rdata) {
    // Detect start of new transaction: req high and either not pending,
    // or address/we changed (i-port never deasserts req, so new fetches
    // are detected by address change).
    bool new_txn = req && (!state.pending || addr != state.txn_addr || we != state.txn_we);
    if (new_txn) {
        state.pending       = true;
        state.latency_count = mem_latency;
        state.txn_addr      = addr;
        state.txn_we        = we;
        if (we) {
            bram_write(addr, wdata, be);
        } else {
            state.rdata = bram_read(addr);
        }
    }

    // Drive ack after latency expires
    if (state.pending) {
        if (state.latency_count > 0) {
            state.latency_count--;
            ack = 0;
        } else {
            ack   = req;  // ack while req is held
            rdata = state.rdata;
        }
        // Clear pending if req drops (master done — d-port only)
        if (!req) state.pending = false;
    } else {
        ack = 0;
    }
}

static void imem_responder(Vkv32_core* top) {
    port_responder(imem_state,
                   top->imem_req, top->imem_addr, false,
                   0, 0xF,
                   top->imem_ack, top->imem_rdata);
    top->imem_err = 0;
}

static void dmem_responder(Vkv32_core* top) {
    port_responder(dmem_state,
                   top->dmem_req, top->dmem_addr, top->dmem_we,
                   top->dmem_wdata, top->dmem_be,
                   top->dmem_ack, top->dmem_rdata);
    top->dmem_err = 0;
}

static void load_program(const TestWord* prog, int count) {
    memset(bram, 0, sizeof(bram));
    for (int i = 0; i < count; i++) {
        bram[prog[i].addr_word] = prog[i].data;
    }
}

static uint32_t read_reg(Vkv32_core* top, int reg) {
    return top->rootp->kv32_core__DOT__u_regfile__DOT__regs[reg];
}

// Run existing hard-coded tests (register-check based)
static void run_and_check(Vkv32_core* top, VerilatedVcdC* tfp,
                          const RegCheck* checks, int max_cycles) {
    for (int i = 0; i < max_cycles; i++) {
        tick(top, tfp);
    }

    printf("\n=== Test Results ===\n");
    int pass = 0, total = 0;
    for (const RegCheck* c = checks; c->label != nullptr; c++) {
        total++;
        uint32_t val = read_reg(top, c->reg);
        if (val == c->expected) {
            pass++;
            printf("  PASS: %s = 0x%08X\n", c->label, val);
        } else {
            fail_count++;
            printf("  FAIL: %s = 0x%08X (expected 0x%08X)\n",
                   c->label, val, c->expected);
        }
    }
    printf("  %d/%d checks passed\n", pass, total);
    printf("====================\n");
}

// Run riscv-test (tohost-based pass/fail detection)
// Returns: 0=pass, 1=fail, 2=timeout
static int run_riscv_test(Vkv32_core* top, VerilatedVcdC* tfp,
                          uint32_t tohost_addr, int max_cycles) {
    bool debug_ma = (getenv("KV32_DEBUG_MA") != nullptr);
    for (int i = 0; i < max_cycles; i++) {
        tick(top, tfp);

        if (debug_ma && i >= 436 && i <= 460) {
            uint32_t w0 = bram_read(0x80002000);
            uint32_t w1 = bram_read(0x80002004);
            auto r = top->rootp;
            printf("  [%d] ma=%d we=%d dmem_addr=0x%08X dmem_be=0x%X dmem_wdata=0x%08X wd_mem=0x%08X B0=0x%08X B1=0x%08X\n",
                   i, r->kv32_core__DOT__u_mem_fe__DOT__ma_state,
                   r->kv32_core__DOT__mem_write_mem,
                   top->dmem_addr,
                   top->dmem_be,
                   top->dmem_wdata,
                   r->kv32_core__DOT__mem_wdata_mem,
                   w0, w1);
        }

        // Check tohost
        uint32_t tohost = bram_read(tohost_addr);
        if (tohost != 0) {
            if (tohost == 1) {
                printf("PASS (tohost=1) after %d cycles\n", i + 1);
                return 0;
            } else {
                int testnum = (int)(tohost >> 1);
                printf("FAIL: test %d (tohost=0x%08X) after %d cycles\n",
                       testnum, tohost, i + 1);
                fail_count++;
                return 1;
            }
        }
    }

    printf("TIMEOUT after %d cycles (tohost=0x%08X)\n",
           max_cycles, bram_read(tohost_addr));
    fail_count++;
    return 2;
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    bool        trace       = true;
    int         test_id     = 0;          // 0=alu, 1=subword
    const char* binary_path = nullptr;
    int         max_cycles  = 50000;      // Default timeout for riscv-tests
    uint32_t    tohost_addr = 0x80001000; // Standard riscv-tests tohost
    bool        tohost_set  = false;      // User override via --tohost

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--notrace") == 0) {
            trace = false;
        } else if (strcmp(argv[i], "--test") == 0 && i + 1 < argc) {
            i++;
            if (strcmp(argv[i], "alu") == 0 || strcmp(argv[i], "0") == 0)
                test_id = 0;
            else if (strcmp(argv[i], "subword") == 0 || strcmp(argv[i], "1") == 0)
                test_id = 1;
            else {
                fprintf(stderr, "Unknown test: %s\n", argv[i]);
                return EXIT_FAILURE;
            }
        } else if (strcmp(argv[i], "--binary") == 0 && i + 1 < argc) {
            binary_path = argv[++i];
        } else if (strcmp(argv[i], "--cycles") == 0 && i + 1 < argc) {
            max_cycles = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--tohost") == 0 && i + 1 < argc) {
            tohost_addr = (uint32_t)strtoul(argv[++i], nullptr, 0);
            tohost_set  = true;
        } else if (strcmp(argv[i], "--latency") == 0 && i + 1 < argc) {
            mem_latency = atoi(argv[++i]);
            if (mem_latency < 0) mem_latency = 0;
        }
    }

    Vkv32_core* top = new Vkv32_core;
    VerilatedVcdC* tfp = nullptr;
    if (trace) {
        mkdir("build", 0755);  // ensure build directory exists
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("build/kv32_core_tb.vcd");
    }

    // Initialize inputs
    top->clk = 0;
    top->rst_n = 0;
    top->irq_external_i = 0;
    top->irq_timer_i    = 0;
    top->irq_software_i = 0;
    top->imem_ack  = 0;
    top->imem_rdata = 0;
    top->imem_err  = 0;
    top->dmem_ack  = 0;
    top->dmem_rdata = 0;
    top->dmem_err  = 0;
    imem_state = {0, false, 0, 0xFFFFFFFF, false};
    dmem_state = {0, false, 0, 0xFFFFFFFF, false};

    if (mem_latency > 0)
        printf("Memory latency: %d cycles\n", mem_latency);

    if (binary_path) {
        // ---- riscv-tests mode ----
        bram_base  = 0x80000000;
        bram_entry = 0x80000000;

        ElfInfo elf = load_binary(binary_path);
        if (!elf.valid) {
            fprintf(stderr, "Failed to load binary: %s\n", binary_path);
            fail_count++;
        } else {
            bram_entry = elf.entry;
            if (!tohost_set && elf.tohost != 0) {
                tohost_addr = elf.tohost;
            }
            printf("Running riscv-test: %s\n", binary_path);
            printf("  Entry: 0x%08X  BRAM base: 0x%08X  tohost: 0x%08X\n",
                   elf.entry, bram_base, tohost_addr);

            reset(top, tfp);
            int rc = run_riscv_test(top, tfp, tohost_addr, max_cycles);
            (void)rc; // fail_count already updated
        }
    } else if (test_id == 0) {
        // ---- ALU test ----
        printf("Running ALU test (test 0)...\n");
        bram_base = 0;
        load_program(prog_alu, sizeof(prog_alu) / sizeof(prog_alu[0]));
        reset(top, tfp);
        run_and_check(top, tfp, check_alu, 200);
    } else if (test_id == 1) {
        // ---- Sub-word memory test ----
        printf("Running sub-word memory test (test 1)...\n");
        bram_base = 0;
        load_program(prog_subword, sizeof(prog_subword) / sizeof(prog_subword[0]));
        reset(top, tfp);
        run_and_check(top, tfp, check_subword, 400);
    }

    if (tfp) {
        tfp->close();
        delete tfp;
    }
    top->final();
    delete top;

    return fail_count ? EXIT_FAILURE : EXIT_SUCCESS;
}
