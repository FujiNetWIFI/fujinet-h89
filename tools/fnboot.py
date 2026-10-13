#!/usr/bin/env python3
"""
fnboot.py: FNBOOT's boot image, and FNBOOT put into a monitor ROM.

  fnboot.py image STAGE2.BIN PROGRAM.ABS -o autorun.img
  fnboot.py patch MONITOR.ROM FNBOOT.BIN --at ADDR -o OUT.ROM

image: what the FujiNet keeps in flash as /autorun.img. Sector 0 is stage 2
(boot/stage2.asm), which FNBOOT reads to 2280H and runs; its parameter block
(bytes 2..6: sectors, load address, entry) gets the program's. The program,
an HDOS .ABS (FF 00, load address, length, entry, then the bytes), follows
from sector 1 without its header. Stage 2 loads it last sector first, each
reply's 6-byte header landing just below its sector, so the first lands
below the program and must miss stage 2.

patch: FNBOOT, assembled for ADDR, into the ROM image at ADDR (the ROM at
0), only over bytes the ROM leaves unused (all 00H, or all FFH).
"""

import argparse
import sys

SECTOR = 512
BOOT_LOAD = 0x2280
REPLY_HEADER = 6


def fail(msg):
    sys.exit('fnboot: ' + msg)


def w16(b, o):
    return b[o] | b[o + 1] << 8


def split_octal(addr):
    return '%03o%03o' % (addr >> 8, addr & 0xFF)


def image(a):
    stage2 = bytearray(open(a.stage2, 'rb').read())
    prog = open(a.program, 'rb').read()
    if len(stage2) > SECTOR:
        fail('stage 2 is %d bytes, more than a sector' % len(stage2))
    if stage2[0:2] != b'\x18\x05':
        fail('stage 2 should start JR over its parameter block')
    if len(prog) < 8 or prog[0:2] != b'\xff\x00':
        fail('%s is not an HDOS .ABS (FF 00 header)' % a.program)
    load, length, entry = w16(prog, 2), w16(prog, 4), w16(prog, 6)
    body = prog[8:]
    if len(body) != length:
        fail('the header says %d bytes, the file has %d' % (length, len(body)))
    n = -(-length // SECTOR)
    if not 1 <= n <= 255:
        fail('%d sectors: stage 2 counts them in a byte' % n)
    if load - REPLY_HEADER < BOOT_LOAD + len(stage2):
        fail('loading at %04X would put a reply header over stage 2 (ends %04X)'
             % (load, BOOT_LOAD + len(stage2)))
    if load + n * SECTOR > 0x10000:
        fail('%d sectors from %04X run past the top of memory' % (n, load))
    if not load <= entry < load + length:
        fail('the entry %04X is outside the program' % entry)

    stage2[2] = n
    stage2[3:5] = bytes((load & 0xFF, load >> 8))
    stage2[5:7] = bytes((entry & 0xFF, entry >> 8))
    out = bytes(stage2) + bytes(SECTOR - len(stage2))
    out += body + bytes(n * SECTOR - length)
    open(a.output, 'wb').write(out)
    print('%s: stage 2 %d bytes; %s, %d bytes at %04X (%d sectors), entry %04X; %d bytes'
          % (a.output, len(stage2), a.program, length, load, n, entry, len(out)))


def patch(a):
    rom = bytearray(open(a.rom, 'rb').read())
    boot = open(a.boot, 'rb').read()
    at, end = a.at, a.at + len(boot)
    if end > len(rom):
        fail('%d bytes at %04X run past the end of the %dK ROM' % (len(boot), at, len(rom) // 1024))
    room = rom[at:end]
    if room != bytes(len(boot)) and room != b'\xff' * len(boot):
        used = next(at + i for i, b in enumerate(room) if b != room[0])
        fail('%04X..%04X is not free in %s (%04X is used)' % (at, end - 1, a.rom, used))
    rom[at:end] = boot
    open(a.output, 'wb').write(rom)
    print('%s: FNBOOT, %d bytes, at %04X..%04X; start it with G%s'
          % (a.output, len(boot), at, end - 1, split_octal(at)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('image', help='the boot image for the FujiNet\'s flash')
    p.add_argument('stage2')
    p.add_argument('program')
    p.add_argument('-o', '--output', required=True)
    p = sub.add_parser('patch', help='FNBOOT into a monitor ROM image')
    p.add_argument('rom')
    p.add_argument('boot')
    p.add_argument('--at', required=True, type=lambda s: int(s, 0))
    p.add_argument('-o', '--output', required=True)
    a = ap.parse_args()
    {'image': image, 'patch': patch}[a.cmd](a)


if __name__ == '__main__':
    main()
