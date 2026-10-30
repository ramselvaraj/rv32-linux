// Bench for the FPGA SoC (rv_soc): core + CLINT + serial UART + AXI bridges against an AXI
// memory model. UART output is decoded from the real txd line at the divisor's baud.
//   +hex=<file>     image, word addressed from RAM base
//   +halt=<hex>     end (PASS) when this PC retires
//   +maxcycles=<n>  timeout
//   +delay=<n>      max random AXI latency (default 8)
module tb_soc;

  localparam int          RAM_WORDS = 1 << 24;
  localparam logic [31:0] AXI_BASE  = 32'h1C00_0000;
  localparam int          UART_DIV  = 27;
  localparam int          BIT_CYC   = 16 * UART_DIV;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  logic run  = 1'b0;
  logic [63:0] emio_i;
  always #5 clk = ~clk;

  logic [1:0]  awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] awaddr [2], wdata [2], araddr [2], rdata [2];
  logic [3:0]  wstrb [2], arlen [2];
  logic [1:0]  rlast;
  logic [1:0]  bresp [2], rresp [2];
  logic        uart_txd;
  logic [3:0]  led;

  rv_soc #(.AXI_BASE(AXI_BASE), .UART_DIV(UART_DIV)) u_soc (
    .clk, .rstn, .emio_o({63'd0, run}), .emio_i,
    .m_axi_ibus_awid(), .m_axi_ibus_awaddr(awaddr[0]), .m_axi_ibus_awlen(), .m_axi_ibus_awsize(),
    .m_axi_ibus_awburst(), .m_axi_ibus_awlock(), .m_axi_ibus_awcache(), .m_axi_ibus_awprot(),
    .m_axi_ibus_awqos(), .m_axi_ibus_awvalid(awvalid[0]), .m_axi_ibus_awready(awready[0]),
    .m_axi_ibus_wid(), .m_axi_ibus_wdata(wdata[0]), .m_axi_ibus_wstrb(wstrb[0]),
    .m_axi_ibus_wlast(), .m_axi_ibus_wvalid(wvalid[0]), .m_axi_ibus_wready(wready[0]),
    .m_axi_ibus_bid(6'd0), .m_axi_ibus_bresp(bresp[0]), .m_axi_ibus_bvalid(bvalid[0]),
    .m_axi_ibus_bready(bready[0]),
    .m_axi_ibus_arid(), .m_axi_ibus_araddr(araddr[0]), .m_axi_ibus_arlen(arlen[0]), .m_axi_ibus_arsize(),
    .m_axi_ibus_arburst(), .m_axi_ibus_arlock(), .m_axi_ibus_arcache(), .m_axi_ibus_arprot(),
    .m_axi_ibus_arqos(), .m_axi_ibus_arvalid(arvalid[0]), .m_axi_ibus_arready(arready[0]),
    .m_axi_ibus_rid(6'd0), .m_axi_ibus_rdata(rdata[0]), .m_axi_ibus_rresp(rresp[0]),
    .m_axi_ibus_rlast(rlast[0]), .m_axi_ibus_rvalid(rvalid[0]), .m_axi_ibus_rready(rready[0]),

    .m_axi_dbus_awid(), .m_axi_dbus_awaddr(awaddr[1]), .m_axi_dbus_awlen(), .m_axi_dbus_awsize(),
    .m_axi_dbus_awburst(), .m_axi_dbus_awlock(), .m_axi_dbus_awcache(), .m_axi_dbus_awprot(),
    .m_axi_dbus_awqos(), .m_axi_dbus_awvalid(awvalid[1]), .m_axi_dbus_awready(awready[1]),
    .m_axi_dbus_wid(), .m_axi_dbus_wdata(wdata[1]), .m_axi_dbus_wstrb(wstrb[1]),
    .m_axi_dbus_wlast(), .m_axi_dbus_wvalid(wvalid[1]), .m_axi_dbus_wready(wready[1]),
    .m_axi_dbus_bid(6'd0), .m_axi_dbus_bresp(bresp[1]), .m_axi_dbus_bvalid(bvalid[1]),
    .m_axi_dbus_bready(bready[1]),
    .m_axi_dbus_arid(), .m_axi_dbus_araddr(araddr[1]), .m_axi_dbus_arlen(arlen[1]), .m_axi_dbus_arsize(),
    .m_axi_dbus_arburst(), .m_axi_dbus_arlock(), .m_axi_dbus_arcache(), .m_axi_dbus_arprot(),
    .m_axi_dbus_arqos(), .m_axi_dbus_arvalid(arvalid[1]), .m_axi_dbus_arready(arready[1]),
    .m_axi_dbus_rid(6'd0), .m_axi_dbus_rdata(rdata[1]), .m_axi_dbus_rresp(rresp[1]),
    .m_axi_dbus_rlast(rlast[1]), .m_axi_dbus_rvalid(rvalid[1]), .m_axi_dbus_rready(rready[1]),

    .uart_rxd(1'b1), .uart_txd, .led
  );

  axi_ram #(.WORDS(RAM_WORDS), .BASE(AXI_BASE)) u_ram (
    .clk, .rst(!rstn),
    .awvalid, .awready, .awaddr, .wvalid, .wready, .wdata, .wstrb, .bvalid, .bready, .bresp,
    .arvalid, .arready, .araddr, .arlen, .rvalid, .rready, .rdata, .rlast, .rresp
  );

  string       hexfile;
  logic [31:0] halt_pc    = 32'hFFFF_FFFF;
  int          max_cycles = 2_000_000;
  longint      cycle;

  initial begin
    if ($value$plusargs("hex=%s", hexfile)) $readmemh(hexfile, u_ram.mem);
    void'($value$plusargs("halt=%h", halt_pc));
    void'($value$plusargs("maxcycles=%d", max_cycles));
    repeat (5) @(posedge clk);
    rstn <= 1'b1;
    repeat (5) @(posedge clk);
    run  <= 1'b1;               // the ARM releases the core
  end

  // UART monitor: start-bit edge, sample mid-bit
  initial begin
    logic [7:0] b;
    forever begin
      @(negedge uart_txd);
      repeat (BIT_CYC + BIT_CYC / 2) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        b[i] = uart_txd;
        repeat (BIT_CYC) @(posedge clk);
      end
      $write("%c", b);
      $fflush();
    end
  end

  int dbg_n = 0;
  always @(posedge clk) begin
    if (arvalid[1] && arready[1] && dbg_n < 6) begin dbg_n++; $display("DBG cycle %0d data AR %08x", cycle, araddr[1]); end
    if (awvalid[1] && awready[1] && dbg_n < 6) begin dbg_n++; $display("DBG cycle %0d data AW %08x", cycle, awaddr[1]); end
  end

  always @(posedge clk) begin
    cycle <= !run ? 0 : cycle + 1;
    if (u_soc.tr_valid && u_soc.tr_pc == halt_pc) begin
      $display("HALT at %08x (cycles=%0d)", u_soc.tr_pc, cycle);
      $finish;
    end
    if (cycle >= longint'(max_cycles)) begin
      $display("TIMEOUT after %0d cycles (last retired pc=%08x)", cycle, u_soc.tr_pc);
      $finish;
    end
  end

  final begin
    $display("DBGSTATE iar=%0d ir=%0d d=%0d pc=%08x iaddr=%08x idata=%08x daddr=%08x ierr=%b derr=%b",
             u_soc.dbg_iar_q, u_soc.dbg_ir_q, u_soc.dbg_d_q, u_soc.dbg_pc_q, u_soc.dbg_iaddr_q,
             u_soc.dbg_idata_q, u_soc.dbg_daddr_q, u_soc.dbg_ierr_q, u_soc.dbg_derr_q);
  end

endmodule
