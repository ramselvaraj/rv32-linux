// 16550-subset UART with real serial lines. 8N1, 16-byte TX and RX FIFOs, DLAB divisor
// (baud = clk / (16 * divisor)), no interrupts (Linux polls an ns16550a without an irq).
// One bus access per call: byte lanes in strb, register = {word_sel, lane}.
module soc_uart #(
  parameter int DIV_DEFAULT = 27     // 50 MHz / (16 * 27) = 115740 baud
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        access,        // one-cycle strobe: a bus request to this UART was accepted
  input  logic        we,
  input  logic        word_sel,      // address bit 2
  input  logic [3:0]  strb,          // byte lanes (writes: store mask, reads: lanes wanted)
  input  logic [31:0] wdata,
  output logic [31:0] rdata,         // valid in the accept cycle

  input  logic        rxd,
  output logic        txd
);

  logic [7:0] ier_q, lcr_q, mcr_q, scr_q, dll_q, dlm_q;
  logic       fifo_en_q, oe_q;
  wire        dlab = lcr_q[7];

  // ---- FIFOs
  logic [7:0] txf [16];
  logic [7:0] rxf [16];
  logic [3:0] txf_wp, txf_rp, rxf_wp, rxf_rp;
  logic [4:0] txf_n, rxf_n;

  // ---- baud: tick16 at 16x the bit rate
  wire [15:0] div = ({dlm_q, dll_q} == 16'd0) ? 16'd1 : {dlm_q, dll_q};
  logic [15:0] bcnt_q;
  wire         tick16 = (bcnt_q == 16'd1);
  always_ff @(posedge clk) begin
    if (rst || tick16 || bcnt_q == 16'd0) bcnt_q <= div;
    else                                  bcnt_q <= bcnt_q - 16'd1;
  end

  // ---- transmitter
  logic [9:0] tsh_q;
  logic [3:0] tbits_q, ttick_q;
  logic       tbusy_q;
  assign txd = tbusy_q ? tsh_q[0] : 1'b1;

  logic tx_pop;
  assign tx_pop = !tbusy_q && (txf_n != 5'd0);

  // ---- receiver
  logic [1:0] rx_sync_q;
  logic       rx_prev_q;
  logic [3:0] rtick_q, rbits_q;
  logic [7:0] rsh_q;
  logic       rbusy_q;
  wire        rxs = rx_sync_q[1];

  logic rx_push;
  logic [7:0] rx_byte;

  // ---- bus side
  function automatic logic [7:0] rd_reg(input logic [2:0] r);
    case (r)
      3'd0:    rd_reg = dlab ? dll_q : (rxf_n != 5'd0 ? rxf[rxf_rp] : 8'h00);
      3'd1:    rd_reg = dlab ? dlm_q : ier_q;
      3'd2:    rd_reg = fifo_en_q ? 8'hC1 : 8'h01;
      3'd3:    rd_reg = lcr_q;
      3'd4:    rd_reg = mcr_q;
      3'd5:    rd_reg = {1'b0, (txf_n == 5'd0) && !tbusy_q, txf_n == 5'd0, 2'b00, 1'b0, oe_q,
                         rxf_n != 5'd0};
      3'd6:    rd_reg = 8'hB0;             // MSR: DCD DSR CTS
      default: rd_reg = scr_q;
    endcase
  endfunction

  always_comb
    for (int i = 0; i < 4; i++) rdata[8*i +: 8] = rd_reg({word_sel, 2'(i)});

  logic rx_pop, tx_push, lsr_read, rxf_clr, txf_clr;
  logic [7:0] tx_byte;

  always_comb begin
    rx_pop = 1'b0; tx_push = 1'b0; tx_byte = 8'h00; lsr_read = 1'b0;
    rxf_clr = 1'b0; txf_clr = 1'b0;
    if (access) begin
      for (int i = 0; i < 4; i++) begin
        if (strb[i]) begin
          if (we) begin
            if ({word_sel, 2'(i)} == 3'd0 && !dlab) begin tx_push = 1'b1; tx_byte = wdata[8*i +: 8]; end
            if ({word_sel, 2'(i)} == 3'd2) begin
              rxf_clr = wdata[8*i + 1];
              txf_clr = wdata[8*i + 2];
            end
          end else begin
            if ({word_sel, 2'(i)} == 3'd0 && !dlab) rx_pop = 1'b1;
            if ({word_sel, 2'(i)} == 3'd5)          lsr_read = 1'b1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ier_q <= 8'd0; lcr_q <= 8'd0; mcr_q <= 8'd0; scr_q <= 8'd0;
      dll_q <= 8'(DIV_DEFAULT & 255); dlm_q <= 8'(DIV_DEFAULT >> 8);
      fifo_en_q <= 1'b0; oe_q <= 1'b0;
      txf_wp <= '0; txf_rp <= '0; txf_n <= '0;
      rxf_wp <= '0; rxf_rp <= '0; rxf_n <= '0;
      tbusy_q <= 1'b0; tsh_q <= 10'h3FF; tbits_q <= '0; ttick_q <= '0;
      rx_sync_q <= 2'b11; rx_prev_q <= 1'b1; rbusy_q <= 1'b0; rtick_q <= '0; rbits_q <= '0; rsh_q <= '0;
    end else begin
      // ---- register writes
      if (access && we) begin
        for (int i = 0; i < 4; i++) begin
          if (strb[i]) begin
            case ({word_sel, 2'(i)})
              3'd0: if (dlab) dll_q <= wdata[8*i +: 8];
              3'd1: if (dlab) dlm_q <= wdata[8*i +: 8]; else ier_q <= wdata[8*i +: 8];
              3'd2: fifo_en_q <= wdata[8*i];
              3'd3: lcr_q <= wdata[8*i +: 8];
              3'd4: mcr_q <= wdata[8*i +: 8];
              3'd7: scr_q <= wdata[8*i +: 8];
              default: ;
            endcase
          end
        end
      end
      if (lsr_read) oe_q <= 1'b0;

      // ---- TX FIFO
      if (txf_clr) begin
        txf_wp <= '0; txf_rp <= '0; txf_n <= '0;
      end else begin
        if (tx_push && txf_n != 5'd16) begin
          txf[txf_wp] <= tx_byte;
          txf_wp <= txf_wp + 4'd1;
        end
        if (tx_pop) txf_rp <= txf_rp + 4'd1;
        txf_n <= txf_n + 5'(tx_push && txf_n != 5'd16) - 5'(tx_pop);
      end

      // ---- transmitter
      if (tx_pop) begin
        tsh_q   <= {1'b1, txf[txf_rp], 1'b0};
        tbusy_q <= 1'b1;
        tbits_q <= 4'd0;
        ttick_q <= 4'd0;
      end else if (tbusy_q && tick16) begin
        ttick_q <= ttick_q + 4'd1;
        if (ttick_q == 4'd15) begin
          tsh_q   <= {1'b1, tsh_q[9:1]};
          tbits_q <= tbits_q + 4'd1;
          if (tbits_q == 4'd9) tbusy_q <= 1'b0;
        end
      end

      // ---- receiver
      rx_sync_q <= {rx_sync_q[0], rxd};
      rx_prev_q <= rxs;
      if (!rbusy_q) begin
        if (rx_prev_q && !rxs) begin     // falling edge: start bit
          rbusy_q <= 1'b1; rtick_q <= 4'd0; rbits_q <= 4'd0;
        end
      end else if (tick16) begin
        rtick_q <= rtick_q + 4'd1;
        if (rbits_q == 4'd0) begin
          if (rtick_q == 4'd7) begin                // middle of start bit
            if (rxs) rbusy_q <= 1'b0;               // glitch
            else begin rbits_q <= 4'd1; rtick_q <= 4'd0; end
          end
        end else if (rtick_q == 4'd15) begin
          rtick_q <= 4'd0;
          if (rbits_q == 4'd9) begin                // stop bit
            rbusy_q <= 1'b0;
          end else begin
            rsh_q   <= {rxs, rsh_q[7:1]};
            rbits_q <= rbits_q + 4'd1;
          end
        end
      end

      // ---- RX FIFO
      if (rxf_clr) begin
        rxf_wp <= '0; rxf_rp <= '0; rxf_n <= '0;
      end else begin
        if (rx_push && rxf_n != 5'd16) begin
          rxf[rxf_wp] <= rx_byte;
          rxf_wp <= rxf_wp + 4'd1;
        end
        if (rx_push && rxf_n == 5'd16) oe_q <= 1'b1;
        if (rx_pop && rxf_n != 5'd0) rxf_rp <= rxf_rp + 4'd1;
        rxf_n <= rxf_n + 5'(rx_push && rxf_n != 5'd16) - 5'(rx_pop && rxf_n != 5'd0);
      end
    end
  end

  // a frame completes at the stop-bit sample point
  assign rx_push = rbusy_q && tick16 && rbits_q == 4'd9 && rtick_q == 4'd15 && rxs;
  assign rx_byte = rsh_q;

endmodule
