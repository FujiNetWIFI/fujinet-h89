;-----------------------------------------------------------------------------
; FNBOOT: FNCONFIG from the FujiNet's flash, started with the monitor's Go
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Restarts the ESP32, which puts the image it keeps in flash in its first
; drive slot (device 31H), reads sector 0 of that to BOOT_LOAD and jumps
; there. Everything else is up to that sector (boot/stage2.asm).
;
; Kept as small as it can be, to fit the monitor's spare bytes:
; - No timeouts. With no card, or no answer, it waits for SHIFT+RESET.
; - No checksum. The sector checks its own: the reply's header is left just
;   below it.
; - The monitor's stack (the top of memory).
; A reply too short to be the sector (a NAK: the slot is empty) HALTs back
; to the monitor with a bell; Go and RETURN try again.
;
; Assembled at any address (-r=) but 76xxH (see MFLAG in mtr.inc): the
; monitor's spare bytes, an EPROM, or RAM clear of 2040H-BB68H.
;-----------------------------------------------------------------------------

        include "h89.inc"
        include "mtr.inc"
        include "fnboot.inc"

boot:
        ld      a,0xC0          ; port A mode 2: port C's outputs go low, EN
        out     (PCTRL),a       ; with them, and the ESP32 stops
        ld      a,50
        call    MTR_DLY         ; for 100 ms
        ld      a,0x06          ; EN and IO0 high at once: it starts its
        out     (PORTC),a       ; firmware
        ld      a,100
        call    MTR_DLY         ; 200 ms while it reads its straps
        ld      a,0x05          ; then /OE low (IO0 is done with), and DIR
        out     (PORTC),a       ; toward the ESP32

        ld      hl,request
        ld      b,REQUEST_SIZE
send:
        ld      a,(hl)
        out     (PORTA),a
send_wait:
        in      a,(PORTC)       ; /OBF: taken yet? The first byte waits out
        rla                     ; the ESP32's start
        jr      nc,send_wait
        inc     hl
        djnz    send
        xor     a               ; DIR_TO_H89
        out     (PCTRL),a

sync:
        call    getc            ; to the reply's first END
        jr      nz,sync
        ld      hl,BOOT_REPLY
recv:
        call    getc
        jr      z,recv_end
        cp      SLIP_ESC
        jr      nz,recv_put
        call    getc            ; ESC_END is END, ESC_ESC is ESC
        cp      SLIP_ESC_ESC
        sbc     a,a
        and     SLIP_END ^ SLIP_ESC
        xor     SLIP_ESC
recv_put:
        ld      (hl),a
        inc     hl
        jr      recv

recv_end:
        ld      a,h             ; the header and 512 bytes? (a NAK is only
        cp      (BOOT_LOAD + SECTOR) >> 8       ; the header)
        jp      z,BOOT_LOAD
        halt                    ; no: a bell and the monitor's prompt
        jr      boot

; The next byte from the ESP32 into A. Z if it's an END.
getc:
        in      a,(PORTC)
        and     PC_IBF
        jr      z,getc
        in      a,(PORTA)
        cp      SLIP_END
        ret

; READ sector 0 of the first slot, with the sector as a byte field. Nothing
; in it needs escaping.
REQ_CKSUM       equ     DEV_DISK + CMD_READ + 7 + FIELDS_U8
request:
        defb    SLIP_END, DEV_DISK, CMD_READ, 7, 0, REQ_CKSUM, FIELDS_U8, 0, SLIP_END
REQUEST_SIZE    equ     $ - request
        assert  REQ_CKSUM < 0x100 && REQ_CKSUM != SLIP_END && REQ_CKSUM != SLIP_ESC
        assert  BOOT_REPLY >> 8 != (BOOT_LOAD + SECTOR) >> 8
