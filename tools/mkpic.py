#!/usr/bin/env python3
"""
mkpic.py: an HDOS device driver (.DVD) from three assemblies of its source.

  mkpic.py --map PIC0.map -o OUT.DVD PIC0.bin PIC1.bin PIC2.bin [--loaded ADDR]

z80asm can't write HDOS's PIC format, so the source is assembled with its
own header at origin 0 (file offset = address), and again at origins 0x0101
and 0xD137. Every word that moves by exactly the origin is an address to
relocate; anything else that differs (an 8-bit part of an address) can't be
relocated by HDOS and is an error. The table is then proven by applying it
to the first image at both other origins.

A PIC file: FF 01, LEN (to the end of the table), PTR (where the table
starts); the device driver's header from offset 6; the resident driver from
0x200 up to PTR; then the table: 16-bit offsets of words to relocate, then
0000. HDOS loads 0x200..PTR at some address and adds (address - 0x200) to
each word the table names.
"""

import argparse
import re
import sys

DELTAS = (0x0101, 0xD137)
ENTRY = 0x200


def fail(msg):
    sys.exit('mkpic: ' + msg)


def w16(b, o):
    return b[o] | b[o + 1] << 8


def symbol(map_text, name):
    m = re.search(r'^%s\s*=\s*\$([0-9A-Fa-f]+)' % re.escape(name), map_text, re.M)
    if not m:
        fail('%s is not in the map' % name)
    return int(m.group(1), 16)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--map', required=True)
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--loaded', type=lambda s: int(s, 0),
                    help='print what memory should hold with the driver loaded there')
    ap.add_argument('images', nargs=3)
    a = ap.parse_args()

    img = [bytearray(open(p, 'rb').read()) for p in a.images]
    n = len(img[0])
    if any(len(i) != n for i in img) or n <= ENTRY:
        fail('the three assemblies differ in length, or have no driver past 0x200')
    m = open(a.map).read()
    if symbol(m, 'dvd_entry') != ENTRY:
        fail('dvd_entry is at %04X, not 0x200' % symbol(m, 'dvd_entry'))
    if symbol(m, 'pic_end') != n:
        fail('pic_end (%04X) is not the end of the image (%04X)' % (symbol(m, 'pic_end'), n))

    h = img[0]
    if h[0:2] != b'\xff\x01' or h[6] != 0xC7:
        fail('no FF 01 / C7 header')
    if any(i[2:6] != b'\0\0\0\0' for i in img):
        fail('LEN and PTR must be left 0 for mkpic')
    mnu = h[9]
    if not 1 <= mnu <= 8 or not all(h[10 + u] for u in range(mnu)):
        fail('MNU %d, or a unit without capabilities' % mnu)
    if any(h[0x12:ENTRY]):
        fail('bytes 0x12..0x1FF must be 0 (no SET code, no INIT)')

    # Words that move with the origin
    relocs = []
    p = 0
    while p < n:
        if img[0][p] == img[1][p]:
            p += 1
            continue
        if p + 1 >= n or (w16(img[1], p) - w16(img[0], p)) & 0xFFFF != DELTAS[0]:
            fail('%04X differs by other than a whole address (an 8-bit part of a label?)' % p)
        if p < ENTRY:
            fail('%04X: an address below the driver' % p)
        relocs.append(p)
        p += 2

    # Prove it
    for delta, other in zip(DELTAS, img[1:]):
        t = bytearray(img[0])
        for r in relocs:
            v = (w16(t, r) + delta) & 0xFFFF
            t[r], t[r + 1] = v & 0xFF, v >> 8
        if t != other:
            bad = next(i for i in range(n) if t[i] != other[i])
            fail('relocating by %04X leaves %04X wrong' % (delta, bad))

    ptr = n
    ln = ptr + 2 * len(relocs) + 2
    if ln > 0xFFFF:
        fail('too big')
    out = bytearray(img[0])
    out[2], out[3] = ln & 0xFF, ln >> 8
    out[4], out[5] = ptr & 0xFF, ptr >> 8
    for r in relocs:
        out += bytes((r & 0xFF, r >> 8))
    out += b'\0\0'
    open(a.output, 'wb').write(out)

    code = ptr - ENTRY
    pages = -(-code // 256)
    print('%s: driver %d bytes, %d relocations, file %d bytes (%d sectors); '
          'HDOS takes %d bytes (%d pages of driver + %d GRT pages)'
          % (a.output, code, len(relocs), len(out), -(-len(out) // 256),
             (pages + mnu) * 256, pages, mnu))

    if a.loaded is not None:
        t = bytearray(img[0][ENTRY:ptr])
        for r in relocs:
            o = r - ENTRY
            v = (w16(t, o) + a.loaded - ENTRY) & 0xFFFF
            t[o], t[o + 1] = v & 0xFF, v >> 8
        for o in range(0, len(t), 16):
            print('%04X: %s' % (a.loaded + o, ' '.join('%02X' % b for b in t[o:o + 16])))


if __name__ == '__main__':
    main()
