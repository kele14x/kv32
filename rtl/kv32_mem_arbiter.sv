module kv32_mem_arbiter (
    input  logic        clk,
    input  logic        rst_n,

    // i-port (instruction fetch)
    input  logic        i_req,
    input  logic [31:0] i_addr,
    output logic        i_gnt,
    output logic        i_valid,
    output logic [31:0] i_rdata,
    output logic        i_err,

    // d-port (data load/store)
    input  logic        d_req,
    input  logic [31:0] d_addr,
    input  logic        d_we,
    input  logic [ 1:0] d_size,
    input  logic [31:0] d_wdata,
    input  logic [ 3:0] d_be,
    input  logic        d_excl,
    output logic        d_gnt,
    output logic        d_valid,
    output logic [31:0] d_rdata,
    output logic        d_err,

    // External memory interface (arbitrated)
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
    input  logic        mem_err,
    output logic        arb_idle
);

    typedef enum logic [1:0] {
        IDLE,
        D_PORT_ACTIVE,
        I_PORT_ACTIVE
    } arb_state_t;

    arb_state_t state, next_state;

    // Granted flag: tracks whether the current transaction has been
    // accepted (mem_gnt seen). Ensures d_gnt/i_gnt is a one-cycle pulse
    // rather than re-asserting every cycle while waiting for mem_valid.
    logic        granted;

    // Latched d-port request (held stable during D_PORT_ACTIVE)
    logic [31:0] d_addr_lat;
    logic        d_we_lat;
    logic [ 1:0] d_size_lat;
    logic [31:0] d_wdata_lat;
    logic [ 3:0] d_be_lat;
    logic        d_excl_lat;

    // Arbiter state machine.
    // IDLE only transitions to *_ACTIVE when mem_gnt is seen AND the
    // response is not yet valid (multi-cycle latency). If mem_valid
    // arrives in the same cycle as mem_gnt (zero-latency, SPEC §4.2
    // rule 4), the transaction completes entirely in IDLE — no
    // transition needed, no double-response risk.
    always_comb begin
        next_state = state;

        unique case (state)
            IDLE: begin
                if (d_req && mem_gnt && !mem_valid) begin
                    next_state = D_PORT_ACTIVE;
                end else if (!d_req && i_req && mem_gnt && !mem_valid) begin
                    next_state = I_PORT_ACTIVE;
                end
            end

            D_PORT_ACTIVE: begin
                if (mem_valid) begin
                    next_state = IDLE;
                end
            end

            I_PORT_ACTIVE: begin
                if (mem_valid) begin
                    next_state = IDLE;
                end
            end

            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            granted     <= 1'b0;
            d_addr_lat  <= 32'h0;
            d_we_lat    <= 1'b0;
            d_size_lat  <= 2'b00;
            d_wdata_lat <= 32'h0;
            d_be_lat    <= 4'h0;
            d_excl_lat  <= 1'b0;
        end else begin
            state <= next_state;
            // Clear granted on return to IDLE; set on first mem_gnt
            if (next_state == IDLE) begin
                granted <= 1'b0;
            end else if (mem_gnt && !granted) begin
                granted <= 1'b1;
            end
            // Latch d-port request when starting a data access
            if (state == IDLE && d_req && mem_gnt) begin
                d_addr_lat  <= d_addr;
                d_we_lat    <= d_we;
                d_size_lat  <= d_size;
                d_wdata_lat <= d_wdata;
                d_be_lat    <= d_be;
                d_excl_lat  <= d_excl;
            end
        end
    end

    // Request mux
    always_comb begin
        mem_req   = 1'b0;
        mem_addr  = 32'h0;
        mem_we    = 1'b0;
        mem_size  = 2'b00;
        mem_wdata = 32'h0;
        mem_be    = 4'h0;
        mem_excl  = 1'b0;

        i_gnt = 1'b0;
        d_gnt = 1'b0;

        unique case (state)
            IDLE: begin
                // Priority: d-port > i-port
                if (d_req) begin
                    mem_req   = 1'b1;
                    mem_addr  = d_addr;
                    mem_we    = d_we;
                    mem_size  = d_size;
                    mem_wdata = d_wdata;
                    mem_be    = d_be;
                    mem_excl  = d_excl;
                    if (mem_gnt) begin
                        d_gnt = 1'b1;
                    end
                end else if (i_req) begin
                    mem_req   = 1'b1;
                    mem_addr  = i_addr;
                    mem_we    = 1'b0;
                    mem_size  = 2'b10; // word
                    mem_wdata = 32'h0;
                    mem_be    = 4'hF;
                    mem_excl  = 1'b0;
                    if (mem_gnt) begin
                        i_gnt = 1'b1;
                    end
                end
            end

            D_PORT_ACTIVE: begin
                // Hold request stable using latched values until mem_valid
                mem_req   = 1'b1;
                mem_addr  = d_addr_lat;
                mem_we    = d_we_lat;
                mem_size  = d_size_lat;
                mem_wdata = d_wdata_lat;
                mem_be    = d_be_lat;
                mem_excl  = d_excl_lat;
                // Grant only on the first accepted cycle (one-cycle pulse)
                if (mem_gnt && !granted) begin
                    d_gnt = 1'b1;
                end
            end

            I_PORT_ACTIVE: begin
                // Hold request stable until mem_valid
                mem_req   = 1'b1;
                mem_addr  = i_addr;
                mem_we    = 1'b0;
                mem_size  = 2'b10;
                mem_wdata = 32'h0;
                mem_be    = 4'hF;
                mem_excl  = 1'b0;
                // Grant only on the first accepted cycle (one-cycle pulse)
                if (mem_gnt && !granted) begin
                    i_gnt = 1'b1;
                end
            end

            default: ;
        endcase
    end

    // Response demux.
    // Handles mem_valid in IDLE (zero-latency: mem_gnt && mem_valid in
    // the same cycle, allowed by SPEC §4.2 rule 4) as well as in
    // *_ACTIVE states (multi-cycle latency).
    assign arb_idle = (state == IDLE);

    always_comb begin
        i_valid = 1'b0;
        i_rdata = 32'h0;
        i_err   = 1'b0;

        d_valid = 1'b0;
        d_rdata = 32'h0;
        d_err   = 1'b0;

        if (mem_valid) begin
            unique case (state)
                IDLE: begin
                    // Zero-latency response: route to the port that was
                    // just granted (d-port has priority).
                    if (d_req && mem_gnt) begin
                        d_valid = 1'b1;
                        d_rdata = mem_rdata;
                        d_err   = mem_err;
                    end else if (i_req && mem_gnt) begin
                        i_valid = 1'b1;
                        i_rdata = mem_rdata;
                        i_err   = mem_err;
                    end
                end

                D_PORT_ACTIVE: begin
                    d_valid = 1'b1;
                    d_rdata = mem_rdata;
                    d_err   = mem_err;
                end

                I_PORT_ACTIVE: begin
                    i_valid = 1'b1;
                    i_rdata = mem_rdata;
                    i_err   = mem_err;
                end

                default: ;
            endcase
        end
    end

endmodule
