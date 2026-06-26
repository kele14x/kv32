// kv32_decompressor.sv — RISC-V C extension (RV32C) decompressor
// Expands 16-bit compressed instructions to their 32-bit equivalents.
// Purely combinational — sits between fetch and decoder in kv32_core.
//
// Reference: RISC-V ISA Spec v20191213, Chapter 16 (Compressed Instructions).
// RV32-specific: C.JAL replaces C.ADDIW; C.FLW/C.FSW replace C.LD/C.SD;
// C.FLWSP/C.FSWSP replace C.LDSP/C.SDSP.

module kv32_decompressor (
    input  logic [15:0] instr,     // 16-bit compressed instruction
    output logic [31:0] expanded,  // 32-bit equivalent instruction
    output logic        illegal    // 1 if encoding is reserved/unimplemented
);

  // -------------------------------------------------------------------------
  // Opcode constants (32-bit instruction opcodes)
  // -------------------------------------------------------------------------
  localparam logic [6:0] OP_LUI = 7'b0110111;
  localparam logic [6:0] OP_JAL = 7'b1101111;
  localparam logic [6:0] OP_JALR = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD = 7'b0000011;
  localparam logic [6:0] OP_STORE = 7'b0100011;
  localparam logic [6:0] OP_IMM = 7'b0010011;
  localparam logic [6:0] OP_REG = 7'b0110011;

  // -------------------------------------------------------------------------
  // Register field extraction
  // -------------------------------------------------------------------------
  // 3-bit compressed register fields map to x8-x15
  logic [4:0] rd_prime;
  logic [4:0] rs1_prime;
  logic [4:0] rs2_prime;
  logic [4:0] rd_full;
  logic [4:0] rs2_full;

  assign rd_prime  = {2'b01, instr[4:2]};
  assign rs1_prime = {2'b01, instr[9:7]};
  assign rs2_prime = {2'b01, instr[4:2]};
  assign rd_full   = instr[11:7];
  assign rs2_full  = instr[6:2];

  // -------------------------------------------------------------------------
  // Main decode logic — constructs 32-bit instruction inline
  // -------------------------------------------------------------------------

  always_comb begin
    expanded = 32'h0;
    illegal  = 1'b0;

    unique case (instr[1:0])
      // =====================================================================
      // Quadrant 0 (bits[1:0] = 00)
      // =====================================================================
      2'b00: begin
        unique case (instr[15:13])
          3'b000: begin
            // C.ADDI4SPN: addi rd', x2, nzuimm
            // nzuimm[5:4|9:6|2|3] = instr[12:5]
            // I-type imm[11:0] = {2'b00, instr[10:7], instr[12:11], instr[5], instr[6], 2'b00}
            if (instr[12:5] == 8'b0) begin
              illegal = 1'b1;
            end else begin
              expanded = {
                2'b00,
                instr[10:7],
                instr[12:11],
                instr[5],
                instr[6],
                2'b00,
                5'd2,
                3'b000,
                rd_prime,
                OP_IMM
              };
            end
          end

          3'b001: begin
            // C.FLD — RV64 only, illegal in RV32
            illegal = 1'b1;
          end

          3'b010: begin
            // C.LW: lw rd', offset(rs1')
            // offset[5|3|2|6|4] = instr[12:10|6|5]
            // I-type imm[11:0] = {5'b0, instr[5], instr[12:10], instr[6], 2'b00}
            expanded = {
              5'b00000,
              instr[5],
              instr[12:10],
              instr[6],
              2'b00,
              rs1_prime,
              3'b010,
              rd_prime,
              OP_LOAD
            };
          end

          3'b011: begin
            // C.FLW — RV32 only (float load), but F ext not implemented
            illegal = 1'b1;
          end

          3'b100: begin
            // Reserved
            illegal = 1'b1;
          end

          3'b101: begin
            // C.FSD — RV64 only, illegal in RV32
            illegal = 1'b1;
          end

          3'b110: begin
            // C.SW: sw rs2', offset(rs1')
            // Same offset encoding as C.LW
            // S-type: imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
            // imm[11:5] = {5'b00000, instr[5], instr[12]}
            // imm[4:0] = {instr[11:10], instr[6], 2'b00}
            expanded = {
              5'b00000,
              instr[5],
              instr[12],
              rs2_prime,
              rs1_prime,
              3'b010,
              instr[11:10],
              instr[6],
              2'b00,
              OP_STORE
            };
          end

          3'b111: begin
            // C.FSW — RV32 only (float store), but F ext not implemented
            illegal = 1'b1;
          end

          default: illegal = 1'b1;
        endcase
      end

      // =====================================================================
      // Quadrant 1 (bits[1:0] = 01)
      // =====================================================================
      2'b01: begin
        unique case (instr[15:13])
          3'b000: begin
            // C.NOP (rd=0, imm=0) or C.ADDI: addi rd, rd, nzimm
            // imm[5:0] = {instr[12], instr[6:2]}, sign-extended to 12 bits
            expanded = {{7{instr[12]}}, instr[6:2], rd_full, 3'b000, rd_full, OP_IMM};
          end

          3'b001: begin
            // C.JAL (RV32 only): jal x1, offset
            // offset[11|4|9:8|10|6|7|3:1|5] = instr[12:2]
            // J-type: imm[20] | imm[10:1] | imm[11] | imm[19:12] | rd | opcode
            // imm[20] = instr[12] (sign bit)
            // imm[19:12] = {8{instr[12]}} (sign extension)
            // imm[11] = instr[12]
            // imm[10:1] = {instr[8], instr[10:9], instr[6], instr[7], instr[2], instr[11], instr[5:3]}
            expanded = {
              instr[12],
              instr[8],
              instr[10:9],
              instr[6],
              instr[7],
              instr[2],
              instr[11],
              instr[5:3],
              instr[12],
              {8{instr[12]}},
              5'd1,
              OP_JAL
            };
          end

          3'b010: begin
            // C.LI: addi rd, x0, imm
            // Same immediate as C.ADDI
            expanded = {{7{instr[12]}}, instr[6:2], 5'd0, 3'b000, rd_full, OP_IMM};
          end

          3'b011: begin
            if (rd_full == 5'd2) begin
              // C.ADDI16SP: addi x2, x2, nzimm
              // nzimm[9|4|6|8:7|5] = instr[12:2]
              // imm[11:0] = {{2{instr[12]}}, instr[12], instr[4:3], instr[5], instr[2], instr[6], 4'b0000}
              // Check nzimm == 0: all immediate bits must be zero
              if ({instr[12], instr[6], instr[5], instr[4:3], instr[2]} == 6'b0) begin
                illegal = 1'b1;
              end else begin
                expanded = {
                  {2{instr[12]}},
                  instr[12],
                  instr[4:3],
                  instr[5],
                  instr[2],
                  instr[6],
                  4'b0000,
                  5'd2,
                  3'b000,
                  5'd2,
                  OP_IMM
                };
              end
            end else if (rd_full == 5'd0) begin
              // C.LUI with rd=0 is reserved (HINT)
              illegal = 1'b1;
            end else begin
              // C.LUI: lui rd, nzimm
              // nzimm[17|16:12] = instr[12:2]
              // U-type imm[31:12] = {{14{instr[12]}}, instr[12], instr[6:2]}
              if (instr[6:2] == 5'b0 && instr[12] == 1'b0) begin
                illegal = 1'b1;  // nzimm = 0 is reserved
              end else begin
                expanded = {{14{instr[12]}}, instr[12], instr[6:2], rd_full, OP_LUI};
              end
            end
          end

          3'b100: begin
            unique case (instr[11:10])
              2'b00: begin
                // C.SRLI: srli rd', rd', shamt
                // shamt = {instr[12], instr[6:2]}
                if (instr[12] == 1'b1) begin
                  illegal = 1'b1;  // RV32: shamt[5] must be 0
                end else begin
                  expanded = {7'b0000000, instr[6:2], rs1_prime, 3'b101, rs1_prime, OP_IMM};
                end
              end

              2'b01: begin
                // C.SRAI: srai rd', rd', shamt
                if (instr[12] == 1'b1) begin
                  illegal = 1'b1;
                end else begin
                  expanded = {7'b0100000, instr[6:2], rs1_prime, 3'b101, rs1_prime, OP_IMM};
                end
              end

              2'b10: begin
                // C.ANDI: andi rd', rd', imm
                // imm = sign-extended from {instr[12], instr[6:2]}
                expanded = {{7{instr[12]}}, instr[6:2], rs1_prime, 3'b111, rs1_prime, OP_IMM};
              end

              2'b11: begin
                unique case ({
                  instr[12], instr[6:5]
                })
                  3'b000: begin
                    // C.SUB: sub rd', rd', rs2'
                    expanded = {7'b0100000, rs2_prime, rs1_prime, 3'b000, rs1_prime, OP_REG};
                  end

                  3'b001: begin
                    // C.XOR: xor rd', rd', rs2'
                    expanded = {7'b0000000, rs2_prime, rs1_prime, 3'b100, rs1_prime, OP_REG};
                  end

                  3'b010: begin
                    // C.OR: or rd', rd', rs2'
                    expanded = {7'b0000000, rs2_prime, rs1_prime, 3'b110, rs1_prime, OP_REG};
                  end

                  3'b011: begin
                    // C.AND: and rd', rd', rs2'
                    expanded = {7'b0000000, rs2_prime, rs1_prime, 3'b111, rs1_prime, OP_REG};
                  end

                  default: begin
                    // C.SUBW/C.ADDW/etc. — RV64 only
                    illegal = 1'b1;
                  end
                endcase
              end

              default: illegal = 1'b1;
            endcase
          end

          3'b101: begin
            // C.J: jal x0, offset
            // Same offset encoding as C.JAL but rd=x0
            expanded = {
              instr[12],
              instr[8],
              instr[10:9],
              instr[6],
              instr[7],
              instr[2],
              instr[11],
              instr[5:3],
              instr[12],
              {8{instr[12]}},
              5'd0,
              OP_JAL
            };
          end

          3'b110: begin
            // C.BEQZ: beq rs1', x0, offset
            // offset[8|4:3|7:6|2:1|5] = instr[12|11:10|6:5|4:3|2]
            // B-type: imm[12] | imm[10:5] | rs2 | rs1 | funct3 | imm[4:1] | imm[11] | opcode
            // imm[12] = instr[12] (sign bit)
            // imm[11] = instr[12] (sign extension)
            // imm[10:9] = {2{instr[12]}} (sign extension)
            // imm[8] = instr[12]
            // imm[7:6] = instr[6:5]
            // imm[5] = instr[2]
            // imm[4:3] = instr[11:10]
            // imm[2:1] = instr[4:3]
            expanded = {
              instr[12],
              {3{instr[12]}},
              instr[6],
              instr[5],
              instr[2],
              5'd0,
              rs1_prime,
              3'b000,
              instr[11:10],
              instr[4:3],
              instr[12],
              OP_BRANCH
            };
          end

          3'b111: begin
            // C.BNEZ: bne rs1', x0, offset
            // Same offset encoding as C.BEQZ but funct3=001
            expanded = {
              instr[12],
              {3{instr[12]}},
              instr[6],
              instr[5],
              instr[2],
              5'd0,
              rs1_prime,
              3'b001,
              instr[11:10],
              instr[4:3],
              instr[12],
              OP_BRANCH
            };
          end

          default: illegal = 1'b1;
        endcase
      end

      // =====================================================================
      // Quadrant 2 (bits[1:0] = 10)
      // =====================================================================
      2'b10: begin
        unique case (instr[15:13])
          3'b000: begin
            // C.SLLI: slli rd, rd, shamt
            // shamt = {instr[12], instr[6:2]}
            if (instr[12] == 1'b1) begin
              illegal = 1'b1;  // RV32: shamt[5] must be 0
            end else if (rd_full == 5'd0) begin
              illegal = 1'b1;  // rd=0 is reserved (HINT)
            end else begin
              expanded = {7'b0000000, instr[6:2], rd_full, 3'b001, rd_full, OP_IMM};
            end
          end

          3'b001: begin
            // C.FLDSP — RV64 only, illegal in RV32
            illegal = 1'b1;
          end

          3'b010: begin
            // C.LWSP: lw rd, offset(x2)
            // offset[5|4:2|7:6] = instr[12:2]
            // I-type imm[11:0] = {4'b0000, instr[3:2], instr[12], instr[6:4], 2'b00}
            if (rd_full == 5'd0) begin
              illegal = 1'b1;  // rd=0 is reserved
            end else begin
              expanded = {
                4'b0000, instr[3:2], instr[12], instr[6:4], 2'b00, 5'd2, 3'b010, rd_full, OP_LOAD
              };
            end
          end

          3'b011: begin
            // C.FLWSP — RV32 only (float load), but F ext not implemented
            illegal = 1'b1;
          end

          3'b100: begin
            if (instr[12] == 1'b0) begin
              if (rs2_full == 5'd0) begin
                // C.JR: jalr x0, rs1, 0
                if (rd_full == 5'd0) begin
                  illegal = 1'b1;  // rs1=0 is reserved
                end else begin
                  expanded = {12'b0, rd_full, 3'b000, 5'd0, OP_JALR};
                end
              end else begin
                // C.MV: add rd, x0, rs2
                expanded = {7'b0000000, rs2_full, 5'd0, 3'b000, rd_full, OP_REG};
              end
            end else begin
              if (rs2_full == 5'd0) begin
                if (rd_full == 5'd0) begin
                  // C.EBREAK: ebreak
                  expanded = 32'h00100073;
                end else begin
                  // C.JALR: jalr x1, rs1, 0
                  expanded = {12'b0, rd_full, 3'b000, 5'd1, OP_JALR};
                end
              end else begin
                // C.ADD: add rd, rd, rs2
                expanded = {7'b0000000, rs2_full, rd_full, 3'b000, rd_full, OP_REG};
              end
            end
          end

          3'b101: begin
            // C.FSDSP — RV64 only, illegal in RV32
            illegal = 1'b1;
          end

          3'b110: begin
            // C.SWSP: sw rs2, offset(x2)
            // offset[5:2|7:6] = instr[12:7]
            // S-type: imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
            // imm[11:5] = {4'b0000, instr[8], instr[7], instr[12]}
            // imm[4:0] = {instr[11], instr[10], instr[9], 2'b00}
            expanded = {
              4'b0000,
              instr[8],
              instr[7],
              instr[12],
              rs2_full,
              5'd2,
              3'b010,
              instr[11:9],
              2'b00,
              OP_STORE
            };
          end

          3'b111: begin
            // C.FSWSP — RV32 only (float store), but F ext not implemented
            illegal = 1'b1;
          end

          default: illegal = 1'b1;
        endcase
      end

      // =====================================================================
      // Quadrant 3 (bits[1:0] = 11) — not a compressed instruction
      // =====================================================================
      2'b11: begin
        illegal = 1'b1;
      end

      default: illegal = 1'b1;
    endcase
  end

endmodule
