

`timescale 1 ns / 10 ps
//
`default_nettype none

module tb_kv32;

  logic        clk;
  logic        rst;
  
  logic        halt;

  task static reset();
    rst <= 1'b1;
    repeat (16) @(posedge clk);
    rst <= 1'b0;
  endtask

  task static load_hex(input string fn);
    int fd;
    int c, d;
    string str;
    int offset;

    fd = $fopen(fn, "r");
    if (fd == 0) begin
      c = $ferror(fd, str);
      $fatal("[%t] Can't open file: (%d) %s", $realtime, c, str);
      return;
    end

    while(!$feof(fd)) begin
      // Get line form file
      c = $fgets(str, fd);
      if (c <= 0) begin
        break;
      end

      // Check if this line speficies address offset
      c = $sscanf(str, "@%x", d);
      if (c > 0) begin
        // @xxxx
        offset = d;
        continue;
      end

      // xx xx xx
      for (int i = 0; i < 999; i++) begin
        c = $sscanf(str.substr(i*3, str.len()-1), "%x", d);
        if (c <= 0) begin
          continue;
        end
        // $display("Data: 0x%x = 0x%x", offset, d[7:0]);
        DUT.i_imem.mem[offset/4][(offset%4)*8+7-:8] = d[7:0];
        offset++;
      end
    end

    $fclose(fd);
  endtask


  // Stimulation

  initial begin
    clk = 0;
    forever begin
      #5 clk = ~clk;
    end
  end

  initial begin
    rst = 1;
    #100;
    rst = 0;
  end

  initial begin
    $timeformat(-6, 6, " us", 10);
    $display("***Simulation starts");
    load_hex("boot.hex");
    #10000;
    $finish();
  end

  final begin
    $display("***Simulation ends");
  end

//  initial begin
//    @(posedge clk);
//    forever begin
//      if (imem_en) begin
//        $display("[%t] PC: %x", $realtime, imem_addr);
//        @(posedge clk);
//        $display("[%t] Instr: %x", $realtime, imem_dout);
//        // TODO: maybe add a RISC-V disassmbler here
//      end
//      @(posedge clk);
//    end
//  end

  // DUT

  kv32_top DUT (.*);

endmodule

`default_nettype wire
