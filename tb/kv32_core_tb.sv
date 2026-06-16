`timescale 1ns/1ps

module kv32_core_tb;

    logic clk;
    logic rst_n;
    logic irq_external_i;

    // Memory interface
    logic        mem_req;
    logic [31:0] mem_addr;
    logic        mem_we;
    logic [ 1:0] mem_size;
    logic [31:0] mem_wdata;
    logic [ 3:0] mem_be;
    logic        mem_excl;
    logic        mem_gnt;
    logic        mem_valid;
    logic [31:0] mem_rdata;
    logic        mem_err;

    // DUT
    kv32_core u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .irq_external_i (irq_external_i),

        .mem_req        (mem_req),
        .mem_addr       (mem_addr),
        .mem_we         (mem_we),
        .mem_size       (mem_size),
        .mem_wdata      (mem_wdata),
        .mem_be         (mem_be),
        .mem_excl       (mem_excl),
        .mem_gnt        (mem_gnt),
        .mem_valid      (mem_valid),
        .mem_rdata      (mem_rdata),
        .mem_err        (mem_err)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // Simple BRAM memory model (64 KB)
    logic [31:0] bram [0:16383]; // 64 KB / 4 bytes per word

    initial begin
        // Load a simple program
        // 0x0000: ADDI x1, x0, 5     (x1 = 5)
        // 0x0004: ADDI x2, x0, 10    (x2 = 10)
        // 0x0008: ADD  x3, x1, x2    (x3 = 15)
        // 0x000C: NOP
        bram[0] = 32'h00500093; // ADDI x1, x0, 5
        bram[1] = 32'h00A00113; // ADDI x2, x0, 10
        bram[2] = 32'h002081B3; // ADD x3, x1, x2
        bram[3] = 32'h00000013; // NOP
    end

    // Memory responder
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_gnt   <= 1'b0;
            mem_valid <= 1'b0;
            mem_rdata <= 32'h0;
            mem_err   <= 1'b0;
        end else begin
            mem_gnt   <= mem_req;
            mem_valid <= mem_req & mem_gnt;

            if (mem_req & mem_gnt) begin
                if (mem_we) begin
                    // Write
                    if (mem_be[0]) bram[mem_addr[15:2]][ 7: 0] <= mem_wdata[ 7: 0];
                    if (mem_be[1]) bram[mem_addr[15:2]][15: 8] <= mem_wdata[15: 8];
                    if (mem_be[2]) bram[mem_addr[15:2]][23:16] <= mem_wdata[23:16];
                    if (mem_be[3]) bram[mem_addr[15:2]][31:24] <= mem_wdata[31:24];
                end else begin
                    // Read
                    mem_rdata <= bram[mem_addr[15:2]];
                end
            end

            mem_err <= 1'b0;
        end
    end

    // Test sequence
    initial begin
        rst_n = 0;
        irq_external_i = 0;
        #20;
        rst_n = 1;
        #1000; // Run for 1000 ns
        $display("Test complete");
        $finish;
    end

    // Monitor
    initial begin
        $monitor("Time=%0t, PC=%h, Instr=%h, x1=%h, x2=%h, x3=%h",
                 $time,
                 u_dut.pc_if,
                 u_dut.instr_id,
                 u_dut.u_regfile.regs[1],
                 u_dut.u_regfile.regs[2],
                 u_dut.u_regfile.regs[3]);
    end

    // Debug output at every clock cycle
    always @(posedge clk) begin
        if (rst_n) begin
            $display("Cycle %0t: EX[pc=%h,rd=%h,rs1=%h,rs2=%h,rs1_data=%h,rs2_data=%h,alu_a=%h,alu_b=%h,fwd_a=%h,fwd_b=%h,alu=%h] MEM[rd=%h,data=%h] WB[rd=%h,data=%h]",
                     $time,
                     u_dut.pc_ex,
                     u_dut.rd_ex,
                     u_dut.rs1_ex,
                     u_dut.rs2_ex,
                     u_dut.rs1_data,
                     u_dut.rs2_data,
                     u_dut.alu_a,
                     u_dut.alu_b,
                     u_dut.fwd_a,
                     u_dut.fwd_b,
                     u_dut.alu_result,
                     u_dut.rd_mem,
                     u_dut.mem_result,
                     u_dut.rd_wb,
                     u_dut.wb_data);
        end
    end

endmodule
