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

endpackage
