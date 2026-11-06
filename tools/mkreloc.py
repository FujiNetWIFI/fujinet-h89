#!/usr/bin/env python3
# Copyright (C) 2026 Thomas Cherryhomes
# SPDX-License-Identifier: GPL-3.0-or-later
"""Relocation data for a Z80 image that can load on any page boundary.

Give it the same program assembled at 0000H and at 0100H. A byte that is the
high byte of an address differs by exactly 1; every other byte is the same.
Anything else means an address the loader couldn't fix up, and fails the
build.

  mkreloc.py --def resident.def img0.bin img1.bin -o resident.bin --bits resident.bits

writes the org-0 image up to the symbol res_bss (what the loader copies) and
a bitmap, one bit per image byte (bit 0 of byte 0 is image byte 0), set where
the loader adds the page it loads at. The bitmap is at most 255 bytes long.
"""
import argparse
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("img0")
    ap.add_argument("img1")
    ap.add_argument("--def", dest="defs", required=True,
                    help="z80asm -g symbol file of the org-0 build")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--bits", required=True)
    args = ap.parse_args()

    syms = {}
    with open(args.defs) as f:
        for line in f:
            m = re.match(r"DEFC\s+(\w+)\s*=\s*\$([0-9A-Fa-f]+)", line)
            if m:
                syms[m.group(1)] = int(m.group(2), 16)
    for need in ("res_bss", "res_end"):
        if need not in syms:
            sys.exit(f"mkreloc: {need} is not in {args.defs}")
    length = syms["res_bss"]

    a = open(args.img0, "rb").read()
    b = open(args.img1, "rb").read()
    if len(a) != len(b):
        sys.exit(f"mkreloc: the builds differ in size ({len(a)}, {len(b)})")
    if len(a) < length:
        sys.exit(f"mkreloc: image is {len(a)} bytes, res_bss at {length}")

    bits = bytearray((length + 7) // 8)
    count = 0
    for i in range(len(a)):
        d = (b[i] - a[i]) & 0xFF
        if d == 0:
            continue
        if d != 1 or i >= length:
            sys.exit(f"mkreloc: byte {i:04X} is {a[i]:02X} at 0, {b[i]:02X} at 100H"
                     + (" (in the part after res_bss)" if i >= length else ""))
        bits[i // 8] |= 1 << (i % 8)
        count += 1
    if len(bits) > 255:
        sys.exit(f"mkreloc: {len(bits)} bitmap bytes; the loader counts them in B")

    open(args.out, "wb").write(a[:length])
    open(args.bits, "wb").write(bits)
    print(f"resident: image {length} bytes, {count} relocations, "
          f"{syms['res_end']} bytes with its buffers "
          f"({(syms['res_end'] + 255) // 256} pages)")


if __name__ == "__main__":
    main()
