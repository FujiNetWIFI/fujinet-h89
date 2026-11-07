#!/usr/bin/env python3
# Copyright (C) 2026 Thomas Cherryhomes
# SPDX-License-Identifier: GPL-3.0-or-later
"""Relocation data for a Z80 image that can load at any address.

Give it the same program assembled at 0000H and at 0100H. A byte that is the
high byte of an address differs by exactly 1; every other byte is the same.
Anything else means an address the loader couldn't fix up, and fails the
build. A third build, at an origin that isn't on a page, checks that each of
those bytes and the one before it make a word that moves by that origin (not,
say, a high(symbol) loaded on its own) and that no other byte moves.

  mkreloc.py --def resident.def img0.bin img1.bin img2.bin --org2 0x1234 \
      -o resident.bin --bits resident.bits

writes the org-0 image up to the symbol res_bss (what the loader copies) and
a bitmap, one bit per image byte (bit 0 of byte 0 is image byte 0), set at the
high byte of each address; the loader adds the load address to that word. The
bitmap is at most 255 bytes long.
"""
import argparse
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("img0")
    ap.add_argument("img1")
    ap.add_argument("img2", help="the build at --org2")
    ap.add_argument("--org2", type=lambda v: int(v, 0), required=True)
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
    c = open(args.img2, "rb").read()
    if not len(a) == len(b) == len(c):
        sys.exit(f"mkreloc: the builds differ in size ({len(a)}, {len(b)}, {len(c)})")
    if len(a) < length:
        sys.exit(f"mkreloc: image is {len(a)} bytes, res_bss at {length}")

    bits = bytearray((length + 7) // 8)
    count = 0
    flagged = set()
    for i in range(len(a)):
        d = (b[i] - a[i]) & 0xFF
        if d == 0:
            continue
        if d != 1 or i >= length:
            sys.exit(f"mkreloc: byte {i:04X} is {a[i]:02X} at 0, {b[i]:02X} at 100H"
                     + (" (in the part after res_bss)" if i >= length else ""))
        if i == 0:
            sys.exit("mkreloc: byte 0000 is the high byte of an address")
        bits[i // 8] |= 1 << (i % 8)
        count += 1
        flagged.add(i)
    # the third build: each flagged byte and the one before it are an address
    claimed = set()
    for i in flagged:
        if i - 1 in flagged or i - 1 in claimed or i in claimed:
            sys.exit(f"mkreloc: the words at {i - 1:04X} overlap")
        claimed.update((i - 1, i))
        w0 = a[i - 1] | a[i] << 8
        w2 = c[i - 1] | c[i] << 8
        if b[i - 1] != a[i - 1] or (w2 - w0) & 0xFFFF != args.org2 & 0xFFFF:
            sys.exit(f"mkreloc: bytes {i - 1:04X}-{i:04X} ({w0:04X} at 0, {w2:04X} at "
                     f"{args.org2:X}H) aren't an address")
    for i in range(len(a)):
        if i not in claimed and a[i] != c[i]:
            sys.exit(f"mkreloc: byte {i:04X} is {a[i]:02X} at 0, {c[i]:02X} at {args.org2:X}H")
    if len(bits) > 255:
        sys.exit(f"mkreloc: {len(bits)} bitmap bytes; the loader counts them in B")

    open(args.out, "wb").write(a[:length])
    open(args.bits, "wb").write(bits)
    print(f"resident: image {length} bytes, {count} relocations, "
          f"{syms['res_end']} bytes with its buffers "
          f"({(syms['res_end'] + 255) // 256} pages)")


if __name__ == "__main__":
    main()
