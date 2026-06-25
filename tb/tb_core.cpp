#include "Vtb_core.h"
#include "Vtb_core___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <random>
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
// Integration memory backdoor helpers
// ============================================================================

static const int BRAM_WORDS = 16384; // 64 KiB / 4

static int mem_index(const Vtb_core* top, uint32_t addr) {
    if (addr < top->mem_base_i) return -1;
    uint32_t off = addr - top->mem_base_i;
    return (int)((off >> 2) & (BRAM_WORDS - 1));
}

static void mem_clear(Vtb_core* top) {
    auto root = top->rootp;
    for (int i = 0; i < BRAM_WORDS; i++) {
        root->tb_core__DOT__u_mem__DOT__mem[i] = 0;
    }
}

static void mem_write_word(Vtb_core* top, uint32_t addr, uint32_t data) {
    const int idx = mem_index(top, addr);
    if (idx < 0) return;
    top->rootp->tb_core__DOT__u_mem__DOT__mem[idx] = data;
}

static void mem_write_byte(Vtb_core* top, uint32_t addr, uint8_t data) {
    const int idx = mem_index(top, addr);
    if (idx < 0) return;

    auto root = top->rootp;
    uint32_t word = root->tb_core__DOT__u_mem__DOT__mem[idx];
    const uint32_t shift = (addr & 3u) * 8u;
    word = (word & ~(0xFFu << shift)) | ((uint32_t)data << shift);
    root->tb_core__DOT__u_mem__DOT__mem[idx] = word;
}

static uint32_t mem_read_word(Vtb_core* top, uint32_t addr) {
    if (top->mem_base_i != 0 && addr < top->mem_base_i) {
        const uint32_t word_index = addr >> 2;
        if (word_index == 0) {
            const uint32_t upper = (top->entry_addr_i + 0x800u) >> 12;
            return (upper << 12) | (5u << 7) | 0x37u;
        }
        if (word_index == 1) {
            return ((top->entry_addr_i & 0xFFFu) << 20) | (5u << 15) | 0x67u;
        }
        return 0x00000013u;
    }

    const int idx = mem_index(top, addr);
    if (idx < 0) return 0;
    return top->rootp->tb_core__DOT__u_mem__DOT__mem[idx];
}

// ============================================================================
// ELF Loader — parse ELF32, load PT_LOAD segments into BRAM
// ============================================================================
static ElfInfo load_elf(Vtb_core* top, const char* path) {
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
            mem_write_byte(top, p_vaddr + j, buf[p_offset + j]);
        }
        // Zero-fill BSS
        for (uint32_t j = p_filesz; j < p_memsz; j++) {
            mem_write_byte(top, p_vaddr + j, 0);
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
// Flat binary loader (fallback, loads at mem_base_i)
// ============================================================================
static bool load_flat_binary(Vtb_core* top, const char* path) {
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
            mem_write_byte(top, top->mem_base_i + offset + (uint32_t)i, rbuf[i]);
        }
        offset += (uint32_t)n;
    }
    fclose(f);
    printf("Loaded flat binary: %u bytes at 0x%08X\n", offset, top->mem_base_i);
    return true;
}

// Smart loader: detects ELF by magic, falls back to flat binary
static ElfInfo load_binary(Vtb_core* top, const char* path) {
    mem_clear(top);

    // Peek at first 4 bytes to detect ELF
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: cannot open %s\n", path);
        return {0, 0, false};
    }
    uint8_t magic[4];
    size_t n = fread(magic, 1, 4, f);
    fclose(f);

    if (n >= 4 && magic[0] == 0x7F && magic[1] == 'E' &&
        magic[2] == 'L'  && magic[3] == 'F') {
        return load_elf(top, path);
    }

    // Flat binary — entry is mem_base_i, no tohost
    if (load_flat_binary(top, path)) {
        return {top->mem_base_i, 0, true};
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

static void tick(Vtb_core* top, VerilatedVcdC* tfp) {
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time += 5;

    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time += 5;
}

static void reset(Vtb_core* top, VerilatedVcdC* tfp) {
    top->rst_n = 0;
    tick(top, tfp);
    tick(top, tfp);
    top->rst_n = 1;
}
static void load_program(Vtb_core* top, const TestWord* prog, int count) {
    mem_clear(top);
    for (int i = 0; i < count; i++) {
        mem_write_word(top, (uint32_t)prog[i].addr_word << 2, prog[i].data);
    }
}

static uint32_t read_reg(Vtb_core* top, int reg) {
    return top->rootp->tb_core__DOT__u_core__DOT__u_regfile__DOT__regs[reg];
}

// Run existing hard-coded tests (register-check based)
static void run_and_check(Vtb_core* top, VerilatedVcdC* tfp,
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
static int run_riscv_test(Vtb_core* top, VerilatedVcdC* tfp,
                          uint32_t tohost_addr, int max_cycles) {
    bool debug_ma = (getenv("KV32_DEBUG_MA") != nullptr);
    for (int i = 0; i < max_cycles; i++) {
        tick(top, tfp);

        if (debug_ma && i >= 436 && i <= 460) {
            uint32_t w0 = mem_read_word(top, 0x80002000);
            uint32_t w1 = mem_read_word(top, 0x80002004);
            auto r = top->rootp;
            printf("  [%d] ma=%d we=%d dmem_addr=0x%08X dmem_be=0x%X dmem_wdata=0x%08X wd_mem=0x%08X B0=0x%08X B1=0x%08X\n",
                   i, r->tb_core__DOT__u_core__DOT__u_mem_fe__DOT__ma_state,
                   r->tb_core__DOT__u_core__DOT__mem_write_mem,
                   r->tb_core__DOT__dmem_addr,
                   r->tb_core__DOT__dmem_be,
                   r->tb_core__DOT__dmem_wdata,
                   r->tb_core__DOT__u_core__DOT__mem_wdata_mem,
                   w0, w1);
        }

        // Check tohost
        uint32_t tohost = top->tohost_word_o;
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
           max_cycles, top->tohost_word_o);
    fail_count++;
    return 2;
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    bool        trace               = true;
    int         test_id             = 0;          // 0=alu, 1=subword
    const char* binary_path         = nullptr;
    int         max_cycles          = 50000;      // Default timeout for riscv-tests
    uint32_t    tohost_addr         = 0x80001000; // Standard riscv-tests tohost
    bool        tohost_set          = false;      // User override via --tohost
    uint32_t    imem_fixed_latency  = 1;
    uint32_t    dmem_fixed_latency  = 1;
    bool        imem_random_latency = false;
    bool        dmem_random_latency = false;

    auto parse_latency = [](const char* arg) {
        int latency = atoi(arg);
        return (latency < 0) ? 0 : latency;
    };

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
            const int latency = parse_latency(argv[++i]);
            imem_fixed_latency = latency;
            dmem_fixed_latency = latency;
        } else if (strcmp(argv[i], "--random-latency") == 0) {
            imem_random_latency = true;
            dmem_random_latency = true;
        } else if (strcmp(argv[i], "--imem-latency") == 0 && i + 1 < argc) {
            imem_fixed_latency = parse_latency(argv[++i]);
        } else if (strcmp(argv[i], "--dmem-latency") == 0 && i + 1 < argc) {
            dmem_fixed_latency = parse_latency(argv[++i]);
        } else if (strcmp(argv[i], "--imem-random-latency") == 0) {
            imem_random_latency = true;
        } else if (strcmp(argv[i], "--dmem-random-latency") == 0) {
            dmem_random_latency = true;
        }
    }

    Vtb_core* top = new Vtb_core;
    VerilatedVcdC* tfp = nullptr;
    if (trace) {
        mkdir("build", 0755);  // ensure build directory exists
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("build/tb_core.vcd");
    }

    // Initialize inputs
    top->clk = 0;
    top->rst_n = 0;
    top->irq_external_i = 0;
    top->irq_timer_i    = 0;
    top->irq_software_i = 0;
    top->imem_fixed_latency_i  = imem_fixed_latency;
    top->imem_random_latency_i = imem_random_latency;
    top->dmem_fixed_latency_i  = dmem_fixed_latency;
    top->dmem_random_latency_i = dmem_random_latency;
    top->mem_base_i            = 0;
    top->entry_addr_i          = 0;
    top->tohost_addr_i         = tohost_addr;

    auto print_latency_cfg = [](const char* name, uint32_t fixed_latency, bool random_enabled) {
        if (random_enabled) {
            printf("%s latency: random stress mode (90%% 1-3 cycles, 10%% 4-10 cycles)\n",
                   name);
        } else {
            printf("%s latency: fixed %d cycle%s\n",
                   name, fixed_latency, (fixed_latency == 1) ? "" : "s");
        }
    };
    print_latency_cfg("IMEM", imem_fixed_latency, imem_random_latency);
    print_latency_cfg("DMEM", dmem_fixed_latency, dmem_random_latency);

    if (binary_path) {
        // ---- riscv-tests mode ----
        top->mem_base_i = 0x80000000;
        top->entry_addr_i = 0x80000000;

        ElfInfo elf = load_binary(top, binary_path);
        if (!elf.valid) {
            fprintf(stderr, "Failed to load binary: %s\n", binary_path);
            fail_count++;
        } else {
            top->entry_addr_i = elf.entry;
            if (!tohost_set && elf.tohost != 0) {
                tohost_addr = elf.tohost;
                top->tohost_addr_i = tohost_addr;
            }
            printf("Running riscv-test: %s\n", binary_path);
            printf("  Entry: 0x%08X  BRAM base: 0x%08X  tohost: 0x%08X\n",
                   elf.entry, top->mem_base_i, tohost_addr);

            reset(top, tfp);
            int rc = run_riscv_test(top, tfp, tohost_addr, max_cycles);
            (void)rc; // fail_count already updated
        }
    } else if (test_id == 0) {
        // ---- ALU test ----
        printf("Running ALU test (test 0)...\n");
        top->mem_base_i = 0;
        top->entry_addr_i = 0;
        load_program(top, prog_alu, sizeof(prog_alu) / sizeof(prog_alu[0]));
        reset(top, tfp);
        run_and_check(top, tfp, check_alu, 200);
    } else if (test_id == 1) {
        // ---- Sub-word memory test ----
        printf("Running sub-word memory test (test 1)...\n");
        top->mem_base_i = 0;
        top->entry_addr_i = 0;
        load_program(top, prog_subword, sizeof(prog_subword) / sizeof(prog_subword[0]));
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
