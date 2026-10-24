// Simulation top: core + RAM + CLINT + UART. Runs riscv-tests style images.
//   +hex=<file>      readmemh image (word addressed from RAM base)
//   +tohost=<hex>    address of the tohost mailbox (default 0x80001000)
//   +maxcycles=<n>   timeout (default 2,000,000)
//   +trace           print every retired instruction
//   +lat=<n>         random extra memory latency 0..n (compile-time MAX_EXTRA; see Makefile)
//   +dump=<file>     at exit, $writememh the first 1M words of RAM (post-mortem)
//   +halt=<hex>      end simulation (PASS) when this PC retires (for non-riscv-tests payloads)
module tb_top;

  localparam int          RAM_WORDS = 1 << 24;           // 64 MiB
  localparam logic [31:0] RAM_BASE  = 32'h8000_0000;
`ifndef MAX_EXTRA
 `define MAX_EXTRA 0
`endif

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  // core buses
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

  rv_core u_core (
    .clk, .rst,
    .ib_req_valid, .ib_req_addr, .ib_req_ready, .ib_rsp_valid, .ib_rsp_data, .ib_rsp_err,
    .db_req_valid, .db_req_we, .db_req_addr, .db_req_wdata, .db_req_wstrb,
    .db_req_ready, .db_rsp_valid, .db_rsp_data, .db_rsp_err,
    .irq_mtip(mtip), .irq_msip(msip), .irq_meip(1'b0), .irq_seip(1'b0), .time_i(mtime),
    .trace_valid(tr_valid), .trace_pc(tr_pc), .trace_insn(tr_insn),
    .trace_rd(tr_rd), .trace_rd_data(tr_rd_data)
  );

  sim_periph #(.RAM_BASE(RAM_BASE), .RAM_WORDS(RAM_WORDS)) u_periph (
    .clk, .rst,
    .req_valid(db_req_valid), .req_we(db_req_we), .req_addr(db_req_addr),
    .req_wdata(db_req_wdata), .req_wstrb(db_req_wstrb),
    .req_ready(db_req_ready), .rsp_valid(db_rsp_valid), .rsp_data(db_rsp_data), .rsp_err(db_rsp_err),
    .ram_req_valid, .ram_req_we, .ram_req_addr, .ram_req_wdata, .ram_req_wstrb,
    .ram_req_ready, .ram_rsp_valid, .ram_rsp_data, .ram_rsp_err,
    .mtip, .msip, .mtime
  );

  sim_ram #(.WORDS(RAM_WORDS), .BASE(RAM_BASE), .MAX_EXTRA(`MAX_EXTRA)) u_ram (
    .clk, .rst,
    .a_req_valid(ib_req_valid), .a_req_addr(ib_req_addr), .a_req_ready(ib_req_ready),
    .a_rsp_valid(ib_rsp_valid), .a_rsp_data(ib_rsp_data), .a_rsp_err(ib_rsp_err),
    .b_req_valid(ram_req_valid), .b_req_we(ram_req_we), .b_req_addr(ram_req_addr),
    .b_req_wdata(ram_req_wdata), .b_req_wstrb(ram_req_wstrb), .b_req_ready(ram_req_ready),
    .b_rsp_valid(ram_rsp_valid), .b_rsp_data(ram_rsp_data), .b_rsp_err(ram_rsp_err)
  );

  string       hexfile;
  logic [31:0] tohost_addr = 32'h8000_1000;
  logic [31:0] halt_pc     = 32'hFFFF_FFFF;
  int          max_cycles  = 2_000_000;
  bit          do_trace;
  longint      cycle;

  initial begin
    if ($value$plusargs("hex=%s", hexfile)) $readmemh(hexfile, u_ram.mem);
    void'($value$plusargs("tohost=%h", tohost_addr));
    void'($value$plusargs("halt=%h", halt_pc));
    void'($value$plusargs("maxcycles=%d", max_cycles));
    do_trace = $test$plusargs("trace");
    repeat (5) @(posedge clk);
    rst <= 1'b0;
  end

  // tohost mailbox
  always @(posedge clk) begin
    if (!rst && db_req_valid && db_req_ready && db_req_we && db_req_addr == tohost_addr &&
        |db_req_wstrb) begin
      if (db_req_wdata == 32'd1) begin
        $display("PASS (cycles=%0d)", cycle);
        $finish;
      end else begin
        $display("FAIL: tohost=%0d (test %0d) cycles=%0d", db_req_wdata, db_req_wdata >> 1, cycle);
        $finish;
      end
    end
  end

  final begin
    string dumpfile;
    if ($value$plusargs("dump=%s", dumpfile)) $writememh(dumpfile, u_ram.mem, 0, (1 << 20) - 1);
  end

  always @(posedge clk) begin
    cycle <= rst ? 0 : cycle + 1;
    if (do_trace && tr_valid)
      $display("%08x %08x x%0d=%08x", tr_pc, tr_insn, tr_rd, tr_rd_data);
    if (tr_valid && tr_pc == halt_pc) begin
      $display("HALT at %08x (cycles=%0d)", tr_pc, cycle);
      $finish;
    end
    if (cycle >= longint'(max_cycles)) begin
      $display("TIMEOUT after %0d cycles (last retired pc=%08x)", cycle, tr_pc);
      $finish;
    end
  end

endmodule
