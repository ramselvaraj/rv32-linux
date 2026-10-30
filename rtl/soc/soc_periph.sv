// Data-bus decoder for the FPGA SoC: DDR window (forwarded to the AXI bridge), CLINT
// (0x0200_0000) and the 16550 UART (0x1000_0000). Unmapped addresses return a bus error.
module soc_periph #(
  parameter logic [31:0] RAM_BASE  = 32'h8000_0000,
  parameter int          RAM_BYTES = 64 * 1024 * 1024,
  parameter int          MTIME_DIV = 5,           // core clk / timebase-frequency
  parameter int          UART_DIV  = 27
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

  output logic        ram_req_valid,
  output logic        ram_req_we,
  output logic [31:0] ram_req_addr,
  output logic [31:0] ram_req_wdata,
  output logic [3:0]  ram_req_wstrb,
  input  logic        ram_req_ready,
  input  logic        ram_rsp_valid,
  input  logic [31:0] ram_rsp_data,
  input  logic        ram_rsp_err,

  output logic        mtip,
  output logic        msip,
  output logic [63:0] mtime,

  input  logic        uart_rxd,
  output logic        uart_txd
);

  logic sel_ram, sel_clint, sel_uart;
  assign sel_ram   = (req_addr >= RAM_BASE) && (req_addr - RAM_BASE) < 32'(RAM_BYTES);
  assign sel_clint = (req_addr[31:16] == 16'h0200);
  assign sel_uart  = (req_addr[31:12] == 20'h10000);

  logic pend_q, tgt_ram_q, per_valid_q, per_err_q;
  logic [31:0] per_data_q;

  assign rsp_valid = pend_q && (tgt_ram_q ? ram_rsp_valid : per_valid_q);
  assign rsp_data  = tgt_ram_q ? ram_rsp_data : per_data_q;
  assign rsp_err   = tgt_ram_q ? ram_rsp_err  : per_err_q;
  assign req_ready = (!pend_q || rsp_valid) && (!sel_ram || ram_req_ready);

  wire accept = req_valid && req_ready;

  assign ram_req_valid = accept && sel_ram;
  assign ram_req_we    = req_we;
  assign ram_req_addr  = req_addr;
  assign ram_req_wdata = req_wdata;
  assign ram_req_wstrb = req_wstrb;

  // ---- CLINT
  logic [63:0] mtimecmp_q;
  logic        msip_q;
  logic [$clog2(MTIME_DIV)+1:0] mdiv_q;
  assign mtip = (mtime >= mtimecmp_q);
  assign msip = msip_q;

  logic [31:0] clint_rd;
  always_comb begin
    case (req_addr[15:2])
      14'(16'h0000 >> 2): clint_rd = {31'b0, msip_q};
      14'(16'h4000 >> 2): clint_rd = mtimecmp_q[31:0];
      14'(16'h4004 >> 2): clint_rd = mtimecmp_q[63:32];
      14'(16'hBFF8 >> 2): clint_rd = mtime[31:0];
      14'(16'hBFFC >> 2): clint_rd = mtime[63:32];
      default:            clint_rd = 32'd0;
    endcase
  end

  // ---- UART
  logic [31:0] uart_rd;
  soc_uart #(.DIV_DEFAULT(UART_DIV)) u_uart (
    .clk, .rst,
    .access(accept && sel_uart), .we(req_we), .word_sel(req_addr[2]),
    .strb(req_wstrb), .wdata(req_wdata), .rdata(uart_rd),
    .rxd(uart_rxd), .txd(uart_txd)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      pend_q <= 1'b0; per_valid_q <= 1'b0; per_err_q <= 1'b0;
      mtime <= 64'd0; mdiv_q <= '0; mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF; msip_q <= 1'b0;
    end else begin
      per_valid_q <= 1'b0;
      if (int'(mdiv_q) == MTIME_DIV - 1) begin mdiv_q <= '0; mtime <= mtime + 64'd1; end
      else                           mdiv_q <= mdiv_q + 1'b1;
      if (rsp_valid) pend_q <= 1'b0;

      if (accept) begin
        pend_q    <= 1'b1;
        tgt_ram_q <= sel_ram;
        if (!sel_ram) begin
          per_valid_q <= 1'b1;
          per_err_q   <= !(sel_clint || sel_uart);
          per_data_q  <= sel_clint ? clint_rd : sel_uart ? uart_rd : 32'd0;
          if (sel_clint && req_we) begin
            case (req_addr[15:2])
              14'(16'h0000 >> 2): if (req_wstrb[0]) msip_q <= req_wdata[0];
              14'(16'h4000 >> 2): for (int i = 0; i < 4; i++)
                                    if (req_wstrb[i]) mtimecmp_q[8*i +: 8] <= req_wdata[8*i +: 8];
              14'(16'h4004 >> 2): for (int i = 0; i < 4; i++)
                                    if (req_wstrb[i]) mtimecmp_q[32 + 8*i +: 8] <= req_wdata[8*i +: 8];
              14'(16'hBFF8 >> 2): for (int i = 0; i < 4; i++)
                                    if (req_wstrb[i]) mtime[8*i +: 8] <= req_wdata[8*i +: 8];
              14'(16'hBFFC >> 2): for (int i = 0; i < 4; i++)
                                    if (req_wstrb[i]) mtime[32 + 8*i +: 8] <= req_wdata[8*i +: 8];
              default: ;
            endcase
          end
        end
      end
    end
  end

endmodule
