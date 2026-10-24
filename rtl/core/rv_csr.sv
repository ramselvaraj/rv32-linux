// Machine + supervisor CSR file, trap entry/return and interrupt arbitration.
module rv_csr
  import rv_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // CSR instruction port (executed in M)
  input  logic [11:0] addr,
  input  logic [1:0]  op,          // 01 write, 10 set, 11 clear
  input  logic [31:0] wdata,
  input  logic        do_write,    // false for csrrs/csrrc with a zero operand
  input  logic        commit,      // apply the write this cycle
  output logic [31:0] rdata,
  output logic        illegal,

  // traps and returns
  input  logic        trap_commit,
  input  logic        trap_irq,
  input  logic [4:0]  trap_cause,
  input  logic [31:0] trap_pc,
  input  logic [31:0] trap_val,
  output logic [31:0] trap_target,
  input  logic        mret_commit,
  input  logic        sret_commit,
  output logic [31:0] mepc_o,
  output logic [31:0] sepc_o,

  input  logic        retire,

  // interrupt inputs
  input  logic        irq_mtip,
  input  logic        irq_msip,
  input  logic        irq_meip,
  input  logic        irq_seip,
  input  logic [63:0] time_i,

  // architectural state used elsewhere
  output logic [1:0]  priv_o,
  output logic        satp_mode_o,
  output logic [19:0] satp_ppn_o,
  output logic        mprv_o,
  output logic [1:0]  mpp_o,
  output logic        sum_o,
  output logic        mxr_o,
  output logic        tvm_o,
  output logic        tw_o,
  output logic        tsr_o,
  output logic        irq_take,
  output logic [4:0]  irq_cause
);

  // ---- state
  logic [1:0]  priv_q, mpp_q;
  logic        mie_q, sie_q, mpie_q, spie_q, spp_q;
  logic        mprv_q, sum_q, mxr_q, tvm_q, tw_q, tsr_q;
  logic [31:0] medeleg_q, mideleg_q, mie_r_q, mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
  logic [31:0] mcounteren_q, mcountinhibit_q;
  logic        ssip_q, stip_q, seip_q;
  logic [31:0] stvec_q, sscratch_q, sepc_q, scause_q, stval_q, scounteren_q;
  logic        satp_mode_q;
  logic [21:0] satp_ppn_q;
  logic [63:0] mcycle_q, minstret_q;
  logic [31:0] pmpcfg_q [4];
  logic [31:0] pmpaddr_q [16];

  localparam logic [31:0] IRQ_ALL  = 32'h0000_0AAA;   // SSI MSI STI MTI SEI MEI
  localparam logic [31:0] IRQ_S    = 32'h0000_0222;   // SSI STI SEI
  localparam logic [31:0] MISA     = 32'h4014_1101;   // RV32 A I M S U
  localparam logic [31:0] SSTATUS_MASK = 32'h000C_0122; // SIE SPIE SPP SUM MXR

  assign priv_o      = priv_q;
  assign satp_mode_o = satp_mode_q;
  assign satp_ppn_o  = satp_ppn_q[19:0];
  assign mprv_o      = mprv_q;
  assign mpp_o       = mpp_q;
  assign sum_o       = sum_q;
  assign mxr_o       = mxr_q;
  assign tvm_o       = tvm_q;
  assign tw_o        = tw_q;
  assign tsr_o       = tsr_q;
  assign mepc_o      = mepc_q;
  assign sepc_o      = sepc_q;

  // ---- composed registers
  logic [31:0] mstatus, mip;
  assign mstatus = {9'b0, tsr_q, tw_q, tvm_q, mxr_q, sum_q, mprv_q, 4'b0, mpp_q, 2'b0,
                    spp_q, mpie_q, 1'b0, spie_q, 1'b0, mie_q, 1'b0, sie_q, 1'b0};
  assign mip = {20'b0, irq_meip, 1'b0, (seip_q | irq_seip), 1'b0, irq_mtip, 1'b0, stip_q, 1'b0,
                irq_msip, 1'b0, ssip_q, 1'b0};

  // ---- read mux
  logic        exists, is_cnt_alias;
  logic [31:0] rd_raw;

  always_comb begin
    exists = 1'b1;
    rd_raw = 32'd0;
    case (addr)
      CSR_SSTATUS:       rd_raw = mstatus & SSTATUS_MASK;
      CSR_SIE:           rd_raw = mie_r_q & mideleg_q;
      CSR_STVEC:         rd_raw = stvec_q;
      CSR_SCOUNTEREN:    rd_raw = scounteren_q;
      CSR_SSCRATCH:      rd_raw = sscratch_q;
      CSR_SEPC:          rd_raw = sepc_q;
      CSR_SCAUSE:        rd_raw = scause_q;
      CSR_STVAL:         rd_raw = stval_q;
      CSR_SIP:           rd_raw = mip & mideleg_q & IRQ_S;
      CSR_SATP:          rd_raw = {satp_mode_q, 9'b0, satp_ppn_q};
      CSR_MSTATUS:       rd_raw = mstatus;
      CSR_MISA:          rd_raw = MISA;
      CSR_MEDELEG:       rd_raw = medeleg_q;
      CSR_MIDELEG:       rd_raw = mideleg_q;
      CSR_MIE:           rd_raw = mie_r_q;
      CSR_MTVEC:         rd_raw = mtvec_q;
      CSR_MCOUNTEREN:    rd_raw = mcounteren_q;
      CSR_MSTATUSH:      rd_raw = 32'd0;
      CSR_MCOUNTINHIBIT: rd_raw = mcountinhibit_q;
      CSR_MSCRATCH:      rd_raw = mscratch_q;
      CSR_MEPC:          rd_raw = mepc_q;
      CSR_MCAUSE:        rd_raw = mcause_q;
      CSR_MTVAL:         rd_raw = mtval_q;
      CSR_MIP:           rd_raw = mip;
      CSR_MCYCLE,   CSR_CYCLE:    rd_raw = mcycle_q[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:   rd_raw = mcycle_q[63:32];
      CSR_MINSTRET, CSR_INSTRET:  rd_raw = minstret_q[31:0];
      CSR_MINSTRETH, CSR_INSTRETH: rd_raw = minstret_q[63:32];
      CSR_TIME:          rd_raw = time_i[31:0];
      CSR_TIMEH:         rd_raw = time_i[63:32];
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID, CSR_MCONFIGPTR: rd_raw = 32'd0;
      default: begin
        if (addr[11:2] == 10'b0011_1010_00)       rd_raw = pmpcfg_q[addr[1:0]];       // 3A0-3A3
        else if (addr[11:4] == 8'h3B)             rd_raw = pmpaddr_q[addr[3:0]];      // 3B0-3BF
        else if ((addr >= 12'h323 && addr <= 12'h33F) ||                              // mhpmevent
                 (addr >= 12'hB03 && addr <= 12'hB1F) ||
                 (addr >= 12'hB83 && addr <= 12'hB9F) ||
                 (addr >= 12'hC03 && addr <= 12'hC1F) ||
                 (addr >= 12'hC83 && addr <= 12'hC9F)) rd_raw = 32'd0;
        else exists = 1'b0;
      end
    endcase
  end

  assign rdata = rd_raw;

  // ---- access legality
  logic [4:0] cnt_idx;
  logic       cnt_ok;
  assign is_cnt_alias = (addr[11:5] == 7'b1100_000) || (addr[11:5] == 7'b1100_100);
  assign cnt_idx      = addr[4:0];
  assign cnt_ok       = (priv_q == PRIV_M) ||
                        (priv_q == PRIV_S && mcounteren_q[cnt_idx]) ||
                        (priv_q == PRIV_U && mcounteren_q[cnt_idx] && scounteren_q[cnt_idx]);

  assign illegal = !exists ||
                   (priv_q < addr[9:8]) ||
                   (do_write && addr[11:10] == 2'b11) ||
                   (is_cnt_alias && !cnt_ok) ||
                   (addr == CSR_SATP && priv_q == PRIV_S && tvm_q);

  // ---- write value
  logic [31:0] wval;
  always_comb begin
    case (op)
      2'b10:   wval = rd_raw | wdata;
      2'b11:   wval = rd_raw & ~wdata;
      default: wval = wdata;
    endcase
  end

  // ---- traps
  logic deleg, to_s, vec;
  logic [31:0] tbase;
  assign deleg = trap_irq ? mideleg_q[trap_cause] : medeleg_q[trap_cause];
  assign to_s  = (priv_q != PRIV_M) && deleg;
  assign tbase = to_s ? stvec_q : mtvec_q;
  assign vec   = trap_irq && tbase[0];
  assign trap_target = {tbase[31:2], 2'b00} + (vec ? {25'b0, trap_cause, 2'b00} : 32'd0);

  // ---- interrupts
  logic [31:0] pend, pend_m, pend_s, pend_sel;
  logic        m_en, s_en, take_m, take_s;
  assign pend   = mip & mie_r_q & IRQ_ALL;
  assign pend_m = pend & ~mideleg_q;
  assign pend_s = pend & mideleg_q;
  assign m_en   = (priv_q != PRIV_M) || mie_q;
  assign s_en   = (priv_q == PRIV_U) || (priv_q == PRIV_S && sie_q);
  assign take_m = m_en && (|pend_m);
  assign take_s = s_en && (|pend_s);
  assign irq_take = take_m | take_s;
  assign pend_sel = take_m ? pend_m : pend_s;

  always_comb begin
    if      (pend_sel[11]) irq_cause = IRQ_MEI;
    else if (pend_sel[3])  irq_cause = IRQ_MSI;
    else if (pend_sel[7])  irq_cause = IRQ_MTI;
    else if (pend_sel[9])  irq_cause = IRQ_SEI;
    else if (pend_sel[1])  irq_cause = IRQ_SSI;
    else                   irq_cause = IRQ_STI;
  end

  // ---- sequential state
  always_ff @(posedge clk) begin
    if (rst) begin
      priv_q <= PRIV_M;
      {mie_q, sie_q, mpie_q, spie_q, spp_q} <= '0;
      {mprv_q, sum_q, mxr_q, tvm_q, tw_q, tsr_q} <= '0;
      mpp_q <= PRIV_M;
      medeleg_q <= '0; mideleg_q <= '0; mie_r_q <= '0; mtvec_q <= '0; mscratch_q <= '0;
      mepc_q <= '0; mcause_q <= '0; mtval_q <= '0; mcounteren_q <= '0; mcountinhibit_q <= '0;
      {ssip_q, stip_q, seip_q} <= '0;
      stvec_q <= '0; sscratch_q <= '0; sepc_q <= '0; scause_q <= '0; stval_q <= '0;
      scounteren_q <= '0;
      satp_mode_q <= 1'b0; satp_ppn_q <= '0;
      mcycle_q <= '0; minstret_q <= '0;
      for (int i = 0; i < 4; i++)  pmpcfg_q[i]  <= '0;
      for (int i = 0; i < 16; i++) pmpaddr_q[i] <= '0;
    end else begin
      // a CSR write to a counter suppresses that cycle's increment (both halves)
      if (!mcountinhibit_q[0] && !(commit && do_write && (addr == CSR_MCYCLE || addr == CSR_MCYCLEH)))
        mcycle_q <= mcycle_q + 64'd1;
      if (retire && !mcountinhibit_q[2] &&
          !(commit && do_write && (addr == CSR_MINSTRET || addr == CSR_MINSTRETH)))
        minstret_q <= minstret_q + 64'd1;

      if (commit && do_write) begin
        case (addr)
          CSR_SSTATUS: begin
            sie_q <= wval[1]; spie_q <= wval[5]; spp_q <= wval[8];
            sum_q <= wval[18]; mxr_q <= wval[19];
          end
          CSR_SIE:        mie_r_q <= (mie_r_q & ~mideleg_q) | (wval & mideleg_q & IRQ_ALL);
          CSR_STVEC:      stvec_q <= {wval[31:2], 1'b0, wval[0]};
          CSR_SCOUNTEREN: scounteren_q <= wval;
          CSR_SSCRATCH:   sscratch_q <= wval;
          CSR_SEPC:       sepc_q <= {wval[31:2], 2'b00};
          CSR_SCAUSE:     scause_q <= wval;
          CSR_STVAL:      stval_q <= wval;
          CSR_SIP:        if (mideleg_q[1]) ssip_q <= wval[1];
          CSR_SATP: begin
            satp_mode_q <= wval[31];
            satp_ppn_q  <= wval[21:0];
          end
          CSR_MSTATUS: begin
            sie_q <= wval[1]; mie_q <= wval[3]; spie_q <= wval[5]; mpie_q <= wval[7];
            spp_q <= wval[8];
            if (wval[12:11] != 2'b10) mpp_q <= wval[12:11];
            mprv_q <= wval[17]; sum_q <= wval[18]; mxr_q <= wval[19];
            tvm_q <= wval[20]; tw_q <= wval[21]; tsr_q <= wval[22];
          end
          CSR_MEDELEG:    medeleg_q <= wval & 32'h0000_B3FF;
          CSR_MIDELEG:    mideleg_q <= wval & IRQ_S;
          CSR_MIE:        mie_r_q <= wval & IRQ_ALL;
          CSR_MTVEC:      mtvec_q <= {wval[31:2], 1'b0, wval[0]};
          CSR_MCOUNTEREN: mcounteren_q <= wval;
          CSR_MCOUNTINHIBIT: mcountinhibit_q <= wval;
          CSR_MSCRATCH:   mscratch_q <= wval;
          CSR_MEPC:       mepc_q <= {wval[31:2], 2'b00};
          CSR_MCAUSE:     mcause_q <= wval;
          CSR_MTVAL:      mtval_q <= wval;
          CSR_MIP: begin
            ssip_q <= wval[1]; stip_q <= wval[5]; seip_q <= wval[9];
          end
          CSR_MCYCLE:     mcycle_q[31:0]    <= wval;
          CSR_MCYCLEH:    mcycle_q[63:32]   <= wval;
          CSR_MINSTRET:   minstret_q[31:0]  <= wval;
          CSR_MINSTRETH:  minstret_q[63:32] <= wval;
          default: begin
            if (addr[11:2] == 10'b0011_1010_00) pmpcfg_q[addr[1:0]]  <= wval;
            else if (addr[11:4] == 8'h3B)       pmpaddr_q[addr[3:0]] <= wval;
          end
        endcase
      end

      if (trap_commit) begin
        if (to_s) begin
          sepc_q   <= {trap_pc[31:2], 2'b00};
          scause_q <= {trap_irq, 26'b0, trap_cause};
          stval_q  <= trap_val;
          spie_q   <= sie_q;
          sie_q    <= 1'b0;
          spp_q    <= priv_q[0];
          priv_q   <= PRIV_S;
        end else begin
          mepc_q   <= {trap_pc[31:2], 2'b00};
          mcause_q <= {trap_irq, 26'b0, trap_cause};
          mtval_q  <= trap_val;
          mpie_q   <= mie_q;
          mie_q    <= 1'b0;
          mpp_q    <= priv_q;
          priv_q   <= PRIV_M;
        end
      end else if (mret_commit) begin
        priv_q <= mpp_q;
        mie_q  <= mpie_q;
        mpie_q <= 1'b1;
        mpp_q  <= PRIV_U;
        if (mpp_q != PRIV_M) mprv_q <= 1'b0;
      end else if (sret_commit) begin
        priv_q <= spp_q ? PRIV_S : PRIV_U;
        sie_q  <= spie_q;
        spie_q <= 1'b1;
        spp_q  <= 1'b0;
        mprv_q <= 1'b0;
      end
    end
  end

endmodule
