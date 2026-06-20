module kv32_regfile (
    input  logic        clk,

    // Read port 1
    input  logic [ 4:0] rs1_addr,
    output logic [31:0] rs1_data,

    // Read port 2
    input  logic [ 4:0] rs2_addr,
    output logic [31:0] rs2_data,

    // Write port
    input  logic        we,
    input  logic [ 4:0] rd_addr,
    input  logic [31:0] rd_data
);

    // Register array: intentionally not reset. Resetting 32×32 bits would
    // waste FPGA resources (and ASIC test time) for no functional benefit —
    // software is responsible for initializing registers before use, and
    // x0 is hardwired to 0 via the read-port mux above. The write port
    // below only updates a register when explicitly enabled.
    logic [31:0] regs [32];

    // Combinational read (x0 always reads as zero)
    assign rs1_data = (rs1_addr == 5'h0) ? 32'h0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'h0) ? 32'h0 : regs[rs2_addr];

    // Synchronous write on rising edge (no reset — see comment above)
    always_ff @(posedge clk) begin
        if (we && rd_addr != 5'h0) begin
            regs[rd_addr] <= rd_data;
        end
    end

endmodule
