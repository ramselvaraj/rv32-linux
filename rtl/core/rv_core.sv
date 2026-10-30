// RV32IMA_Zicsr_Zifencei core with M/S/U privilege and Sv32 virtual memory.
//
//   F  fetch + iTLB + 4-entry queue (rv_fetch)
//   D  decode, register read
//   X  ALU, branch resolve, mul/div, forwarding
//   M  data access (dTLB, PTW, atomics), CSR access, ALL trap/xRET commit
//   W  register write-back
//
// Exceptions travel down the pipe with their instruction and are taken in M, so
// every older instruction has already retired and no younger one has touched
// architectural state. Interrupts are taken at the same point, before an
// instruction starts executing in M.
module rv_core
  import rv_pkg::*;
#(
  parameter logic [31:0] RESET_PC     = 32'h8000_0000,
  parameter int          ITLB_ENTRIES = 4,
  parameter int          DTLB_ENTRIES = 8
) (
  input  logic        clk,
  input  logic        rst,

  // instruction bus
  output logic        ib_req_valid,
  output logic [31:0] ib_req_addr,
  input  logic        ib_req_ready,
  input  logic        ib_rsp_valid,
  input  logic [31:0] ib_rsp_data,
  input  logic        ib_rsp_err,

  // data bus
  output logic        db_req_valid,
  output logic        db_req_we,
  output logic [31:0] db_req_addr,
  output logic [31:0] db_req_wdata,
  output logic [3:0]  db_req_wstrb,
  input  logic        db_req_ready,
  input  logic        db_rsp_valid,
  input  logic [31:0] db_rsp_data,
  input  logic        db_rsp_err,

  // interrupts / timer
  input  logic        irq_mtip,
  input  logic        irq_msip,
  input  logic        irq_meip,
  input  logic        irq_seip,
  input  logic [63:0] time_i,

  // retirement trace
  output logic        trace_valid,
  output logic [31:0] trace_pc,
  output logic [31:0] trace_insn,
  output logic [4:0]  trace_rd,
  output logic [31:0] trace_rd_data,

  output logic [31:0] dbg,
  output logic [31:0] dbg_mcause,
  output logic [31:0] dbg_mepc,
  output logic [31:0] dbg_mtval
);

  typedef enum logic [2:0] { M_IDLE, M_PTW, M_RSP, M_AMO_W, M_AMO_WRSP } mstate_e;

  // =====================================================================
  // Declarations
  // =====================================================================
  // CSR state
  logic [1:0]  priv, mpp;
  logic        satp_mode, mprv, sum, mxr, tvm, tw, tsr;
  logic [19:0] satp_ppn;
  logic        irq_take;
  logic [4:0]  irq_cause;
  logic [31:0] csr_rdata, trap_target, mepc, sepc;
  logic        csr_illegal;

  // redirect / flush
  logic        redir_v;
  logic [31:0] redir_pc;
  logic        m_kill, x_redirect;
  logic        tlb_flush;

  // fetch -> D
  logic        f_valid, f_exc, f_ready;
  logic [31:0] f_pc, f_insn;
  logic [4:0]  f_cause;

  // D
  logic        d_valid, d_exc;
  logic [31:0] d_pc, d_insn;
  logic [4:0]  d_cause;
  ctrl_t       d_ctrl_raw, d_ctrl;
  logic        d_exc_all;
  logic [4:0]  d_cause_all;
  logic [31:0] d_tval;
  logic [31:0] rf_rs1, rf_rs2;

  // X
  logic        x_valid, x_exc;
  logic [31:0] x_pc, x_insn, x_rs1_val, x_rs2_val, x_tval;
  logic [4:0]  x_cause, x_rd, x_rs1, x_rs2;
  ctrl_t       x_c;

  // M
  logic        m_valid, m_exc, m_csr_wr;
  logic [31:0] m_pc, m_insn, m_result, m_data, m_tval, m_pa_q, m_old_q;
  logic [4:0]  m_cause, m_rd;
  logic        m_rd_we;
  ctrl_t       m_c;
  mstate_e     m_state, m_state_n;
  logic        rsv_valid_q;
  logic [31:0] rsv_pa_q;

  // W
  logic        w_valid, w_rd_we;
  logic [31:0] w_pc, w_insn, w_result;
  logic [4:0]  w_rd;

  // pipeline handshakes
  logic xm_go, dx_go, x_done, x_haz, m_done, m_trap, m_free;

  // =====================================================================
  // Fetch
  // =====================================================================
  logic        ptw_i_req, ptw_i_ack, ptw_d_req, ptw_d_ack;
  logic [19:0] ptw_i_vpn;
  logic        ptw_done, ptw_done_d, ptw_fault, ptw_afault;
  logic        fill_valid, fill_super;
  logic [19:0] fill_vpn, fill_ppn;
  logic [7:0]  fill_flags;

  logic [7:0] f_dbg;
  assign dbg_mepc = mepc;
  assign f_ready = !d_valid || dx_go;
  assign dbg = {f_dbg, 8'd0, f_valid, f_ready, d_valid, x_valid, m_valid, w_valid, x_free, x_haz,
                x_done, xm_go, m_done, m_free, redir_v, m_kill, md_done, dx_go};

  rv_fetch #(.RESET_PC(RESET_PC), .TLB_ENTRIES(ITLB_ENTRIES)) u_fetch (
    .clk, .rst,
    .redirect_valid(redir_v), .redirect_pc(redir_pc),
    .xlate_en(satp_mode && priv != PRIV_M),
    .priv_u(priv == PRIV_U),
    .tlb_flush,
    .ib_req_valid, .ib_req_addr, .ib_req_ready, .ib_rsp_valid, .ib_rsp_data, .ib_rsp_err,
    .ptw_req(ptw_i_req), .ptw_vpn(ptw_i_vpn), .ptw_ack(ptw_i_ack),
    .ptw_done(ptw_done && !ptw_done_d), .ptw_fault, .ptw_afault,
    .fill_valid(fill_valid && !ptw_done_d), .fill_vpn, .fill_ppn, .fill_flags, .fill_super,
    .out_valid(f_valid), .out_pc(f_pc), .out_insn(f_insn), .out_exc(f_exc),
    .out_cause(f_cause), .out_ready(f_ready), .dbg(f_dbg)
  );

  // =====================================================================
  // D stage
  // =====================================================================
  rv_decode u_dec (.insn(d_insn), .c(d_ctrl_raw));

  assign d_ctrl      = d_exc ? '0 : d_ctrl_raw;
  assign d_exc_all   = d_exc | d_ctrl_raw.illegal;
  assign d_cause_all = d_exc ? d_cause : EXC_ILLEGAL;
  assign d_tval      = d_exc ? d_pc : d_insn;

  always_ff @(posedge clk) begin
    if (rst || redir_v) begin
      d_valid <= 1'b0;
    end else if (f_ready) begin
      d_valid <= f_valid;
      d_pc    <= f_pc;
      d_insn  <= f_insn;
      d_exc   <= f_exc;
      d_cause <= f_cause;
    end
  end

  rv_regfile u_rf (
    .clk,
    .rs1_addr(d_insn[19:15]), .rs2_addr(d_insn[24:20]),
    .rs1_data(rf_rs1), .rs2_data(rf_rs2),
    .we(w_valid && w_rd_we), .rd_addr(w_rd), .rd_data(w_result)
  );

  // =====================================================================
  // X stage
  // =====================================================================
  logic        x_free;
  logic [31:0] xa, xb, alu_a, alu_b, alu_y, x_result, x_data, tgt_sum, x_tgt;
  logic        x_need1, x_need2, m_hit1, m_hit2, w_hit1, w_hit2, m_late;
  logic        br_taken, x_taken, tgt_misal, md_done;
  logic [31:0] md_result;

  assign x_free = !x_valid || xm_go;
  assign dx_go  = d_valid && x_free && !m_kill && !x_redirect;

  // forwarding + load-use / late-result hazard
  assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_amo | m_c.is_csr;
  assign x_need1 = x_valid && x_c.rs1_used && (x_rs1 != 5'd0);
  assign x_need2 = x_valid && x_c.rs2_used && (x_rs2 != 5'd0);
  assign m_hit1  = m_valid && m_rd_we && (m_rd == x_rs1);
  assign m_hit2  = m_valid && m_rd_we && (m_rd == x_rs2);
  assign w_hit1  = w_valid && w_rd_we && (w_rd == x_rs1);
  assign w_hit2  = w_valid && w_rd_we && (w_rd == x_rs2);
  assign x_haz   = (x_need1 && m_hit1 && m_late) || (x_need2 && m_hit2 && m_late);

  assign xa = (x_need1 && m_hit1) ? m_result : (x_need1 && w_hit1) ? w_result : x_rs1_val;
  assign xb = (x_need2 && m_hit2) ? m_result : (x_need2 && w_hit2) ? w_result : x_rs2_val;

  assign alu_a = (x_c.opa == OPA_PC) ? x_pc : (x_c.opa == OPA_ZERO) ? 32'd0 : xa;
  assign alu_b = (x_c.opb == OPB_IMM) ? x_c.imm : (x_c.opb == OPB_FOUR) ? 32'd4 : xb;

  rv_alu u_alu (.op(x_c.alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  rv_muldiv u_md (
    .clk, .rst,
    .req(x_valid && x_c.is_md && !x_haz),
    .funct3(x_c.funct3), .a(xa), .b(xb),
    .ack(xm_go), .kill(m_kill),
    .done(md_done), .result(md_result)
  );

  assign x_done   = !x_haz && (!x_c.is_md || md_done);
  assign x_result = x_c.is_md ? md_result : alu_y;
  assign x_data   = x_c.is_csr ? (x_c.funct3[2] ? {27'b0, x_rs1} : xa) : xb;

  // branches / jumps
  always_comb begin
    case (x_c.funct3)
      3'b000:  br_taken = (xa == xb);
      3'b001:  br_taken = (xa != xb);
      3'b100:  br_taken = ($signed(xa) <  $signed(xb));
      3'b101:  br_taken = ($signed(xa) >= $signed(xb));
      3'b110:  br_taken = (xa <  xb);
      default: br_taken = (xa >= xb);
    endcase
  end

  assign x_taken   = x_valid && !x_exc &&
                     (x_c.is_jal | x_c.is_jalr | (x_c.is_branch & br_taken));
  assign tgt_sum   = (x_c.is_jalr ? xa : x_pc) + x_c.imm;
  assign x_tgt     = x_c.is_jalr ? {tgt_sum[31:1], 1'b0} : tgt_sum;
  assign tgt_misal = x_tgt[1];
  assign x_redirect = x_taken && !tgt_misal && x_done && !m_kill;

  assign xm_go = x_valid && x_done && m_free && !m_kill;

  always_ff @(posedge clk) begin
    if (rst || m_kill) begin
      x_valid <= 1'b0;
    end else if (x_free) begin
      x_valid <= dx_go;
      if (dx_go) begin
        x_pc      <= d_pc;
        x_insn    <= d_insn;
        x_c       <= d_ctrl;
        x_c.rd_we <= d_ctrl.rd_we && (d_insn[11:7] != 5'd0);
        x_rd      <= d_insn[11:7];
        x_rs1     <= d_insn[19:15];
        x_rs2     <= d_insn[24:20];
        x_rs1_val <= rf_rs1;
        x_rs2_val <= rf_rs2;
        x_exc     <= d_exc_all;
        x_cause   <= d_cause_all;
        x_tval    <= d_tval;
      end
    end else begin
      // stalled in X: keep operand values current as producers retire
      if (!(x_need1 && m_hit1 && m_late)) x_rs1_val <= xa;
      if (!(x_need2 && m_hit2 && m_late)) x_rs2_val <= xb;
    end
  end

  // =====================================================================
  // M stage
  // =====================================================================
  logic        m_is_ld, m_is_st, m_is_mem, m_misal, m_xlate, m_perm_ok, m_priv_u;
  logic [1:0]  m_size, m_dpriv;
  logic [31:0] m_pa_x, m_load_val, m_amo_new, m_cmp_a, m_cmp_b;
  logic        dtlb_hit;
  logic [19:0] dtlb_ppn;
  logic [7:0]  dtlb_flags;

  // data-bus request from the LSU
  logic        l_req_valid, l_req_we, l_req_ready, l_rsp_valid;
  logic [31:0] l_req_addr, l_req_wdata;
  logic [3:0]  l_req_wstrb;

  // PTW bus
  logic        p_req_valid, p_req_ready, p_rsp_valid, p_rsp_err;
  logic [31:0] p_req_addr, bus_rsp_data;
  logic        bus_rsp_err;

  // CSR controls
  logic        csr_commit, xret_m, xret_s, m_redir, m_retire;
  logic [31:0] m_redir_pc;
  logic        m_trap_irq;
  logic [4:0]  m_trap_cause;
  logic [31:0] m_trap_tval;
  logic [31:0] m_wres;

  assign m_is_ld  = m_c.is_load | m_c.is_lr;
  assign m_is_st  = m_c.is_store | m_c.is_sc | m_c.is_amo;
  assign m_is_mem = m_is_ld | m_is_st;
  assign m_size   = (m_c.is_amo | m_c.is_lr | m_c.is_sc) ? 2'd2 : m_c.funct3[1:0];
  assign m_misal  = (m_size == 2'd1 && m_result[0]) || (m_size == 2'd2 && (|m_result[1:0]));

  assign m_dpriv  = mprv ? mpp : priv;
  assign m_xlate  = satp_mode && (m_dpriv != PRIV_M);
  assign m_priv_u = (m_dpriv == PRIV_U);
  assign m_perm_ok = pte_ok(dtlb_flags, m_is_st ? ACC_W : ACC_R, m_priv_u, sum, mxr);
  assign m_pa_x    = m_xlate ? {dtlb_ppn, m_result[11:0]} : m_result;

  assign m_free = !m_valid || m_done;

  rv_tlb #(.N(DTLB_ENTRIES)) u_dtlb (
    .clk, .rst, .flush(tlb_flush),
    .vpn(m_result[31:12]), .hit(dtlb_hit), .ppn(dtlb_ppn), .flags(dtlb_flags),
    .fill(fill_valid && ptw_done_d), .fill_vpn, .fill_ppn, .fill_flags, .fill_super
  );

  // load alignment
  logic [31:0] ld_sh;
  assign ld_sh = db_rsp_data >> {m_result[1:0], 3'b000};
  always_comb begin
    case (m_c.funct3)
      3'b000:  m_load_val = {{24{ld_sh[7]}},  ld_sh[7:0]};
      3'b001:  m_load_val = {{16{ld_sh[15]}}, ld_sh[15:0]};
      3'b100:  m_load_val = {24'b0, ld_sh[7:0]};
      3'b101:  m_load_val = {16'b0, ld_sh[15:0]};
      default: m_load_val = db_rsp_data;
    endcase
  end

  // atomics (old value in m_old_q, source in m_data)
  assign m_cmp_a = m_old_q;
  assign m_cmp_b = m_data;
  always_comb begin
    case (m_c.funct5)
      5'b00001: m_amo_new = m_data;
      5'b00000: m_amo_new = m_old_q + m_data;
      5'b00100: m_amo_new = m_old_q ^ m_data;
      5'b01100: m_amo_new = m_old_q & m_data;
      5'b01000: m_amo_new = m_old_q | m_data;
      5'b10000: m_amo_new = ($signed(m_cmp_a) < $signed(m_cmp_b)) ? m_old_q : m_data;
      5'b10100: m_amo_new = ($signed(m_cmp_a) > $signed(m_cmp_b)) ? m_old_q : m_data;
      5'b11000: m_amo_new = (m_cmp_a < m_cmp_b) ? m_old_q : m_data;
      default:  m_amo_new = (m_cmp_a > m_cmp_b) ? m_old_q : m_data;   // MAXU
    endcase
  end

  function automatic logic [31:0] st_data(input logic [31:0] d, input logic [1:0] sz);
    case (sz)
      2'd0:    st_data = {4{d[7:0]}};
      2'd1:    st_data = {2{d[15:0]}};
      default: st_data = d;
    endcase
  endfunction

  function automatic logic [3:0] st_strb(input logic [1:0] sz, input logic [1:0] a);
    case (sz)
      2'd0:    st_strb = 4'b0001 << a;
      2'd1:    st_strb = 4'b0011 << a;
      default: st_strb = 4'b1111;
    endcase
  endfunction


  always_comb begin
    m_done       = 1'b0;
    m_trap       = 1'b0;
    m_trap_irq   = 1'b0;
    m_trap_cause = '0;
    m_trap_tval  = '0;
    m_redir      = 1'b0;
    m_redir_pc   = m_pc + 32'd4;
    xret_m       = 1'b0;
    xret_s       = 1'b0;
    m_state_n    = m_state;
    l_req_valid  = 1'b0;
    l_req_we     = 1'b0;
    l_req_addr   = m_pa_q;
    l_req_wdata  = st_data(m_data, m_size);
    l_req_wstrb  = st_strb(m_size, m_result[1:0]);
    ptw_d_req    = 1'b0;
    csr_commit   = 1'b0;
    tlb_flush    = 1'b0;
    m_wres       = m_result;

    if (m_valid) begin
      case (m_state)
        M_IDLE: begin
          if (irq_take) begin
            m_trap = 1'b1; m_trap_irq = 1'b1; m_trap_cause = irq_cause;
          end else if (m_exc) begin
            m_trap = 1'b1; m_trap_cause = m_cause; m_trap_tval = m_tval;
          end else if (m_is_mem) begin
            if (m_misal) begin
              m_trap = 1'b1; m_trap_tval = m_result;
              m_trap_cause = m_is_ld ? EXC_LOAD_MISALIGNED : EXC_STORE_MISALIGNED;
            end else if (m_xlate && !dtlb_hit) begin
              ptw_d_req = 1'b1;
              if (ptw_d_ack) m_state_n = M_PTW;
            end else if (m_xlate && !m_perm_ok) begin
              m_trap = 1'b1; m_trap_tval = m_result;
              m_trap_cause = m_is_st ? EXC_STORE_PAGE : EXC_LOAD_PAGE;
            end else if (m_c.is_sc && !(rsv_valid_q && rsv_pa_q == m_pa_x)) begin
              m_done = 1'b1; m_wres = 32'd1;                    // SC failure
            end else begin
              l_req_valid = 1'b1;
              l_req_we    = m_c.is_store | m_c.is_sc;
              l_req_addr  = m_pa_x;
              if (l_req_ready) m_state_n = M_RSP;
            end
          end else if (m_c.is_csr) begin
            if (csr_illegal) begin
              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;
            end else begin
              csr_commit = 1'b1; m_done = 1'b1; m_wres = csr_rdata;
              if (m_insn[31:20] == CSR_SATP && m_csr_wr) begin
                tlb_flush = 1'b1; m_redir = 1'b1;
              end
            end
          end else if (m_c.is_ecall) begin
            m_trap = 1'b1;
            m_trap_cause = (priv == PRIV_M) ? EXC_ECALL_M : (priv == PRIV_S) ? EXC_ECALL_S : EXC_ECALL_U;
          end else if (m_c.is_ebreak) begin
            m_trap = 1'b1; m_trap_cause = EXC_BREAKPOINT; m_trap_tval = m_pc;
          end else if (m_c.is_mret) begin
            if (priv == PRIV_M) begin
              xret_m = 1'b1; m_done = 1'b1; m_redir = 1'b1; m_redir_pc = mepc;
            end else begin
              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;
            end
          end else if (m_c.is_sret) begin
            if (priv == PRIV_M || (priv == PRIV_S && !tsr)) begin
              xret_s = 1'b1; m_done = 1'b1; m_redir = 1'b1; m_redir_pc = sepc;
            end else begin
              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;
            end
          end else if (m_c.is_wfi) begin
            if (priv == PRIV_U || (priv == PRIV_S && tw)) begin
              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;
            end else m_done = 1'b1;
          end else if (m_c.is_sfence) begin
            if (priv == PRIV_U || (priv == PRIV_S && tvm)) begin
              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;
            end else begin
              m_done = 1'b1; m_redir = 1'b1; tlb_flush = 1'b1;
            end
          end else if (m_c.is_fencei) begin
            m_done = 1'b1; m_redir = 1'b1;
          end else begin
            m_done = 1'b1;
          end
        end

        M_PTW: begin
          if (ptw_done && ptw_done_d) begin
            if (ptw_fault) begin
              m_trap = 1'b1; m_trap_tval = m_result;
              if (ptw_afault) m_trap_cause = m_is_st ? EXC_STORE_ACCESS : EXC_LOAD_ACCESS;
              else            m_trap_cause = m_is_st ? EXC_STORE_PAGE   : EXC_LOAD_PAGE;
            end else begin
              m_state_n = M_IDLE;
            end
          end
        end

        M_RSP: begin
          if (l_rsp_valid) begin
            if (bus_rsp_err) begin
              m_trap = 1'b1; m_trap_tval = m_result;
              m_trap_cause = m_is_st ? EXC_STORE_ACCESS : EXC_LOAD_ACCESS;
            end else if (m_c.is_amo) begin
              m_state_n = M_AMO_W;
            end else begin
              m_done = 1'b1;
              if (m_c.is_sc)      m_wres = 32'd0;
              else if (m_c.is_lr) m_wres = db_rsp_data;
              else                m_wres = m_load_val;
            end
          end
        end

        M_AMO_W: begin
          l_req_valid = 1'b1;
          l_req_we    = 1'b1;
          l_req_addr  = m_pa_q;
          l_req_wdata = m_amo_new;
          l_req_wstrb = 4'b1111;
          if (l_req_ready) m_state_n = M_AMO_WRSP;
        end

        default: begin  // M_AMO_WRSP
          if (l_rsp_valid) begin
            if (bus_rsp_err) begin
              m_trap = 1'b1; m_trap_tval = m_result; m_trap_cause = EXC_STORE_ACCESS;
            end else begin
              m_done = 1'b1; m_wres = m_old_q;
            end
          end
        end
      endcase
    end
  end

  assign m_kill   = m_valid && (m_trap || m_redir);
  assign m_retire = m_valid && m_done;

  assign redir_v  = m_kill || x_redirect;
  assign redir_pc = !m_kill ? x_tgt :
                    m_trap  ? trap_target : m_redir_pc;

  always_ff @(posedge clk) begin
    if (rst) begin
      m_valid     <= 1'b0;
      m_state     <= M_IDLE;
      rsv_valid_q <= 1'b0;
    end else begin
      if (m_trap) begin
        m_valid <= 1'b0;
        m_state <= M_IDLE;
      end else if (m_free) begin
        m_valid <= xm_go;
        m_state <= M_IDLE;
      end else begin
        m_state <= m_state_n;
      end

      if (m_valid && m_state == M_IDLE && m_is_mem && m_state_n == M_RSP) m_pa_q <= m_pa_x;
      if (m_valid && m_state == M_RSP && l_rsp_valid && m_c.is_amo) m_old_q <= db_rsp_data;

      // load-reserved / store-conditional reservation
      if (m_trap || xret_m || xret_s) rsv_valid_q <= 1'b0;
      else if (m_valid && m_state == M_RSP && l_rsp_valid && !bus_rsp_err && m_c.is_lr) begin
        rsv_valid_q <= 1'b1; rsv_pa_q <= m_pa_q;
      end else if (m_valid && m_done && m_c.is_sc) rsv_valid_q <= 1'b0;
    end

    if (xm_go) begin
      m_pc     <= x_pc;
      m_insn   <= x_insn;
      m_c      <= x_c;
      m_rd     <= x_rd;
      m_rd_we  <= x_c.rd_we;
      m_result <= x_result;
      m_data   <= x_data;
      m_exc    <= x_exc | (x_taken & tgt_misal);
      m_cause  <= x_exc ? x_cause : EXC_INSN_MISALIGNED;
      m_tval   <= x_exc ? x_tval  : x_tgt;
      m_csr_wr <= (x_c.funct3[1:0] == 2'b01) || (x_rs1 != 5'd0);
    end
  end

  // =====================================================================
  // CSR file, PTW, data-bus sharing
  // =====================================================================
  rv_csr u_csr (
    .clk, .rst,
    .addr(m_insn[31:20]), .op(m_c.funct3[1:0]), .wdata(m_data),
    .do_write(m_csr_wr), .commit(csr_commit), .rdata(csr_rdata), .illegal(csr_illegal),
    .trap_commit(m_trap), .trap_irq(m_trap_irq), .trap_cause(m_trap_cause),
    .trap_pc(m_pc), .trap_val(m_trap_tval), .trap_target,
    .mret_commit(xret_m && m_done), .sret_commit(xret_s && m_done),
    .mepc_o(mepc), .dbg_mcause_o(dbg_mcause), .dbg_mtval_o(dbg_mtval), .sepc_o(sepc),
    .retire(m_retire),
    .irq_mtip, .irq_msip, .irq_meip, .irq_seip, .time_i,
    .priv_o(priv), .satp_mode_o(satp_mode), .satp_ppn_o(satp_ppn),
    .mprv_o(mprv), .mpp_o(mpp), .sum_o(sum), .mxr_o(mxr),
    .tvm_o(tvm), .tw_o(tw), .tsr_o(tsr),
    .irq_take, .irq_cause
  );

  rv_ptw u_ptw (
    .clk, .rst, .satp_ppn, .flush(tlb_flush),
    .i_req(ptw_i_req), .i_vpn(ptw_i_vpn), .i_ack(ptw_i_ack),
    .d_req(ptw_d_req), .d_vpn(m_result[31:12]), .d_store(m_is_st), .d_ack(ptw_d_ack),
    .done(ptw_done), .done_d(ptw_done_d), .fault(ptw_fault), .afault(ptw_afault),
    .fill_valid, .fill_vpn, .fill_ppn, .fill_flags, .fill_super,
    .req_valid(p_req_valid), .req_addr(p_req_addr), .req_ready(p_req_ready),
    .rsp_valid(p_rsp_valid), .rsp_data(bus_rsp_data), .rsp_err(bus_rsp_err)
  );

  rv_dmux u_dmux (
    .clk, .rst,
    .m_req_valid(l_req_valid), .m_req_we(l_req_we), .m_req_addr(l_req_addr & 32'hFFFF_FFFC),
    .m_req_wdata(l_req_wdata), .m_req_wstrb(l_req_wstrb),
    .m_req_ready(l_req_ready), .m_rsp_valid(l_rsp_valid),
    .p_req_valid, .p_req_addr, .p_req_ready, .p_rsp_valid,
    .rsp_data(bus_rsp_data), .rsp_err(bus_rsp_err),
    .s_req_valid(db_req_valid), .s_req_we(db_req_we), .s_req_addr(db_req_addr),
    .s_req_wdata(db_req_wdata), .s_req_wstrb(db_req_wstrb),
    .s_req_ready(db_req_ready), .s_rsp_valid(db_rsp_valid),
    .s_rsp_data(db_rsp_data), .s_rsp_err(db_rsp_err)
  );

  // =====================================================================
  // W stage
  // =====================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      w_valid <= 1'b0;
    end else begin
      w_valid <= m_retire;
      if (m_retire) begin
        w_pc     <= m_pc;
        w_insn   <= m_insn;
        w_rd     <= m_rd;
        w_rd_we  <= m_rd_we;
        w_result <= m_wres;
      end
    end
  end

  assign trace_valid   = w_valid;
  assign trace_pc      = w_pc;
  assign trace_insn    = w_insn;
  assign trace_rd      = w_rd_we ? w_rd : 5'd0;
  assign trace_rd_data = w_result;

endmodule
