// FPGA SoC: rv_core + CLINT + UART, with RAM reached through two AXI3 masters (one per
// core bus) that go to Zynq S_AXI_HP0 (instruction) and S_AXI_HP1 (data).
//
//   RV address 0x8000_0000 + off  ->  AXI address AXI_BASE + off   (RAM_BYTES window)
//   0x0200_0000 CLINT, 0x1000_0000 UART (see soc_periph)
//
// `run` (emio_o[0]) is held low by the ARM until the OpenSBI/kernel image is in DDR.
module rv_soc #(
  parameter logic [31:0] RAM_BASE  = 32'h8000_0000,
  parameter int          RAM_BYTES = 64 * 1024 * 1024,
  parameter logic [31:0] AXI_BASE  = 32'h1C00_0000,
  parameter int          MTIME_DIV = 5,            // 50 MHz clk -> 10 MHz timebase
  parameter int          UART_DIV  = 27            // 50 MHz clk -> ~115200 baud
) (
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI3, ASSOCIATED_BUSIF m_axi_ibus:m_axi_dbus, ASSOCIATED_RESET rstn" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  input  logic        clk,
  input  logic        rstn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWID" *)
  output logic [5:0] m_axi_ibus_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWADDR" *)
  output logic [31:0] m_axi_ibus_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWLEN" *)
  output logic [3:0] m_axi_ibus_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWSIZE" *)
  output logic [2:0] m_axi_ibus_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWBURST" *)
  output logic [1:0] m_axi_ibus_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWLOCK" *)
  output logic [1:0] m_axi_ibus_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWCACHE" *)
  output logic [3:0] m_axi_ibus_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWPROT" *)
  output logic [2:0] m_axi_ibus_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWQOS" *)
  output logic [3:0] m_axi_ibus_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWVALID" *)
  output logic         m_axi_ibus_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus AWREADY" *)
  input  logic         m_axi_ibus_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WID" *)
  output logic [5:0] m_axi_ibus_wid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WDATA" *)
  output logic [31:0] m_axi_ibus_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WSTRB" *)
  output logic [3:0] m_axi_ibus_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WLAST" *)
  output logic         m_axi_ibus_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WVALID" *)
  output logic         m_axi_ibus_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus WREADY" *)
  input  logic         m_axi_ibus_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus BID" *)
  input  logic [5:0] m_axi_ibus_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus BRESP" *)
  input  logic [1:0] m_axi_ibus_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus BVALID" *)
  input  logic         m_axi_ibus_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus BREADY" *)
  output logic         m_axi_ibus_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARID" *)
  output logic [5:0] m_axi_ibus_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARADDR" *)
  output logic [31:0] m_axi_ibus_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARLEN" *)
  output logic [3:0] m_axi_ibus_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARSIZE" *)
  output logic [2:0] m_axi_ibus_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARBURST" *)
  output logic [1:0] m_axi_ibus_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARLOCK" *)
  output logic [1:0] m_axi_ibus_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARCACHE" *)
  output logic [3:0] m_axi_ibus_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARPROT" *)
  output logic [2:0] m_axi_ibus_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARQOS" *)
  output logic [3:0] m_axi_ibus_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARVALID" *)
  output logic         m_axi_ibus_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus ARREADY" *)
  input  logic         m_axi_ibus_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RID" *)
  input  logic [5:0] m_axi_ibus_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RDATA" *)
  input  logic [31:0] m_axi_ibus_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RRESP" *)
  input  logic [1:0] m_axi_ibus_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RLAST" *)
  input  logic         m_axi_ibus_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RVALID" *)
  input  logic         m_axi_ibus_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_ibus RREADY" *)
  output logic         m_axi_ibus_rready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWID" *)
  output logic [5:0] m_axi_dbus_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWADDR" *)
  output logic [31:0] m_axi_dbus_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWLEN" *)
  output logic [3:0] m_axi_dbus_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWSIZE" *)
  output logic [2:0] m_axi_dbus_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWBURST" *)
  output logic [1:0] m_axi_dbus_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWLOCK" *)
  output logic [1:0] m_axi_dbus_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWCACHE" *)
  output logic [3:0] m_axi_dbus_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWPROT" *)
  output logic [2:0] m_axi_dbus_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWQOS" *)
  output logic [3:0] m_axi_dbus_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWVALID" *)
  output logic         m_axi_dbus_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus AWREADY" *)
  input  logic         m_axi_dbus_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WID" *)
  output logic [5:0] m_axi_dbus_wid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WDATA" *)
  output logic [31:0] m_axi_dbus_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WSTRB" *)
  output logic [3:0] m_axi_dbus_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WLAST" *)
  output logic         m_axi_dbus_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WVALID" *)
  output logic         m_axi_dbus_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus WREADY" *)
  input  logic         m_axi_dbus_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus BID" *)
  input  logic [5:0] m_axi_dbus_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus BRESP" *)
  input  logic [1:0] m_axi_dbus_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus BVALID" *)
  input  logic         m_axi_dbus_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus BREADY" *)
  output logic         m_axi_dbus_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARID" *)
  output logic [5:0] m_axi_dbus_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARADDR" *)
  output logic [31:0] m_axi_dbus_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARLEN" *)
  output logic [3:0] m_axi_dbus_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARSIZE" *)
  output logic [2:0] m_axi_dbus_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARBURST" *)
  output logic [1:0] m_axi_dbus_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARLOCK" *)
  output logic [1:0] m_axi_dbus_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARCACHE" *)
  output logic [3:0] m_axi_dbus_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARPROT" *)
  output logic [2:0] m_axi_dbus_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARQOS" *)
  output logic [3:0] m_axi_dbus_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARVALID" *)
  output logic         m_axi_dbus_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus ARREADY" *)
  input  logic         m_axi_dbus_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RID" *)
  input  logic [5:0] m_axi_dbus_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RDATA" *)
  input  logic [31:0] m_axi_dbus_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RRESP" *)
  input  logic [1:0] m_axi_dbus_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RLAST" *)
  input  logic         m_axi_dbus_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RVALID" *)
  input  logic         m_axi_dbus_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dbus RREADY" *)
  output logic         m_axi_dbus_rready,
  // PS EMIO GPIO: emio_o[0] = run, emio_o[6:1] = debug word select (bit 6 set: logic analyzer entry [5:1]); emio_i = status for the ARM
  input  logic [63:0] emio_o,
  output logic [63:0] emio_i,
  input  logic        uart_rxd,
  output logic        uart_txd,
  output logic [3:0]  led
);

  // reset: asserted while the PS reset or `run` is low, released synchronously
  logic [2:0] rst_sync_q;
  wire        arst_n = rstn & emio_o[0];
  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) rst_sync_q <= 3'b000;
    else         rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end
  wire rst = !rst_sync_q[2];

  logic        ib_req_valid, ib_req_ready, ib_rsp_valid, ib_rsp_err;
  logic [31:0] ib_req_addr, ib_rsp_data;
  logic        db_req_valid, db_req_we, db_req_ready, db_rsp_valid, db_rsp_err;
  logic [31:0] db_req_addr, db_req_wdata, db_rsp_data;
  logic [3:0]  db_req_wstrb;

  logic        ram_req_valid, ram_req_we, ram_req_ready, ram_rsp_valid, ram_rsp_err;
  logic [31:0] ram_req_addr, ram_req_wdata, ram_rsp_data;
  logic [3:0]  ram_req_wstrb;

  logic        mtip, msip;
  logic [63:0] mtime;
  logic        tr_valid;
  logic [31:0] tr_pc, tr_insn, tr_rd_data;
  logic [4:0]  tr_rd;
  logic [31:0] core_dbg, core_mcause, core_mepc, core_mtval;

  rv_core #(.RESET_PC(RAM_BASE)) u_core (
    .clk, .rst,
    .ib_req_valid, .ib_req_addr, .ib_req_ready, .ib_rsp_valid, .ib_rsp_data, .ib_rsp_err,
    .db_req_valid, .db_req_we, .db_req_addr, .db_req_wdata, .db_req_wstrb,
    .db_req_ready, .db_rsp_valid, .db_rsp_data, .db_rsp_err,
    .irq_mtip(mtip), .irq_msip(msip), .irq_meip(1'b0), .irq_seip(1'b0), .time_i(mtime),
    .trace_valid(tr_valid), .trace_pc(tr_pc), .trace_insn(tr_insn),
    .trace_rd(tr_rd), .trace_rd_data(tr_rd_data), .dbg(core_dbg),
    .dbg_mcause(core_mcause), .dbg_mepc(core_mepc), .dbg_mtval(core_mtval)
  );

  soc_periph #(.RAM_BASE(RAM_BASE), .RAM_BYTES(RAM_BYTES), .MTIME_DIV(MTIME_DIV),
               .UART_DIV(UART_DIV)) u_periph (
    .clk, .rst,
    .req_valid(db_req_valid), .req_we(db_req_we), .req_addr(db_req_addr),
    .req_wdata(db_req_wdata), .req_wstrb(db_req_wstrb),
    .req_ready(db_req_ready), .rsp_valid(db_rsp_valid), .rsp_data(db_rsp_data), .rsp_err(db_rsp_err),
    .ram_req_valid, .ram_req_we, .ram_req_addr, .ram_req_wdata, .ram_req_wstrb,
    .ram_req_ready, .ram_rsp_valid, .ram_rsp_data, .ram_rsp_err,
    .mtip, .msip, .mtime, .uart_rxd, .uart_txd
  );

  // instruction fetch (read only)
  soc_axi_master #(.RAM_BASE(RAM_BASE), .RAM_BYTES(RAM_BYTES), .AXI_BASE(AXI_BASE)) u_ibus (
    .clk, .rst,
    .req_valid(ib_req_valid), .req_we(1'b0), .req_addr(ib_req_addr),
    .req_wdata(32'd0), .req_wstrb(4'd0),
    .req_ready(ib_req_ready), .rsp_valid(ib_rsp_valid), .rsp_data(ib_rsp_data), .rsp_err(ib_rsp_err),
    .awaddr(m_axi_ibus_awaddr), .awvalid(m_axi_ibus_awvalid), .awready(m_axi_ibus_awready),
    .wdata(m_axi_ibus_wdata), .wstrb(m_axi_ibus_wstrb), .wvalid(m_axi_ibus_wvalid),
    .wready(m_axi_ibus_wready),
    .bresp(m_axi_ibus_bresp), .bvalid(m_axi_ibus_bvalid), .bready(m_axi_ibus_bready),
    .araddr(m_axi_ibus_araddr), .arlen(m_axi_ibus_arlen), .arvalid(m_axi_ibus_arvalid), .arready(m_axi_ibus_arready),
    .rdata(m_axi_ibus_rdata), .rresp(m_axi_ibus_rresp), .rlast(m_axi_ibus_rlast), .rvalid(m_axi_ibus_rvalid),
    .rready(m_axi_ibus_rready)
  );

  // data RAM
  soc_axi_master #(.RAM_BASE(RAM_BASE), .RAM_BYTES(RAM_BYTES), .AXI_BASE(AXI_BASE)) u_dbus (
    .clk, .rst,
    .req_valid(ram_req_valid), .req_we(ram_req_we), .req_addr(ram_req_addr),
    .req_wdata(ram_req_wdata), .req_wstrb(ram_req_wstrb),
    .req_ready(ram_req_ready), .rsp_valid(ram_rsp_valid), .rsp_data(ram_rsp_data),
    .rsp_err(ram_rsp_err),
    .awaddr(m_axi_dbus_awaddr), .awvalid(m_axi_dbus_awvalid), .awready(m_axi_dbus_awready),
    .wdata(m_axi_dbus_wdata), .wstrb(m_axi_dbus_wstrb), .wvalid(m_axi_dbus_wvalid),
    .wready(m_axi_dbus_wready),
    .bresp(m_axi_dbus_bresp), .bvalid(m_axi_dbus_bvalid), .bready(m_axi_dbus_bready),
    .araddr(m_axi_dbus_araddr), .arlen(m_axi_dbus_arlen), .arvalid(m_axi_dbus_arvalid), .arready(m_axi_dbus_arready),
    .rdata(m_axi_dbus_rdata), .rresp(m_axi_dbus_rresp), .rlast(m_axi_dbus_rlast), .rvalid(m_axi_dbus_rvalid),
    .rready(m_axi_dbus_rready)
  );

  // fixed AXI3 attributes: single 32-bit beats, normal non-cacheable
  localparam logic [1:0] INCR = 2'b01;
  assign m_axi_ibus_awid = '0;  assign m_axi_ibus_awlen = '0;  assign m_axi_ibus_awsize = 3'd2;
  assign m_axi_ibus_awburst = INCR; assign m_axi_ibus_awlock = '0; assign m_axi_ibus_awcache = '0;
  assign m_axi_ibus_awprot = '0;    assign m_axi_ibus_awqos = '0;  assign m_axi_ibus_wid = '0;
  assign m_axi_ibus_wlast = 1'b1;
  assign m_axi_ibus_arid = '0;  assign m_axi_ibus_arsize = 3'd2;
  assign m_axi_ibus_arburst = INCR; assign m_axi_ibus_arlock = '0; assign m_axi_ibus_arcache = '0;
  assign m_axi_ibus_arprot = '0;    assign m_axi_ibus_arqos = '0;

  assign m_axi_dbus_awid = '0;  assign m_axi_dbus_awlen = '0;  assign m_axi_dbus_awsize = 3'd2;
  assign m_axi_dbus_awburst = INCR; assign m_axi_dbus_awlock = '0; assign m_axi_dbus_awcache = '0;
  assign m_axi_dbus_awprot = '0;    assign m_axi_dbus_awqos = '0;  assign m_axi_dbus_wid = '0;
  assign m_axi_dbus_wlast = 1'b1;
  assign m_axi_dbus_arid = '0;  assign m_axi_dbus_arsize = 3'd2;
  assign m_axi_dbus_arburst = INCR; assign m_axi_dbus_arlock = '0; assign m_axi_dbus_arcache = '0;
  assign m_axi_dbus_arprot = '0;    assign m_axi_dbus_arqos = '0;


  // ---- debug window for the ARM (emio_i): live status of the buses and the pipeline.
  // Cleared by the core reset, so every run starts from zero.
  //   emio_i[63:32]  word selected by emio_o[5:1]:
  //     0 last retired pc   1 last fetch addr (AXI)   2 last fetch data   3 last data addr (AXI)
  //     4..7 first 4 retired pcs   8..11 first 4 core data-bus requests (addr)
  //     12 {core dreq count, core drsp count, core drsp err count, retired count[7:0]}
  //     13 first core data-bus store data   14,15 last core data-bus addr / wdata
  //   emio_i[31:0]   [7:0] fetch AR count  [15:8] fetch R count  [23:16] data AR+AW count
  //                  [24] fetch err seen [25] data err seen [26] ibus arvalid [27] ibus rready
  //                  [28] dbus busy [29] retired any [30] in reset
  function automatic logic [7:0] sat8(input logic [7:0] c, input logic inc);
    return (inc && c != 8'hFF) ? c + 8'd1 : c;
  endfunction
  logic [31:0] dbg_pc_q, dbg_iaddr_q, dbg_idata_q, dbg_daddr_q;
  logic [31:0] pc_hist_q [4];
  logic [31:0] dreq_hist_q [4];
  logic [31:0] dreq_last_a_q, dreq_last_w_q, dreq_first_w_q;
  logic [7:0]  dbg_iar_q, dbg_ir_q, dbg_d_q, dreq_n_q, drsp_n_q, derr_n_q, ret_n_q;
  logic        dbg_ierr_q, dbg_derr_q, dbg_ret_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      dbg_pc_q <= '0; dbg_iaddr_q <= '0; dbg_idata_q <= '0; dbg_daddr_q <= '0;
      dbg_iar_q <= '0; dbg_ir_q <= '0; dbg_d_q <= '0; dbg_ierr_q <= 1'b0; dbg_derr_q <= 1'b0;
      dbg_ret_q <= 1'b0; dreq_n_q <= '0; drsp_n_q <= '0; derr_n_q <= '0; ret_n_q <= '0;
      dreq_last_a_q <= '0; dreq_last_w_q <= '0; dreq_first_w_q <= '0;
      for (int i = 0; i < 4; i++) begin pc_hist_q[i] <= '0; dreq_hist_q[i] <= '0; end
    end else begin
      if (tr_valid) begin
        dbg_pc_q <= tr_pc; dbg_ret_q <= 1'b1;
        if (ret_n_q < 8'd4) pc_hist_q[ret_n_q[1:0]] <= tr_pc;
        ret_n_q <= sat8(ret_n_q, 1'b1);
      end
      if (m_axi_ibus_arvalid && m_axi_ibus_arready) dbg_iaddr_q <= m_axi_ibus_araddr;
      if (m_axi_ibus_rvalid && m_axi_ibus_rready) begin
        dbg_idata_q <= m_axi_ibus_rdata;
        if (m_axi_ibus_rresp != 2'b00) dbg_ierr_q <= 1'b1;
      end
      if (m_axi_dbus_arvalid && m_axi_dbus_arready) dbg_daddr_q <= m_axi_dbus_araddr;
      if (m_axi_dbus_awvalid && m_axi_dbus_awready) dbg_daddr_q <= m_axi_dbus_awaddr;
      if ((m_axi_dbus_rvalid && m_axi_dbus_rready && m_axi_dbus_rresp != 2'b00) ||
          (m_axi_dbus_bvalid && m_axi_dbus_bready && m_axi_dbus_bresp != 2'b00)) dbg_derr_q <= 1'b1;
      dbg_iar_q <= sat8(dbg_iar_q, m_axi_ibus_arvalid && m_axi_ibus_arready);
      dbg_ir_q  <= sat8(dbg_ir_q,  m_axi_ibus_rvalid && m_axi_ibus_rready);
      dbg_d_q   <= sat8(dbg_d_q, (m_axi_dbus_arvalid && m_axi_dbus_arready) ||
                                 (m_axi_dbus_awvalid && m_axi_dbus_awready));
      // core side of the data bus
      if (db_req_valid && db_req_ready) begin
        if (dreq_n_q < 8'd4) dreq_hist_q[dreq_n_q[1:0]] <= db_req_addr;
        if (dreq_n_q == 8'd0) dreq_first_w_q <= db_req_wdata;
        dreq_last_a_q <= db_req_addr;
        dreq_last_w_q <= db_req_wdata;
        dreq_n_q <= sat8(dreq_n_q, 1'b1);
      end
      if (db_rsp_valid) begin
        drsp_n_q <= sat8(drsp_n_q, 1'b1);
        if (db_rsp_err) derr_n_q <= sat8(derr_n_q, 1'b1);
      end
    end
  end
  logic [31:0] core_dbg_lat_q;   // every core_dbg bit that was ever 1 since reset
  always_ff @(posedge clk) core_dbg_lat_q <= rst ? 32'd0 : (core_dbg_lat_q | core_dbg);
  // first trap since reset (the later ones are the trap loop at mtvec)
  logic [31:0] ft_cause_q, ft_epc_q, ft_tval_q;
  logic        ft_valid_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      ft_cause_q <= '0; ft_epc_q <= '0; ft_tval_q <= '0; ft_valid_q <= 1'b0;
    end else if (!ft_valid_q && (core_mepc != 32'd0 || core_mcause != 32'd0 || core_mtval != 32'd0)) begin
      ft_cause_q <= core_mcause; ft_epc_q <= core_mepc; ft_tval_q <= core_mtval; ft_valid_q <= 1'b1;
    end
  end
  // data of the first two instruction-fetch responses, on AXI and as the core sees them
  logic [31:0] axi_r_first_q [2];
  logic [31:0] core_r_first_q [2];
  logic [1:0]  core_r_n_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 2; i++) begin axi_r_first_q[i] <= '0; core_r_first_q[i] <= '0; end
      core_r_n_q <= '0;
    end else begin
      if (m_axi_ibus_rvalid && m_axi_ibus_rready && dbg_ir_q < 8'd2)
        axi_r_first_q[dbg_ir_q[0]] <= m_axi_ibus_rdata;
      if (ib_rsp_valid && core_r_n_q < 2'd2) begin
        core_r_first_q[core_r_n_q[0]] <= ib_rsp_data;
        core_r_n_q <= core_r_n_q + 2'd1;
      end
    end
  end
  // mini logic analyzer: 32 cycles of the fetch AXI read channel, from the first AR
  //   entry = {2'b0, arvalid, arready, rvalid, rready, rlast, core req_valid, core req_ready, araddr[4:2], rdata[19:0]}
  logic [31:0] la_mem [32];
  logic [5:0]  la_n_q;
  logic        la_run_q;
  wire  [31:0] la_entry = {2'b00, m_axi_ibus_arvalid, m_axi_ibus_arready, m_axi_ibus_rvalid,
                           m_axi_ibus_rready, m_axi_ibus_rlast, ib_req_valid, ib_req_ready,
                           m_axi_ibus_araddr[4:2], m_axi_ibus_rdata[19:0]};
  always_ff @(posedge clk) begin
    if (rst) begin
      la_n_q <= '0; la_run_q <= 1'b0;
      for (int i = 0; i < 32; i++) la_mem[i] <= '0;
    end else begin
      if (m_axi_ibus_arvalid) la_run_q <= 1'b1;
      if ((la_run_q || m_axi_ibus_arvalid) && la_n_q < 6'd32) begin
        la_mem[la_n_q[4:0]] <= la_entry;
        la_n_q <= la_n_q + 6'd1;
      end
    end
  end
  logic [31:0] dbg_word;
  always_comb begin
    if (emio_o[6]) dbg_word = la_mem[emio_o[5:1]];
    else case (emio_o[5:1])
      5'd0:  dbg_word = dbg_pc_q;
      5'd1:  dbg_word = dbg_iaddr_q;
      5'd2:  dbg_word = dbg_idata_q;
      5'd3:  dbg_word = dbg_daddr_q;
      5'd4, 5'd5, 5'd6, 5'd7:     dbg_word = pc_hist_q[emio_o[2:1]];
      5'd8, 5'd9, 5'd10, 5'd11:   dbg_word = dreq_hist_q[emio_o[2:1]];
      5'd12: dbg_word = {dreq_n_q, drsp_n_q, derr_n_q, ret_n_q};
      5'd13: dbg_word = dreq_first_w_q;
      5'd14: dbg_word = dreq_last_a_q;
      5'd16: dbg_word = core_dbg;
      5'd17: dbg_word = core_dbg_lat_q;
      5'd18: dbg_word = core_mcause;
      5'd19: dbg_word = core_mepc;
      5'd20: dbg_word = core_mtval;
      5'd21: dbg_word = ft_cause_q;
      5'd22: dbg_word = ft_epc_q;
      5'd23: dbg_word = ft_tval_q;
      5'd24: dbg_word = axi_r_first_q[0];
      5'd25: dbg_word = axi_r_first_q[1];
      5'd26: dbg_word = core_r_first_q[0];
      5'd27: dbg_word = core_r_first_q[1];
      default: dbg_word = dreq_last_w_q;
    endcase
  end
  assign emio_i = {dbg_word, 1'b0, rst, dbg_ret_q, !ram_req_ready, m_axi_ibus_rready,
                   m_axi_ibus_arvalid, dbg_derr_q, dbg_ierr_q, dbg_d_q, dbg_ir_q, dbg_iar_q};

  // LEDs: running, uart tx, uart rx, timer pending
  assign led = {mtip, uart_rxd, uart_txd, !rst};

  // unused
  logic unused;
  assign unused = &{1'b0, tr_valid, tr_pc, tr_insn, tr_rd, tr_rd_data,
                    m_axi_ibus_bid, m_axi_ibus_rid,
                    m_axi_dbus_bid, m_axi_dbus_rid, emio_o[63:7]};

endmodule
