# FujiNet for the Heathkit H89

Software that runs on the H89 to use the H89-ESP32 FujiNet card (an 82C55
at 0D0H): FNDISK for CP/M and FN.DVD for HDOS make the FujiNet's drive slots
disks, FNDISK and LP.DVD print on the FujiNet's printer, and FNBOOT starts
CONFIG from the monitor, with no disk. CONFIG, which
picks the images for the FujiNet's drive slots, is in
[fujinet-config](https://github.com/FujiNetWIFI/fujinet-config) (`make h89`).

## FNDISK: FujiNet drives for CP/M

`FNDISK.COM` makes the FujiNet's eight drive slots CP/M drives, D: to K:
on an H17 system, and its printer the list device UL1:, under Heath/Zenith
CP/M 2.2.04:

```
A>B:FNDISK
FNDISK: FujiNet drives for H89 CP/M
Installed.
  D: slot 1  GAMES.H8D (read/write)
  E: slot 2  -
  ...
LST: is UL1:, the FujiNet's printer (STAT LST:=LPT: for the BIOS's).
A>DIR D:
A>PIP LST:=D:README.TXT
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
- **Printing:** installing sets LST: to UL1:, the FujiNet's printer
  ([where it goes](#where-printing-goes)), so `PIP LST:=`, ^P and
  programs' printing go there. `STAT LST:=LPT:` gives LST: back to the
  BIOS's printer, and `STAT LST:=UL1:` brings it back. Characters go as they
  are, a line at a time, and what's left of a line when the program ends.
- **If the printer doesn't answer** (it's turned off in the FujiNet's web
  UI), the first line waits 15 s, and the rest of that program's printing
  is dropped.

### How it works

FNDISK copies its resident part to F720H and points the BIOS jump table's
disk entries (HOME to WRITE), and LIST, LISTST and WBOOT, at it. Calls for
the BIOS's drives go straight on; calls for a FujiNet drive are served over
FujiBus: the FujiNet serves an image as 512-byte sectors, and a CP/M record
is a quarter of one. Reads keep the last sector; writes go through at once.
A warm boot reloads only the CCP and BDOS, so the jump table stays as FNDISK
left it.

LIST and LISTST go to the BIOS unless the IOBYTE has LST: on UL1:. LIST
keeps characters in a 64-byte buffer and sends them to the FujiNet's
printer (FujiBus device 40H, `W`) at LF or FF, when the buffer fills, and at
WBOOT, where every program ends. LISTST always says ready.

## FN.DVD: FujiNet drives for HDOS 2.0

`FN.DVD` is an HDOS 2.0 device driver: the FujiNet's drive slots 1 to 8 are
units FN0: to FN7:.

```
>MOUNT FN0:
VOLUME 000, MOUNTED ON FN0:
LABEL: FUJINET TEST DISK
>CAT FN0:
>COPY FN0:PIP.ABS=SY0:PIP.ABS
```

- **Install it** by copying `FN.DVD` (it's on `build/fn-hdos.h8d`) onto the
  system disk in SY0:, then rebooting: HDOS takes in the drivers on SY0: as
  it starts. The stock HDOS 2.0 disk is full; DK.DVD (the H47 driver) can
  make way.
- **Images** are H17 disks (`.h8d`) formatted by HDOS. A slot is a unit only
  while the FujiNet has an `.h8d` mounted in it: MOUNT says *Unit Not
  Available* for an empty slot and *Unable to Read this Disk* for anything
  else. An image mounted read only is write locked.
- HDOS loads the driver on first use and keeps it until the next boot: it
  takes about 4.3K (the driver, and a 256-byte GRT for each unit).
  `LOAD FN:` loads it at once.
- **DISMOUNT before changing the slots with CONFIG**, and MOUNT again after.
  RESET doesn't suit FN: (it waits for the drive to go not-ready, which a
  FujiNet slot never does).

### How it works

The driver is a PIC file assembled at origin 0 with its own header;
`tools/mkpic.py` builds the relocation table HDOS needs from two more
assemblies at other origins, and proves it by applying it. HDOS sector *n*
is half *n* AND 1 of FujiNet sector *n*/2, so an HDOS group (two sectors from
an even one) is one FujiNet sector and is written without reading it first.
A byte count of 0 is HDOS asking whether the disk is write-protected, and
writes nothing.

## LP.DVD: the FujiNet's printer for HDOS 2.0

`LP.DVD` is an HDOS 2.0 device driver: LP: prints on the FujiNet's printer
([where it goes](#where-printing-goes)).

```
>COPY LP:=FN0:README.TXT
```

- **Install it** as FN.DVD: copy `LP.DVD` (also on `build/fn-hdos.h8d`) onto
  SY0:, then reboot. The stock HDOS 2.0 disk has no LP.DVD, so it clashes
  with nothing; rename it (FP.DVD gives FP:) to keep a Heath LP: driver.
  Making room for both drivers takes DK.DVD and TEST47.ABS off the stock
  disk.
- It prints as Heath's LP: drivers do: lines end in CR LF (HDOS's end in
  NL alone), tabs become spaces to the next column of 8, and the NULs that
  pad a file's last sector are dropped. Lines go a whole one at a time, and
  what's left at CLOSE.
- **If the printer doesn't answer** (it's turned off in the FujiNet's web
  UI), the first line waits 15 s (CTL-C cuts it short), then the job fails
  with *Write Failure*; the next OPEN tries again.
- HDOS loads it on first use; it takes 1.4K, with no GRT. `LOAD LP:` loads
  it at once. It has no SET options.

FNDISK, FN.DVD and LP.DVD share their FujiBus code (`common/`).

## Where printing goes

The FujiNet keeps what it's sent in one file, until the Print button in its
web UI (or `/print`) downloads it; the next line printed starts a new one.

- "Use as virtual printer" has to be on. The emulator's FujiNet has it off.
- The printer type decides the file. *file printer (RAW)* keeps every byte,
  and so does *file printer (TRIM)*, the default, unless a line holds 9BH
  (the Atari's end of line). *Epson 80* makes a PDF, in which FF starts a
  page. *file printer (ASCII)* drops CR and LF, so doesn't suit the H89.

## FNBOOT: CONFIG from the FujiNet's flash

FNBOOT is about 100 bytes, started with the monitor's Go. It restarts the
ESP32, which puts the boot image it keeps in flash (`/autorun.img`) in its
first drive slot, and boots CONFIG from that:

```
  H: Go 017200
FujiNet boot .........................................................
```

- **Where it lives** is `BOOT_ORG` (`make BOOT_ORG=...`):
  - `0x0F80` (the default): the unused bytes at the end of MTR-90 (444-142
    and 444-84). `make monitor-rom MTR=2732_444-142_mtr90.u518` puts it in a
    copy of the ROM, `build/monitor-fnboot.rom`, to burn into a 2732.
    `G017200`.
  - `0x1000`: an EPROM of its own, if the board decodes it there. `G020000`.
  - RAM clear of 2040H-BB68H, such as `0xC000`. `G300000`.

  The monitor takes split octal; `R` then `H` switches it to hex.
- **The boot image** is `make autorun CONFIG_ABS=.../h89-hdos/config.abs`:
  `build/autorun.img`. The FujiNet's firmware has to ship it as
  `/autorun.img` for the H89. Today the H89 builds as the RS232 platform and
  ships the MS-DOS one, and fn-h89 doesn't mount one on the H89 at all
  (`#ifndef PINMAP_H89` in `rs232Fuji.cpp`).
- **CONFIG returns to the monitor**, after mounting the drives (ESC) or not
  (Q). Go again restarts the ESP32, so CONFIG comes back whatever was mounted.
- **When it fails:**
  - An empty slot: a bell and the monitor's prompt. Go then RETURN tries
    again.
  - A bad sector: stage 2 says so (`bad boot sector`, `read error`), then
    the same.
  - No card, or no answer: it waits, with no timeout; SHIFT+RESET.
- Needs 48K, and an MTR-88, MTR-89 or MTR-90 monitor: it uses the monitor's
  delay routine (002BH), RST 38H vector (2031H) and 2 ms tick (201BH).

### How it works

FNBOOT does as little as it can: it sends one fixed request (READ sector 0
of device 31H), SLIP-decodes the reply to 227AH so that the sector lands at
2280H, and jumps there if it got all 512 bytes. It doesn't check the
checksum or time out.

Sector 0 is stage 2 (`boot/stage2.asm`), and `tools/fnboot.py` puts
`CONFIG.ABS` after it. Stage 2:

1. Checks its own reply.
2. Sets the card's setup mark, so CONFIG leaves the card alone.
3. Loads CONFIG to 2A80H, last sector first. Each reply's header lands
   below its sector, in space that's loaded next.
4. Runs CONFIG in HDOS's place.

CONFIG makes only four HDOS calls (`.SCIN`, `.SCOUT`, `.CONSL`, `.EXIT`).
`boot/shim.asm` answers them from 2040H, through the monitor's RST 38H
vector, with the console's 8250 polled. The monitor's own 2 ms tick is at
201BH, where HDOS keeps its own.

Two things the monitor needs, which stage 2 sees to:

- **The HALT check.** Stage 2 sets bit 7 of the monitor's MFLAG (2008H).
  Otherwise every tick enters the monitor if the byte before the PC is
  76H, and an instruction that only ends in one (`LD A,'v'`) trips it.
- **A clean command line.** It zeroes 2100H-227FH, which z88dk's HDOS
  start-up reads as a command line.

## Building

Needs z88dk (`z88dk-z80asm`, `z88dk-appmake`) on PATH.

```
make                    # build/FNDISK.COM, build/fndisk-cpm.h8d,
                        # build/FN.DVD, build/LP.DVD, build/fn-hdos.h8d
make tools-disk CONFIG=../fujinet-config/r2r/h89-cpm/config.com
                        # build/fujinet-cpm.h8d: CONFIG.COM and FNDISK.COM
make hdos-tools-disk CONFIG_ABS=../fujinet-config/r2r/h89-hdos/config.abs
                        # build/fujinet-hdos.h8d: CONFIG.ABS, FN.DVD, LP.DVD
make autorun CONFIG_ABS=../fujinet-config/r2r/h89-hdos/config.abs
                        # build/autorun.img: FNBOOT's boot image
make monitor-rom MTR=.../2732_444-142_mtr90.u518
                        # build/monitor-fnboot.rom: MTR-90 with FNBOOT in it
make check              # the host tools' tests (no emulator)
```

`tools/hdosfs.py` reads and writes HDOS disk images: it converts Heath's
`.h17disk` images to `.h8d`, lists (and checks) them, and takes files off
and puts them on.

## Testing

On [fujinet-go-h89-desktop](../fujinet-go-h89-desktop)'s headless H89,
with FujiNet in-process:

```
tests/make-62k-boot.sh cpm62.h8d
tests/fndisk-e2e.sh --boot cpm62.h8d --config CONFIG.COM
```

The second mounts an H17 image in slot 1 with CONFIG, loads FNDISK, reads
and writes D:, warm boots, and checks on the host that the file written is
in the image byte for byte. Then it prints two files on UL1: and one on
CRT:, and checks that the FujiNet's printer (turned on, as RAW, for the
test: its `SD/paper`) got the first two byte for byte, the end of the
second, which has no CR LF, included. `CONFIG.COM` must be built with
`-DH89_RIG_KEYS` (the rig types only printable keys; ` stands in for ESC):

```
make -C ../fujinet-config FUJINET_LIB=... \
  CFLAGS_EXTRA_H89-CPM="-DBUILD_H89 -DH89_RIG_KEYS" h89-cpm/r2r
```

Changing the flags alone rebuilds nothing: remove `build/config/h89-cpm`
(or `-hdos`) first.

For HDOS:

```
tests/make-hdos-boot.sh boot.h8d            # HDOS 2.0 with FN.DVD and LP.DVD on SY0:
tests/fn-hdos-e2e.sh --boot boot.h8d --config CONFIG.ABS
```

The second mounts an image with CONFIG, then LOADs, MOUNTs, CATs, TYPEs,
RUNs from and COPYs onto FN0:, COPYs a file to LP:, DISMOUNTs and MOUNTs
again, and checks on the host that the copy is in the image byte for byte,
that the printer got the file as LP: puts it, and that HDOS put both
drivers where they should; then it tries a read-only image, an empty slot,
an image that isn't an H17 disk, and printing with the printer off (which
has to fail, and leave FN0: working). `CONFIG.ABS` must be built with
`-DH89_RIG_KEYS` (`CFLAGS_EXTRA_H89-HDOS`).

For FNBOOT:

```
tests/fnboot-e2e.sh --config CONFIG.ABS
```

The emulator only takes stock ROMs, so this puts FNBOOT in RAM at 0C000H
with the debugger and types `G300000`. The FujiNet gets the boot image in
its flash: CONFIG has to come up, and ESC has to bring back the monitor.
Then, with no image, Go has to come straight back. Any HDOS `CONFIG.ABS`
does (the rig presses a real ESC here). The emulator's FujiNet keeps
running when EN drops, so only real hardware shows the restart bringing
the image back.

`tests/fujibus-disk-probe.py HOST PORT SD_DIR` checks the FujiNet's disk
device directly over BoIP, against an RS232 fujinet-pc: 512-byte sectors
from 0, the end of an image, and the fixes FNDISK needed in the firmware (a
request without a sector field, STATUS, writing past the end, reading after
an unmount).
