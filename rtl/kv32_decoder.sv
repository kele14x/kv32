module kv32_decoder (
    input  logic [31:0] instr,

    // Decoded fields
    output logic [ 4:0] rd,
    output logic [ 2:0] funct3,
    output logic [ 4:0] rs1,
    output logic [ 4:0] rs2,
    output logic [31:0] imm,

    // Control signals
    output logic        use_imm,      // 1 = use immediate, 0 = use rs2
    output logic        alu_op_valid, // ALU operation is valid
    output logic [ 3:0] alu_op,       // ALU operation code
    output logic        mem_read,     // Memory read
    output logic        mem_write,    // Memory write
    output logic        reg_write,    // Register writeback
    output logic        branch,       // Branch instruction
    output logic        jump,         // Jump instruction (JAL/JALR)
    output logic        illegal,      // Illegal instruction
    output logic        lui,          // LUI instruction
    output logic        auipc         // AUIPC instruction
);

    // RV32I opcodes
    localparam logic [6:0] OP_LUI    = 7'b0110111,
                           OP_AUIPC  = 7'b0010111,
                           OP_JAL    = 7'b1101111,
                           OP_JALR   = 7'b1100111,
                           OP_BRANCH = 7'b1100011,
                           OP_LOAD   = 7'b0000011,
                           OP_STORE  = 7'b0100011,
                           OP_IMM    = 7'b0010011,
                           OP_REG    = 7'b0110011,
                           OP_SYSTEM = 7'b1110011;

    // ALU operations
    localparam logic [3:0] ALU_ADD  = 4'h0,
                           ALU_SUB  = 4'h1,
                           ALU_SLL  = 4'h2,
                           ALU_SLT  = 4'h3,
                           ALU_SLTU = 4'h4,
                           ALU_XOR  = 4'h5,
                           ALU_SRL  = 4'h6,
                           ALU_SRA  = 4'h7,
                           ALU_OR   = 4'h8,
                           ALU_AND  = 4'h9;

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
            OP_LUI, OP_AUIPC: begin
                // U-type
                imm = {instr[31:12], 12'h0};
            end

            OP_JAL: begin
                // J-type
                imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
            end

            OP_BRANCH: begin
                // B-type
                imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
            end

            OP_LOAD, OP_JALR, OP_IMM: begin
                // I-type
                imm = {{21{instr[31]}}, instr[30:20]};
            end

            OP_STORE: begin
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
        illegal      = 1'b0;
        lui          = 1'b0;
        auipc        = 1'b0;

        unique case (opcode)
            OP_LUI: begin
                reg_write = 1'b1;
                lui       = 1'b1;
            end

            OP_AUIPC: begin
                use_imm      = 1'b1;
                alu_op_valid = 1'b1;
                alu_op       = ALU_ADD;
                reg_write    = 1'b1;
                auipc        = 1'b1;
            end

            OP_JAL: begin
                jump      = 1'b1;
                reg_write = 1'b1;
            end

            OP_JALR: begin
                use_imm = 1'b1;
                jump    = 1'b1;
                reg_write = 1'b1;
            end

            OP_BRANCH: begin
                branch = 1'b1;
            end

            OP_LOAD: begin
                use_imm      = 1'b1;
                alu_op_valid = 1'b1;
                alu_op       = ALU_ADD;
                mem_read     = 1'b1;
                reg_write    = 1'b1;
            end

            OP_STORE: begin
                use_imm      = 1'b1;
                alu_op_valid = 1'b1;
                alu_op       = ALU_ADD;
                mem_write    = 1'b1;
            end

            OP_IMM: begin
                use_imm      = 1'b1;
                alu_op_valid = 1'b1;
                reg_write    = 1'b1;

                unique case (funct3)
                    3'b000: alu_op = ALU_ADD;  // ADDI
                    3'b001: alu_op = ALU_SLL;  // SLLI
                    3'b010: alu_op = ALU_SLT;  // SLTI
                    3'b011: alu_op = ALU_SLTU; // SLTIU
                    3'b100: alu_op = ALU_XOR;  // XORI
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_SRL;  // SRLI
                        end else if (funct7 == 7'b0100000) begin
                            alu_op = ALU_SRA;  // SRAI
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b110: alu_op = ALU_OR;   // ORI
                    3'b111: alu_op = ALU_AND;  // ANDI
                    default: illegal = 1'b1;
                endcase
            end

            OP_REG: begin
                alu_op_valid = 1'b1;
                reg_write    = 1'b1;

                unique case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_ADD;  // ADD
                        end else if (funct7 == 7'b0100000) begin
                            alu_op = ALU_SUB;  // SUB
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b001: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_SLL;  // SLL
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b010: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_SLT;  // SLT
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b011: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_SLTU; // SLTU
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b100: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_XOR;  // XOR
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_SRL;  // SRL
                        end else if (funct7 == 7'b0100000) begin
                            alu_op = ALU_SRA;  // SRA
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b110: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_OR;   // OR
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    3'b111: begin
                        if (funct7 == 7'b0000000) begin
                            alu_op = ALU_AND;  // AND
                        end else begin
                            illegal = 1'b1;
                        end
                    end
                    default: illegal = 1'b1;
                endcase
            end

            OP_SYSTEM: begin
                // CSR instructions handled separately
                reg_write = 1'b1;
            end

            default: begin
                illegal = 1'b1;
            end
        endcase
    end

endmodule
