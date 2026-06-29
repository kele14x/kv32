// tb_mem_fe.sv -- SystemVerilog testbench for kv32_mem_fe
// Translated from tb_mem_fe.cpp. Tests: sub-word store positioning,
// load extraction, aligned access flow, non-crossing misaligned SH@01,
// crossing accesses (SH@11, SW@01/10/11), FSM state transitions,
// reset, rdata_valid timing, error handling.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PROCASSINIT */

module tb_mem_fe;

  // Clock: 100 MHz (period = 10 time units)
  logic clk = 0;
  always #5 clk = ~clk;

  // DUT interface
  logic        rst_n;
  logic        req;
  logic [31:0] addr;
  logic        we;
  logic [ 1:0] size;
  logic [31:0] wdata;
  logic [ 2:0] funct3;
  logic        excl;

  logic [31:0] rdata;
  logic        rdata_valid;
  logic        err;

  logic        dmem_req;
  logic [31:0] dmem_addr;
  logic        dmem_we;
  logic [ 1:0] dmem_size;
  logic [31:0] dmem_wdata;
  logic [ 3:0] dmem_be;
  logic        dmem_excl;
  logic        dmem_gnt;
  logic        dmem_ack;
  logic [31:0] dmem_rdata;
  logic        dmem_err;

  kv32_mem_fe u_dut (.*);

  // Test counters
  int tests = 0;
  int failures = 0;

  // ---------------------------------------------------------------------------
  // Helper tasks
  // ---------------------------------------------------------------------------

  task automatic tick();
    @(posedge clk);
    #1;
  endtask

  task automatic reset();
    rst_n     = 0;
    req       = 0;
    addr      = 32'h0;
    we        = 0;
    size      = 2'b00;
    wdata     = 32'h0;
    funct3    = 3'b000;
    excl      = 0;
    dmem_gnt  = 0;
    dmem_ack  = 0;
    dmem_rdata = 32'h0;
    dmem_err  = 0;
    @(posedge clk);
    #1;
    rst_n = 1;
    #1;
  endtask

  task automatic set_inputs(
      input logic        ireq,
      input logic [31:0] iaddr,
      input logic        iwe,
      input logic [ 1:0] isize,
      input logic [31:0] iwdata,
      input logic [ 2:0] ifunct3
  );
    req    = ireq;
    addr   = iaddr;
    we     = iwe;
    size   = isize;
    wdata  = iwdata;
    funct3 = ifunct3;
    #1;
  endtask

  task automatic check_eq(input string name, input logic [31:0] got, input logic [31:0] want);
    tests++;
    if (got !== want) begin
      $display("FAIL  %-40s got=0x%08h want=0x%08h", name, got, want);
      failures++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Store positioning (combinational)
  // ---------------------------------------------------------------------------

  task automatic test_store_positioning();
    $display("--- Store positioning ---");

    // SB at all offsets
    for (int off = 0; off < 4; off++) begin
      set_inputs(1, 32'h1000 + off, 1, 2'b00, 32'hAB, 3'b000);
      check_eq($sformatf("SB@%0d be", off), dmem_be, 1 << off);
      check_eq($sformatf("SB@%0d wdata", off), dmem_wdata, 32'hAB << (off * 8));
      check_eq("SB req passthrough", dmem_req, 1);
      check_eq("SB addr passthrough", dmem_addr, 32'h1000 + off);
    end

    // SH aligned (offset 0 and 2)
    set_inputs(1, 32'h1000, 1, 2'b01, 32'hABCD, 3'b000);
    check_eq("SH@0 be", dmem_be, 4'h3);
    check_eq("SH@0 wdata", dmem_wdata, 32'h0000ABCD);

    set_inputs(1, 32'h1002, 1, 2'b01, 32'hABCD, 3'b000);
    check_eq("SH@2 be", dmem_be, 4'hC);
    check_eq("SH@2 wdata", dmem_wdata, 32'hABCD0000);

    // SW aligned
    set_inputs(1, 32'h1000, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    check_eq("SW@0 be", dmem_be, 4'hF);
    check_eq("SW@0 wdata", dmem_wdata, 32'hDEADBEEF);
  endtask

  // ---------------------------------------------------------------------------
  // Load extraction (combinational, needs dmem_ack)
  // ---------------------------------------------------------------------------

  task automatic test_load_extraction();
    $display("--- Load extraction ---");
    reset();

    // LW aligned
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hDEADBEEF;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LW rdata_valid", rdata_valid, 1);
    check_eq("LW rdata", rdata, 32'hDEADBEEF);
    dmem_ack = 0; dmem_gnt = 0;

    // LB sign-extend positive
    reset();
    set_inputs(1, 32'h1000, 0, 2'b00, 32'h0, 3'b000);
    dmem_rdata = 32'h00000042;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LB@0 positive rdata", rdata, 32'h00000042);

    // LB sign-extend negative
    reset();
    set_inputs(1, 32'h1001, 0, 2'b00, 32'h0, 3'b000);
    dmem_rdata = 32'h00008200;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LB@1 negative rdata", rdata, 32'hFFFFFF82);

    // LBU zero-extend
    reset();
    set_inputs(1, 32'h1002, 0, 2'b00, 32'h0, 3'b100);
    dmem_rdata = 32'h00820000;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LBU@2 rdata", rdata, 32'h00000082);

    // LH sign-extend positive
    reset();
    set_inputs(1, 32'h1000, 0, 2'b01, 32'h0, 3'b001);
    dmem_rdata = 32'h00001234;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LH@0 positive rdata", rdata, 32'h00001234);

    // LH sign-extend negative
    reset();
    set_inputs(1, 32'h1002, 0, 2'b01, 32'h0, 3'b001);
    dmem_rdata = 32'h82340000;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LH@2 negative rdata", rdata, 32'hFFFF8234);

    // LHU zero-extend
    reset();
    set_inputs(1, 32'h1000, 0, 2'b01, 32'h0, 3'b101);
    dmem_rdata = 32'h00008234;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("LHU@0 rdata", rdata, 32'h00008234);
  endtask

  // ---------------------------------------------------------------------------
  // Comprehensive load extraction (all offsets)
  // ---------------------------------------------------------------------------

  task automatic test_load_extraction_all_offsets();
    $display("--- Load extraction (all offsets) ---");

    // LB sign-extend at all 4 offsets
    begin
      logic [31:0] want[4];
      want[0] = 32'h00000000;
      want[1] = 32'hFFFFFFFF;
      want[2] = 32'hFFFFFF80;
      want[3] = 32'h0000007F;
      for (int off = 0; off < 4; off++) begin
        reset();
        set_inputs(1, 32'h1000 + off, 0, 2'b00, 32'h0, 3'b000);
        dmem_rdata = 32'h7F80FF00;
        dmem_ack = 1; dmem_gnt = 1;
        #1;
        check_eq($sformatf("LB@%0d sign-extend", off), rdata, want[off]);
      end
    end

    // LBU zero-extend at all 4 offsets
    begin
      logic [31:0] want[4];
      want[0] = 32'h00000000;
      want[1] = 32'h000000FF;
      want[2] = 32'h00000080;
      want[3] = 32'h0000007F;
      for (int off = 0; off < 4; off++) begin
        reset();
        set_inputs(1, 32'h1000 + off, 0, 2'b00, 32'h0, 3'b100);
        dmem_rdata = 32'h7F80FF00;
        dmem_ack = 1; dmem_gnt = 1;
        #1;
        check_eq($sformatf("LBU@%0d zero-extend", off), rdata, want[off]);
      end
    end

    // LH sign-extend at both halfword offsets
    begin
      reset();
      set_inputs(1, 32'h1000, 0, 2'b01, 32'h0, 3'b001);
      dmem_rdata = 32'h7FFF8000;
      dmem_ack = 1; dmem_gnt = 1;
      #1;
      check_eq("LH@0 negative", rdata, 32'hFFFF8000);

      reset();
      set_inputs(1, 32'h1002, 0, 2'b01, 32'h0, 3'b001);
      dmem_rdata = 32'h7FFF8000;
      dmem_ack = 1; dmem_gnt = 1;
      #1;
      check_eq("LH@2 positive", rdata, 32'h00007FFF);
    end

    // LHU zero-extend at offset 2
    begin
      reset();
      set_inputs(1, 32'h1002, 0, 2'b01, 32'h0, 3'b101);
      dmem_rdata = 32'hABCD1234;
      dmem_ack = 1; dmem_gnt = 1;
      #1;
      check_eq("LHU@2 zero-extend", rdata, 32'h0000ABCD);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Aligned access flow (sequential)
  // ---------------------------------------------------------------------------

  task automatic test_aligned_flow();
    $display("--- Aligned flow ---");
    reset();

    // Zero-latency: req and ack in same cycle
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hCAFEBABE;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("zero-lat rdata_valid", rdata_valid, 1);
    check_eq("zero-lat rdata", rdata, 32'hCAFEBABE);

    // Multi-cycle latency: req held, ack after 2 cycles
    reset();
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 0;
    dmem_ack = 0; dmem_gnt = 0;
    #1;
    check_eq("latency cycle0 rdata_valid", rdata_valid, 0);
    tick();
    check_eq("latency cycle1 rdata_valid", rdata_valid, 0);
    tick();
    dmem_rdata = 32'h12345678;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("latency cycle2 rdata_valid", rdata_valid, 1);
    check_eq("latency cycle2 rdata", rdata, 32'h12345678);
  endtask

  // ---------------------------------------------------------------------------
  // Non-crossing misaligned SH@01: load latency helper
  // ---------------------------------------------------------------------------

  task automatic check_nc_sh01_lat(int latency);
    string label;

    reset();
    set_inputs(1, 32'h1001, 0, 2'b01, 32'h0, 3'b001);  // LH load
    dmem_rdata = 32'h12AB3400;  // bytes 1-2 = 0xAB34

    if (latency == 0) begin
      dmem_ack = 1;
      dmem_gnt = 1;
      #1;
      label = $sformatf("SH@01 load lat%0d rdata_valid", latency);
      check_eq(label, rdata_valid, 1);
      label = $sformatf("SH@01 load lat%0d rdata", latency);
      check_eq(label, rdata, 32'hFFFFAB34);
      return;
    end

    dmem_ack = 0;
    dmem_gnt = 1;
    #1;
    label = $sformatf("SH@01 load lat%0d req", latency);
    check_eq(label, dmem_req, 1);
    label = $sformatf("SH@01 load lat%0d addr", latency);
    check_eq(label, dmem_addr, 32'h1000);
    label = $sformatf("SH@01 load lat%0d be", latency);
    check_eq(label, dmem_be, 32'h6);
    label = $sformatf("SH@01 load lat%0d wait0", latency);
    check_eq(label, rdata_valid, 0);
    tick();  // request accepted, now waiting for ack

    dmem_gnt = 0;
    for (int cycle = 1; cycle < latency; cycle++) begin
      dmem_ack = 0;
      #1;
      label = $sformatf("SH@01 load lat%0d wait%0d", latency, cycle);
      check_eq(label, rdata_valid, 0);
      tick();
    end

    dmem_ack = 1;
    #1;
    label = $sformatf("SH@01 load lat%0d rdata_valid", latency);
    check_eq(label, rdata_valid, 1);
    label = $sformatf("SH@01 load lat%0d rdata", latency);
    check_eq(label, rdata, 32'hFFFFAB34);
  endtask

  // ---------------------------------------------------------------------------
  // Non-crossing misaligned SH@01
  // ---------------------------------------------------------------------------

  task automatic test_non_crossing_sh01();
    $display("--- Non-crossing SH@01 ---");
    reset();

    // Store: addr=0x1001, size=SH, should align to 0x1000, BE=0110
    set_inputs(1, 32'h1001, 1, 2'b01, 32'hABCD, 3'b000);
    check_eq("SH@01 store addr", dmem_addr, 32'h1000);
    check_eq("SH@01 store be", dmem_be, 32'h6);
    check_eq("SH@01 store wdata", dmem_wdata, 32'h00ABCD00);
    check_eq("SH@01 store req", dmem_req, 1);

    // Load at various latencies
    check_nc_sh01_lat(0);
    check_nc_sh01_lat(1);
    check_nc_sh01_lat(2);
    check_nc_sh01_lat(10);
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SH@addr[1:0]=11 (store)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sh11_store();
    $display("--- Crossing SH@11 store ---");
    reset();

    set_inputs(1, 32'h1003, 1, 2'b01, 32'hABCD, 3'b000);
    // Cycle 0: IDLE drives the first beat immediately and waits for grant.
    check_eq("SH@11 cycle0 req", dmem_req, 1);
    check_eq("SH@11 cycle0 addr", dmem_addr, 32'h1000);
    check_eq("SH@11 cycle0 be", dmem_be, 32'h8);
    check_eq("SH@11 cycle0 wdata", dmem_wdata, 32'hCD000000);
    tick();

    // Cycle 1: MA_FIRST, req asserted, waiting for ack
    check_eq("SH@11 cycle1 req", dmem_req, 1);
    check_eq("SH@11 cycle1 addr", dmem_addr, 32'h1000);
    dmem_ack = 1; dmem_gnt = 1;
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // Cycle 2: after the first ack, the second beat request is already on the bus.
    check_eq("SH@11 cycle2 req", dmem_req, 1);
    tick();

    // Cycle 3: MA_SECOND, req asserted, addr+4
    check_eq("SH@11 cycle3 req", dmem_req, 1);
    check_eq("SH@11 cycle3 addr", dmem_addr, 32'h1004);
    check_eq("SH@11 cycle3 be", dmem_be, 32'h1);
    check_eq("SH@11 cycle3 wdata", dmem_wdata, 32'h000000AB);
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("SH@11 rdata_valid", rdata_valid, 1);
    tick();
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SH@11 (load)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sh11_load();
    $display("--- Crossing SH@11 load ---");
    reset();

    set_inputs(1, 32'h1003, 0, 2'b01, 32'h0, 3'b001);
    check_eq("SH@11 load cycle0 req", dmem_req, 1);
    tick();

    // MA_FIRST
    dmem_rdata = 32'h12345678;
    dmem_ack = 1; dmem_gnt = 1;
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // MA_SECOND_REQ
    tick();

    // MA_SECOND_WAIT
    dmem_rdata = 32'hAABBCCDD;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("SH@11 load rdata_valid", rdata_valid, 1);
    // Stitched: {second[7:0], first[31:24], 16'h0} = {0xDD, 0x12, 0x0000}
    // LH extracts: addr[1]=1 (from 0x1003), high half: 0xFFFFDD12
    check_eq("SH@11 load rdata", rdata, 32'hFFFFDD12);
    tick();
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SW@addr[1:0]=01 (store)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sw01_store();
    $display("--- Crossing SW@01 store ---");
    reset();

    set_inputs(1, 32'h1001, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    check_eq("SW@01 cycle0 req", dmem_req, 1);
    check_eq("SW@01 cycle0 be", dmem_be, 32'hE);
    check_eq("SW@01 cycle0 wdata", dmem_wdata, 32'hADBEEF00);
    tick();

    dmem_ack = 1; dmem_gnt = 1;
    tick();
    dmem_ack = 0; dmem_gnt = 0;
    tick();

    // MA_SECOND
    check_eq("SW@01 cycle3 addr", dmem_addr, 32'h1004);
    check_eq("SW@01 cycle3 be", dmem_be, 32'h1);
    check_eq("SW@01 cycle3 wdata", dmem_wdata, 32'h000000DE);
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("SW@01 rdata_valid", rdata_valid, 1);
    tick();
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SW@01 (load)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sw01_load();
    $display("--- Crossing SW@01 load ---");
    reset();

    set_inputs(1, 32'h1001, 0, 2'b10, 32'h0, 3'b010);
    tick();

    dmem_rdata = 32'hAABBCCDD;
    dmem_ack = 1; dmem_gnt = 1;
    tick();
    dmem_ack = 0; dmem_gnt = 0;
    tick();

    dmem_rdata = 32'h11223344;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("SW@01 load rdata_valid", rdata_valid, 1);
    // Stitched: {second[7:0], first[31:8]} = {0x44, 0xAABBCC}
    check_eq("SW@01 load rdata", rdata, 32'h44AABBCC);
    tick();
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SW@10 (store + load)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sw10();
    $display("--- Crossing SW@10 ---");

    // Store
    reset();
    set_inputs(1, 32'h1002, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    check_eq("SW@10 store cycle0 be", dmem_be, 32'hC);
    check_eq("SW@10 store cycle0 wdata", dmem_wdata, 32'hBEEF0000);
    tick();
    dmem_ack = 1; dmem_gnt = 1; tick();
    dmem_ack = 0; dmem_gnt = 0; tick();
    check_eq("SW@10 store cycle3 be", dmem_be, 32'h3);
    check_eq("SW@10 store cycle3 wdata", dmem_wdata, 32'h0000DEAD);
    dmem_ack = 1; dmem_gnt = 1; #1;
    check_eq("SW@10 store rdata_valid", rdata_valid, 1);

    // Load
    reset();
    set_inputs(1, 32'h1002, 0, 2'b10, 32'h0, 3'b010);
    tick();
    dmem_rdata = 32'hAABBCCDD;
    dmem_ack = 1; dmem_gnt = 1; tick();
    dmem_ack = 0; dmem_gnt = 0; tick();
    dmem_rdata = 32'h11223344;
    dmem_ack = 1; dmem_gnt = 1; #1;
    check_eq("SW@10 load rdata_valid", rdata_valid, 1);
    // Stitched: {second[15:0], first[31:16]} = {0x3344, 0xAABB}
    check_eq("SW@10 load rdata", rdata, 32'h3344AABB);
  endtask

  // ---------------------------------------------------------------------------
  // Crossing SW@11 (store + load)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_sw11();
    $display("--- Crossing SW@11 ---");

    // Store
    reset();
    set_inputs(1, 32'h1003, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    check_eq("SW@11 store cycle0 be", dmem_be, 32'h8);
    check_eq("SW@11 store cycle0 wdata", dmem_wdata, 32'hEF000000);
    tick();
    dmem_ack = 1; dmem_gnt = 1; tick();
    dmem_ack = 0; dmem_gnt = 0; tick();
    check_eq("SW@11 store cycle3 be", dmem_be, 32'h7);
    check_eq("SW@11 store cycle3 wdata", dmem_wdata, 32'h00DEADBE);
    dmem_ack = 1; dmem_gnt = 1; #1;
    check_eq("SW@11 store rdata_valid", rdata_valid, 1);

    // Load
    reset();
    set_inputs(1, 32'h1003, 0, 2'b10, 32'h0, 3'b010);
    tick();
    dmem_rdata = 32'hAABBCCDD;
    dmem_ack = 1; dmem_gnt = 1; tick();
    dmem_ack = 0; dmem_gnt = 0; tick();
    dmem_rdata = 32'h11223344;
    dmem_ack = 1; dmem_gnt = 1; #1;
    check_eq("SW@11 load rdata_valid", rdata_valid, 1);
    // Stitched: {second[23:0], first[31:24]} = {0x223344, 0xAA}
    check_eq("SW@11 load rdata", rdata, 32'h223344AA);
  endtask

  // ---------------------------------------------------------------------------
  // Back-to-back transactions (FSM returns to IDLE cleanly)
  // ---------------------------------------------------------------------------

  task automatic test_back_to_back();
    $display("--- Back-to-back ---");
    reset();

    // Store then immediately load at the same address
    set_inputs(1, 32'h1000, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("b2b store rdata_valid", rdata_valid, 1);
    check_eq("b2b store err", err, 0);
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // Next cycle: load at same address, zero-latency
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hCAFEBABE;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("b2b load rdata_valid", rdata_valid, 1);
    check_eq("b2b load rdata", rdata, 32'hCAFEBABE);
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // Crossing store then aligned load
    reset();
    set_inputs(1, 32'h1003, 1, 2'b01, 32'hABCD, 3'b000);
    tick();  // -> MA_FIRST
    dmem_ack = 1; dmem_gnt = 1; tick();
    dmem_ack = 0; dmem_gnt = 0; tick();  // -> MA_SECOND_REQ
    dmem_ack = 1; dmem_gnt = 1; #1;
    check_eq("b2b crossing store rdata_valid", rdata_valid, 1);
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // Immediately do an aligned load -- FSM must be back in IDLE
    set_inputs(1, 32'h2000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'h12345678;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("b2b post-crossing load rdata_valid", rdata_valid, 1);
    check_eq("b2b post-crossing load rdata", rdata, 32'h12345678);
  endtask

  // ---------------------------------------------------------------------------
  // Error: single-beat (aligned)
  // ---------------------------------------------------------------------------

  task automatic test_err_single_beat();
    $display("--- Error: single-beat ---");
    reset();

    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_err = 1;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("single-beat err rdata_valid", rdata_valid, 1);
    check_eq("single-beat err err", err, 1);
    tick();
    dmem_err = 0;
    dmem_ack = 0; dmem_gnt = 0;

    // Verify err is NOT asserted when dmem_err=1 but no ack
    reset();
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_err = 1;
    dmem_ack = 0; dmem_gnt = 0;
    #1;
    check_eq("single-beat no-ack rdata_valid", rdata_valid, 0);
    check_eq("single-beat no-ack err", err, 0);
  endtask

  // ---------------------------------------------------------------------------
  // Error: first-beat abort on crossing (no second beat issued)
  // ---------------------------------------------------------------------------

  task automatic test_err_first_beat_abort();
    $display("--- Error: first-beat abort ---");
    reset();

    set_inputs(1, 32'h1003, 0, 2'b01, 32'h0, 3'b001);
    check_eq("abort cycle0 req", dmem_req, 1);
    check_eq("abort cycle0 rdata_valid", rdata_valid, 0);
    check_eq("abort cycle0 err", err, 0);
    tick();  // -> MA_FIRST

    // MA_FIRST: drive err on ack
    dmem_rdata = 32'hDEADBEEF;
    dmem_err = 1;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("abort cycle1 rdata_valid", rdata_valid, 1);
    check_eq("abort cycle1 err", err, 1);
    tick();  // -> MA_IDLE (abort, not MA_BETWEEN)
    dmem_err = 0;
    dmem_ack = 0; dmem_gnt = 0;

    // Verify FSM is back in IDLE: a new aligned access should work immediately
    set_inputs(1, 32'h2000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hCAFEBABE;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("abort recovery rdata_valid", rdata_valid, 1);
    check_eq("abort recovery rdata", rdata, 32'hCAFEBABE);
    check_eq("abort recovery err", err, 0);
  endtask

  // ---------------------------------------------------------------------------
  // Error: second-beat on crossing
  // ---------------------------------------------------------------------------

  task automatic test_err_second_beat();
    $display("--- Error: second-beat ---");
    reset();

    set_inputs(1, 32'h1003, 0, 2'b01, 32'h0, 3'b001);
    tick();  // -> MA_FIRST

    // MA_FIRST: success
    dmem_rdata = 32'h12345678;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("second-err cycle1 rdata_valid", rdata_valid, 0);
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // MA_SECOND_REQ
    tick();  // -> MA_SECOND_WAIT

    // MA_SECOND: err
    dmem_rdata = 32'hAABBCCDD;
    dmem_err = 1;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("second-err rdata_valid", rdata_valid, 1);
    check_eq("second-err err", err, 1);
    tick();
    dmem_err = 0;
    dmem_ack = 0; dmem_gnt = 0;

    // Verify recovery
    set_inputs(1, 32'h3000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hBEEF1234;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("second-err recovery rdata_valid", rdata_valid, 1);
    check_eq("second-err recovery err", err, 0);
  endtask

  // ---------------------------------------------------------------------------
  // Error: crossing overflow (aligned_base + 4 wraps past 0xFFFFFFFF)
  // ---------------------------------------------------------------------------

  task automatic test_err_overflow();
    $display("--- Error: crossing overflow ---");
    reset();

    // SW@0xFFFFFFFD: addr[1:0]=01 (crossing), addr[31:2] all-ones (overflow)
    set_inputs(1, 32'hFFFFFFFD, 0, 2'b10, 32'h0, 3'b010);
    check_eq("overflow req", dmem_req, 0);
    check_eq("overflow rdata_valid", rdata_valid, 1);
    check_eq("overflow err", err, 1);
    check_eq("overflow addr", dmem_addr, 32'hFFFFFFFC);
    tick();  // FSM stays in IDLE

    // Verify recovery with a normal access
    req = 0;
    #1;
    set_inputs(1, 32'h1000, 0, 2'b10, 32'h0, 3'b010);
    dmem_rdata = 32'hCAFEBABE;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("overflow recovery rdata_valid", rdata_valid, 1);
    check_eq("overflow recovery rdata", rdata, 32'hCAFEBABE);
    check_eq("overflow recovery err", err, 0);

    // Also test SH@0xFFFFFFFF (crossing + overflow)
    reset();
    set_inputs(1, 32'hFFFFFFFF, 1, 2'b01, 32'hABCD, 3'b000);
    check_eq("overflow SH req", dmem_req, 0);
    check_eq("overflow SH rdata_valid", rdata_valid, 1);
    check_eq("overflow SH err", err, 1);
  endtask

  // ---------------------------------------------------------------------------
  // Crossing access with multi-cycle latency (FSM holds under wait)
  // ---------------------------------------------------------------------------

  task automatic test_crossing_with_latency();
    $display("--- Crossing with latency ---");
    reset();

    set_inputs(1, 32'h1003, 0, 2'b01, 32'h0, 3'b001);
    check_eq("lat-cross cycle0 req", dmem_req, 1);
    tick();  // -> MA_FIRST

    // MA_FIRST: hold for 2 cycles with no ack
    check_eq("lat-cross cycle1 req", dmem_req, 1);
    check_eq("lat-cross cycle1 rdata_valid", rdata_valid, 0);
    dmem_ack = 0; dmem_gnt = 0;
    #1;
    tick();  // stay in MA_FIRST

    check_eq("lat-cross cycle2 req", dmem_req, 1);
    check_eq("lat-cross cycle2 rdata_valid", rdata_valid, 0);
    tick();  // stay in MA_FIRST

    // Now ack the first beat
    dmem_rdata = 32'h12345678;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("lat-cross first-ack rdata_valid", rdata_valid, 0);
    tick();
    dmem_ack = 0; dmem_gnt = 0;

    // The second-beat request stays presented while waiting for the first ack.
    check_eq("lat-cross between req", dmem_req, 1);
    tick();  // -> MA_SECOND

    // MA_SECOND: hold for 2 cycles
    check_eq("lat-cross cycle5 req", dmem_req, 1);
    check_eq("lat-cross cycle5 addr", dmem_addr, 32'h1004);
    check_eq("lat-cross cycle5 rdata_valid", rdata_valid, 0);
    dmem_ack = 0; dmem_gnt = 0;
    #1;
    tick();

    check_eq("lat-cross cycle6 rdata_valid", rdata_valid, 0);
    tick();

    // Ack the second beat
    dmem_rdata = 32'hAABBCCDD;
    dmem_ack = 1; dmem_gnt = 1;
    #1;
    check_eq("lat-cross second-ack rdata_valid", rdata_valid, 1);
    check_eq("lat-cross second-ack rdata", rdata, 32'hFFFFDD12);
    tick();
  endtask

  // ---------------------------------------------------------------------------
  // Reset behavior
  // ---------------------------------------------------------------------------

  task automatic test_reset();
    $display("--- Reset ---");
    reset();
    set_inputs(1, 32'h1003, 1, 2'b10, 32'hDEADBEEF, 3'b000);
    tick();  // transitions to MA_FIRST
    reset();  // reset mid-transaction
    check_eq("reset req", dmem_req, 0);
    check_eq("reset rdata_valid", rdata_valid, 0);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------

  initial begin
    reset();

    test_store_positioning();
    test_load_extraction();
    test_load_extraction_all_offsets();
    test_aligned_flow();
    test_non_crossing_sh01();
    test_crossing_sh11_store();
    test_crossing_sh11_load();
    test_crossing_sw01_store();
    test_crossing_sw01_load();
    test_crossing_sw10();
    test_crossing_sw11();
    test_back_to_back();
    test_err_single_beat();
    test_err_first_beat_abort();
    test_err_second_beat();
    test_err_overflow();
    test_crossing_with_latency();
    test_reset();

    $display("\n=== tb_mem_fe: %0d tests, %0d failures ===", tests, failures);
    $finish(failures ? 1 : 0);
  end

endmodule

/* verilator lint_on WIDTHEXPAND */
