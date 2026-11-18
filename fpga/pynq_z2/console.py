#!/usr/bin/env python3
"""Interactive console for the RV32 Linux on the PYNQ-Z2 with no UART adapter.

Run on the board as root (or over `ssh -t`): loads the bitstream and the firmware built with
`DTS=board_ddrcon.dts sw/build_linux_fw.sh`, starts the core, then relays the DDR mailbox that
OpenSBI's ddrcon driver exposes (sw/opensbi-ddrcon) to this terminal. Linux uses it as hvc0.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python console.py rv32_pynq.bit fw_linux.bin
    ... --script cmds.txt   non-interactive: send each line of the file once the shell prompt appears
    ... --log out.txt       also save everything the guest prints
Quit an interactive session with Ctrl-].  Boot to the shell takes about 6 minutes.
"""
import argparse, mmap, os, select, sys, termios, time, tty

from run_on_board import DDR_BASE, RAM_BYTES, emio_gpio, set_hp_32bit, sysfs_gpio

MB = 0x3F0000           # mailbox offset in the RAM window (RV32 0x803f0000, reserved-memory in board_ddrcon.dts)
ATT, TXH, TXT, RXH, RXT = 0x04, 0x08, 0x0C, 0x10, 0x14
TXB, TXSZ, RXB, RXSZ = 0x100, 1024, 0x500, 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bit"); ap.add_argument("image")
    ap.add_argument("--script"); ap.add_argument("--log")
    ap.add_argument("--timeout", type=float, default=1800, help="script mode: give up after SEC")
    ap.add_argument("--prompt", default="# ", help="script mode: shell prompt to wait for")
    a = ap.parse_args()
    img = open(a.image, "rb").read()
    from pynq import Overlay
    Overlay(a.bit)
    set_hp_32bit()
    gpio = emio_gpio(); sysfs_gpio(gpio, 0)
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mem = mmap.mmap(fd, RAM_BYTES, offset=DDR_BASE)
    mem[:len(img)] = img
    assert mem[:len(img)] == img, "readback mismatch"
    mem[MB:MB + 0x900] = bytes(0x900)            # clean mailbox (DDR keeps stale data across runs)
    w = lambda o: int.from_bytes(mem[MB + o:MB + o + 4], "little")
    sw = lambda o, v: mem.__setitem__(slice(MB + o, MB + o + 4), v.to_bytes(4, "little"))
    sw(ATT, 1)
    sysfs_gpio(gpio, 1)
    print(f"core released, waiting for the guest console (Ctrl-] quits)", file=sys.stderr, flush=True)
    logf = open(a.log, "wb") if a.log else None
    script = [l.rstrip("\n") for l in open(a.script)] if a.script else None
    interactive = script is None and sys.stdin.isatty()
    old = None
    if interactive:
        old = termios.tcgetattr(0); tty.setraw(0)
    out_tail, last_rx, t0, sent_idx, since = b"", time.time(), time.time(), 0, 0.0
    rxbuf = b"" if script is not None else None
    seen_prompt = False
    try:
        while True:
            # guest -> host
            h, t = w(TXH), w(TXT)
            if h != t:
                n = (h - t) % TXSZ
                chunk = b"".join(mem[MB + TXB + ((t + i) % TXSZ):MB + TXB + ((t + i) % TXSZ) + 1] for i in range(n))
                sw(TXT, (t + n) % TXSZ)
                os.write(1, chunk if interactive else chunk.replace(b"\r", b""))
                if logf: logf.write(chunk); logf.flush()
                out_tail = (out_tail + chunk)[-64:]; last_rx = time.time()
                continue
            # host -> guest
            if script is not None:
                seen_prompt = seen_prompt or a.prompt.encode() in out_tail
                if seen_prompt and time.time() - last_rx > 4.0:
                    if sent_idx >= len(script):
                        break
                    rxbuf = (script[sent_idx] + "\n").encode(); sent_idx += 1; out_tail = b""; last_rx = time.time()
                if time.time() - t0 > a.timeout:
                    print("\nconsole.py: timeout", file=sys.stderr); break
            else:
                r, _, _ = select.select([0], [], [], 0.02)
                if r:
                    d = os.read(0, 64)
                    if not d or b"\x1d" in d:
                        break
                    rxbuf = d
                else:
                    rxbuf = None
            if rxbuf:
                for b in rxbuf:
                    h = w(RXH)
                    while (h + 1) % RXSZ == w(RXT):
                        time.sleep(0.01)
                    mem[MB + RXB + h] = b
                    sw(RXH, (h + 1) % RXSZ)
                rxbuf = b"" if script is not None else None
            time.sleep(0.01)
    finally:
        if old: termios.tcsetattr(0, termios.TCSADRAIN, old)
        sw(ATT, 0)
        sysfs_gpio(gpio, 0)
        print("\nconsole.py: core held in reset, console closed", file=sys.stderr)


if __name__ == "__main__":
    main()
