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
]

def build(work, name):
    shutil.copytree(f"{ROOT}/rtl/core", f"{work}/rtl", dirs_exist_ok=True)
    for t in TB: shutil.copy(f"{ROOT}/tb/{t}", work)
    return work

def corpus():
    c  = sorted(glob.glob(f"{ROOT}/build/random/*/r*.elf"))[::7][:60]          # sample of random programs
    c += [f for f in sorted(glob.glob(f"{ROOT}/tools/riscv-tests/isa/rv32u[imа]-p-*")) if not f.endswith((".dump",))]
    c += [f for f in sorted(glob.glob(f"{ROOT}/tools/riscv-tests/isa/rv32ua-p-*")) if not f.endswith((".dump",))]
    seen, out = set(), []
    for f in c:
        if f not in seen and not f.endswith((".dump", ".hex", ".bin", ".S", ".err")) and os.path.exists(f): seen.add(f); out.append(f)
    return out

def run_mutant(m, corp):
    name, f, old, new = m
    work = tempfile.mkdtemp(prefix=f"mut_{name}_")
    try:
        build(work, name)
        p = f"{work}/rtl/{f}.sv"; src = open(p).read()
        if src.count(old) != 1: return name, "BAD-PATTERN", f"pattern occurs {src.count(old)}x", 0
        open(p, "w").write(src.replace(old, new))
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
    ap = argparse.ArgumentParser(); ap.add_argument("--jobs", type=int, default=8); ap.add_argument("--only")
    a = ap.parse_args()
    corp = corpus(); muts = [m for m in M if not a.only or a.only in m[0]]
    print(f"{len(muts)} mutants x {len(corp)} corpus programs", flush=True)
    t0 = time.time(); res = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(lambda m: run_mutant(m, corp), muts):
            res.append(r); print(f"{r[0]:22s} {r[1]:9s} after {r[3]:3d} programs  {r[2]}", flush=True)
    k = sum(1 for r in res if r[1] == "KILLED"); s = [r[0] for r in res if r[1] == "SURVIVED"]
    print(f"== killed {k}/{len(res)} mutants in {time.time()-t0:.0f}s; survivors: {s or 'none'}")
