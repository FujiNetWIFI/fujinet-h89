#!/usr/bin/env python3
"""
FujiBus disk-device probe: talks to an RS232 fujinet-pc over BoIP, as the
H89's 82C55 card would, and checks what FNDISK relies on from the disk
device and the fixes it needed:

  - sectors are 512 bytes from 0; the last one reads, the one after doesn't
  - writing past the end is refused and doesn't grow the image
  - a request without its sector field is refused, and the FujiNet lives on
  - STATUS ('S') answers with status and doesn't write the disk
  - after an unmount, reads are refused (and the FujiNet lives on)

  fujibus-disk-probe.py HOST PORT SD_DIR [--skip-no-field]

--skip-no-field leaves out the request without a sector field, which takes
an unfixed firmware down before the later checks.

SD_DIR is the FujiNet's SD folder (host slot 1 must be SD); the probe makes
PROBE.IMG there.
"""

import os
import socket
import sys

END, ESC, ESC_END, ESC_ESC = 0xC0, 0xDB, 0xDC, 0xDD
ACK, NAK = 0x06, 0x15
FUJI, DISK0 = 0x70, 0x31
SECTORS = 200


def checksum(data):
    c = 0
    for b in data:
        c += b
        c = (c >> 8) + (c & 0xFF)
    return c & 0xFF


def slip(data):
    out = bytearray([END])
    for b in data:
        if b == END:
            out += bytes([ESC, ESC_END])
        elif b == ESC:
            out += bytes([ESC, ESC_ESC])
        else:
            out.append(b)
    out.append(END)
    return bytes(out)


class Bus:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)

    def call(self, dev, cmd, descr=0, params=b'', payload=b''):
        pkt = bytearray([dev, cmd, 0, 0, 0, descr]) + params + payload
        pkt[2:4] = len(pkt).to_bytes(2, 'little')
        pkt[4] = checksum(pkt)
        self.s.sendall(slip(pkt))
        return self.reply()

    def reply(self):
        buf = bytearray()
        started = False
        esc = False
        while True:
            b = self.s.recv(1)
            if not b:
                raise ConnectionError('the FujiNet closed the connection')
            b = b[0]
            if not started:
                started = b == END
                continue
            if b == END:
                if not buf:
                    continue
                break
            if esc:
                buf.append(END if b == ESC_END else ESC if b == ESC_ESC else b)
                esc = False
            elif b == ESC:
                esc = True
            else:
                buf.append(b)
        hdr = bytes(buf[:6])
        if int.from_bytes(hdr[2:4], 'little') != len(buf):
            raise ValueError('reply length %d, header says %d' % (len(buf), int.from_bytes(hdr[2:4], 'little')))
        chk = bytearray(buf)
        chk[4] = 0
        if checksum(chk) != hdr[4]:
            raise ValueError('reply checksum')
        return hdr[1], bytes(buf[6:])


def u8(*v):
    return bytes(v)


def u16(v):
    return v.to_bytes(2, 'little')


failures = 0


def check(ok, what):
    global failures
    print(('PASS ' if ok else 'FAIL ') + what)
    if not ok:
        failures += 1


def alive(bus):
    try:
        r, _ = bus.call(FUJI, 0xE8)            # adapter config
        return r == ACK
    except (OSError, ConnectionError, ValueError):
        return False


def main():
    host, port, sd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    skip_no_field = '--skip-no-field' in sys.argv[4:]
    img = os.path.join(sd, 'PROBE.IMG')
    with open(img, 'wb') as f:
        for n in range(SECTORS):
            f.write(bytes([n & 0xFF]) * 512)
    size = os.path.getsize(img)

    bus = Bus(host, port)
    check(alive(bus), 'the FujiNet answers')

    r, _ = bus.call(FUJI, 0xF9, 1, u8(0))                                   # mount host slot 1
    check(r == ACK, 'host slot 1 (SD) mounts')
    name = b'/PROBE.IMG'.ljust(256, b'\0')
    r, _ = bus.call(FUJI, 0xE2, 3, u8(0, 0, 2), name)                        # slot 1 <- /PROBE.IMG, R/W
    check(r == ACK, 'slot 1 is set to /PROBE.IMG')
    r, _ = bus.call(FUJI, 0xF8, 2, u8(0, 2))                                 # mount it
    check(r == ACK, 'slot 1 mounts')

    r, d = bus.call(DISK0, ord('R'), 5, u16(5))
    check(r == ACK and d == bytes([5]) * 512, 'sector 5 reads 512 bytes of 05')
    r, d = bus.call(DISK0, ord('R'), 5, u16(SECTORS - 1))
    check(r == ACK and d == bytes([SECTORS - 1]) * 512, 'the last sector (%d) reads' % (SECTORS - 1))
    r, d = bus.call(DISK0, ord('R'), 5, u16(SECTORS))
    check(r == NAK and not d, 'sector %d, past the end, is refused' % SECTORS)

    r, _ = bus.call(DISK0, ord('W'), 5, u16(7), bytes([0xA5]) * 512)
    r2, d = bus.call(DISK0, ord('R'), 5, u16(7))
    check(r == ACK and r2 == ACK and d == bytes([0xA5]) * 512, 'sector 7 writes and reads back')

    r, _ = bus.call(DISK0, ord('W'), 5, u16(SECTORS), bytes([0x5A]) * 512)
    check(r == NAK, 'writing sector %d, past the end, is refused' % SECTORS)
    check(os.path.getsize(img) == size, 'the image is still %d bytes' % size)

    if not skip_no_field:
        try:
            r, _ = bus.call(DISK0, ord('R'))                                  # no sector field
            check(r == NAK, 'a read with no sector field is refused')
        except (OSError, ConnectionError, ValueError) as e:
            check(False, 'a read with no sector field is refused (%s)' % e)
        check(alive(bus), '...and the FujiNet lives on')

    try:
        r, d = bus.call(DISK0, ord('S'), 1, u8(0), bytes([0x77]) * 512)       # status, as a write would come
        check(r == ACK and len(d) == 4, 'STATUS answers with 4 status bytes')
        r2, d2 = bus.call(DISK0, ord('R'), 5, u16(0))
        check(r2 == ACK and d2 == bytes([0]) * 512, '...and leaves sector 0 alone')
    except (OSError, ConnectionError, ValueError) as e:
        check(False, 'STATUS answers (%s)' % e)

    try:
        r, _ = bus.call(FUJI, 0xE9, 1, u8(0))                                # unmount slot 1
        check(r == ACK, 'slot 1 unmounts')
        r, d = bus.call(DISK0, ord('R'), 5, u16(5))
        check(r == NAK and not d, 'a read after the unmount is refused')
    except (OSError, ConnectionError, ValueError) as e:
        check(False, 'a read after the unmount is refused (%s)' % e)
    check(alive(bus), '...and the FujiNet lives on')

    print('%d failed' % failures)
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
