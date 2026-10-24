// Sv32 hardware page-table walker shared by the instruction and data sides.
// Read-only: pages with A=0 (or D=0 on a store) raise page faults and software
// updates the PTE (Svade behaviour), which Linux supports.
module rv_ptw
  import rv_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic [19:0] satp_ppn,
  input  logic        flush,         // sfence.vma / satp write: do not fill from an in-flight walk

  input  logic        i_req,
  input  logic [19:0] i_vpn,
  output logic        i_ack,
  input  logic        d_req,
  input  logic [19:0] d_vpn,
  input  logic        d_store,
  output logic        d_ack,

  output logic        done,          // one-cycle pulse
  output logic        done_d,        // pulse belongs to the data side
  output logic        fault,
  output logic        afault,        // access fault instead of page fault

  output logic        fill_valid,
  output logic [19:0] fill_vpn,
  output logic [19:0] fill_ppn,
  output logic [7:0]  fill_flags,
  output logic        fill_super,

  output logic        req_valid,
  output logic [31:0] req_addr,
  input  logic        req_ready,
  input  logic        rsp_valid,
  input  logic [31:0] rsp_data,
  input  logic        rsp_err
);

  typedef enum logic [2:0] { S_IDLE, S_L1_REQ, S_L1_RSP, S_L0_REQ, S_L0_RSP, S_DONE } state_e;

  state_e       state_q;
  logic         side_d_q, store_q, discard_q, fault_q, afault_q, super_q;
  logic [19:0]  vpn_q, ppn_q;
  logic [7:0]   flags_q;
  logic [31:0]  addr_q;

  assign i_ack = (state_q == S_IDLE) && i_req && !d_req && !flush;
  assign d_ack = (state_q == S_IDLE) && d_req && !flush;

  assign req_valid = (state_q == S_L1_REQ) || (state_q == S_L0_REQ);
  assign req_addr  = addr_q;

  assign done       = (state_q == S_DONE);
  assign done_d     = side_d_q;
  assign fault      = fault_q;
  assign afault     = afault_q;
  assign fill_valid = done && !fault_q && !discard_q;
  assign fill_vpn   = vpn_q;
  assign fill_ppn   = ppn_q;
  assign fill_flags = flags_q;
  assign fill_super = super_q;

  // PTE decode
  logic        pte_v, pte_r, pte_w, pte_x, pte_a, pte_d, pte_leaf, pte_bad, pte_hi;
  logic [19:0] pte_ppn;

  assign pte_v    = rsp_data[0];
  assign pte_r    = rsp_data[1];
  assign pte_w    = rsp_data[2];
  assign pte_x    = rsp_data[3];
  assign pte_a    = rsp_data[6];
  assign pte_d    = rsp_data[7];
  assign pte_ppn  = rsp_data[29:10];
  assign pte_hi   = |rsp_data[31:30];
  assign pte_leaf = pte_r | pte_x;
  assign pte_bad  = !pte_v || (!pte_r && pte_w);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q   <= S_IDLE;
      discard_q <= 1'b0;
    end else begin
      if (flush && state_q != S_IDLE) discard_q <= 1'b1;

      case (state_q)
        S_IDLE: begin
          if (!flush && (d_req || i_req)) begin
            side_d_q  <= d_req;
            store_q   <= d_req && d_store;
            vpn_q     <= d_req ? d_vpn : i_vpn;
            addr_q    <= {satp_ppn, (d_req ? d_vpn[19:10] : i_vpn[19:10]), 2'b00};
            fault_q   <= 1'b0;
            afault_q  <= 1'b0;
            super_q   <= 1'b0;
            discard_q <= 1'b0;
            state_q   <= S_L1_REQ;
          end
        end
        S_L1_REQ: if (req_ready) state_q <= S_L1_RSP;
        S_L0_REQ: if (req_ready) state_q <= S_L0_RSP;
        S_L1_RSP, S_L0_RSP: if (rsp_valid) begin
          state_q <= S_DONE;
          if (rsp_err) begin
            fault_q <= 1'b1; afault_q <= 1'b1;
          end else if (pte_bad) begin
            fault_q <= 1'b1;
          end else if (pte_leaf) begin
            ppn_q   <= pte_ppn;
            flags_q <= rsp_data[7:0];
            super_q <= (state_q == S_L1_RSP);
            if ((state_q == S_L1_RSP && pte_ppn[9:0] != 10'd0) ||
                !pte_a || (store_q && !pte_d)) begin
              fault_q <= 1'b1;
            end else if (pte_hi) begin
              fault_q <= 1'b1; afault_q <= 1'b1;
            end
          end else if (state_q == S_L0_RSP) begin
            fault_q <= 1'b1;                       // non-leaf at the last level
          end else if (pte_hi) begin
            fault_q <= 1'b1; afault_q <= 1'b1;
          end else begin
            addr_q  <= {pte_ppn, vpn_q[9:0], 2'b00};
            state_q <= S_L0_REQ;
          end
        end
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
