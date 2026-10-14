#!/usr/bin/env python3
"""cpm-get.py: a file, or the directory, from an H17 CP/M disk image (.h8d).

  cpm-get.py IMG NAME.EXT [-o OUT]     the file's records (to stdout)
  cpm-get.py IMG --ls                  NAME.EXT and its size in records

The layout Heath's CP/M gives a hard-sectored H17 disk (z88dk's appmake
+cpmdisk -f hz89): 40 tracks of ten 256-byte sectors, three of them the
system's, sectors skewed 0 4 8 2 6 1 5 9 3 7, 1K blocks, the directory in
blocks 0 and 1.

Copyright (C) 2026 Thomas Cherryhomes
SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import sys

SKEW = [0, 4, 8, 2, 6, 1, 5, 9, 3, 7]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('img')
    ap.add_argument('name', nargs='?')
    ap.add_argument('--ls', action='store_true')
    ap.add_argument('-o', dest='out')
    a = ap.parse_args()
    img = open(a.img, 'rb').read()

    def lsec(ls):
        t, s = 3 + ls // 10, SKEW[ls % 10]
        o = (t * 10 + s) * 256
        return img[o:o + 256]

    def block(b):
        return b''.join(lsec(b * 4 + i) for i in range(4))

    d = block(0) + block(1)
    files = {}
    for e in range(64):
        ent = d[e * 32:e * 32 + 32]
        if ent[0] != 0:
            continue
        name = ent[1:9].decode('ascii', 'replace').rstrip() + '.' + \
            ent[9:12].decode('ascii', 'replace').rstrip()
        files.setdefault(name, []).append((ent[12], ent[15], [x for x in ent[16:32] if x]))
    if a.ls:
        for name, exts in sorted(files.items()):
            print(name, sum(rc for _, rc, _ in exts))
        return
    if not a.name or a.name.upper() not in files:
        sys.exit('cpm-get.py: %s: not on the disk' % a.name)
    data = b''
    for ex, rc, blks in sorted(files[a.name.upper()]):
        data += b''.join(block(b) for b in blks)[:rc * 128]
    if a.out:
        open(a.out, 'wb').write(data)
    else:
        sys.stdout.buffer.write(data)


if __name__ == '__main__':
    main()
