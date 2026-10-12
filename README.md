# FujiNet for the Heathkit H89

Software that runs on the H89 to use the H89-ESP32 FujiNet card (an 82C55
at 0D0H). CONFIG, which picks the images for the FujiNet's drive slots, is
in [fujinet-config](https://github.com/FujiNetWIFI/fujinet-config) (`make h89`).

## FNDISK: FujiNet drives for CP/M

`FNDISK.COM` makes the FujiNet's eight drive slots CP/M drives, D: to K:
on an H17 system, under Heath/Zenith CP/M 2.2.04:

```
A>B:FNDISK
FNDISK: FujiNet drives for H89 CP/M
Installed.
  D: slot 1  GAMES.H8D (read/write)
  E: slot 2  -
  ...
A>DIR D:
```

- **Images** are H17 disks: `.h8d` files of 40 tracks of ten 256-byte
  sectors, in the layout Heath's CP/M gives a hard-sectored disk (the same
  as z88dk's `appmake +cpmdisk -f hz89`). A slot is a drive only while the
  FujiNet has an image mounted in it and its name ends in `.h8d`; any other
  slot gives `Bdos Err On x: Select`.
- **It needs a 62K (or smaller) system.** The driver stays resident above
  the BIOS, and the BIOS of a 64K system runs to the top of memory. Make one
  once with `MOVCPM17 62 *` and then `SYSGEN` onto the boot disk.
- `FNDISK x` puts slot 1 on drive x: instead (not one of the BIOS's own).
  Running it again lists the drives.
- Mount images with CONFIG; it returns to CP/M with a warm boot, which
  logs the drives in afresh.

### How it works

FNDISK copies its resident part to F720H and points the BIOS jump table's
disk entries (HOME to WRITE) at it. Calls for the BIOS's drives go straight
on; calls for a FujiNet drive are served over FujiBus: the FujiNet serves an
image as 512-byte sectors, and a CP/M record is a quarter of one. Reads
keep the last sector; writes go through at once. A warm boot reloads only
the CCP and BDOS, so the jump table stays as FNDISK left it.

## Building

Needs z88dk (`z88dk-z80asm`, `z88dk-appmake`) on PATH.

```
make                    # build/FNDISK.COM, build/fndisk-cpm.h8d
make tools-disk CONFIG=../fujinet-config/r2r/h89-cpm/config.com
                        # build/fujinet-cpm.h8d: CONFIG.COM and FNDISK.COM
```

## Testing

On [fujinet-go-h89-desktop](../fujinet-go-h89-desktop)'s headless H89,
with FujiNet in-process:

```
tests/make-62k-boot.sh cpm62.h8d
tests/fndisk-e2e.sh --boot cpm62.h8d --config CONFIG.COM
```

The second mounts an H17 image in slot 1 with CONFIG, loads FNDISK, reads
and writes D:, warm boots, and checks on the host that the file written is
in the image byte for byte. `CONFIG.COM` must be built with
`-DH89_RIG_KEYS` (the rig types only printable keys; ` stands in for ESC):

```
make -C ../fujinet-config FUJINET_LIB=... \
  CFLAGS_EXTRA_H89-CPM="-DBUILD_H89 -DH89_RIG_KEYS" h89-cpm/r2r
```

`tests/fujibus-disk-probe.py HOST PORT SD_DIR` checks the FujiNet's disk
device directly over BoIP, against an RS232 fujinet-pc: 512-byte sectors
from 0, the end of an image, and the fixes FNDISK needed in the firmware (a
request without a sector field, STATUS, writing past the end, reading after
an unmount).
