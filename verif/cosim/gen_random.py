#!/usr/bin/env python3
"""Constrained-random RV32IMA program generator for lock-step co-simulation.

  gen_random.py <seed> <out.S> [--n 400] [--profile mix|hazard|mem|muldiv|amo]

Programs run in M-mode, never trap, and end by writing 1 to tohost. A small
register pool (x5..x15) forces RAW/WAW hazards; x31 holds the data-buffer base;
immediates and register seeds are biased toward corner values (0, -1, INT_MIN,
INT_MAX, powers of two). Branches only jump forward so every program terminates.
"""
import argparse, random

POOL = list(range(5, 16))
CORNER = [0, 1, 2, 3, 0xFFFFFFFF, 0xFFFFFFFE, 0x80000000, 0x7FFFFFFF, 0x80000001,
          0x0000FFFF, 0xFFFF0000, 0x55555555, 0xAAAAAAAA, 0x00000100, 0xFFFFFF00]
BUF_WORDS = 256   # 1 KiB data buffer

def s12(r):
    return r.choice([0, 1, -1, 2047, -2048, 4, -4, 255, -256]) if r.random() < 0.5 else r.randint(-2048, 2047)

class Gen:
    def __init__(self, seed, n, profile):
        self.r = random.Random(seed); self.n = n; self.profile = profile
        self.out = []; self.lbl = 0
        w = dict(alu=30, alui=25, shift=8, lui=3, auipc=2, mul=10, ld=10, st=10, br=8, jal=2, amo=4, lrsc=3, csr=2, fence=1, jalr=3)
        w.update({"hazard": dict(alu=40, alui=30, shift=10, mul=5, ld=6, st=6, br=3, jal=1, amo=0, lrsc=0, csr=0, fence=0, jalr=1),
                  "mem": dict(alu=10, alui=10, shift=2, mul=1, ld=30, st=30, br=3, jal=1, amo=6, lrsc=6, csr=0, fence=2),
                  "muldiv": dict(alu=5, alui=5, shift=2, mul=70, ld=2, st=2, br=2, jal=0, amo=0, lrsc=0, csr=0, fence=0),
                  "amo": dict(alu=8, alui=8, shift=2, mul=2, ld=10, st=10, br=2, jal=0, amo=35, lrsc=20, csr=0, fence=1)}.get(profile, {}))
        self.weights = w
    def reg(self): return f"x{self.r.choice(POOL)}"
    def src(self): return "x0" if self.r.random() < 0.08 else self.reg()
    def e(self, s): self.out.append("  " + s)
    def label(self): self.lbl += 1; return f".L{self.lbl}"
    def gen_one(self):
        kind = self.r.choices(list(self.weights), weights=list(self.weights.values()))[0]
        r = self.r; rd = self.reg()
        if kind == "alu":
            self.e(f"{r.choice(['add','sub','sll','slt','sltu','xor','srl','sra','or','and'])} {rd}, {self.src()}, {self.src()}")
        elif kind == "alui":
            self.e(f"{r.choice(['addi','slti','sltiu','xori','ori','andi'])} {rd}, {self.src()}, {s12(r)}")
        elif kind == "shift":
            self.e(f"{r.choice(['slli','srli','srai'])} {rd}, {self.src()}, {r.choice([0,1,31,r.randint(0,31)])}")
        elif kind == "lui": self.e(f"lui {rd}, {r.choice([0,1,0xFFFFF,0x80000,r.randint(0,0xFFFFF)])}")
        elif kind == "auipc": self.e(f"auipc {rd}, {r.randint(0,0xFFFFF)}")
        elif kind == "mul":
            self.e(f"{r.choice(['mul','mulh','mulhsu','mulhu','div','divu','rem','remu'])} {rd}, {self.src()}, {self.src()}")
        elif kind in ("ld", "st"):
            op = r.choice(["lb", "lbu", "lh", "lhu", "lw"]) if kind == "ld" else r.choice(["sb", "sh", "sw"])
            sz = {"b": 1, "h": 2, "w": 4}[op[1]]
            # hot-spot a few words so loads hit freshly stored data (forwarding / ordering)
            off = r.choice([0, 4, 8, 12]) if r.random() < 0.6 else r.randrange(0, BUF_WORDS * 4, 4)
            off += r.randrange(0, 4, sz) if sz < 4 else 0
            if kind == "ld": self.e(f"{op} {rd}, {off}(x31)")
            else: self.e(f"{op} {self.src()}, {off}(x31)")
        elif kind == "br":
            l = self.label()
            self.e(f"{r.choice(['beq','bne','blt','bge','bltu','bgeu'])} {self.src()}, {self.src()}, {l}")
            for _ in range(r.randint(1, 4)): self.gen_one_simple()
            self.out.append(f"{l}:")
        elif kind == "jal":
            l = self.label(); self.e(f"jal {rd}, {l}")
            for _ in range(r.randint(0, 2)): self.gen_one_simple()
            self.out.append(f"{l}:")
        elif kind == "jalr":
            l = self.label(); rd2 = self.reg(); imm = r.choice([0, 4, -4, 8]); lsb = r.choice([0, 1])
            self.e(f"la x29, {l}")
            self.e(f"addi x29, x29, {-imm + lsb}")      # target = x29 + imm = label (+1: LSB must be cleared)
            self.e(f"jalr {rd2}, {imm}(x29)")
            for _ in range(r.randint(0, 2)): self.gen_one_simple()
            self.out.append(f"{l}:")
        elif kind == "amo":
            off = r.randrange(0, BUF_WORDS * 4, 4)
            self.e(f"addi x30, x31, {off}")
            self.e(f"{r.choice(['amoswap.w','amoadd.w','amoxor.w','amoand.w','amoor.w','amomin.w','amomax.w','amominu.w','amomaxu.w'])} {rd}, {self.src()}, (x30)")
        elif kind == "lrsc":
            off = r.randrange(0, BUF_WORDS * 4, 4)
            self.e(f"addi x30, x31, {off}")
            variant = r.choice(["same", "same", "other_addr", "no_lr", "store_between", "double_sc"])
            if variant != "no_lr":
                self.e(f"lr.w {rd}, (x30)")
            for _ in range(r.randint(0, 2)): self.gen_one_simple()
            if variant == "other_addr":
                self.e(f"addi x28, x31, {(off + 4 * r.randint(1, 8)) % (BUF_WORDS * 4)}")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x28)")
            elif variant == "store_between":
                self.e(f"sw {self.src()}, 0(x30)")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
            elif variant == "double_sc":
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
            else:
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
        elif kind == "amo":
            off = r.randrange(0, BUF_WORDS * 4, 4)
            self.e(f"addi x30, x31, {off}")
            self.e(f"{r.choice(['amoswap.w','amoadd.w','amoxor.w','amoand.w','amoor.w','amomin.w','amomax.w','amominu.w','amomaxu.w'])} {rd}, {self.src()}, (x30)")
        elif kind == "lrsc":
            off = r.randrange(0, BUF_WORDS * 4, 4)
            self.e(f"addi x30, x31, {off}")
            variant = r.choice(["same", "same", "other_addr", "no_lr", "store_between", "double_sc"])
            if variant != "no_lr":
                self.e(f"lr.w {rd}, (x30)")
            for _ in range(r.randint(0, 2)): self.gen_one_simple()
            if variant == "other_addr":
                self.e(f"addi x28, x31, {(off + 4 * r.randint(1, 8)) % (BUF_WORDS * 4)}")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x28)")
            elif variant == "store_between":
                self.e(f"sw {self.src()}, 0(x30)")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
            elif variant == "double_sc":
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
            else:
                self.e(f"sc.w {self.reg()}, {self.src()}, (x30)")
        elif kind == "csr":
            # mscratch is a free R/W CSR: write/read/set/clear it
            op = r.choice(["csrrw", "csrrs", "csrrc"]); self.e(f"{op} {rd}, mscratch, {self.src()}")
        elif kind == "fence":
            self.e(r.choice(["fence", "fence.i"]))
    def gen_one_simple(self):
        rd = self.reg(); r = self.r
        if r.random() < 0.5: self.e(f"{r.choice(['add','sub','xor','or','and','mul'])} {rd}, {self.src()}, {self.src()}")
        else: self.e(f"addi {rd}, {self.src()}, {s12(r)}")
    def program(self):
        hdr = ["  .section .text.init,\"ax\"", "  .globl _start", "_start:", "  la x31, databuf"]
        for x in POOL: hdr.append(f"  li x{x}, {self.r.choice(CORNER + [self.r.getrandbits(32)])}")
        hdr += ["  li x30, 0", "  li x1, 0", "  li x2, 0"]
        self.out = []
        for _ in range(self.n): self.gen_one()
        tail = ["  li x30, 1", "  la x29, tohost", "  sw x30, 0(x29)", "1: j 1b",
                "  .section .tohost,\"aw\",@progbits", "  .align 6", "  .globl tohost", "tohost: .dword 0",
                "  .globl fromhost", "fromhost: .dword 0",
                "  .section .data", "  .align 4", "databuf:"]
        for _ in range(BUF_WORDS): tail.append(f"  .word {self.r.choice(CORNER + [self.r.getrandbits(32)])}")
        return "\n".join(hdr + self.out + tail) + "\n"

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("seed", type=int); ap.add_argument("out")
    ap.add_argument("--n", type=int, default=400); ap.add_argument("--profile", default="mix")
    a = ap.parse_args()
    open(a.out, "w").write(Gen(a.seed, a.n, a.profile).program())
