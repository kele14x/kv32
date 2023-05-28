`timescale 1 ns / 1 ps
//
`default_nettype none

module control (
    input var        clk,
    input var        rst,
    //
    input var [31:0] pc,
    output var       pc_en,
    //
    output var       halt
);


  typedef enum int {
    S_RST,
    S_RUN,
    S_HALT
  } state_t;

  state_t state, state_next;


  // FSM
  //----

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_RST;
    end else begin
      state <= state_next;
    end
  end

  always_comb begin
    state_next = state;
    case (state)
      S_RST: begin
        state_next = S_RUN;
      end

      S_RUN: begin
        if (pc == '1) begin
          state_next = S_HALT;
        end else begin
          state_next = S_RUN;
        end
      end

      S_HALT: begin
        state_next = S_HALT;
      end

      default: begin
        state_next = S_RST;
      end
    endcase
  end

  assign pc_en = (state == S_RUN);

  assign halt = (state == S_HALT);

endmodule

`default_nettype wire
