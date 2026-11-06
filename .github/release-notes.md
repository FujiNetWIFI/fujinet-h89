FujiNet for the Heathkit H89 and the H89-ESP32 FujiNet card. The
[README](https://github.com/FujiNetWIFI/fujinet-h89#readme) says how to use
each file.

This release is for the card without its 74LVC245 (needs
FujiNetWIFI/fujinet-firmware#2232). Cards that still have the 245 should stay
on v1.0.4.

`FNDISK.COM` no longer needs a 62K system: it installs at the top of the TPA,
below the CCP, on the system as it boots (64K, or a BIOS with CF, RTC or LPT
drivers), and lowers the BDOS address to itself. It takes about 2.5K of the
TPA.

H17 disks (`.h8d`):
- `fujinet-cpm.h8d`: FNCONFIG.COM, FNDISK.COM and NPIP.COM, for CP/M
- `fujinet-hdos.h8d`: FNCONFIG.ABS, FN.DVD, LP.DVD and NPIP.ABS, for HDOS 2.0
- `fndisk-cpm.h8d`: FNDISK.COM and NPIP.COM
- `fn-hdos.h8d`: FN.DVD, LP.DVD and NPIP.ABS

CP/M (Heath/Zenith 2.2.04):
- `FNCONFIG.COM`: picks the images for the FujiNet's drive slots
- `FNDISK.COM`: the drive slots as CP/M drives, and the printer as UL1:
- `NPIP.COM`: copies files to and from the network

HDOS 2.0:
- `FNCONFIG.ABS`: picks the images for the FujiNet's drive slots
- `FN.DVD`: the drive slots as FN0: to FN7:. Copy it onto SY0: and reboot.
- `LP.DVD`: the FujiNet's printer as LP:. Copy it onto SY0: and reboot.
- `NPIP.ABS`: copies files to and from the network

FNBOOT (starts FNCONFIG from the monitor, with no disk):
- `fnboot.bin`: assembled at 0F80H, for the spare bytes at the end of MTR-90.
  `tools/fnboot.py patch` puts it in your own copy of the ROM.
- `autorun.img`: the boot image (stage 2, then FNCONFIG.ABS), which the
  FujiNet keeps in its flash as `/autorun.img`
- `stage2.bin`: stage 2 on its own
