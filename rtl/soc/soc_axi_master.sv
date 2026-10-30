// Core req/rsp bus -> AXI3 master (single outstanding, 32-bit, INCR len 1). The request is
// latched on accept, so the core may withdraw req_valid afterwards. Addresses outside the
// RAM window get an immediate bus error without touching AXI. AXI errors become rsp_err.
// rready/bready are always high so a response left over from before a reset (the PS ports
// outlive the PL) drains instead of being mistaken for the next request's answer.
// Reads are aligned 2-beat bursts (the Zynq HP port returned the wrong word for single reads
// of the odd word); the beat selected by address bit 2 is the answer.
// The RAM window is remapped: core RAM_BASE.. -> AXI_BASE..
module soc_axi_master #(
  parameter logic [31:0] RAM_BASE  = 32'h8000_0000,
  parameter int          RAM_BYTES = 64 * 1024 * 1024,
  parameter logic [31:0] AXI_BASE  = 32'h1C00_0000
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        req_valid,
  input  logic        req_we,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic        req_ready,
  output logic        rsp_valid,
  output logic [31:0] rsp_data,
  output logic        rsp_err,

  output logic [31:0] awaddr, output logic awvalid, input logic awready,
  output logic [31:0] wdata,  output logic [3:0] wstrb, output logic wvalid, input logic wready,
  input  logic [1:0]  bresp,  input  logic bvalid, output logic bready,
  output logic [31:0] araddr, output logic [3:0] arlen, output logic arvalid, input logic arready,
  input  logic [31:0] rdata,  input  logic [1:0] rresp, input logic rlast, input logic rvalid, output logic rready
);

  typedef enum logic [1:0] { S_IDLE, S_WR, S_RD } state_e;
  state_e state_q;

  logic [31:0] addr_q, wdata_q;
  logic [3:0]  wstrb_q;
  logic        aw_done_q, w_done_q;
  logic        beat_q, rerr_q;
  logic [31:0] beat0_q;

  wire in_range = (req_addr >= RAM_BASE) && (req_addr - RAM_BASE) < 32'(RAM_BYTES);
  assign req_ready = (state_q == S_IDLE) && !rsp_valid;

  wire [31:0] axi_addr = AXI_BASE + (req_addr - RAM_BASE);

  assign awaddr  = addr_q;
  assign awvalid = (state_q == S_WR) && !aw_done_q;
  assign wdata   = wdata_q;
  assign wstrb   = wstrb_q;
  assign wvalid  = (state_q == S_WR) && !w_done_q;
  assign bready  = 1'b1;
  assign araddr  = {addr_q[31:3], 3'b000};
  assign arlen   = 4'd1;
  assign arvalid = (state_q == S_RD) && !aw_done_q;
  assign rready  = 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE; rsp_valid <= 1'b0; rsp_data <= 32'd0; rsp_err <= 1'b0;
      aw_done_q <= 1'b0; w_done_q <= 1'b0;
    end else begin
      rsp_valid <= 1'b0;
      case (state_q)
        S_IDLE: if (req_valid && req_ready) begin
          addr_q  <= axi_addr;
          wdata_q <= req_wdata;
          wstrb_q <= req_wstrb;
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          beat_q    <= 1'b0;
          rerr_q    <= 1'b0;
          if (!in_range) begin
            rsp_valid <= 1'b1; rsp_data <= 32'd0; rsp_err <= 1'b1;
          end else begin
            state_q <= req_we ? S_WR : S_RD;
          end
        end
        S_WR: begin
          if (awvalid && awready) aw_done_q <= 1'b1;
          if (wvalid && wready)   w_done_q  <= 1'b1;
          if (bvalid && aw_done_q && w_done_q) begin
            state_q <= S_IDLE; rsp_valid <= 1'b1; rsp_data <= 32'd0; rsp_err <= (bresp != 2'b00);
          end
        end
        S_RD: begin
          if (arvalid && arready) aw_done_q <= 1'b1;
          if (rvalid && aw_done_q) begin
            if (!beat_q) begin
              beat0_q <= rdata; rerr_q <= (rresp != 2'b00); beat_q <= 1'b1;
            end else begin
              state_q   <= S_IDLE;
              rsp_valid <= 1'b1;
              rsp_data  <= addr_q[2] ? rdata : beat0_q;
              rsp_err   <= rerr_q || (rresp != 2'b00);
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
