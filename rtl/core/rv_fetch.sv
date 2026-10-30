// Instruction fetch: translates the PC through an iTLB, issues word reads on the
// instruction bus and queues the results (or a fetch fault) for decode.
//
// Bus protocol (one request outstanding): a request is accepted when
// req_valid && req_ready; the response arrives later as rsp_valid. A new request
// may be accepted in the same cycle the previous response is returned.
module rv_fetch
  import rv_pkg::*;
#(
  parameter logic [31:0] RESET_PC    = 32'h8000_0000,
  parameter int          TLB_ENTRIES = 4
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,

  input  logic        xlate_en,
  input  logic        priv_u,
  input  logic        tlb_flush,

  output logic        ib_req_valid,
  output logic [31:0] ib_req_addr,
  input  logic        ib_req_ready,
  input  logic        ib_rsp_valid,
  input  logic [31:0] ib_rsp_data,
  input  logic        ib_rsp_err,

  output logic        ptw_req,
  output logic [19:0] ptw_vpn,
  input  logic        ptw_ack,
  input  logic        ptw_done,
  input  logic        ptw_fault,
  input  logic        ptw_afault,
  input  logic        fill_valid,
  input  logic [19:0] fill_vpn,
  input  logic [19:0] fill_ppn,
  input  logic [7:0]  fill_flags,
  input  logic        fill_super,

  output logic        out_valid,
  output logic [31:0] out_pc,
  output logic [31:0] out_insn,
  output logic        out_exc,
  output logic [4:0]  out_cause,
  input  logic        out_ready,

  output logic [7:0]  dbg
);

  localparam int DEPTH = 4;

  logic [31:0] pc_q, ifl_pc_q;
  logic        inflight_q, discard_q, halt_q, ptw_wait_q, fault_pend_q;
  logic [4:0]  fault_cause_q;

  logic [31:0] q_pc    [DEPTH];
  logic [31:0] q_insn  [DEPTH];
  logic        q_exc   [DEPTH];
  logic [4:0]  q_cause [DEPTH];
  logic [1:0]  wr_q, rd_q;
  logic [2:0]  cnt_q;

  // ---- translation
  logic        tlb_hit;
  logic [19:0] tlb_ppn;
  logic [7:0]  tlb_flags;
  logic        perm_ok;

  rv_tlb #(.N(TLB_ENTRIES)) u_itlb (
    .clk, .rst, .flush(tlb_flush),
    .vpn(pc_q[31:12]), .hit(tlb_hit), .ppn(tlb_ppn), .flags(tlb_flags),
    .fill(fill_valid), .fill_vpn, .fill_ppn, .fill_flags, .fill_super
  );

  assign perm_ok = pte_ok(tlb_flags, ACC_X, priv_u, 1'b0, 1'b0);

  // ---- control
  logic room, xl_fault_now, push_fault, push_rsp, issue_ok, pop;

  assign room         = ({1'b0, cnt_q} + {2'b0, inflight_q}) < 4'(DEPTH);
  assign xl_fault_now = xlate_en && tlb_hit && !perm_ok;
  assign push_fault   = !halt_q && (fault_pend_q || xl_fault_now) &&
                        !inflight_q && (cnt_q < 3'(DEPTH)) && !redirect_valid;
  assign push_rsp     = ib_rsp_valid && inflight_q && !discard_q && !redirect_valid;
  assign issue_ok     = !halt_q && !fault_pend_q && room &&
                        (!inflight_q || ib_rsp_valid) &&
                        (!xlate_en || (tlb_hit && perm_ok));

  assign ib_req_valid = issue_ok && !redirect_valid;
  assign ib_req_addr  = xlate_en ? {tlb_ppn, pc_q[11:0]} : pc_q;

  assign ptw_req = xlate_en && !tlb_hit && !halt_q && !fault_pend_q &&
                   !ptw_wait_q && !redirect_valid;
  assign ptw_vpn = pc_q[31:12];

  assign out_valid = (cnt_q != 3'd0);
  assign out_pc    = q_pc[rd_q];
  assign out_insn  = q_insn[rd_q];
  assign out_exc   = q_exc[rd_q];
  assign out_cause = q_cause[rd_q];
  assign pop       = out_valid && out_ready;

  logic push;
  assign push = push_fault || push_rsp;
  assign dbg  = {1'b0, inflight_q, discard_q, halt_q, ptw_wait_q, fault_pend_q, cnt_q[1:0]};


  always_ff @(posedge clk) begin
    if (rst) begin
      pc_q         <= RESET_PC;
      inflight_q   <= 1'b0;
      discard_q    <= 1'b0;
      halt_q       <= 1'b0;
      ptw_wait_q   <= 1'b0;
      fault_pend_q <= 1'b0;
      wr_q         <= '0;
      rd_q         <= '0;
      cnt_q        <= '0;
    end else begin
      if (ptw_ack) ptw_wait_q <= 1'b1;
      if (ptw_done && ptw_wait_q) begin
        ptw_wait_q <= 1'b0;
        if (ptw_fault) begin
          fault_pend_q  <= 1'b1;
          fault_cause_q <= ptw_afault ? EXC_INSN_ACCESS : EXC_INSN_PAGE;
        end
      end

      if (ib_rsp_valid && inflight_q) begin
        inflight_q <= 1'b0;
        discard_q  <= 1'b0;
      end
      if (ib_req_valid && ib_req_ready) begin
        inflight_q <= 1'b1;
        ifl_pc_q   <= pc_q;
        pc_q       <= pc_q + 32'd4;
      end

      if (push) begin
        q_pc[wr_q]    <= push_fault ? pc_q : ifl_pc_q;
        q_insn[wr_q]  <= push_fault ? 32'd0 : ib_rsp_data;
        q_exc[wr_q]   <= push_fault | ib_rsp_err;
        q_cause[wr_q] <= push_fault ? (fault_pend_q ? fault_cause_q : EXC_INSN_PAGE)
                                    : EXC_INSN_ACCESS;
        wr_q          <= wr_q + 2'd1;
        if (push_fault) begin
          halt_q       <= 1'b1;
          fault_pend_q <= 1'b0;
        end else if (ib_rsp_err) begin
          halt_q       <= 1'b1;
        end
      end
      if (pop) rd_q <= rd_q + 2'd1;
      cnt_q <= cnt_q + 3'(push) - 3'(pop);

      if (redirect_valid) begin
        pc_q         <= redirect_pc;
        cnt_q        <= '0;
        wr_q         <= '0;
        rd_q         <= '0;
        halt_q       <= 1'b0;
        fault_pend_q <= 1'b0;
        ptw_wait_q   <= 1'b0;
        inflight_q   <= inflight_q && !ib_rsp_valid;
        discard_q    <= inflight_q && !ib_rsp_valid;
      end
    end
  end

endmodule
