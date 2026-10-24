// Data-bus decoder for the simulation SoC: RAM, CLINT (0x0200_0000) and a minimal
// 16550-style UART (0x1000_0000). Unmapped addresses return a bus error.
module sim_periph #(
  parameter logic [31:0] RAM_BASE  = 32'h8000_0000,
  parameter int          RAM_WORDS = 1 << 22
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
  output logic [63:0] mtime
);

  logic sel_ram, sel_clint, sel_uart;
  assign sel_ram   = (req_addr >= RAM_BASE) && ((req_addr - RAM_BASE) >> 2) < RAM_WORDS;
  assign sel_clint = (req_addr[31:16] == 16'h0200);
  assign sel_uart  = (req_addr[31:12] == 20'h10000);

  logic pend_q, tgt_ram_q, per_valid_q, per_err_q;
  logic [31:0] per_data_q;

  assign rsp_valid = pend_q && (tgt_ram_q ? ram_rsp_valid : per_valid_q);
  assign rsp_data  = tgt_ram_q ? ram_rsp_data : per_data_q;
  assign rsp_err   = tgt_ram_q ? ram_rsp_err  : per_err_q;
  assign req_ready = !pend_q || rsp_valid;

  assign ram_req_valid = req_valid && req_ready && sel_ram;
  assign ram_req_we    = req_we;
  assign ram_req_addr  = req_addr;
  assign ram_req_wdata = req_wdata;
  assign ram_req_wstrb = req_wstrb;

  // ---- CLINT
  logic [63:0] mtimecmp_q;
  logic        msip_q;
  assign mtip  = (mtime >= mtimecmp_q);
  assign msip  = msip_q;

  // ---- UART
  logic [7:0] uart_ier_q, uart_lcr_q, uart_mcr_q, uart_scr_q;

  function automatic logic [7:0] uart_reg(input logic [2:0] r);
    case (r)
      3'd1:    uart_reg = uart_ier_q;
      3'd2:    uart_reg = 8'h01;          // IIR: no interrupt pending
      3'd3:    uart_reg = uart_lcr_q;
      3'd4:    uart_reg = uart_mcr_q;
      3'd5:    uart_reg = 8'h60;          // LSR: THRE | TEMT, no RX data
      3'd7:    uart_reg = uart_scr_q;
      default: uart_reg = 8'h00;
    endcase
  endfunction

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

  always_ff @(posedge clk) begin
    if (rst) begin
      pend_q <= 1'b0; per_valid_q <= 1'b0; per_err_q <= 1'b0;
      mtime <= 64'd0; mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF; msip_q <= 1'b0;
      uart_ier_q <= 8'd0; uart_lcr_q <= 8'd0; uart_mcr_q <= 8'd0; uart_scr_q <= 8'd0;
    end else begin
      mtime       <= mtime + 64'd1;
      per_valid_q <= 1'b0;
      if (rsp_valid) pend_q <= 1'b0;

      if (req_valid && req_ready) begin
        pend_q    <= 1'b1;
        tgt_ram_q <= sel_ram;
        if (!sel_ram) begin
          per_valid_q <= 1'b1;
          per_err_q   <= !(sel_clint || sel_uart);
          per_data_q  <= 32'd0;
          if (sel_clint) begin
            per_data_q <= clint_rd;
            if (req_we) begin
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
          end else if (sel_uart) begin
            per_data_q <= {uart_reg({req_addr[2], 2'd3}), uart_reg({req_addr[2], 2'd2}),
                           uart_reg({req_addr[2], 2'd1}), uart_reg({req_addr[2], 2'd0})};
            if (req_we) begin
              for (int i = 0; i < 4; i++) begin
                if (req_wstrb[i]) begin
                  case ({req_addr[2], 2'(i)})
                    3'd0: $write("%c", req_wdata[8*i +: 8]);
                    3'd1: uart_ier_q <= req_wdata[8*i +: 8];
                    3'd3: uart_lcr_q <= req_wdata[8*i +: 8];
                    3'd4: uart_mcr_q <= req_wdata[8*i +: 8];
                    3'd7: uart_scr_q <= req_wdata[8*i +: 8];
                    default: ;
                  endcase
                end
              end
            end
          end
        end
      end
    end
  end

endmodule
