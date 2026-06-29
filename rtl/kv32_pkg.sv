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

  // Privilege mode encoding
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,  // User mode
    PRIV_S = 2'b01,  // Supervisor mode
    PRIV_M = 2'b11   // Machine mode
  } priv_mode_t;

  /* verilator lint_off UNUSEDPARAM */
  // CSR address constants (Phase 5: S-mode and delegation CSRs)
  // S-mode CSRs
  localparam logic [11:0] CsrSstatus = 12'h100;
  localparam logic [11:0] CsrSie = 12'h104;
  localparam logic [11:0] CsrStvec = 12'h105;
  localparam logic [11:0] CsrScounteren = 12'h106;
  localparam logic [11:0] CsrSscratch = 12'h140;
  localparam logic [11:0] CsrSepc = 12'h141;
  localparam logic [11:0] CsrScause = 12'h142;
  localparam logic [11:0] CsrStval = 12'h143;
  localparam logic [11:0] CsrSip = 12'h144;
  localparam logic [11:0] CsrSatp = 12'h180;

  // Delegation CSRs
  localparam logic [11:0] CsrMedeleg = 12'h302;
  localparam logic [11:0] CsrMideleg = 12'h303;

  // U-mode counter CSRs
  localparam logic [11:0] CsrCycle = 12'hC00;
  localparam logic [11:0] CsrCycleh = 12'hC80;
  localparam logic [11:0] CsrInstret = 12'hC02;
  localparam logic [11:0] CsrInstreth = 12'hC82;
  /* verilator lint_on UNUSEDPARAM */

endpackage
