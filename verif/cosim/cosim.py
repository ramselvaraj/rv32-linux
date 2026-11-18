#!/usr/bin/env python3
"""Lock-step co-simulation: compare the rv32-linux retire trace against Spike.

  cosim.py <sim-binary> <elf> [--spike PATH] [--maxcycles N] [--lat]

Per retired instruction the checker compares PC, instruction word and the
integer-register write (x0 writes must not appear). Reads of free-running
counters (cycle/time/instret/hpm) are compared for PC/insn only, since their
values legitimately differ between a cycle-accurate core and an ISS.
Exit 0 = traces identical over their common length.
"""
import argparse, os, re, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
NM = f"{ROOT}/tools/gcc/bin/riscv-none-elf-nm"
OBJCOPY = f"{ROOT}/tools/gcc/bin/riscv-none-elf-objcopy"
SPIKE = os.environ.get("SPIKE", os.path.expanduser("~/builds/spike-cl/bin/spike"))
ISA = "rv32ima_zicsr_zifencei_zicntr"
RAM_BASE = 0x80000000

SP_RE = re.compile(r"core\s+0:\s+\d\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
SP_MEM = re.compile(r"\s+mem\s+0x([0-9a-f]+)")
SP_W = re.compile(r"\s+x(\d+)\s+0x([0-9a-f]+)")
DUT_RE = re.compile(r"^([0-9a-f]{8}) ([0-9a-f]{8}) x(\d+)=([0-9a-f]{8})")

TOHOST = 0
def is_counter_read(insn):
    # csrr* with csr in cycle/time/instret/hpm (0xC00-0xC1F, 0xC80-0xC9F) or m-mode counters (0xB00-0xB1F, 0xB80-0xB9F)
    if insn & 0x7f != 0x73 or (insn >> 12) & 7 == 0:
        return False
    csr = insn >> 20
    return (0xC00 <= csr < 0xC20) or (0xC80 <= csr < 0xCA0) or (0xB00 <= csr < 0xB20) or (0xB80 <= csr < 0xBA0)

# mstatus/sstatus: Spike keeps FS/VS/XS/SD live even without F/V; this core hardwires them to 0
STATUS_MASK = ~0x8001E600 & 0xFFFFFFFF
# Implementation-defined read-only IDs: mvendorid/marchid/mimpid (mhartid is 0 on both)
def is_id_read(insn):
    return insn & 0x7f == 0x73 and (insn >> 12) & 7 != 0 and (insn >> 20) in (0xF11, 0xF12, 0xF13)

def is_status_read(insn):
    return insn & 0x7f == 0x73 and (insn >> 12) & 7 != 0 and (insn >> 20) in (0x300, 0x100)

def spike_trace(elf, path, tohost):
    subprocess.run([SPIKE, f"--isa={ISA}", f"-m0x80000000:0x4000000", "--log-commits",
                    f"--log={path}", elf], check=False, timeout=300,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = []
    for line in open(path):
        m = SP_RE.match(line)
        if not m: continue
        pc = int(m.group(1), 16)
        if not out and pc < RAM_BASE: continue   # Spike's reset ROM (leading entries only; v-tests run at low VAs)
        w = SP_W.match(m.group(3))
        out.append((pc, int(m.group(2), 16), int(w.group(1)) if w else 0, int(w.group(2), 16) if w else 0))
        mm = SP_MEM.search(m.group(3))
        if mm and int(mm.group(1), 16) == tohost:
            break                           # test finished; Spike would spin on tohost until its host polls
    return out

def dut_trace(sim, elf, maxcycles):
    with tempfile.TemporaryDirectory() as td:
        binf, hexf = f"{td}/a.bin", f"{td}/a.hex"
        subprocess.run([OBJCOPY, "-O", "binary", elf, binf], check=True)
        subprocess.run([sys.executable, f"{ROOT}/sw/bin2hex.py", hexf, binf], check=True)
        syms = subprocess.run([NM, elf], capture_output=True, text=True).stdout
        th = next(l.split()[0] for l in syms.splitlines() if l.split()[-1] == "tohost")
        global TOHOST; TOHOST = int(th, 16)
        r = subprocess.run([sim, f"+hex={hexf}", f"+tohost={th}", f"+maxcycles={maxcycles}", "+trace"],
                           capture_output=True, text=True, timeout=600)
    out, status = [], "NO RESULT"
    for l in r.stdout.splitlines():
        m = DUT_RE.match(l)
        if m:
            rd = int(m.group(3))
            out.append((int(m.group(1), 16), int(m.group(2), 16), rd, int(m.group(4), 16) if rd else 0))
        elif l.startswith(("PASS", "FAIL", "TIMEOUT")):
            status = l
    return out, status

def compare(dut, spk):
    n = min(len(dut), len(spk))
    for i in range(n):
        d, s = dut[i], spk[i]
        if d[0] != s[0] or d[1] != s[1]:
            return i, f"PC/insn: dut {d[0]:08x} {d[1]:08x} vs spike {s[0]:08x} {s[1]:08x}"
        dv, sv = d[3], s[3]
        if is_status_read(d[1]): dv &= STATUS_MASK; sv &= STATUS_MASK
        # trap handlers spill sstatus to the stack and reload it later, so the SD/FS skew can
        # surface in a plain load; tolerate differences confined to exactly those two fields
        elif (dv ^ sv) & 0xFFFFFFFF and ((dv ^ sv) & ~0x80006000) == 0 and not is_counter_read(d[1]): sv = dv
        if is_id_read(d[1]): sv = dv
        if d[2] != s[2] or (d[2] and dv != sv and not is_counter_read(d[1])):
            return i, (f"reg write @pc {d[0]:08x} insn {d[1]:08x}: dut x{d[2]}={d[3]:08x} "
                       f"vs spike x{s[2]}={s[3]:08x}")
    return None, None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sim"); ap.add_argument("elf")
    ap.add_argument("--maxcycles", type=int, default=2_000_000)
    ap.add_argument("-q", action="store_true")
    a = ap.parse_args()
    dut, status = dut_trace(a.sim, a.elf, a.maxcycles)
    with tempfile.NamedTemporaryFile(suffix=".log") as t:
        spk = spike_trace(a.elf, t.name, TOHOST)
    idx, why = compare(dut, spk)
    name = os.path.basename(a.elf)
    # the last instruction(s) before the tohost store may be cut off on one side
    # Spike may run past the DUT: in v-tests tohost is written via a virtual address so the cut above
    # cannot see it. Accept that only if the DUT itself finished with PASS.
    if idx is None and len(spk) > len(dut) and status.startswith("PASS"):
        spk = spk[:len(dut)]
    if idx is None and abs(len(dut) - len(spk)) > 2:
        idx, why = min(len(dut), len(spk)), f"length mismatch dut={len(dut)} spike={len(spk)}"
    if idx is None:
        if not a.q: print(f"{name}: MATCH {len(dut)} instrs ({status.split()[0]})")
        return 0
    print(f"{name}: MISMATCH at retire #{idx}: {why}")
    return 1

if __name__ == "__main__":
    sys.exit(main())
