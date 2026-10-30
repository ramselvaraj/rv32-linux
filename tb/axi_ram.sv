// Two-port AXI3 slave memory (single beat, 32-bit) with random latency, standing in for the
// Zynq HP ports + DDR. Port 0 = instruction, port 1 = data; both share one array.
module axi_ram #(
  parameter int          WORDS     = 1 << 24,
  parameter logic [31:0] BASE      = 32'h1C00_0000,
  parameter int          MAX_DELAY = 8
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  awvalid, output logic [1:0] awready,
  input  logic [31:0] awaddr [2],
  input  logic [1:0]  wvalid,  output logic [1:0] wready,
  input  logic [31:0] wdata  [2],
  input  logic [3:0]  wstrb  [2],
  output logic [1:0]  bvalid,  input  logic [1:0] bready,
  output logic [1:0]  bresp  [2],
  input  logic [1:0]  arvalid, output logic [1:0] arready,
  input  logic [31:0] araddr [2],
  input  logic [3:0]  arlen  [2],
  output logic [1:0]  rvalid,  input  logic [1:0] rready,
  output logic [31:0] rdata  [2],
  output logic [1:0]  rlast,
  output logic [1:0]  rresp  [2]
);

  logic [31:0] mem [WORDS];
  int max_delay = MAX_DELAY;
  initial void'($value$plusargs("delay=%d", max_delay));

  function automatic bit in_range(input logic [31:0] a);
    return a >= BASE && ((a - BASE) >> 2) < WORDS;
  endfunction
  function automatic int idx(input logic [31:0] a);
    return int'((a - BASE) >> 2);
  endfunction

  for (genvar p = 0; p < 2; p++) begin : g_port
    // ---- reads
    logic        r_pend_q;
    int          r_cnt_q;
    logic [31:0] r_addr_q;
    logic [3:0]  r_left_q;
    assign arready[p] = !r_pend_q;
    assign rvalid[p]  = r_pend_q && r_cnt_q == 0;
    assign rlast[p]   = r_left_q == 4'd0;
    assign rdata[p]   = in_range(r_addr_q) ? mem[idx(r_addr_q)] : 32'hDEAD_BEEF;
    assign rresp[p]   = in_range(r_addr_q) ? 2'b00 : 2'b11;

    always_ff @(posedge clk) begin
      if (rst) r_pend_q <= 1'b0;
      else begin
        if (rvalid[p] && rready[p]) begin
          if (r_left_q == 4'd0) r_pend_q <= 1'b0;
          else begin r_left_q <= r_left_q - 4'd1; r_addr_q <= r_addr_q + 32'd4; end
        end
        else if (r_pend_q && r_cnt_q > 0) r_cnt_q <= r_cnt_q - 1;
        if (arvalid[p] && arready[p]) begin
          r_pend_q <= 1'b1;
          r_addr_q <= araddr[p];
          r_left_q <= arlen[p];
          r_cnt_q  <= int'($urandom_range(max_delay));
        end
      end
    end

    // ---- writes (AW and W in any order)
    logic        aw_got_q, w_got_q, b_pend_q;
    int          b_cnt_q;
    logic [31:0] w_addr_q, w_data_q;
    logic [3:0]  w_strb_q;
    assign awready[p] = !aw_got_q && !b_pend_q;
    assign wready[p]  = !w_got_q && !b_pend_q;
    assign bvalid[p]  = b_pend_q && b_cnt_q == 0;
    assign bresp[p]   = in_range(w_addr_q) ? 2'b00 : 2'b11;

    always_ff @(posedge clk) begin
      if (rst) begin
        aw_got_q <= 1'b0; w_got_q <= 1'b0; b_pend_q <= 1'b0;
      end else begin
        if (awvalid[p] && awready[p]) begin aw_got_q <= 1'b1; w_addr_q <= awaddr[p]; end
        if (wvalid[p] && wready[p])   begin w_got_q <= 1'b1; w_data_q <= wdata[p]; w_strb_q <= wstrb[p]; end
        if (aw_got_q && w_got_q && !b_pend_q) begin
          if (in_range(w_addr_q))
            for (int i = 0; i < 4; i++)
              if (w_strb_q[i]) mem[idx(w_addr_q)][8*i +: 8] <= w_data_q[8*i +: 8];
          b_pend_q <= 1'b1;
          b_cnt_q  <= int'($urandom_range(max_delay));
        end
        if (bvalid[p] && bready[p]) begin
          b_pend_q <= 1'b0; aw_got_q <= 1'b0; w_got_q <= 1'b0;
        end else if (b_pend_q && b_cnt_q > 0) b_cnt_q <= b_cnt_q - 1;
      end
    end
  end

endmodule
