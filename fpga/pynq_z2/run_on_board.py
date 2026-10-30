#!/usr/bin/env python3
"""Run on the PYNQ-Z2 (as root): load the bitstream and an OpenSBI image, then start the core.

    cd /tmp && sudo /usr/local/share/pynq-venv/bin/python run_on_board.py rv32_pynq.bit fw_payload.bin [--dump 4096]

The image goes to DDR 0x1C000000 (RV32 0x80000000). The top 64 MiB of DDR must be reserved
from Linux (boot with mem=448M). EMIO GPIO 0 is the core's `run` line.
"""
import argparse, mmap, os, time

DDR_BASE = 0x1C000000
RAM_BYTES = 64 * 1024 * 1024
EMIO0 = 54  # first EMIO line on the zynq_gpio chip (after 54 MIO lines)


def emio_gpio(n=0):
    """Absolute sysfs number: the gpiochip base differs per kernel (0 on old, 906 on 5.15)."""
    base = "/sys/class/gpio"
    for chip in sorted(os.listdir(base)):
        if chip.startswith("gpiochip") and open(f"{base}/{chip}/label").read().strip() == "zynq_gpio":
            return int(open(f"{base}/{chip}/base").read()) + EMIO0 + n
    raise RuntimeError("zynq_gpio chip not found")


def sysfs_gpio(n, value):
    base = "/sys/class/gpio"
    if not os.path.exists(f"{base}/gpio{n}"):
        with open(f"{base}/export", "w") as f:
            f.write(str(n))
    with open(f"{base}/gpio{n}/direction", "w") as f:
        f.write("out")
    with open(f"{base}/gpio{n}/value", "w") as f:
        f.write(str(value))


def set_hp_32bit():
    """The PS HP ports (AFI0/AFI1) power up in 64-bit mode and the bitstream cannot change that;
    our AXI masters are 32 bits wide, so set FabricWidth=1 on both channels of HP0 and HP1."""
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    for base in (0xF8008000, 0xF8009000):
        regs = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        for off in (0x00, 0x14):  # AFI_RDCHAN_CTRL, AFI_WRCHAN_CTRL
            v = int.from_bytes(regs[off:off + 4], "little") | 1
            regs[off:off + 4] = v.to_bytes(4, "little")
        regs.close()


def read_debug():
    """EMIO bank2 (GPIO_I[31:0]) = flags/counters, bank3 (GPIO_I[63:32]) = word picked by sel."""
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    regs = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xE000A000)
    rd = lambda o: int.from_bytes(regs[o:o + 4], "little")
    names = ["last retired pc", "last fetch addr", "last fetch data", "last AXI data addr",
             "retired pc[0]", "retired pc[1]", "retired pc[2]", "retired pc[3]",
             "core dreq addr[0]", "core dreq addr[1]", "core dreq addr[2]", "core dreq addr[3]",
             "dreq/drsp/derr/ret", "first store data", "last dreq addr", "last dreq wdata",
             "core dbg (live)", "core dbg (ever 1)", "mcause", "mepc", "mtval", "first mcause", "first mepc", "first mtval",
             "AXI R data #0", "AXI R data #1", "core rsp data #0", "core rsp data #1"]
    word = {}
    sels = list(range(28))
    for sel in sels:
        for b in range(6):
            sysfs_gpio(emio_gpio(1 + b), (sel >> b) & 1)
        time.sleep(0.005)
        word[names[sel]] = rd(0x6C)
    f = rd(0x68)
    print(f"  flags={f:#010x}  fetch AR={f & 255} R={(f >> 8) & 255}  data AR+AW={(f >> 16) & 255}"
          f"  ierr={(f >> 24) & 1} derr={(f >> 25) & 1}  ibus arvalid={(f >> 26) & 1} rready={(f >> 27) & 1}"
          f"  dbus busy={(f >> 28) & 1}  retired_any={(f >> 29) & 1}  in_reset={(f >> 30) & 1}")
    for k, v in word.items():
        print(f"  {k:20s} {v:#010x}")


def read_la():
    """Fetch-channel trace: one line per clock, from the first AR."""
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    regs = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xE000A000)
    print("  cyc arvalid arready rvalid rready rlast | core req_v req_r | araddr[4:2] rdata[19:0]")
    for i in range(32):
        sysfs_gpio(emio_gpio(6), 1)
        for b in range(5):
            sysfs_gpio(emio_gpio(1 + b), (i >> b) & 1)
        time.sleep(0.005)
        v = int.from_bytes(regs[0x6C:0x70], "little")
        bit = lambda n: v >> n & 1
        print(f"  {i:3d}    {bit(29)}       {bit(28)}       {bit(27)}      {bit(26)}      {bit(25)}   |"
              f"        {bit(24)}     {bit(23)}   |   {(v >> 20 & 7) << 2:#04x}        {v & 0xFFFFF:#07x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bit")
    ap.add_argument("image")
    ap.add_argument("--probe", action="store_true", help="read the PL debug window (pc, fetch addr/data, counters)")
    ap.add_argument("--watch", action="store_true", help="poll the debug flags right after release and print every change")
    ap.add_argument("--check", action="store_true", help="after 3 s, report which RAM words the core changed")
    a = ap.parse_args()

    img = open(a.image, "rb").read()
    assert len(img) <= RAM_BYTES, "image larger than the 64 MiB window"

    from pynq import Overlay  # loads .bit (and .hwh next to it), sets FCLK0 = 50 MHz
    Overlay(a.bit)
    set_hp_32bit()
    gpio = emio_gpio()
    sysfs_gpio(gpio, 0)  # hold the core in reset while loading

    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)  # O_SYNC -> uncached, coherent with HP ports
    mem = mmap.mmap(fd, RAM_BYTES, offset=DDR_BASE)
    if a.check:
        mem[:] = bytes(RAM_BYTES)  # DDR keeps stale data across reboots; start from zero
    mem[:len(img)] = img
    assert mem[:len(img)] == img, "readback mismatch: is the DDR window really free?"
    print(f"loaded {len(img)} bytes at {DDR_BASE:#x}")

    if a.watch:
        gfd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        gregs = mmap.mmap(gfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xE000A000)
        t0 = time.perf_counter()
    sysfs_gpio(gpio, 1)
    if a.watch:
        last = None
        while time.perf_counter() - t0 < 0.5:
            f = int.from_bytes(gregs[0x68:0x6C], "little")
            if f != last:
                print(f"  t={1000 * (time.perf_counter() - t0):7.1f}ms flags={f:#010x} fetchAR={f & 255} R={(f >> 8) & 255}"
                      f" dAR+AW={(f >> 16) & 255} arvalid={(f >> 26) & 1} rready={(f >> 27) & 1}"
                      f" retired={(f >> 29) & 1} rst={(f >> 30) & 1}")
                last = f
    print("core released; console on Pmod JA1/JA2 at 115200 8N1")
    if a.probe:
        for t in (0.2, 1.0, 3.0):
            time.sleep(t if t == 0.2 else t - (1.0 if t == 3.0 else 0.2))
            print(f"debug window at ~{t}s:")
            read_debug()
        read_la()
    if a.check:
        time.sleep(3)
        cur = mem[:]
        ref = img + bytes(RAM_BYTES - len(img))
        diff = [i for i in range(0, RAM_BYTES, 4) if cur[i:i + 4] != ref[i:i + 4]]
        print(f"words changed by the core: {len(diff)}")
        for i in diff[:12]:
            print(f"  RV {0x80000000 + i:#010x}: {ref[i:i+4].hex()} -> {cur[i:i+4].hex()}")


if __name__ == "__main__":
    main()
