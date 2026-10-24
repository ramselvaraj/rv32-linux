// Shares the single data-bus port between the load/store unit and the page-table
// walker. One request may be accepted per cycle; responses return in order and are
// steered to the master that issued the matching request.
module rv_dmux (
  input  logic        clk,
  input  logic        rst,

  input  logic        m_req_valid,
  input  logic        m_req_we,
  input  logic [31:0] m_req_addr,
  input  logic [31:0] m_req_wdata,
  input  logic [3:0]  m_req_wstrb,
  output logic        m_req_ready,
  output logic        m_rsp_valid,

  input  logic        p_req_valid,
  input  logic [31:0] p_req_addr,
  output logic        p_req_ready,
  output logic        p_rsp_valid,

  output logic [31:0] rsp_data,
  output logic        rsp_err,

  output logic        s_req_valid,
  output logic        s_req_we,
  output logic [31:0] s_req_addr,
  output logic [31:0] s_req_wdata,
  output logic [3:0]  s_req_wstrb,
  input  logic        s_req_ready,
  input  logic        s_rsp_valid,
  input  logic [31:0] s_rsp_data,
  input  logic        s_rsp_err
);

  logic owner_m_q;   // owner of the outstanding request (1 = LSU, 0 = PTW)

  assign s_req_valid = m_req_valid | p_req_valid;
  assign s_req_we    = m_req_valid ? m_req_we    : 1'b0;
  assign s_req_addr  = m_req_valid ? m_req_addr  : p_req_addr;
  assign s_req_wdata = m_req_wdata;
  assign s_req_wstrb = m_req_valid ? m_req_wstrb : 4'b0000;

  assign m_req_ready = s_req_ready && m_req_valid;
  assign p_req_ready = s_req_ready && p_req_valid && !m_req_valid;

  assign m_rsp_valid = s_rsp_valid && owner_m_q;
  assign p_rsp_valid = s_rsp_valid && !owner_m_q;
  assign rsp_data    = s_rsp_data;
  assign rsp_err     = s_rsp_err;

  always_ff @(posedge clk) begin
    if (rst) owner_m_q <= 1'b0;
    else if (s_req_valid && s_req_ready) owner_m_q <= m_req_valid;
  end

endmodule
