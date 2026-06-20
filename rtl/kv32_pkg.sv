package kv32_pkg;

  typedef struct packed {
    logic [31:0] addr;
    logic        we;
    logic [1:0]  size;
    logic [31:0] wdata;
    logic [3:0]  be;
    logic        excl;
  } mem_req_t;

  typedef struct packed {
    logic [31:0] rdata;
    logic        err;
  } mem_resp_t;

  // ALU operation encoding
  localparam logic [3:0] AluAdd  = 4'h0,
                       AluSub  = 4'h1,
                       AluSll  = 4'h2,
                       AluSlt  = 4'h3,
                       AluSltu = 4'h4,
                       AluXor  = 4'h5,
                       AluSrl  = 4'h6,
                       AluSra  = 4'h7,
                       AluOr   = 4'h8,
                       AluAnd  = 4'h9;

  // CSR operation encoding
  typedef enum logic [1:0] {
    CSR_OP_NONE  = 2'b00,  // No operation
    CSR_OP_WRITE = 2'b01,  // CSRRW: rd = old; csr = rs1
    CSR_OP_SET   = 2'b10,  // CSRRS: rd = old; csr = old | rs1
    CSR_OP_CLEAR = 2'b11   // CSRRC: rd = old; csr = old & ~rs1
  } csr_op_t;

endpackage
