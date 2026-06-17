package kv32_pkg;

typedef struct packed {
    logic [31:0] addr;
    logic        we;
    logic [ 1:0] size;
    logic [31:0] wdata;
    logic [ 3:0] be;
    logic        excl;
} mem_req_t;

typedef struct packed {
    logic [31:0] rdata;
    logic        err;
} mem_resp_t;

// ALU operation encoding
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

// CSR operation encoding
typedef enum logic [1:0] {
    CSR_OP_NONE  = 2'b00,  // No operation
    CSR_OP_WRITE = 2'b01,  // CSRRW: rd = old; csr = rs1
    CSR_OP_SET   = 2'b10,  // CSRRS: rd = old; csr = old | rs1
    CSR_OP_CLEAR = 2'b11   // CSRRC: rd = old; csr = old & ~rs1
} csr_op_t;

endpackage
