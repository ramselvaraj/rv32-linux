// Small fully-associative Sv32 TLB. Entries hold a 4 KiB or 4 MiB translation
// plus the PTE flags {D,A,G,U,X,W,R,V}. No ASIDs: any sfence.vma flushes everything.
module rv_tlb #(
  parameter int N = 4
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        flush,

  input  logic [19:0] vpn,
  output logic        hit,
  output logic [19:0] ppn,
  output logic [7:0]  flags,

  input  logic        fill,
  input  logic [19:0] fill_vpn,
  input  logic [19:0] fill_ppn,
  input  logic [7:0]  fill_flags,
  input  logic        fill_super
);

  logic [N-1:0]           valid_q, super_q;
  logic [19:0]            vpn_q   [N];
  logic [19:0]            ppn_q   [N];
  logic [7:0]             flags_q [N];
  logic [$clog2(N)-1:0]   repl_q;

  always_comb begin
    hit   = 1'b0;
    ppn   = '0;
    flags = '0;
    for (int i = 0; i < N; i++) begin
      if (valid_q[i] && vpn_q[i][19:10] == vpn[19:10] &&
          (super_q[i] || vpn_q[i][9:0] == vpn[9:0])) begin
        hit   = 1'b1;
        ppn   = ppn | (super_q[i] ? {ppn_q[i][19:10], vpn[9:0]} : ppn_q[i]);
        flags = flags | flags_q[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      valid_q <= '0;
      repl_q  <= '0;
    end else if (fill) begin
      valid_q[repl_q] <= 1'b1;
      super_q[repl_q] <= fill_super;
      vpn_q[repl_q]   <= fill_vpn;
      ppn_q[repl_q]   <= fill_ppn;
      flags_q[repl_q] <= fill_flags;
      repl_q          <= repl_q + 1'b1;
    end
  end

endmodule
