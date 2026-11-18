#!/usr/bin/env python3
"""Mutation testing for the lock-step co-sim.

Each mutant is a one-line RTL bug. For every mutant the core is rebuilt in a scratch
directory and the Spike co-sim corpus (riscv-tests + random programs) is run against it;
a mutant is KILLED if any program diverges from Spike. Survivors are real verification gaps.

  mutate.py [--jobs N] [--only NAME]
"""
import argparse, glob, os, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
CORE = "rv_pkg rv_alu rv_regfile rv_decode rv_muldiv rv_tlb rv_ptw rv_dmux rv_fetch rv_csr rv_core".split()
# tests the core does not support by design (debug triggers, HW misaligned data): they diverge on the clean core too
XFAIL = {"rv32mi-p-breakpoint", "rv32ui-p-ma_data", "rv32ui-v-ma_data"}
TB = ["sim_ram.sv", "sim_periph.sv", "tb_top.sv"]

# (name, file, old, new)
M = [
 ("alu_slt_unsigned",   "rv_alu",    "ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};", "ALU_SLT:  y = {31'b0, a < b};"),
 ("alu_sltu_le",        "rv_alu",    "ALU_SLTU: y = {31'b0, a < b};", "ALU_SLTU: y = {31'b0, a <= b};"),
 ("alu_sra_logical",    "rv_alu",    "32'($signed(a) >>> b[4:0])", "(a >> b[4:0])"),
 ("alu_sll_4bit_shamt", "rv_alu",    "ALU_SLL:  y = a << b[4:0];", "ALU_SLL:  y = a << b[3:0];"),
 ("alu_sub_as_add",     "rv_alu",    "ALU_SUB:  y = a - b;", "ALU_SUB:  y = a + b;"),
 ("fwd_m_over_w_swap",  "rv_core",   "assign xa = (x_need1 && m_hit1) ? m_result : (x_need1 && w_hit1) ? w_result : x_rs1_val;",
                                      "assign xa = (x_need1 && w_hit1) ? w_result : (x_need1 && m_hit1) ? m_result : x_rs1_val;"),
 ("fwd_no_w_rs2",       "rv_core",   "assign w_hit2  = w_valid && w_rd_we && (w_rd == x_rs2);", "assign w_hit2  = 1'b0;"),
 ("fwd_no_m_rs1",       "rv_core",   "assign m_hit1  = m_valid && m_rd_we && (m_rd == x_rs1);", "assign m_hit1  = 1'b0;"),
 ("hazard_no_loaduse",  "rv_core",   "assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_amo | m_c.is_csr;",
                                      "assign m_late  = m_c.is_lr | m_c.is_sc | m_c.is_amo | m_c.is_csr;"),
 ("hazard_no_amo_late", "rv_core",   "assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_amo | m_c.is_csr;",
                                      "assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_csr;"),
 ("hazard_no_csr_late", "rv_core",   "assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_amo | m_c.is_csr;",
                                      "assign m_late  = m_c.is_load | m_c.is_lr | m_c.is_sc | m_c.is_amo;"),
 ("br_blt_unsigned",    "rv_core",   "3'b100:  br_taken = ($signed(xa) <  $signed(xb));", "3'b100:  br_taken = (xa < xb);"),
 ("br_bge_unsigned",    "rv_core",   "3'b101:  br_taken = ($signed(xa) >= $signed(xb));", "3'b101:  br_taken = (xa >= xb);"),
 ("br_bne_as_beq",      "rv_core",   "3'b001:  br_taken = (xa != xb);", "3'b001:  br_taken = (xa == xb);"),
 ("jalr_keep_lsb",      "rv_core",   "{tgt_sum[31:1], 1'b0}", "tgt_sum"),
 ("md_div0_zero",       "rv_muldiv", "by_zero ? 32'hFFFF_FFFF :", "by_zero ? 32'h0 :"),
 ("md_rem_sign_b",      "rv_muldiv", "neg_r   <= (funct3[1] == 1'b1) && !funct3[0] && a[31];", "neg_r   <= (funct3[1] == 1'b1) && !funct3[0] && b[31];"),
 ("md_mulhsu_signed_b", "rv_muldiv", "assign b_ext   = {(f3_q == 3'b001) ? b_q[31] : 1'b0, b_q};", "assign b_ext   = {b_q[31], b_q};"),
 ("md_mulhu_signed_a",  "rv_muldiv", "assign a_ext   = {(f3_q == 3'b011) ? 1'b0 : a_q[31], a_q};", "assign a_ext   = {a_q[31], a_q};"),
 ("md_div_neg_zero",    "rv_muldiv", "(a[31] ^ b[31]) && (b != 32'd0);", "(a[31] ^ b[31]);"),
 ("rf_no_bypass_rs2",   "rv_regfile","rs2_data = (we && rd_addr == rs2_addr) ? rd_data : regs[rs2_addr];", "rs2_data = regs[rs2_addr];"),
 ("sc_ignore_rsv_addr", "rv_core",   "!(rsv_valid_q && rsv_pa_q == m_pa_x)", "!(rsv_valid_q)"),
 ("trap_ecall_s_u_swap", "rv_core", "(priv == PRIV_S) ? EXC_ECALL_S : EXC_ECALL_U;", "(priv == PRIV_S) ? EXC_ECALL_U : EXC_ECALL_S;"),
 ("trap_ebreak_tval_zero", "rv_core", "m_trap_tval = m_pc;", "m_trap_tval = 32'd0;"),
 ("trap_misal_ld_st_swap", "rv_core", "m_is_ld ? EXC_LOAD_MISALIGNED : EXC_STORE_MISALIGNED;", "m_is_ld ? EXC_STORE_MISALIGNED : EXC_LOAD_MISALIGNED;"),
 ("trap_misal_tval_zero", "rv_core", "m_trap = 1'b1; m_trap_tval = m_result;\n              m_trap_cause = m_is_ld", "m_trap = 1'b1; m_trap_tval = 32'd0;\n              m_trap_cause = m_is_ld"),
 ("trap_csr_illegal_tval_zero", "rv_core", "if (csr_illegal) begin\n              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = m_insn;", "if (csr_illegal) begin\n              m_trap = 1'b1; m_trap_cause = EXC_ILLEGAL; m_trap_tval = 32'd0;"),
 ("trap_mret_allowed_in_s", "rv_core", "if (priv == PRIV_M) begin\n              xret_m = 1'b1;", "if (priv != PRIV_U) begin\n              xret_m = 1'b1;"),
 ("trap_amo_fault_cause", "rv_core", "m_trap_tval = m_result; m_trap_cause = EXC_STORE_ACCESS;", "m_trap_tval = m_result; m_trap_cause = EXC_LOAD_ACCESS;"),
 ("csr_priv_check_off", "rv_csr", "(priv_q < addr[9:8]) ||", "1'b0 ||"),
 ("csr_ro_write_allowed", "rv_csr", "(do_write && addr[11:10] == 2'b11) ||", "1'b0 ||"),
 ("trap_mpp_zero", "rv_csr", "mpp_q    <= priv_q;", "mpp_q    <= PRIV_U;"),
 ("trap_mpie_one", "rv_csr", "mpie_q   <= mie_q;", "mpie_q   <= 1'b1;"),
 ("mret_mpp_not_cleared", "rv_csr", "mpp_q  <= PRIV_U;", "mpp_q  <= mpp_q;"),
 ("sret_always_s", "rv_csr", "priv_q <= spp_q ? PRIV_S : PRIV_U;", "priv_q <= PRIV_S;"),
 ("trap_mie_not_cleared", "rv_csr", "mie_q    <= 1'b0;", "mie_q    <= mie_q;"),
 ("sc_fail_value", "rv_core", "m_done = 1'b1; m_wres = 32'd1;", "m_done = 1'b1; m_wres = 32'd2;"),
 ("pte_mxr_ignored", "rv_pkg", "ok = f[1] | (mxr & f[3]);", "ok = f[1];"),
 ("pte_sum_ignored", "rv_pkg", "ok = ok & (acc != ACC_X) & sum;", "ok = ok & (acc != ACC_X);"),
 ("pte_sum_allows_exec", "rv_pkg", "ok = ok & (acc != ACC_X) & sum;", "ok = ok & sum;"),
 ("pte_user_bit_ignored", "rv_pkg", "if (priv_u)    ok = ok & f[4];", "if (priv_u)    ok = ok;"),
 ("pte_a_ignored_perm", "rv_pkg", "if (!f[6])                 ok = 1'b0;", "if (1'b0)                 ok = 1'b0;"),
 ("pte_d_ignored_perm", "rv_pkg", "if (acc == ACC_W && !f[7]) ok = 1'b0;", "if (1'b0) ok = 1'b0;"),
 ("ptw_w_without_r_ok", "rv_ptw", "assign pte_bad  = !pte_v || (!pte_r && pte_w);", "assign pte_bad  = !pte_v;"),
 ("ptw_superpage_misalign_ok", "rv_ptw", "(state_q == S_L1_RSP && pte_ppn[9:0] != 10'd0) ||", "(1'b0) ||"),
 ("ptw_a_bit_ignored", "rv_ptw", "!pte_a || (store_q && !pte_d)", "(store_q && !pte_d)"),
 ("ptw_d_bit_ignored", "rv_ptw", "!pte_a || (store_q && !pte_d)", "!pte_a"),
 ("tlb_super_offset", "rv_tlb", "(super_q[i] ? {ppn_q[i][19:10], vpn[9:0]} : ppn_q[i])", "ppn_q[i]"),
 ("tlb_tag_alias", "rv_tlb", "(super_q[i] || vpn_q[i][9:0] == vpn[9:0])", "(super_q[i] || vpn_q[i][9:2] == vpn[9:2])"),
 ("sfence_no_flush", "rv_core", "m_done = 1'b1; m_redir = 1'b1; tlb_flush = 1'b1;", "m_done = 1'b1; m_redir = 1'b1;"),
 ("pf_tval_zero", "rv_core", "m_trap = 1'b1; m_trap_tval = m_result;\n              m_trap_cause = m_is_st ? EXC_STORE_PAGE : EXC_LOAD_PAGE;", "m_trap = 1'b1; m_trap_tval = 32'd0;\n              m_trap_cause = m_is_st ? EXC_STORE_PAGE : EXC_LOAD_PAGE;"),
 ("ad_a_unchecked_everywhere", "multi", [("rv_pkg", "if (!f[6])                 ok = 1'b0;", "if (1'b0)                 ok = 1'b0;"), ("rv_ptw", "!pte_a || (store_q && !pte_d)", "(store_q && !pte_d)")], None),
 ("ad_d_unchecked_everywhere", "multi", [("rv_pkg", "if (acc == ACC_W && !f[7]) ok = 1'b0;", "if (1'b0) ok = 1'b0;"), ("rv_ptw", "!pte_a || (store_q && !pte_d)", "!pte_a")], None),
 ("pf_cause_swap", "rv_core", "m_is_st ? EXC_STORE_PAGE : EXC_LOAD_PAGE;", "m_is_st ? EXC_LOAD_PAGE : EXC_STORE_PAGE;"),
]


def build(work, name):
    shutil.copytree(f"{ROOT}/rtl/core", f"{work}/rtl", dirs_exist_ok=True)
    for t in TB: shutil.copy(f"{ROOT}/tb/{t}", work)
    return work

FULL = False
def corpus():
    c = []
    for prof in sorted(glob.glob(f"{ROOT}/build/random/*")):
        els = sorted(glob.glob(f"{prof}/r*.elf"))
        step = 5 if os.path.basename(prof) in ("trap", "mmu") else 14
        c += els if FULL else els[::step][:16 if os.path.basename(prof) in ("trap", "mmu") else 8]
    for pat in ("rv32ui-p-*", "rv32um-p-*", "rv32ua-p-*", "rv32mi-p-*", "rv32si-p-*"):
        c += sorted(glob.glob(f"{ROOT}/tools/riscv-tests/isa/{pat}"))
    seen, out = set(), []
    for f in c:
        if os.path.basename(f) in XFAIL: continue
        if f not in seen and not f.endswith((".dump", ".hex", ".bin", ".S", ".err")) and os.path.exists(f): seen.add(f); out.append(f)
    return out

def run_mutant(m, corp):
    name, f, old, new = m
    work = tempfile.mkdtemp(prefix=f"mut_{name}_")
    try:
        build(work, name)
        edits = old if isinstance(old, list) else [(f, old, new)]      # a mutant may edit several files/places
        for ef, eo, en in edits:
            p = f"{work}/rtl/{ef}.sv"; src = open(p).read()
            if src.count(eo) != 1: return name, "BAD-PATTERN", f"pattern occurs {src.count(eo)}x", 0
            open(p, "w").write(src.replace(eo, en))
        files = [f"{work}/rtl/{x}.sv" for x in CORE] + [f"{work}/{t}" for t in TB]
        r = subprocess.run(["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-UNUSEDPARAM", "-Wno-UNUSEDSIGNAL", "-Wno-WIDTH",
                            "--top-module", "tb_top", "-O1", "--Mdir", f"{work}/obj", "-o", "Vtb_top", *files],
                           capture_output=True, text=True)
        sim = f"{work}/obj/Vtb_top"
        if not os.path.exists(sim): return name, "BUILD-FAIL", r.stderr[-300:], 0
        for i, e in enumerate(corp):
            c = subprocess.run([sys.executable, f"{ROOT}/verif/cosim/cosim.py", sim, e], capture_output=True, text=True)
            if c.returncode != 0:
                return name, "KILLED", c.stdout.strip().split("\n")[-1][:150], i + 1
        return name, "SURVIVED", "", len(corp)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    global_full = None
    ap = argparse.ArgumentParser(); ap.add_argument("--jobs", type=int, default=8); ap.add_argument("--only"); ap.add_argument("--full", action="store_true", help="use every generated random program (slow; for survivors)")
    a = ap.parse_args()
    globals()["FULL"] = a.full; corp = corpus(); muts = [m for m in M if not a.only or a.only in m[0]]
    print(f"{len(muts)} mutants x {len(corp)} corpus programs", flush=True)
    base = run_mutant(("baseline", "rv_alu", "default:  y = '0;", "default:  y = '0;"), corp)   # no-op mutation
    print(f"baseline (unmodified core): {base[1]} {base[2]}", flush=True)
    if base[1] != "SURVIVED":
        sys.exit("baseline must match Spike on the whole corpus before mutants mean anything")
    t0 = time.time(); res = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(lambda m: run_mutant(m, corp), muts):
            res.append(r); print(f"{r[0]:22s} {r[1]:9s} after {r[3]:3d} programs  {r[2]}", flush=True)
    k = sum(1 for r in res if r[1] == "KILLED"); s = [r[0] for r in res if r[1] == "SURVIVED"]
    print(f"== killed {k}/{len(res)} mutants in {time.time()-t0:.0f}s; survivors: {s or 'none'}")
