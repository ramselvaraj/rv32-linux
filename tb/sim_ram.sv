// Dual-port word RAM (port A: instruction fetch, port B: data) with optional random
// extra latency. Same req/rsp protocol as the core buses.
module sim_ram #(
  parameter int          WORDS     = 1 << 22,           // 16 MiB
  parameter logic [31:0] BASE      = 32'h8000_0000,
  parameter int          MAX_EXTRA = 0                  // random extra wait cycles (0..MAX_EXTRA)
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        a_req_valid,
  input  logic [31:0] a_req_addr,
  output logic        a_req_ready,
  output logic        a_rsp_valid,
  output logic [31:0] a_rsp_data,
  output logic        a_rsp_err,

  input  logic        b_req_valid,
  input  logic        b_req_we,
  input  logic [31:0] b_req_addr,
  input  logic [31:0] b_req_wdata,
  input  logic [3:0]  b_req_wstrb,
  output logic        b_req_ready,
  output logic        b_rsp_valid,
  output logic [31:0] b_rsp_data,
  output logic        b_rsp_err
);

  logic [31:0] mem [WORDS];

  logic [31:0] lfsr_q;
  always_ff @(posedge clk) begin
    if (rst) lfsr_q <= 32'hACE1_1234;
    else     lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
  end

  logic [3:0] extra;
  assign extra = (MAX_EXTRA == 0) ? 4'd0 : 4'(lfsr_q[7:4] % (MAX_EXTRA + 1));

  // ---- port A
  logic        a_pend_q, a_err_q;
  logic [3:0]  a_cnt_q;
  logic [31:0] a_data_q;
  logic [31:0] a_idx;
  logic        a_in;

  assign a_in        = (a_req_addr >= BASE) && ((a_req_addr - BASE) >> 2) < WORDS;
  assign a_idx       = (a_req_addr - BASE) >> 2;
  assign a_rsp_valid = a_pend_q && (a_cnt_q == 4'd0);
  assign a_rsp_data  = a_data_q;
  assign a_rsp_err   = a_err_q;
  assign a_req_ready = !a_pend_q || a_rsp_valid;

  always_ff @(posedge clk) begin
    if (rst) begin
      a_pend_q <= 1'b0;
    end else begin
      if (a_rsp_valid) a_pend_q <= 1'b0;
      else if (a_pend_q) a_cnt_q <= a_cnt_q - 4'd1;
      if (a_req_valid && a_req_ready) begin
        a_pend_q <= 1'b1;
        a_cnt_q  <= extra;
        a_err_q  <= !a_in;
        a_data_q <= a_in ? mem[a_idx[$clog2(WORDS)-1:0]] : 32'd0;
      end
    end
  end

  // ---- port B
  logic        b_pend_q, b_err_q;
  logic [3:0]  b_cnt_q;
  logic [31:0] b_data_q;
  logic [31:0] b_idx;
  logic        b_in;

  assign b_in        = (b_req_addr >= BASE) && ((b_req_addr - BASE) >> 2) < WORDS;
  assign b_idx       = (b_req_addr - BASE) >> 2;
  assign b_rsp_valid = b_pend_q && (b_cnt_q == 4'd0);
  assign b_rsp_data  = b_data_q;
  assign b_rsp_err   = b_err_q;
  assign b_req_ready = !b_pend_q || b_rsp_valid;

  always_ff @(posedge clk) begin
    if (rst) begin
      b_pend_q <= 1'b0;
    end else begin
      if (b_rsp_valid) b_pend_q <= 1'b0;
      else if (b_pend_q) b_cnt_q <= b_cnt_q - 4'd1;
      if (b_req_valid && b_req_ready) begin
        b_pend_q <= 1'b1;
        b_cnt_q  <= extra;
        b_err_q  <= !b_in;
        b_data_q <= b_in ? mem[b_idx[$clog2(WORDS)-1:0]] : 32'd0;
        if (b_in && b_req_we) begin
          for (int i = 0; i < 4; i++)
            if (b_req_wstrb[i]) mem[b_idx[$clog2(WORDS)-1:0]][8*i +: 8] <= b_req_wdata[8*i +: 8];
        end
      end
    end
  end

endmodule
