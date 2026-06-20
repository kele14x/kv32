module kv32_decoder
  import kv32_pkg::*;
(
    input logic [31:0] instr,

    // Decoded fields
    output logic [ 4:0] rd,
    output logic [ 2:0] funct3,
    output logic [ 4:0] rs1,
    output logic [ 4:0] rs2,
    output logic [31:0] imm,

    // Control signals
    output logic       use_imm,       // 1 = use immediate, 0 = use rs2
    output logic       alu_op_valid,  // ALU operation is valid
    output logic [3:0] alu_op,        // ALU operation code
    output logic       mem_read,      // Memory read
    output logic       mem_write,     // Memory write
    output logic       reg_write,     // Register writeback
    output logic       branch,        // Branch instruction
    output logic       jump,          // Jump instruction (JAL/JALR)
    output logic       is_jalr,       // JALR instruction (distinguishes from JAL)
    output logic       illegal,       // Illegal instruction
    output logic       lui,           // LUI instruction
    output logic       auipc,         // AUIPC instruction

    // CSR / System control signals
    output csr_op_t csr_op,    // CSR operation type
    output logic    csr_wen,   // CSR write enable
    output logic    is_csr,    // CSR instruction (rd gets CSR read value)
    output logic    is_mret,   // MRET instruction
    output logic    use_zimm,  // Use zimm instead of rs1 (CSR immediate variants)
    output logic    is_ecall,  // ECALL instruction
    output logic    is_ebreak  // EBREAK instruction
);

  // RV32I opcodes
  localparam logic [6:0] OpLui      = 7'b0110111,
                           OpAuipc    = 7'b0010111,
                           OpJal      = 7'b1101111,
                           OpJalr     = 7'b1100111,
                           OpBranch   = 7'b1100011,
                           OpLoad     = 7'b0000011,
                           OpStore    = 7'b0100011,
                           OpImm      = 7'b0010011,
                           OpReg      = 7'b0110011,
                           OpMiscMem = 7'b0001111,
                           OpSystem   = 7'b1110011;

  // Extract fields
  logic [6:0] opcode;
  logic [6:0] funct7;

  assign opcode = instr[6:0];
  assign funct7 = instr[31:25];
  assign rd     = instr[11:7];
  assign funct3 = instr[14:12];
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];

  // Immediate generation
  always_comb begin
    imm = 32'h0;

    unique case (opcode)
      OpLui, OpAuipc: begin
        // U-type
        imm = {instr[31:12], 12'h0};
      end

      OpJal: begin
        // J-type
        imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
      end

      OpBranch: begin
        // B-type
        imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      end

      OpLoad, OpJalr, OpImm: begin
        // I-type
        imm = {{21{instr[31]}}, instr[30:20]};
      end

      OpStore: begin
        // S-type
        imm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
      end

      default: imm = 32'h0;
    endcase
  end

  // Control signals and ALU operation
  always_comb begin
    use_imm      = 1'b0;
    alu_op_valid = 1'b0;
    alu_op       = 4'h0;
    mem_read     = 1'b0;
    mem_write    = 1'b0;
    reg_write    = 1'b0;
    branch       = 1'b0;
    jump         = 1'b0;
    is_jalr      = 1'b0;
    illegal      = 1'b0;
    lui          = 1'b0;
    auipc        = 1'b0;
    csr_op       = CSR_OP_NONE;
    csr_wen      = 1'b0;
    is_csr       = 1'b0;
    is_mret      = 1'b0;
    use_zimm     = 1'b0;
    is_ecall     = 1'b0;
    is_ebreak    = 1'b0;

    unique case (opcode)
      OpLui: begin
        reg_write = 1'b1;
        lui       = 1'b1;
      end

      OpAuipc: begin
        use_imm      = 1'b1;
        alu_op_valid = 1'b1;
        alu_op       = AluAdd;
        reg_write    = 1'b1;
        auipc        = 1'b1;
      end

      OpJal: begin
        jump      = 1'b1;
        reg_write = 1'b1;
      end

      OpJalr: begin
        use_imm   = 1'b1;
        jump      = 1'b1;
        is_jalr   = 1'b1;
        reg_write = 1'b1;
        // JALR requires funct3=000; any other value is illegal.
        if (funct3 != 3'b000) illegal = 1'b1;
      end

      OpBranch: begin
        branch = 1'b1;
        // Valid funct3: BEQ=000, BNE=001, BLT=100, BGE=101,
        // BLTU=110, BGEU=111. funct3 010/011 are reserved.
        unique case (funct3)
          3'b010, 3'b011: illegal = 1'b1;
          default: ;  // 000,001,100,101,110,111 valid
        endcase
      end

      OpLoad: begin
        use_imm      = 1'b1;
        alu_op_valid = 1'b1;
        alu_op       = AluAdd;
        mem_read     = 1'b1;
        reg_write    = 1'b1;
        // Valid funct3: LB=000, LH=001, LW=010, LBU=100, LHU=101.
        // 011/110/111 are not defined in RV32I.
        unique case (funct3)
          3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;  // valid
          default: illegal = 1'b1;
        endcase
      end

      OpStore: begin
        use_imm      = 1'b1;
        alu_op_valid = 1'b1;
        alu_op       = AluAdd;
        mem_write    = 1'b1;
        // Valid funct3: SB=000, SH=001, SW=010. Others illegal.
        unique case (funct3)
          3'b000, 3'b001, 3'b010: ;  // valid
          default: illegal = 1'b1;
        endcase
      end

      OpImm: begin
        use_imm      = 1'b1;
        alu_op_valid = 1'b1;
        reg_write    = 1'b1;

        unique case (funct3)
          3'b000:  alu_op = AluAdd;  // ADDI
          3'b001:  alu_op = AluSll;  // SLLI
          3'b010:  alu_op = AluSlt;  // SLTI
          3'b011:  alu_op = AluSltu;  // SLTIU
          3'b100:  alu_op = AluXor;  // XORI
          3'b101: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluSrl;  // SRLI
            end else if (funct7 == 7'b0100000) begin
              alu_op = AluSra;  // SRAI
            end else begin
              illegal = 1'b1;
            end
          end
          3'b110:  alu_op = AluOr;  // ORI
          3'b111:  alu_op = AluAnd;  // ANDI
          default: illegal = 1'b1;
        endcase
      end

      OpReg: begin
        alu_op_valid = 1'b1;
        reg_write    = 1'b1;

        unique case (funct3)
          3'b000: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluAdd;  // ADD
            end else if (funct7 == 7'b0100000) begin
              alu_op = AluSub;  // SUB
            end else begin
              illegal = 1'b1;
            end
          end
          3'b001: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluSll;  // SLL
            end else begin
              illegal = 1'b1;
            end
          end
          3'b010: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluSlt;  // SLT
            end else begin
              illegal = 1'b1;
            end
          end
          3'b011: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluSltu;  // SLTU
            end else begin
              illegal = 1'b1;
            end
          end
          3'b100: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluXor;  // XOR
            end else begin
              illegal = 1'b1;
            end
          end
          3'b101: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluSrl;  // SRL
            end else if (funct7 == 7'b0100000) begin
              alu_op = AluSra;  // SRA
            end else begin
              illegal = 1'b1;
            end
          end
          3'b110: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluOr;  // OR
            end else begin
              illegal = 1'b1;
            end
          end
          3'b111: begin
            if (funct7 == 7'b0000000) begin
              alu_op = AluAnd;  // AND
            end else begin
              illegal = 1'b1;
            end
          end
          default: illegal = 1'b1;
        endcase
      end

      OpMiscMem: begin
        // FENCE (funct3=000) and FENCE.I (funct3=001) are treated as
        // NOPs in this in-order single-hart pipeline (no separate
        // I-cache to synchronize against the unified BRAM in
        // simulation). Any other funct3 is not a valid MISC-MEM
        // instruction.
        unique case (funct3)
          3'b000, 3'b001: ;  // FENCE, FENCE.I — NOP
          default: illegal = 1'b1;
        endcase
      end

      OpSystem: begin
        unique case (funct3)
          3'b001: begin  // CSRRW
            csr_op    = CSR_OP_WRITE;
            csr_wen   = 1'b1;
            is_csr    = 1'b1;
            reg_write = 1'b1;
          end
          3'b010: begin  // CSRRS
            csr_op    = CSR_OP_SET;
            // Suppress write when rs1==x0: per spec, CSRRS with
            // rs1=x0 is a pure read (no side effects).
            csr_wen   = (rs1 != 5'h0);
            is_csr    = 1'b1;
            reg_write = 1'b1;
          end
          3'b011: begin  // CSRRC
            csr_op    = CSR_OP_CLEAR;
            // Suppress write when rs1==x0: per spec, CSRRC with
            // rs1=x0 is a pure read (no side effects).
            csr_wen   = (rs1 != 5'h0);
            is_csr    = 1'b1;
            reg_write = 1'b1;
          end
          3'b101: begin  // CSRRWI
            csr_op    = CSR_OP_WRITE;
            csr_wen   = 1'b1;
            is_csr    = 1'b1;
            use_zimm  = 1'b1;
            reg_write = 1'b1;
          end
          3'b110: begin  // CSRRSI
            csr_op    = CSR_OP_SET;
            // Same zero-suppress as CSRRS, but the rs1 field
            // holds a 5-bit zimm. zimm==0 makes set a no-op,
            // so suppressing the write is equivalent and
            // avoids a spurious CSR write cycle.
            csr_wen   = (instr[19:15] != 5'h0);
            is_csr    = 1'b1;
            use_zimm  = 1'b1;
            reg_write = 1'b1;
          end
          3'b111: begin  // CSRRCI
            csr_op    = CSR_OP_CLEAR;
            // Same zero-suppress as CSRRC, but the rs1 field
            // holds a 5-bit zimm. zimm==0 makes clear a no-op,
            // so suppressing the write is equivalent and
            // avoids a spurious CSR write cycle.
            csr_wen   = (instr[19:15] != 5'h0);
            is_csr    = 1'b1;
            use_zimm  = 1'b1;
            reg_write = 1'b1;
          end
          3'b000: begin
            // System instructions (ECALL/EBREAK/MRET)
            unique case (instr[31:20])
              12'h000: is_ecall = 1'b1;
              12'h001: is_ebreak = 1'b1;
              12'h302: is_mret = 1'b1;
              default: illegal = 1'b1;
            endcase
          end
          default: illegal = 1'b1;
        endcase
      end

      default: begin
        illegal = 1'b1;
      end
    endcase
  end

endmodule
