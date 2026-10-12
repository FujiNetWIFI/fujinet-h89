#!/usr/bin/env python3
"""
hdosfs.py: HDOS disk images (.h8d) on the host.

  hdosfs.py convert IN.h17disk OUT.h8d    the draft H17Disk container -> .h8d
  hdosfs.py ls IMG [--check]              label, files, free groups
  hdosfs.py get IMG NAME [-o OUT]         a file's sectors
  hdosfs.py rm IMG NAME                   delete a file
  hdosfs.py put IMG FILE [--name N.E] [--flags HEX] [--date DD-MMM-YY]
  hdosfs.py blank OUT [--label TEXT]      an empty 100K data disk (via appmake)

An .h8d holds HDOS sector n at n * 256. Sector 9 is the label; the label
names the GRT sector (one byte a group: byte 0 heads the free chain, byte g
is the group after g) and the first directory block (two sectors: 22
entries of 23 bytes, then the entry length at 507, the block's own sector
at 508 and the next block's at 510). A directory entry FF is free; FE ends
the directory.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

SECTOR = 256
LABEL = 9
ENTRY = 23
ENTRIES = 22
END, FREE = 0xFE, 0xFF
MONTHS = 'JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC'.split()


def fail(msg):
    sys.exit('hdosfs: ' + msg)


def w16(b, o):
    return b[o] | b[o + 1] << 8


def p16(b, o, v):
    b[o] = v & 0xFF
    b[o + 1] = v >> 8 & 0xFF


# --- the draft H17Disk container (core/machine/H17Image.cpp loadH17DDraft) ---

def h17_checksum(data):
    d = 0
    for b in data:
        d ^= b
        d = ((d << 1) | (d >> 7)) & 0xFF
    return d


def decode_window(w):
    """The header and data of a captured sector: FD vol trk sec ck ... FD data ck"""
    i = 0
    while True:
        i = w.find(b'\xfd', i)
        if i < 0 or i + 5 > len(w):
            return None
        hdr = w[i + 1:i + 4]
        if h17_checksum(hdr) == w[i + 4]:
            break
        i += 1
    j = i + 5
    while True:
        j = w.find(b'\xfd', j)
        if j < 0 or j + 258 > len(w):
            return None
        data = w[j + 1:j + 257]
        if h17_checksum(data) == w[j + 257]:
            return hdr, data
        j += 1


def convert(src, dst):
    f = open(src, 'rb').read()
    if f[:4] != b'H17D':
        fail('%s is not an H17Disk image' % src)
    p, sides, tracks, data = 7, 1, 40, None
    while p + 6 <= len(f):
        bid, flg, ln = f[p], f[p + 1], int.from_bytes(f[p + 2:p + 6], 'big')
        body = f[p + 6:p + 6 + ln]
        if bid == 0x00 and ln >= 1:
            sides = body[0]
            tracks = body[1] if ln >= 2 else 40
        elif bid == 0x10:
            data = body
        elif flg & 0x80 and bid not in (0x01, 0x20):
            fail('a block this tool does not know (%02X)' % bid)
        p += 6 + ln
    if data is None or sides != 1 or tracks != 40:
        fail('only one-sided 40-track draft images are handled (%d sides, %d tracks)' % (sides, tracks))

    out = [None] * 400
    moved = 0
    q = 0
    while q + 5 <= len(data):
        if data[q] != 0x11:
            fail('damaged data block')
        trk = data[q + 2]
        tend = min(q + 5 + int.from_bytes(data[q + 3:q + 5], 'big'), len(data))
        q += 5
        while q + 5 <= tend and data[q] == 0x12:
            sec = data[q + 1]
            hl, sl = 5, int.from_bytes(data[q + 3:q + 5], 'big')
            if q + 5 + sl > tend or (q + 5 + sl < tend and data[q + 5 + sl] != 0x12):
                hl, sl = 8, int.from_bytes(data[q + 6:q + 8], 'big')
            dec = decode_window(data[q + hl:q + hl + sl])
            if dec is None:
                fail('track %d sector %d does not decode' % (trk, sec))
            hdr, sdata = dec
            if (hdr[1], hdr[2]) != (trk, sec):
                moved += 1
            n = hdr[1] * 10 + hdr[2]
            if n >= 400:
                fail('a sector header names track %d sector %d' % (hdr[1], hdr[2]))
            if out[n] is not None and out[n] != sdata:
                fail('two different copies of sector %d' % n)
            out[n] = sdata
            q += hl + sl
        q = tend
    missing = [n for n, s in enumerate(out) if s is None]
    if missing:
        fail('sectors missing: %s' % missing[:10])
    open(dst, 'wb').write(b''.join(out))
    print('%s: 400 sectors (%d placed by their header, not their position)' % (dst, moved))


# --- the file system ---

class Disk:
    def __init__(self, path):
        self.path = path
        self.d = bytearray(open(path, 'rb').read())
        if len(self.d) % SECTOR:
            fail('%s is not whole sectors' % path)
        lab = self.sector(LABEL)
        self.ser = lab[0]
        self.dis = w16(lab, 3)
        self.grt_sec = w16(lab, 5)
        self.spg = lab[7]
        self.ver = lab[9]
        self.siz = w16(lab, 12) or len(self.d) // SECTOR
        self.text = bytes(lab[17:77]).rstrip(b'\0 ').decode('latin-1')
        if not self.spg or self.grt_sec >= self.siz or self.dis >= self.siz:
            fail('%s has no HDOS label' % path)
        self.grt = bytearray(self.sector(self.grt_sec))

    def sector(self, n):
        return self.d[n * SECTOR:(n + 1) * SECTOR]

    def put_sector(self, n, data):
        data = bytes(data).ljust(SECTOR, b'\0')
        self.d[n * SECTOR:(n + 1) * SECTOR] = data

    def save(self):
        self.put_sector(self.grt_sec, self.grt)
        open(self.path, 'wb').write(self.d)

    def blocks(self):
        """The directory's blocks: (first sector, 512 bytes)"""
        seen = set()
        b = self.dis
        while b:
            if b in seen:
                fail('the directory loops at sector %d' % b)
            seen.add(b)
            blk = self.sector(b) + self.sector(b + 1)
            if blk[507] != ENTRY or w16(blk, 508) != b:
                fail('directory block at sector %d is malformed' % b)
            yield b, blk
            b = w16(blk, 510)

    def entries(self):
        """Every directory slot up to the end marker: (block, index, entry)"""
        for b, blk in self.blocks():
            for i in range(ENTRIES):
                e = blk[i * ENTRY:(i + 1) * ENTRY]
                yield b, i, e
                if e[0] == END:
                    return

    def files(self):
        return [(b, i, e) for b, i, e in self.entries() if e[0] not in (END, FREE)]

    def put_entry(self, b, i, e):
        blk = self.sector(b) + self.sector(b + 1)
        blk[i * ENTRY:(i + 1) * ENTRY] = e
        self.put_sector(b, blk[:SECTOR])
        self.put_sector(b + 1, blk[SECTOR:])

    def chain(self, first, last=None):
        groups, g, seen = [], first, set()
        while True:
            if g in seen or g == 0:
                fail('a group chain loops or ends early at group %d' % g)
            seen.add(g)
            groups.append(g)
            if g == last or (last is None and self.grt[g] == 0):
                return groups
            g = self.grt[g]

    def free(self):
        groups, g, seen = [], self.grt[0], set()
        while g:
            if g in seen:
                fail('the free chain loops at group %d' % g)
            seen.add(g)
            groups.append(g)
            g = self.grt[g]
        return groups

    def find(self, name):
        n, _, x = name.upper().partition('.')
        for b, i, e in self.files():
            if (name_of(e) == (n, x)):
                return b, i, e
        return None

    def file_data(self, e):
        groups = self.chain(e[16], e[17])
        secs = []
        for k, g in enumerate(groups):
            count = e[18] if k == len(groups) - 1 else self.spg
            secs += [g * self.spg + s for s in range(count)]
        return b''.join(self.sector(s) for s in secs), len(secs)


def name_of(e):
    nam = bytes(e[0:8]).rstrip(b'\0 ').decode('latin-1')
    ext = bytes(e[8:11]).rstrip(b'\0 ').decode('latin-1')
    return nam, ext


def date_text(v):
    if not v:
        return '         '
    d, m, y = v & 31, v >> 5 & 15, (v >> 9) + 1970
    return '%02d-%s-%02d' % (d, MONTHS[m - 1] if 1 <= m <= 12 else '???', y % 100)


def date_value(text):
    d, m, y = text.upper().split('-')
    y = int(y)
    y += 1900 if y >= 70 else 2000
    return int(d) | (MONTHS.index(m) + 1) << 5 | (y - 1970) << 9


def cmd_ls(a):
    disk = Disk(a.image)
    print('Label: %s  (serial %d, version %02X, %d sectors, %d a group)'
          % (disk.text or '-', disk.ser, disk.ver, disk.siz, disk.spg))
    problems = []
    used = {}
    for b, i, e in disk.files():
        nam, ext = name_of(e)
        try:
            groups = disk.chain(e[16], e[17])
        except SystemExit as x:
            problems.append('%s.%s: %s' % (nam, ext, x))
            continue
        lsi = e[18]
        nsec = (len(groups) - 1) * disk.spg + lsi
        print('  %-8s.%-3s %4d sectors  flags %02X  clu %d  groups %3d-%-3d lsi %d  %s'
              % (nam, ext, nsec, e[14], e[13], e[16], e[17], lsi, date_text(w16(e, 19))))
        if not 1 <= lsi <= disk.spg:
            problems.append('%s.%s: last-sector count %d' % (nam, ext, lsi))
        for g in groups:
            if g in used:
                problems.append('group %d is in %s and %s.%s' % (g, used[g], nam, ext))
            used[g] = '%s.%s' % (nam, ext)
    free = disk.free()
    for g in free:
        if g in used:
            problems.append('group %d is free and in %s' % (g, used[g]))
    print('%d groups free (%d sectors)' % (len(free), len(free) * disk.spg))
    if a.check:
        for p in problems:
            print('PROBLEM: ' + p)
        if problems:
            sys.exit(1)


def cmd_get(a):
    disk = Disk(a.image)
    hit = disk.find(a.name)
    if not hit:
        fail('%s: no %s' % (a.image, a.name))
    data, _ = disk.file_data(hit[2])
    open(a.output or a.name.upper(), 'wb').write(data)


def cmd_rm(a):
    disk = Disk(a.image)
    hit = disk.find(a.name)
    if not hit:
        fail('%s: no %s' % (a.image, a.name))
    b, i, e = hit
    groups = disk.chain(e[16], e[17])
    disk.grt[groups[-1]] = disk.grt[0]
    disk.grt[0] = groups[0]
    e = bytearray(e)
    e[0] = FREE
    disk.put_entry(b, i, e)
    disk.save()


def cmd_put(a):
    disk = Disk(a.image)
    data = open(a.file, 'rb').read()
    name = (a.name or os.path.basename(a.file)).upper()
    nam, _, ext = name.partition('.')
    if not (1 <= len(nam) <= 8 and len(ext) <= 3 and (nam + ext).isalnum()):
        fail('%s is not an HDOS file name' % name)
    if disk.find(name):
        fail('%s already holds %s' % (a.image, name))
    nsec = max(1, -(-len(data) // SECTOR))
    ng = -(-nsec // disk.spg)
    free = disk.free()
    if len(free) < ng:
        fail('%s has %d groups free, %s needs %d' % (a.image, len(free), name, ng))
    slot = None
    for b, i, e in disk.entries():
        if e[0] in (END, FREE):
            slot = (b, i, e[0])
            break
    if slot is None:
        fail('%s has no free directory entry' % a.image)

    groups = free[:ng]
    disk.grt[0] = disk.grt[groups[-1]]
    disk.grt[groups[-1]] = 0
    padded = data.ljust(nsec * SECTOR, b'\0')
    k = 0
    for g in groups:
        for s in range(disk.spg):
            if k < nsec:
                disk.put_sector(g * disk.spg + s, padded[k * SECTOR:(k + 1) * SECTOR])
                k += 1

    date = date_value(a.date)
    e = bytearray(ENTRY)
    e[0:8] = nam.encode().ljust(8, b'\0')
    e[8:11] = ext.encode().ljust(3, b'\0')
    e[13] = 3                                   # cluster factor, as HDOS writes it
    e[14] = int(a.flags, 16)
    e[16], e[17] = groups[0], groups[-1]
    e[18] = (nsec - 1) % disk.spg + 1           # sectors used in the last group, from 1
    p16(e, 19, date)
    p16(e, 21, date)
    b, i, was = slot
    disk.put_entry(b, i, e)
    if was == END:
        # the end marker moves along one
        nxt = None
        for b2, i2, e2 in disk.entries():
            if (b2, i2) == (b, i):
                nxt = True
                continue
            if nxt:
                if e2[0] != END:
                    e2 = bytearray(e2)
                    e2[0] = END
                    disk.put_entry(b2, i2, e2)
                break
    disk.save()


def cmd_blank(a):
    appmake = os.environ.get('APPMAKE', 'z88dk-appmake')
    tmp = tempfile.mkdtemp()
    try:
        open(os.path.join(tmp, 'blank.bin'), 'wb').write(b'\0')
        subprocess.run([appmake, '+hdos', '--dumb', '-b', 'blank.bin', '-o', 'BLANK'],
                       cwd=tmp, check=True, stdout=subprocess.DEVNULL)
        shutil.copy(os.path.join(tmp, 'blank.h8d'), a.output)
    finally:
        shutil.rmtree(tmp)
    cmd_rm(argparse.Namespace(image=a.output, name='BLANK'))
    disk = Disk(a.output)
    lab = bytearray(disk.sector(LABEL))
    lab[17:77] = a.label.encode('latin-1')[:60].ljust(60, b' ')
    disk.put_sector(LABEL, lab)
    disk.save()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('convert'); s.add_argument('src'); s.add_argument('dst')
    s = sub.add_parser('ls'); s.add_argument('image'); s.add_argument('--check', action='store_true')
    s = sub.add_parser('get'); s.add_argument('image'); s.add_argument('name'); s.add_argument('-o', '--output')
    s = sub.add_parser('rm'); s.add_argument('image'); s.add_argument('name')
    s = sub.add_parser('put'); s.add_argument('image'); s.add_argument('file')
    s.add_argument('--name'); s.add_argument('--flags', default='0'); s.add_argument('--date', default='11-OCT-80')
    s = sub.add_parser('blank'); s.add_argument('output'); s.add_argument('--label', default='FujiNet')
    a = ap.parse_args()
    if a.cmd == 'convert':
        convert(a.src, a.dst)
    else:
        globals()['cmd_' + a.cmd](a)


if __name__ == '__main__':
    main()
