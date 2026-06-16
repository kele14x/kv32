module kv32_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        irq_external_i,

    // External memory interface
    output logic        mem_req,
    output logic [31:0] mem_addr,
    output logic        mem_we,
    output logic [ 1:0] mem_size,
    output logic [31:0] mem_wdata,
    output logic [ 3:0] mem_be,
    output logic        mem_excl,
    input  logic        mem_gnt,
    input  logic        mem_valid,
    input  logic [31:0] mem_rdata,
    input  logic        mem_err
);

    // Internal memory ports
    logic        i_req, d_req;
    logic [31:0] i_addr, d_addr;
    logic        d_we;
    logic [ 1:0] d_size;
    logic [31:0] d_wdata;
    logic [ 3:0] d_be;
    logic        d_excl;

    // Grant signals reserved for future pipeline optimizations
    // verilator lint_off UNUSEDSIGNAL
    logic        i_gnt, d_gnt;
    // verilator lint_on UNUSEDSIGNAL
    logic        i_valid, d_valid;
    logic [31:0] i_rdata, d_rdata;
    // Error signals reserved for exception handling (Phase 5)
    // verilator lint_off UNUSEDSIGNAL
    logic        i_err, d_err;
    // verilator lint_on UNUSEDSIGNAL

    // Memory arbiter
    kv32_mem_arbiter u_arbiter (
        .clk       (clk),
        .rst_n     (rst_n),

        .i_req     (i_req),
        .i_addr    (i_addr),
        .i_gnt     (i_gnt),
        .i_valid   (i_valid),
        .i_rdata   (i_rdata),
        .i_err     (i_err),

        .d_req     (d_req),
        .d_addr    (d_addr),
        .d_we      (d_we),
        .d_size    (d_size),
        .d_wdata   (d_wdata),
        .d_be      (d_be),
        .d_excl    (d_excl),
        .d_gnt     (d_gnt),
        .d_valid   (d_valid),
        .d_rdata   (d_rdata),
        .d_err     (d_err),

        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_we    (mem_we),
        .mem_size  (mem_size),
        .mem_wdata (mem_wdata),
        .mem_be    (mem_be),
        .mem_excl  (mem_excl),
        .mem_gnt   (mem_gnt),
        .mem_valid (mem_valid),
        .mem_rdata (mem_rdata),
        .mem_err   (mem_err)
    );

    // Pipeline registers
    // verilator lint_off UNUSEDSIGNAL
    logic [31:0] pc_if, pc_id, pc_ex, pc_mem;
    logic [31:0] instr_id, instr_ex;
    // verilator lint_on UNUSEDSIGNAL

    // Decode outputs
    logic [ 4:0] rd_id, rs1_id, rs2_id;
    logic [ 2:0] funct3_id;
    logic [31:0] imm_id;
    logic        use_imm_id, alu_op_valid_id, mem_read_id, mem_write_id;
    logic        reg_write_id, branch_id, jump_id, illegal_id;
    logic        lui_id, auipc_id;
    logic [ 3:0] alu_op_id;

    // Register file
    logic [31:0] rs1_data, rs2_data;
    logic        regfile_we;
    logic [ 4:0] regfile_rd;
    logic [31:0] regfile_wdata;

    // Decoder
    kv32_decoder u_decoder (
        .instr        (instr_id),
        .rd           (rd_id),
        .funct3       (funct3_id),
        .rs1          (rs1_id),
        .rs2          (rs2_id),
        .imm          (imm_id),
        .use_imm      (use_imm_id),
        .alu_op_valid (alu_op_valid_id),
        .alu_op       (alu_op_id),
        .mem_read     (mem_read_id),
        .mem_write    (mem_write_id),
        .reg_write    (reg_write_id),
        .branch       (branch_id),
        .jump         (jump_id),
        .illegal      (illegal_id),
        .lui          (lui_id),
        .auipc        (auipc_id)
    );

    // EX stage
    logic [ 4:0] rd_ex, rs1_ex, rs2_ex;
    logic [ 2:0] funct3_ex;

    // Register file (reads from EX stage for forwarding)
    kv32_regfile u_regfile (
        .clk      (clk),
        .rs1_addr (rs1_ex),
        .rs1_data (rs1_data),
        .rs2_addr (rs2_ex),
        .rs2_data (rs2_data),
        .we       (regfile_we),
        .rd_addr  (regfile_rd),
        .rd_data  (regfile_wdata)
    );
    logic [31:0] imm_ex;
    logic        use_imm_ex, alu_op_valid_ex, mem_read_ex, mem_write_ex;
    // illegal_ex reserved for exception handling (Phase 5)
    // verilator lint_off UNUSEDSIGNAL
    logic        reg_write_ex, branch_ex, jump_ex, illegal_ex;
    // verilator lint_on UNUSEDSIGNAL
    logic        lui_ex, auipc_ex;
    logic [ 3:0] alu_op_ex;

    logic [31:0] alu_a, alu_b, alu_result;
    logic [31:0] ex_result;
    logic [31:0] fwd_a, fwd_b;

    kv32_alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .op     (alu_op_ex),
        .result (alu_result)
    );

    // Branch comparison
    logic branch_taken;
    logic [31:0] branch_target;

    always_comb begin
        branch_taken  = 1'b0;
        branch_target = pc_ex + 4;

        if (branch_ex) begin
            unique case (funct3_ex)
                3'b000: branch_taken = (rs1_data == rs2_data);   // BEQ
                3'b001: branch_taken = (rs1_data != rs2_data);   // BNE
                3'b100: branch_taken = ($signed(rs1_data) < $signed(rs2_data));   // BLT
                3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));  // BGE
                3'b110: branch_taken = (rs1_data < rs2_data);    // BLTU
                3'b111: branch_taken = (rs1_data >= rs2_data);   // BGEU
                default: branch_taken = 1'b0;
            endcase

            if (branch_taken) begin
                branch_target = pc_ex + imm_ex;
            end
        end

        if (jump_ex) begin
            branch_taken = 1'b1;
            if (instr_ex[2]) begin // JALR
                branch_target = (rs1_data + imm_ex) & ~32'h1;
            end else begin // JAL
                branch_target = pc_ex + imm_ex;
            end
        end
    end

    // ALU input mux with forwarding
    assign alu_a = auipc_ex ? pc_ex : fwd_a;
    assign alu_b = use_imm_ex ? imm_ex : fwd_b;

    // EX result mux
    always_comb begin
        if (lui_ex) begin
            ex_result = imm_ex;
        end else if (alu_op_valid_ex || auipc_ex) begin
            ex_result = alu_result;
        end else begin
            ex_result = pc_ex + 4; // For JAL/JALR link address
        end
    end

    // MEM stage
    logic [ 4:0] rd_mem;
    logic        mem_read_mem, mem_write_mem, reg_write_mem;
    logic [31:0] mem_wdata_mem, mem_addr_mem;
    logic [ 1:0] mem_size_mem;
    logic [ 2:0] funct3_mem;
    logic [ 3:0] mem_be_mem;
    logic [31:0] mem_result;

    always_comb begin
        d_req   = mem_read_mem || mem_write_mem;
        d_addr  = mem_addr_mem;
        d_we    = mem_write_mem;
        d_size  = mem_size_mem;
        d_wdata = mem_wdata_mem;
        d_be    = mem_be_mem;
        d_excl  = 1'b0;

        // Default: ALU result for non-load instructions
        mem_result = mem_addr_mem;

        // For loads, extract and extend the correct bytes
        if (mem_read_mem && d_valid) begin
            case (funct3_mem)
                3'b000: begin // LB - load byte, sign-extend
                    case (mem_addr_mem[1:0])
                        2'b00: mem_result = {{24{d_rdata[7]}},  d_rdata[7:0]};
                        2'b01: mem_result = {{24{d_rdata[15]}}, d_rdata[15:8]};
                        2'b10: mem_result = {{24{d_rdata[23]}}, d_rdata[23:16]};
                        2'b11: mem_result = {{24{d_rdata[31]}}, d_rdata[31:24]};
                    endcase
                end
                3'b001: begin // LH - load halfword, sign-extend
                    case (mem_addr_mem[1])
                        1'b0: mem_result = {{16{d_rdata[15]}}, d_rdata[15:0]};
                        1'b1: mem_result = {{16{d_rdata[31]}}, d_rdata[31:16]};
                    endcase
                end
                3'b010: begin // LW - load word
                    mem_result = d_rdata;
                end
                3'b100: begin // LBU - load byte, zero-extend
                    case (mem_addr_mem[1:0])
                        2'b00: mem_result = {24'h0, d_rdata[7:0]};
                        2'b01: mem_result = {24'h0, d_rdata[15:8]};
                        2'b10: mem_result = {24'h0, d_rdata[23:16]};
                        2'b11: mem_result = {24'h0, d_rdata[31:24]};
                    endcase
                end
                3'b101: begin // LHU - load halfword, zero-extend
                    case (mem_addr_mem[1])
                        1'b0: mem_result = {16'h0, d_rdata[15:0]};
                        1'b1: mem_result = {16'h0, d_rdata[31:16]};
                    endcase
                end
                default: mem_result = d_rdata;
            endcase
        end
    end

    // WB stage
    logic [ 4:0] rd_wb;
    logic        reg_write_wb;
    logic [31:0] wb_data;

    assign regfile_we    = reg_write_wb;
    assign regfile_rd    = rd_wb;
    assign regfile_wdata = wb_data;

    // Forwarding unit: select forwarded values from MEM or WB stages
    always_comb begin
        // Default: use register file values
        fwd_a = rs1_data;
        fwd_b = rs2_data;

        // MEM→EX forwarding (highest priority)
        if (reg_write_mem && rd_mem != 5'h0) begin
            if (rd_mem == rs1_ex) fwd_a = mem_result;
            if (rd_mem == rs2_ex) fwd_b = mem_result;
        end

        // WB→EX forwarding (lower priority, overridden by MEM→EX)
        if (reg_write_wb && rd_wb != 5'h0) begin
            if (rd_wb == rs1_ex && !(reg_write_mem && rd_mem == rs1_ex)) begin
                fwd_a = wb_data;
            end
            if (rd_wb == rs2_ex && !(reg_write_mem && rd_mem == rs2_ex)) begin
                fwd_b = wb_data;
            end
        end
    end

    // Pipeline control
    logic if_stall, id_stall, ex_stall, mem_stall;
    logic if_flush, id_flush, ex_flush;
    logic load_use_hazard, if_wait;

    // Hazard detection: stall if EX stage has a load and ID stage uses its result
    assign load_use_hazard = mem_read_ex && rd_ex != 5'h0 &&
                            ((rd_ex == rs1_id) || (rd_ex == rs2_id));

    // IF wait: instruction fetch requested but not yet completed
    assign if_wait = i_req && !i_valid;

    // MEM stalls when waiting for data memory response
    assign mem_stall = (mem_read_mem || mem_write_mem) && !d_valid;

    // Backpressure: mem_stall propagates to all earlier stages
    assign ex_stall  = mem_stall;
    assign id_stall  = load_use_hazard || mem_stall || if_wait;
    assign if_stall  = if_wait || load_use_hazard || mem_stall;

    assign if_flush = branch_taken;
    assign id_flush = branch_taken;
    assign ex_flush = 1'b0;

    // IF stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_if <= 32'h0;
            i_req <= 1'b1;
        end else if (if_flush) begin
            pc_if <= branch_target;
            i_req <= 1'b1;
        end else if (!if_stall) begin
            pc_if <= pc_if + 4;
            i_req <= 1'b1;
        end
    end

    assign i_addr = pc_if;

    // IF/ID pipeline register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_id    <= 32'h0;
            instr_id <= 32'h00000013; // NOP (ADDI x0, x0, 0)
        end else if (id_flush) begin
            instr_id <= 32'h00000013; // NOP
        end else if (!id_stall) begin
            if (i_valid) begin
                pc_id    <= pc_if;
                instr_id <= i_rdata;
            end
        end
    end

    // ID/EX pipeline register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_ex           <= 32'h0;
            instr_ex        <= 32'h0;
            rd_ex           <= 5'h0;
            rs1_ex          <= 5'h0;
            rs2_ex          <= 5'h0;
            funct3_ex       <= 3'h0;
            imm_ex          <= 32'h0;
            use_imm_ex      <= 1'b0;
            alu_op_valid_ex <= 1'b0;
            alu_op_ex       <= 4'h0;
            mem_read_ex     <= 1'b0;
            mem_write_ex    <= 1'b0;
            reg_write_ex    <= 1'b0;
            branch_ex       <= 1'b0;
            jump_ex         <= 1'b0;
            illegal_ex      <= 1'b0;
            lui_ex          <= 1'b0;
            auipc_ex        <= 1'b0;
        end else if (ex_stall) begin
            // Backpressure from MEM stage — freeze ID/EX
        end else if (ex_flush) begin
            reg_write_ex  <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            branch_ex     <= 1'b0;
            jump_ex       <= 1'b0;
            lui_ex        <= 1'b0;
            auipc_ex      <= 1'b0;
        end else if (load_use_hazard || if_wait) begin
            // Insert bubble: load-use hazard or IF waiting for instruction
            reg_write_ex  <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            branch_ex     <= 1'b0;
            jump_ex       <= 1'b0;
            lui_ex        <= 1'b0;
            auipc_ex      <= 1'b0;
            alu_op_valid_ex <= 1'b0;
            rd_ex         <= 5'h0;
        end else begin
            pc_ex           <= pc_id;
            instr_ex        <= instr_id;
            rd_ex           <= rd_id;
            rs1_ex          <= rs1_id;
            rs2_ex          <= rs2_id;
            funct3_ex       <= funct3_id;
            imm_ex          <= imm_id;
            use_imm_ex      <= use_imm_id;
            alu_op_valid_ex <= alu_op_valid_id;
            alu_op_ex       <= alu_op_id;
            mem_read_ex     <= mem_read_id;
            mem_write_ex    <= mem_write_id;
            reg_write_ex    <= reg_write_id;
            branch_ex       <= branch_id;
            jump_ex         <= jump_id;
            illegal_ex      <= illegal_id;
            lui_ex          <= lui_id;
            auipc_ex        <= auipc_id;
        end
    end

    // EX/MEM pipeline register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_mem        <= 32'h0;
            rd_mem        <= 5'h0;
            mem_read_mem  <= 1'b0;
            mem_write_mem <= 1'b0;
            reg_write_mem <= 1'b0;
            mem_addr_mem  <= 32'h0;
            mem_wdata_mem <= 32'h0;
            mem_size_mem  <= 2'b00;
            funct3_mem    <= 3'b000;
            mem_be_mem    <= 4'h0;
        end else if (!mem_stall) begin
            pc_mem        <= pc_ex;
            rd_mem        <= rd_ex;
            mem_read_mem  <= mem_read_ex;
            mem_write_mem <= mem_write_ex;
            reg_write_mem <= reg_write_ex;
            mem_addr_mem  <= ex_result;
            funct3_mem    <= funct3_ex;

            // Position write data and calculate byte enables for sub-word stores
            case (funct3_ex[1:0])
                2'b00: begin // SB - store byte
                    case (ex_result[1:0])
                        2'b00: begin
                            mem_wdata_mem <= {24'h0, fwd_b[7:0]};
                            mem_be_mem    <= 4'b0001;
                        end
                        2'b01: begin
                            mem_wdata_mem <= {16'h0, fwd_b[7:0], 8'h0};
                            mem_be_mem    <= 4'b0010;
                        end
                        2'b10: begin
                            mem_wdata_mem <= {8'h0, fwd_b[7:0], 16'h0};
                            mem_be_mem    <= 4'b0100;
                        end
                        2'b11: begin
                            mem_wdata_mem <= {fwd_b[7:0], 24'h0};
                            mem_be_mem    <= 4'b1000;
                        end
                    endcase
                end
                2'b01: begin // SH - store halfword
                    case (ex_result[1])
                        1'b0: begin
                            mem_wdata_mem <= {16'h0, fwd_b[15:0]};
                            mem_be_mem    <= 4'b0011;
                        end
                        1'b1: begin
                            mem_wdata_mem <= {fwd_b[15:0], 16'h0};
                            mem_be_mem    <= 4'b1100;
                        end
                    endcase
                end
                default: begin // SW - store word
                    mem_wdata_mem <= fwd_b;
                    mem_be_mem    <= 4'b1111;
                end
            endcase

            mem_size_mem <= funct3_ex[1:0]; // Load/store size from EX stage
        end
    end

    // MEM/WB pipeline register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_wb        <= 5'h0;
            reg_write_wb <= 1'b0;
            wb_data      <= 32'h0;
        end else if (!mem_stall) begin
            rd_wb        <= rd_mem;
            reg_write_wb <= reg_write_mem;
            wb_data      <= mem_result;
        end
    end

    // Unused interrupt input (for future use)
    // verilator lint_off UNUSEDSIGNAL
    logic unused_irq;
    assign unused_irq = irq_external_i;
    // verilator lint_on UNUSEDSIGNAL

endmodule
