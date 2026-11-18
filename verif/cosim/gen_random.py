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
        w = dict(alu=30, alui=25, shift=8, lui=3, auipc=2, mul=10, ld=10, st=10, br=8, jal=2, amo=4, lrsc=3, csr=2, fence=1, jalr=3, trap=0, mode=0, vmem=0, vjump=0)
        w.update({"hazard": dict(alu=40, alui=30, shift=10, mul=5, ld=6, st=6, br=3, jal=1, amo=0, lrsc=0, csr=0, fence=0, jalr=1),
                  "mem": dict(alu=10, alui=10, shift=2, mul=1, ld=30, st=30, br=3, jal=1, amo=6, lrsc=6, csr=0, fence=2),
                  "muldiv": dict(alu=5, alui=5, shift=2, mul=70, ld=2, st=2, br=2, jal=0, amo=0, lrsc=0, csr=0, fence=0),
                  "amo": dict(alu=8, alui=8, shift=2, mul=2, ld=10, st=10, br=2, jal=0, amo=35, lrsc=20, csr=0, fence=1),
                  "trap": dict(alu=22, alui=18, shift=5, mul=6, ld=8, st=8, br=5, jal=1, amo=3, lrsc=2, csr=4, fence=1, jalr=2,
                               trap=16, mode=5),
                  "mmu": dict(alu=14, alui=12, shift=3, mul=3, ld=5, st=5, br=4, jal=1, amo=3, lrsc=2, csr=2, fence=1, jalr=1,
                              trap=4, mode=6, vmem=35, vjump=10)}.get(profile, {}))
        self.mode = "M"
        self.mmu = profile == "mmu"
        self.pgflags = {}

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
        elif kind == "vjump":
            if self.mode != "M": self.gen_vjump()
            else: self.gen_one_simple()
        elif kind == "vmem":
            if self.mode != "M": self.gen_vmem()
            else: self.gen_one_simple()
        elif kind == "trap":
            self.gen_trap()
        elif kind == "mode":
            if self.mode == "M": self.gen_mode_block()
            else: self.gen_one_simple()
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
    def gen_trap(self):
        r = self.r; rd = self.reg(); mode = self.mode
        c = r.choice(["ecall", "ebreak", "illegal", "illegal_csr", "mis_ld", "mis_st", "fault_ld", "fault_st",
                      "jalr_misal", "amo_misal", "amo_fault", "xret", "csr_ro_write", "mis_ld_edge", "jalr_fault"])
        if c == "ecall":
            self.e("li x30, 0"); self.e("ecall")                       # x30 != magic: handler just skips it
        elif c == "ebreak": self.e("ebreak")
        elif c == "illegal":
            self.e(f".word {r.choice([0x00000000, 0xFFFFFFFF, 0x0000000B, 0x0000002B, 0x0000007B])}")
        elif c == "illegal_csr":
            # M-only CSRs from S/U, or a write to a read-only CSR: illegal instruction in every mode
            csr = r.choice(["mscratch", "mstatus", "mtvec", "mepc"]) if mode != "M" else "mvendorid"
            self.e(f"csrrw {rd}, {csr}, {self.src()}")
        elif c == "xret":
            # mret/sret are illegal below M (sret also in U); in M-mode they would really return, so use a ro-CSR write
            if mode == "M": self.e(f"csrrw {rd}, mvendorid, {self.reg()}")
            else: self.e("mret" if mode == "S" else r.choice(["mret", "sret"]))
        elif c == "csr_ro_write":
            self.e(f"csrrw {rd}, {r.choice(['mvendorid','marchid','mimpid','mhartid'])}, {self.reg()}")
        elif c in ("mis_ld", "mis_st", "mis_ld_edge"):
            op, sz = r.choice([("lh", 2), ("lhu", 2), ("lw", 4)]) if c != "mis_st" else r.choice([("sh", 2), ("sw", 4)])
            off = r.randrange(0, 64, 1)
            while off % sz == 0: off = r.randrange(1, 64)
            self.e(f"addi x29, x31, {off}")
            self.e(f"{op} {rd if op[0]=='l' else self.src()}, 0(x29)")
        elif c in ("fault_ld", "fault_st"):
            self.e(f"li x29, {r.choice([0x40000000, 0x40001000, 0x3FFFFFFC, 0x00003000, 0xF0000000])}")
            self.e(f"lw {rd}, 0(x29)" if c == "fault_ld" else f"sw {self.src()}, 0(x29)")
        elif c == "jalr_misal":
            l = self.label()
            self.e(f"la x29, {l}"); self.e("addi x29, x29, 2"); self.e(f"jalr {rd}, 0(x29)")
            self.out.append(f"{l}:")
        elif c == "jalr_fault":
            self.e(f"li x29, {r.choice([0x40000000, 0x00003000, 0xF0000000, 0x3FFFFFF0])}"); self.e("jalr x1, 0(x29)")
        elif c == "amo_misal":
            self.e(f"addi x29, x31, {r.choice([1, 2, 3, 5, 6, 7])}")
            self.e(f"amoadd.w {rd}, {self.src()}, (x29)")
        elif c == "amo_fault":
            self.e("li x29, 0x40000000"); self.e(f"amoswap.w {rd}, {self.src()}, (x29)")
    def gen_mode_block(self):
        r = self.r; tgt = r.choice(["U", "U", "S"]); l = self.label()
        if self.mmu: self.mmu_prepare_block(tgt)
        self.e(f"la x29, {l}"); self.e("csrw mepc, x29")
        self.e("li x28, 0x1800"); self.e("csrc mstatus, x28")          # MPP = 00 (U)
        if tgt == "S": self.e("li x28, 0x800"); self.e("csrs mstatus, x28")
        self.e("mret")
        self.out.append(f"{l}:")
        self.mode = tgt
        for _ in range(r.randint(8, 40)): self.gen_one()
        self.e("li x30, 0x7ff"); self.e("ecall")                       # handler returns to M-mode
        self.mode = "M"
    # ---- Sv32 MMU support (profile "mmu"): fixed-address page tables, see link.ld
    ROOT, L0, PGDATA, IDENT = 0x80100000, 0x80101000, 0x80110000, 0x80100800
    W0, S1, S2 = 0x10000000, 0x10400000, 0x10800000
    def pte_flags(self, force_user=None):
        r = self.r
        v = 1 if r.random() < 0.88 else 0
        rr = 1 if r.random() < 0.75 else 0
        w = 1 if r.random() < 0.55 else 0          # W without R is a reserved combination -> fault (kept on purpose)
        x = 1 if r.random() < 0.35 else 0
        u = (1 if r.random() < 0.5 else 0) if force_user is None else force_user
        a = 1 if r.random() < 0.8 else 0
        d = 1 if r.random() < 0.65 else 0
        return v | rr << 1 | w << 2 | x << 3 | u << 4 | a << 6 | d << 7
    def leaf4k(self, page, flags): return ((self.PGDATA >> 12) + page) << 10 | flags
    def ident_pte(self, user): return (0x80000000 >> 12) << 10 | 0xCF | (0x10 if user else 0)
    def mmu_data(self):
        r = self.r; out = []
        root = [0] * 1024
        root[0x200] = self.ident_pte(True)
        root[self.W0 >> 22] = ((self.L0 >> 12) << 10) | 1                  # pointer to the 4 KiB-page table
        root[self.S1 >> 22] = (0x80400000 >> 12) << 10 | self.pte_flags() | 1   # aligned 4 MiB leaf (V forced)
        root[self.S2 >> 22] = (0x80401000 >> 12) << 10 | self.pte_flags() | 1   # misaligned 4 MiB leaf -> always faults
        out += ['  .section .ptroot,"aw",@progbits', "  .align 12"] + [f"  .word {x}" for x in root]
        out += ['  .section .ptl0,"aw",@progbits', "  .align 12"] + [f"  .word {self.leaf4k(i, self.pte_flags())}" for i in range(16)] + ["  .space 4032"]
        out += ['  .section .pgdata,"aw",@progbits', "  .align 12"]
        for i in range(16):                                            # every 16-byte group starts with `ret` (jalr x0, 0(x1))
            for _ in range(256 // 4):
                out.append(f"  .word 0x00008067, {r.choice(CORNER + [r.getrandbits(32)])}, {r.choice(CORNER + [r.getrandbits(32)])}, {r.choice(CORNER + [r.getrandbits(32)])}")
        return out
    def gen_vmem(self):
        r = self.r
        pick = r.random()
        if pick < 0.70:   va = self.W0 + r.randrange(16) * 0x1000 + r.randrange(0, 0x1000, 4)
        elif pick < 0.90: va = self.S1 + r.randrange(0, 0x400000, 4)
        else:             va = self.S2 + r.randrange(0, 0x400000, 4)
        if r.random() < 0.8:                                               # exercise the hot words of a page
            va = (va & ~0xFFF) | r.choice([0, 4, 8, 12])
        rd = self.reg(); k = r.random()
        if k >= 0.45 and (va & 0xC) == 0: va |= 4                            # never overwrite the planted `ret` at a 16-byte group start
        if va < self.S2: pass
        self.e(f"li x29, {va}")
        if k < 0.45:   self.e(f"{r.choice(['lw','lh','lhu','lb','lbu'])} {rd}, 0(x29)")
        elif k < 0.85: self.e(f"{r.choice(['sw','sh','sb'])} {self.src()}, 0(x29)")
        else:          self.e(f"{r.choice(['amoadd.w', 'amoswap.w', 'amoor.w', 'amoxor.w'])} {rd}, {self.src()}, (x29)")
    def gen_vjump(self):
        r = self.r
        va = self.W0 + r.randrange(16) * 0x1000 + r.randrange(0, 0x1000, 16) if r.random() < 0.9 else self.S2 + r.randrange(0, 0x1000, 16)
        self.e(f"li x29, {va}"); self.e("jalr x1, 0(x29)")                  # success lands on `ret`; a fetch fault is resumed at x1
    def mmu_prepare_block(self, tgt):
        r = self.r
        for _ in range(r.randint(2, 6)):                                   # rewrite some PTEs, then flush
            i = r.randrange(16)
            self.e(f"li x28, {self.leaf4k(r.randrange(16), self.pte_flags())}"); self.e(f"li x29, {self.L0 + 4*i}"); self.e("sw x28, 0(x29)")
        if r.random() < 0.3:
            self.e(f"li x28, {(0x80400000 >> 12) << 10 | self.pte_flags() | 1}"); self.e(f"li x29, {self.ROOT + 4*(self.S1 >> 22)}"); self.e("sw x28, 0(x29)")
        self.e(f"li x28, {self.ident_pte(tgt == 'U')}"); self.e(f"li x29, {self.IDENT}"); self.e("sw x28, 0(x29)")
        self.e(f"li x28, {0x80000000 | (self.ROOT >> 12)}"); self.e("csrw satp, x28")
        self.e("li x28, 0xC0000"); self.e("csrc mstatus, x28")             # clear MXR|SUM
        bits = r.choice([0, 0x40000, 0x80000, 0xC0000])
        if bits: self.e(f"li x28, {bits}"); self.e("csrs mstatus, x28")
        self.e("sfence.vma x0, x0")
    def gen_one_simple(self):
        rd = self.reg(); r = self.r
        if r.random() < 0.5: self.e(f"{r.choice(['add','sub','xor','or','and','mul'])} {rd}, {self.src()}, {self.src()}")
        else: self.e(f"addi {rd}, {self.src()}, {s12(r)}")
    def program(self):
        hdr = ["  .section .text.init,\"ax\"", "  .globl _start", "_start:", "  la x31, databuf"]
        if self.profile in ("trap", "mmu"):
            hdr += ["  la x29, handler", "  csrw mtvec, x29", "  li x29, -1", "  csrw pmpaddr0, x29", "  li x29, 0x1f", "  csrw pmpcfg0, x29"]
        for x in POOL: hdr.append(f"  li x{x}, {self.r.choice(CORNER + [self.r.getrandbits(32)])}")
        hdr += ["  li x30, 0", "  li x1, 0", "  li x2, 0"]
        self.out = []
        for _ in range(self.n): self.gen_one()
        handler = []
        if self.profile in ("trap", "mmu"):
            handler = ["  .p2align 2", "handler:", "  csrr x28, mcause", "  csrr x29, mtval",
                       "  li x29, 12", "  beq x28, x29, 2f", "  li x29, 1", "  beq x28, x29, 2f",
                       "  csrr x28, mstatus", "  csrr x29, mepc", "  addi x29, x29, 4", "  csrw mepc, x29", "  j 3f",
                       "2: csrr x28, mstatus", "  csrr x29, mepc", "  csrw mepc, x1",       # fetch fault: resume at the jalr's return address
                       "3: li x28, 0x7ff", "  bne x30, x28, 1f",
                       "  li x28, 0x1800", "  csrs mstatus, x28", "  li x30, 0", "1: mret"]
        tail = ["  li x30, 1", "  la x29, tohost", "  sw x30, 0(x29)", "1: j 1b"] + handler + [
                "  .section .tohost,\"aw\",@progbits", "  .align 6", "  .globl tohost", "tohost: .dword 0",
                "  .globl fromhost", "fromhost: .dword 0",
                "  .section .data", "  .align 4", "databuf:"]
        for _ in range(BUF_WORDS): tail.append(f"  .word {self.r.choice(CORNER + [self.r.getrandbits(32)])}")
        if self.mmu: tail += self.mmu_data()
        return "\n".join(hdr + self.out + tail) + "\n"

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("seed", type=int); ap.add_argument("out")
    ap.add_argument("--n", type=int, default=400); ap.add_argument("--profile", default="mix")
    a = ap.parse_args()
    open(a.out, "w").write(Gen(a.seed, a.n, a.profile).program())
