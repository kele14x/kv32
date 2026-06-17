module kv32_core
  import kv32_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        irq_external_i,
    input  logic        irq_timer_i,
    input  logic        irq_software_i,

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
    logic        arb_idle;

    // Arbiter-facing signals (modified by misaligned access handler)
    logic        d_req_a, d_we_a;
    logic [31:0] d_addr_a, d_wdata_a;
    logic [ 1:0] d_size_a;
    logic [ 3:0] d_be_a;
    logic        d_excl_a;
    logic        d_valid_a;
    logic [31:0] d_rdata_a;
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

        .d_req     (d_req_a),
        .d_addr    (d_addr_a),
        .d_we      (d_we_a),
        .d_size    (d_size_a),
        .d_wdata   (d_wdata_a),
        .d_be      (d_be_a),
        .d_excl    (d_excl_a),
        .d_gnt     (d_gnt),
        .d_valid   (d_valid_a),
        .d_rdata   (d_rdata_a),
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
        .mem_err   (mem_err),
        .arb_idle  (arb_idle)
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
    csr_op_t     csr_op_id;
    logic        csr_wen_id, is_csr_id, is_mret_id, use_zimm_id;

    logic        is_ecall_id, is_ebreak_id;

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
        .auipc        (auipc_id),
        .csr_op       (csr_op_id),
        .csr_wen      (csr_wen_id),
        .is_csr       (is_csr_id),
        .is_mret      (is_mret_id),
        .use_zimm     (use_zimm_id),
        .is_ecall     (is_ecall_id),
        .is_ebreak    (is_ebreak_id)
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
    logic        reg_write_ex, branch_ex, jump_ex, illegal_ex;
    logic        lui_ex, auipc_ex;
    logic [ 3:0] alu_op_ex;
    csr_op_t     csr_op_ex;
    logic        csr_wen_ex, is_csr_ex, is_mret_ex, use_zimm_ex;
    logic        is_ecall_ex, is_ebreak_ex;

    logic [31:0] alu_a, alu_b, alu_result;
    logic [31:0] ex_result;
    logic [31:0] fwd_a, fwd_b;

    kv32_alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .op     (alu_op_ex),
        .result (alu_result)
    );

    // CSR module signals
    logic [31:0] csr_rdata;
    logic [11:0] csr_addr_w;
    logic [31:0] csr_wdata_w;
    logic        csr_wen_gated;

    // mtvec[1:0] is the MODE field; we use Direct mode (bits stripped)
    // verilator lint_off UNUSEDSIGNAL
    logic [31:0] mtvec_out;
    // verilator lint_on UNUSEDSIGNAL
    // mstatus_mie reserved for interrupt handling (Phase 5)
    // verilator lint_off UNUSEDSIGNAL
    logic        mstatus_mie;
    // verilator lint_on UNUSEDSIGNAL
    logic [31:0] mepc_out;
    logic        instr_retired;

    // Trap detection signals
    logic        trap_taken;
    logic [31:0] trap_pc;
    logic [31:0] trap_cause;
    logic [31:0] trap_val;

    assign csr_addr_w    = instr_ex[31:20];
    assign csr_wdata_w   = use_zimm_ex ? {27'b0, instr_ex[19:15]} : fwd_a;
    assign csr_wen_gated = csr_wen_ex && !mem_stall && !trap_taken;

    // Instruction retired: valid instruction completing WB that is not a bubble
    assign instr_retired = reg_write_wb;

    // -------------------------------------------------------------------------
    // Trap detection (EX stage): illegal, ECALL, EBREAK
    // RISC-V mcause codes:
    //   2 = Illegal instruction
    //   8 = Environment call from U-mode (use 11 for M-mode)
    //   3 = Breakpoint
    // In Phase 1 (M-mode only), ECALL uses cause 11.
    // -------------------------------------------------------------------------
    always_comb begin
        trap_taken = 1'b0;
        trap_pc    = pc_ex;
        trap_cause = 32'h0;
        trap_val   = 32'h0;

        if (!mem_stall) begin
            if (illegal_ex) begin
                trap_taken = 1'b1;
                trap_cause = 32'd2;          // Illegal instruction
                trap_val   = instr_ex;       // The bad instruction
            end else if (is_ecall_ex) begin
                trap_taken = 1'b1;
                trap_cause = 32'd11;         // Environment call from M-mode
                trap_val   = 32'h0;
            end else if (is_ebreak_ex) begin
                trap_taken = 1'b1;
                trap_cause = 32'd3;          // Breakpoint
                trap_val   = pc_ex;
            end
        end
    end

    // Branch comparison
    logic branch_taken;
    logic [31:0] branch_target;

    always_comb begin
        branch_taken  = 1'b0;
        branch_target = pc_ex + 4;

        if (is_mret_ex) begin
            branch_taken  = 1'b1;
            branch_target = mepc_out;
        end else if (branch_ex) begin
            unique case (funct3_ex)
                3'b000: branch_taken = (fwd_a == fwd_b);          // BEQ
                3'b001: branch_taken = (fwd_a != fwd_b);          // BNE
                3'b100: branch_taken = ($signed(fwd_a) < $signed(fwd_b));   // BLT
                3'b101: branch_taken = ($signed(fwd_a) >= $signed(fwd_b));  // BGE
                3'b110: branch_taken = (fwd_a < fwd_b);           // BLTU
                3'b111: branch_taken = (fwd_a >= fwd_b);          // BGEU
                default: branch_taken = 1'b0;
            endcase

            if (branch_taken) begin
                branch_target = pc_ex + imm_ex;
            end
        end

        if (jump_ex) begin
            branch_taken = 1'b1;
            if (!instr_ex[3]) begin // JALR (opcode bit3=0: 1100111)
                branch_target = (fwd_a + imm_ex) & ~32'h1;
            end else begin // JAL (opcode bit3=1: 1101111)
                branch_target = pc_ex + imm_ex;
            end
        end
    end

    // ALU input mux with forwarding
    assign alu_a = auipc_ex ? pc_ex : fwd_a;
    assign alu_b = use_imm_ex ? imm_ex : fwd_b;

    // EX result mux
    always_comb begin
        if (is_csr_ex) begin
            ex_result = csr_rdata;
        end else if (lui_ex) begin
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

    // -------------------------------------------------------------------------
    // Misaligned access handler: splits misaligned loads/stores into two
    // aligned word accesses. Adds ~4 cycles of latency for misaligned accesses.
    //
    // Non-crossing case (SH at offset 1): both bytes fit in one word,
    // handled inline without the state machine.
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        MA_IDLE,
        MA_FIRST,     // First access in flight (arbiter D_PORT_ACTIVE)
        MA_WAIT,      // First access done, suppress d_req until arbiter IDLE
        MA_SECOND,    // Second access being driven (arbiter IDLE → latch → D_PORT_ACTIVE)
        MA_HOLD       // Second access in flight (d_valid suppressed until done)
    } ma_state_t;

    // verilator lint_off UNUSEDSIGNAL
    ma_state_t   ma_state;
    logic [31:0] ma_first_rdata;
    logic [ 1:0] ma_offset;
    logic [ 1:0] ma_size;
    // verilator lint_on UNUSEDSIGNAL

    // Misalignment detection
    logic word_crossing;
    logic non_crossing_ma;
    always_comb begin
        word_crossing  = 1'b0;
        non_crossing_ma = 1'b0;
        if (d_req && ma_state == MA_IDLE) begin
            if (d_size == 2'b01 && d_addr[0]) begin
                if (d_addr[1]) word_crossing  = 1'b1;
                else           non_crossing_ma = 1'b1;
            end else if (d_size == 2'b10 && d_addr[1:0] != 2'b00) begin
                word_crossing = 1'b1;
            end
        end
    end

    // Extract raw halfword from pipeline-positioned d_wdata
    // Pipeline register places halfword in bytes 0,1 (addr[1]=0) or bytes 2,3 (addr[1]=1)
    logic [15:0] raw_hw;
    assign raw_hw = d_addr[1] ? d_wdata[31:16] : d_wdata[15:0];

    // Helper: compute first-access byte enables and write data (crossing case)
    logic [3:0] first_be;
    logic [31:0] first_wdata;
    always_comb begin
        first_be    = d_be;
        first_wdata = d_wdata;
        if (d_size == 2'b01) begin
            // SH crossing (offset 3 only): low byte to byte 3
            first_be    = 4'b1000;
            first_wdata = {raw_hw[7:0], 24'h0};
        end else begin
            // SW crossing
            unique case (d_addr[1:0])
                2'b01: begin first_be = 4'b1110; first_wdata = {d_wdata[23:0], 8'h0};  end
                2'b10: begin first_be = 4'b1100; first_wdata = {d_wdata[15:0], 16'h0}; end
                2'b11: begin first_be = 4'b1000; first_wdata = {d_wdata[7:0], 24'h0};  end
                default: begin first_be = 4'b1111; first_wdata = d_wdata; end
            endcase
        end
    end

    // Helper: compute second-access byte enables and write data (crossing case)
    logic [3:0] second_be;
    logic [31:0] second_wdata;
    always_comb begin
        second_be    = 4'b1111;
        second_wdata = d_wdata;
        if (d_we) begin
            if (ma_size == 2'b01) begin
                // SH crossing (offset 3): high byte to byte 0 of second word
                second_wdata = {24'h0, raw_hw[15:8]};
                second_be    = 4'b0001;
            end else begin
                // SW: remaining bytes go to low positions of second word
                unique case (ma_offset)
                    2'b01: begin second_wdata = {24'h0, d_wdata[31:24]}; second_be = 4'b0001; end
                    2'b10: begin second_wdata = {16'h0, d_wdata[31:16]}; second_be = 4'b0011; end
                    2'b11: begin second_wdata = {8'h0,  d_wdata[31:8]};  second_be = 4'b0111; end
                    default: begin second_wdata = d_wdata; second_be = 4'b1111; end
                endcase
            end
        end
    end

    // Alignment handler state machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ma_state       <= MA_IDLE;
            ma_first_rdata <= 32'h0;
            ma_offset      <= 2'b00;
            ma_size        <= 2'b00;
        end else begin
            unique case (ma_state)
                MA_IDLE: begin
                    if (word_crossing) begin
                        ma_state  <= MA_FIRST;
                        ma_offset <= d_addr[1:0];
                        ma_size   <= d_size;
                    end
                end
                MA_FIRST: begin
                    if (d_valid_a) begin
                        ma_state       <= MA_WAIT;
                        ma_first_rdata <= d_rdata_a;
                    end
                end
                MA_WAIT: begin
                    ma_state <= MA_SECOND;
                end
                MA_SECOND: begin
                    if (arb_idle) begin
                        ma_state <= MA_HOLD;
                    end
                end
                MA_HOLD: begin
                    if (d_valid_a) begin
                        ma_state <= MA_IDLE;
                    end
                end
                default: ma_state <= MA_IDLE;
            endcase
        end
    end

    // Arbiter-facing d-port signals (with alignment handling)
    always_comb begin
        // Default: pass through
        d_req_a   = d_req;
        d_addr_a  = d_addr;
        d_we_a    = d_we;
        d_size_a  = d_size;
        d_wdata_a = d_wdata;
        d_be_a    = d_be;
        d_excl_a  = d_excl;

        unique case (ma_state)
            MA_IDLE: begin
                if (non_crossing_ma) begin
                    // SH at offset 1: both bytes in same word, no splitting
                    d_addr_a = {d_addr[31:2], 2'b00};
                    d_be_a   = 4'b0110;
                    if (d_we) d_wdata_a = {d_wdata[23:0], 8'h0};
                end else if (word_crossing) begin
                    d_req_a   = 1'b0;
                    d_addr_a  = {d_addr[31:2], 2'b00};
                    d_be_a    = first_be;
                    if (d_we) d_wdata_a = first_wdata;
                end
            end

            MA_FIRST: begin
                d_req_a   = d_req;
                d_addr_a  = {d_addr[31:2], 2'b00};
                d_be_a    = first_be;
                if (d_we) d_wdata_a = first_wdata;
            end

            MA_WAIT: begin
                d_req_a   = 1'b0;
                d_addr_a  = {d_addr[31:2], 2'b00};
                d_be_a    = first_be;
                if (d_we) d_wdata_a = first_wdata;
            end

            MA_SECOND: begin
                d_addr_a  = {d_addr[31:2], 2'b00} + 32'd4;
                d_wdata_a = second_wdata;
                d_be_a    = second_be;
            end

            MA_HOLD: begin
                d_addr_a  = {d_addr[31:2], 2'b00} + 32'd4;
                d_wdata_a = second_wdata;
                d_be_a    = second_be;
            end

            default: ;
        endcase
    end

    // Combine misaligned load data from two word reads
    always_comb begin
        d_valid = d_valid_a;
        d_rdata = d_rdata_a;

        if (ma_state != MA_IDLE) begin
            d_valid = 1'b0;
        end

        if (ma_state == MA_HOLD && d_valid_a) begin
            d_valid = 1'b1;
            unique case (ma_size)
                2'b01: begin // Halfword (offset 3 only)
                    d_rdata = {d_rdata_a[7:0], ma_first_rdata[31:24], 16'h0};
                end
                2'b10: begin // Word
                    unique case (ma_offset)
                        2'b01: d_rdata = {d_rdata_a[7:0],  ma_first_rdata[31:8]};
                        2'b10: d_rdata = {d_rdata_a[15:0], ma_first_rdata[31:16]};
                        2'b11: d_rdata = {d_rdata_a[23:0], ma_first_rdata[31:24]};
                        default: d_rdata = d_rdata_a;
                    endcase
                end
                default: d_rdata = d_rdata_a;
            endcase
        end

        // Non-crossing misaligned load (SH at offset 1): shift rdata right
        // so the existing load extraction picks up bytes 1,2 correctly
        if (non_crossing_ma && !d_we && d_valid_a) begin
            d_rdata = {8'h0, d_rdata_a[31:8]};
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

    // Flush: branch_taken OR trap_taken both flush IF and ID stages
    assign if_flush = branch_taken || trap_taken;
    assign id_flush = branch_taken || trap_taken;
    assign ex_flush = trap_taken;  // Trap also squashes the faulting instruction in EX

    // IF stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_if <= 32'h0;
            i_req <= 1'b1;
        end else if (trap_taken) begin
            // Trap: redirect to mtvec (highest priority)
            pc_if <= {mtvec_out[31:2], 2'b00};  // MODE=Direct: jump to BASE
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
            csr_op_ex       <= CSR_OP_NONE;
            csr_wen_ex      <= 1'b0;
            is_csr_ex       <= 1'b0;
            is_mret_ex      <= 1'b0;
            use_zimm_ex     <= 1'b0;
            is_ecall_ex     <= 1'b0;
            is_ebreak_ex    <= 1'b0;
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
            csr_wen_ex    <= 1'b0;
            is_csr_ex     <= 1'b0;
            is_mret_ex    <= 1'b0;
            illegal_ex    <= 1'b0;
            is_ecall_ex   <= 1'b0;
            is_ebreak_ex  <= 1'b0;
        end else if (load_use_hazard || if_wait) begin
            // Insert bubble: load-use hazard or IF waiting for instruction
            reg_write_ex    <= 1'b0;
            mem_read_ex     <= 1'b0;
            mem_write_ex    <= 1'b0;
            branch_ex       <= 1'b0;
            jump_ex         <= 1'b0;
            lui_ex          <= 1'b0;
            auipc_ex        <= 1'b0;
            alu_op_valid_ex <= 1'b0;
            rd_ex           <= 5'h0;
            csr_wen_ex      <= 1'b0;
            is_csr_ex       <= 1'b0;
            is_mret_ex      <= 1'b0;
            illegal_ex      <= 1'b0;
            is_ecall_ex     <= 1'b0;
            is_ebreak_ex    <= 1'b0;
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
            csr_op_ex       <= csr_op_id;
            csr_wen_ex      <= csr_wen_id;
            is_csr_ex       <= is_csr_id;
            is_mret_ex      <= is_mret_id;
            use_zimm_ex     <= use_zimm_id;
            is_ecall_ex     <= is_ecall_id;
            is_ebreak_ex    <= is_ebreak_id;
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
        end else if (trap_taken) begin
            // Trap squashes the faulting instruction — insert bubble
            mem_read_mem  <= 1'b0;
            mem_write_mem <= 1'b0;
            reg_write_mem <= 1'b0;
            rd_mem        <= 5'h0;
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

    // CSR module instantiation
    kv32_csr u_csr (
        .clk          (clk),
        .rst_n        (rst_n),
        .csr_addr     (csr_addr_w),
        .csr_wdata    (csr_wdata_w),
        .csr_op       (csr_op_ex),
        .csr_wen      (csr_wen_gated),
        .csr_rdata    (csr_rdata),
        .irq_external (irq_external_i),
        .irq_timer    (irq_timer_i),
        .irq_software (irq_software_i),
        .trap_taken   (trap_taken),
        .trap_pc      (trap_pc),
        .trap_cause   (trap_cause),
        .trap_val     (trap_val),
        .mret_taken   (is_mret_ex && !mem_stall),
        .mtvec_out    (mtvec_out),
        .mepc_out     (mepc_out),
        .mstatus_mie  (mstatus_mie),
        .instr_retired(instr_retired)
    );

endmodule
