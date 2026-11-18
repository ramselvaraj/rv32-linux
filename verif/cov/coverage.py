#!/usr/bin/env python3
"""Trace-based functional coverage of the lock-step corpus (DUT retire trace).

  coverage.py <sim-binary> [--out report.md]

Bins:
  * instruction: every RV32IMA / Zicsr / system mnemonic retired at least once
  * hazard: producer class x distance (1..3) x consumer operand (rs1/rs2)
  * trap: cause x privilege the trap came from (taken from the handler's mcause/mstatus reads)
  * csr: every CSR address accessed by a retired csr instruction
Impossible bins (e.g. ecall-from-S raised in U) are excluded from the denominator.
"""
import argparse, collections, glob, os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__) + "/../cosim")
import cosim
from concurrent.futures import ThreadPoolExecutor

ROOT = cosim.ROOT

R = [(0x37, None, None, "lui"), (0x17, None, None, "auipc"), (0x6f, None, None, "jal"), (0x67, 0, None, "jalr")]
BR = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
LD = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
ST = {0: "sb", 1: "sh", 2: "sw"}
OPI = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
OP = {(0, 0): "add", (0, 32): "sub", (1, 0): "sll", (2, 0): "slt", (3, 0): "sltu", (4, 0): "xor", (5, 0): "srl", (5, 32): "sra", (6, 0): "or", (7, 0): "and"}
MD = {0: "mul", 1: "mulh", 2: "mulhsu", 3: "mulhu", 4: "div", 5: "divu", 6: "rem", 7: "remu"}
AMO = {0: "amoadd", 1: "amoswap", 2: "lr", 3: "sc", 4: "amoxor", 8: "amoor", 12: "amoand", 16: "amomin", 20: "amomax", 24: "amominu", 28: "amomaxu"}
CSR = {1: "csrrw", 2: "csrrs", 3: "csrrc", 5: "csrrwi", 6: "csrrsi", 7: "csrrci"}
ALL = (["lui", "auipc", "jal", "jalr"] + list(BR.values()) + list(LD.values()) + list(ST.values()) + list(OPI.values()) +
       ["slli", "srli", "srai"] + list(OP.values()) + list(MD.values()) + [v + ".w" for v in AMO.values()] +
       list(CSR.values()) + ["fence", "fence.i", "ecall", "ebreak", "mret", "sret", "wfi", "sfence.vma"])

def decode(i):
    op = i & 0x7f; f3 = (i >> 12) & 7; f7 = i >> 25
    if op == 0x37: return "lui", "alu"
    if op == 0x17: return "auipc", "alu"
    if op == 0x6f: return "jal", "alu"
    if op == 0x67: return "jalr", "alu"
    if op == 0x63: return BR.get(f3), "br"
    if op == 0x03: return LD.get(f3), "load"
    if op == 0x23: return ST.get(f3), "store"
    if op == 0x13:
        if f3 == 1: return "slli", "alu"
        if f3 == 5: return ("srai" if f7 == 32 else "srli"), "alu"
        return OPI.get(f3), "alu"
    if op == 0x33:
        if f7 == 1: return MD[f3], ("div" if f3 >= 4 else "mul")
        return OP.get((f3, f7)), "alu"
    if op == 0x2f: n = AMO.get(i >> 27); return (n + ".w" if n else None), ("lr" if n == "lr" else "sc" if n == "sc" else "amo")
    if op == 0x0f: return ("fence.i" if f3 == 1 else "fence"), "alu"
    if op == 0x73:
        if f3 == 0:
            return {0x73: "ecall", 0x100073: "ebreak", 0x30200073: "mret", 0x10200073: "sret", 0x10500073: "wfi"}.get(i, "sfence.vma" if f7 == 9 else None), "sys"
        return CSR.get(f3), "csr"
    return None, None

def uses(i):
    op = i & 0x7f
    u1 = op in (0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x2f) or (op == 0x73 and ((i >> 12) & 7) in (1, 2, 3))
    u2 = op in (0x63, 0x23, 0x33, 0x2f)
    return u1, u2

def analyse(args):
    sim, elf = args
    try: dut, st = cosim.dut_trace(sim, elf, 3_000_000)
    except Exception: return None
    syms = subprocess.run([cosim.NM, elf], capture_output=True, text=True).stdout.split("\n")
    h = next((int(l.split()[0], 16) for l in syms if l.endswith(" handler")), None)
    insns, haz, traps, csrs = collections.Counter(), set(), set(), set()
    for k, (pc, insn, rd, val) in enumerate(dut):
        m, cls = decode(insn)
        if m: insns[m] += 1
        if (insn & 0x7f) == 0x73 and (insn >> 12) & 7: csrs.add(insn >> 20)
        u1, u2 = uses(insn); rs1 = (insn >> 15) & 31; rs2 = (insn >> 20) & 31
        for dist in (1, 2, 3):
            if k - dist < 0: break
            p = dut[k - dist]
            if p[2] == 0: continue
            pm, pc_ = decode(p[1])
            if pc_ is None: continue
            if u1 and rs1 == p[2]: haz.add((pc_, dist, "rs1"))
            if u2 and rs2 == p[2]: haz.add((pc_, dist, "rs2"))
        if h is not None and pc == h and k + 8 < len(dut):
            cause = val
            for j in range(k + 1, min(k + 9, len(dut))):
                if dut[j][1] == 0x30002e73:                   # csrr x28, mstatus in the handler
                    traps.add((cause, (dut[j][3] >> 11) & 3)); break
    return insns, haz, traps, csrs

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("sim"); ap.add_argument("--out", default=f"{ROOT}/verif/cov/report.md")
    a = ap.parse_args()
    elfs = sorted(f for f in glob.glob(f"{ROOT}/tools/riscv-tests/isa/rv32u[imа]-[pv]-*") + glob.glob(f"{ROOT}/tools/riscv-tests/isa/rv32[ums][iam]-p-*") + glob.glob(f"{ROOT}/tools/riscv-tests/isa/rv32ua-v-*")
                  if not f.endswith((".dump", ".hex", ".bin")) and os.path.basename(f) not in cosim_xfail())
    elfs += sorted(glob.glob(f"{ROOT}/build/random/*/r*.elf"))
    insns, haz, traps, csrs = collections.Counter(), set(), set(), set()
    n = 0
    with ThreadPoolExecutor(20) as ex:
        for r in ex.map(analyse, [(a.sim, e) for e in elfs]):
            if r: i, h, t, c = r; insns.update(i); haz |= h; traps |= t; csrs |= c; n += 1
    classes = ["alu", "load", "mul", "div", "csr", "amo", "lr", "sc", "br", "store"]
    hz_all = {(c, d, o) for c in ["alu", "load", "mul", "div", "csr", "amo", "lr", "sc"] for d in (1, 2, 3) for o in ("rs1", "rs2")}
    # a producer class that cannot be 1 cycle ahead of its consumer without stalling is still a bin: it exercises the hazard unit
    legal_trap = {(c, m) for c in (0, 2, 3, 4, 5, 6, 7) for m in (0, 1, 3)} | {(1, m) for m in (0, 1, 3)} | {(8, 0), (9, 1), (11, 3)} | {(c, m) for c in (12, 13, 15) for m in (0, 1)}
    # ecall/ebreak trap instead of retiring: count them as covered when their trap causes were taken
    for mn, causes in (("ecall", (8, 9, 11)), ("ebreak", (3,))):
        if insns[mn] == 0 and any(c in {t[0] for t in traps} for c in causes): insns[mn] = 1
    miss_i = [m for m in ALL if insns[m] == 0]; miss_h = sorted(hz_all - haz); miss_t = sorted(legal_trap - traps)
    out = [f"# Functional coverage (retire-trace) over {n} programs, {sum(insns.values())} retired instructions\n",
           f"* instruction mnemonics: {len(ALL)-len(miss_i)}/{len(ALL)}  missing: {miss_i or 'none'}",
           f"* hazard bins (producer class x distance x operand): {len(hz_all & haz)}/{len(hz_all)}  missing: {miss_h or 'none'}",
           f"* trap bins (cause x privilege taken from): {len(legal_trap & traps)}/{len(legal_trap)}  missing: {miss_t or 'none'}",
           f"* CSR addresses accessed: {len(csrs)}  ({', '.join(hex(c) for c in sorted(csrs))})"]
    open(a.out, "w").write("\n".join(out) + "\n"); print("\n".join(out))

def cosim_xfail(): return {"rv32mi-p-breakpoint", "rv32ui-p-ma_data", "rv32ui-v-ma_data"}

if __name__ == "__main__":
    main()
