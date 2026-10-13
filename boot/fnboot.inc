; Between FNBOOT and the boot sector it loads (stage 2)

BOOT_LOAD       equ     0x2280  ; sector 0 goes here, and FNBOOT jumps to it
BOOT_REPLY      equ     BOOT_LOAD - 6   ; with its reply's header left below
