#!/usr/bin/env python3
"""Inject keystrokes into the guest console of a running console.py (host -> guest ring).
    sudo python3 send.py 'uname -a'      (a newline is appended)"""
import mmap, os, sys
from run_on_board import DDR_BASE
MB, RXH, RXT, RXB, RXSZ = 0x3F0000, 0x10, 0x14, 0x500, 1024
mem = mmap.mmap(os.open("/dev/mem", os.O_RDWR | os.O_SYNC), 0x400000, offset=DDR_BASE)
w = lambda o: int.from_bytes(mem[MB + o:MB + o + 4], "little")
for b in (" ".join(sys.argv[1:]) + "\n").encode():
    h = w(RXH)
    while (h + 1) % RXSZ == w(RXT):
        pass
    mem[MB + RXB + h] = b
    mem[MB + RXH:MB + RXH + 4] = ((h + 1) % RXSZ).to_bytes(4, "little")
