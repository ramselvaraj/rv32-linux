#!/usr/bin/env python3
"""Convert binary images to a $readmemh file addressed in 32-bit words from RAM base.

usage: bin2hex.py out.hex [file@0xOFFSET ...]   (offset relative to RAM base, default 0)
"""
import struct
import sys


def main():
    out = sys.argv[1]
    with open(out, "w") as f:
        for spec in sys.argv[2:]:
            path, _, off = spec.partition("@")
            off = int(off, 0) if off else 0
            data = open(path, "rb").read()
            data += b"\0" * (-len(data) % 4)
            # all-zero words are skipped: simulated RAM powers up zeroed
            prev_zero = True
            for i, (w,) in enumerate(struct.iter_unpack("<I", data)):
                if w == 0:
                    prev_zero = True
                    continue
                if prev_zero:
                    f.write("@%x\n" % (off // 4 + i))
                    prev_zero = False
                f.write("%08x\n" % w)


if __name__ == "__main__":
    main()
