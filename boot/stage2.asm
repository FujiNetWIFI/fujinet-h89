;-----------------------------------------------------------------------------
; FNBOOT stage 2: sector 0 of the FujiNet's boot image, which FNBOOT reads
; to 2280H and jumps to
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Loads the program in the sectors after it (an HDOS .ABS: CONFIG) and runs
; it in HDOS's place: the system calls it makes go to the shim, which lives
; at SHIM_ORG under it, and its console bytes and tick counter are where HDOS
; keeps them (the tick is the monitor's own).
;
; Comes in from FNBOOT with the card running and facing the H89, interrupts
; on, the monitor's stack (kept to the end), and FNBOOT's reply just below:
; its 6-byte header at 227AH.
;
; tools/fnboot.py fills in the parameter block and puts the program after.
;-----------------------------------------------------------------------------

        include "h89.inc"
        include "mtr.inc"
        include "fnboot.inc"
        include "shim.def"

SHIM_ORG        equ     0x2040
SHIM_TOP        equ     0x20D6  ; S.CSLMD..S.CONFL: CONFIG reads them
CMDLINE         equ     0x2100  ; ..227FH: HDOS's command line, see below
CMDLINE_SIZE    equ     0x2280 - CMDLINE
RETRIES         equ     3

stage2:
        jr      start
nsect:  defb    0               ; the program's sectors, after this one
load:   defw    0               ; where the first of them goes
entry:  defw    0               ; where it starts

start:
        ld      hl,MFLAG        ; no HALT traps from here (see mtr.inc)
        set     7,(hl)
        ld      hl,msg_boot
        call    print
        ld      ix,BOOT_REPLY   ; did this sector come whole?
        call    check
        jp      nz,bad_sector

        ld      a,SETUP_MARK    ; the card is set up: CONFIG's port_init
        out     (PORTB),a       ; leaves it be

        ; Sector k goes to load + 512 * (k - 1), last first: each reply's
        ; header lands 6 bytes below its sector, in the space of the one
        ; read next (the first's below the program).
        ld      a,(nsect)
        ld      (sector),a
next_sector:
        ld      a,(sector)
        or      a
        jr      z,loaded
        dec     a
        add     a,a
        ld      d,a
        ld      e,0
        ld      hl,(load)
        add     hl,de
        ld      de,-6
        add     hl,de
        ld      (reply_at),hl
        ld      a,RETRIES
        ld      (tries),a
read_sector:
        call    send_request
        ld      hl,(reply_at)
        push    hl
        call    recv
        pop     de
        or      a
        sbc     hl,de           ; the header and 512 bytes, exactly?
        ld      de,6 + SECTOR
        sbc     hl,de
        jr      nz,read_bad
        ld      ix,(reply_at)
        call    check
        jr      z,read_ok
read_bad:
        ld      hl,tries
        dec     (hl)
        jr      nz,read_sector
        ld      hl,msg_read
        call    fail            ; Go and RETURN: three more tries
        jr      next_sector
read_ok:
        ld      a,'.'
        call    con_out
        ld      hl,sector
        dec     (hl)
        jr      next_sector

        ; HDOS's start-up code in z88dk takes 2182H..227EH for a command
        ; line: leftover bytes would be arguments (a '<' or '>' one opens a
        ; file), and it writes a 0 over every space
loaded:
        ld      hl,CMDLINE
        ld      de,CMDLINE + 1
        ld      bc,CMDLINE_SIZE - 1
        ld      (hl),0
        ldir
        ld      hl,shim
        ld      de,SHIM_ORG
        ld      bc,SHIM_SIZE
        ldir
        ld      a,0xC3          ; JP scall
        ld      (UIVEC_RST7),a
        ld      hl,scall
        ld      (UIVEC_RST7 + 1),hl
        ld      hl,(entry)
        jp      (hl)

bad_sector:
        ld      hl,msg_bad      ; this sector won't do: Go and RETURN can
        call    fail            ; only say so again
        jr      bad_sector

; Say what went wrong (HL), then a bell and the monitor's prompt. Go and
; RETURN come back here.
fail:
        call    print
        ld      hl,MFLAG
        res     7,(hl)
        halt
        ld      hl,MFLAG
        set     7,(hl)
        ld      hl,msg_boot
        jp      print

;-----------------------------------------------------------------------------
; FujiBus, as FNBOOT has it, with the sector asked for and the reply checked
;-----------------------------------------------------------------------------

; READ (sector) of the first slot, its sector a byte field
send_request:
        ld      a,(sector)
        ld      (req_sector),a
        add     a,DEV_DISK + CMD_READ + 7 + FIELDS_U8
        adc     a,0
        ld      (req_cksum),a
        ld      a,DIR_TO_ESP
        out     (PCTRL),a
        ld      a,SLIP_END
        call    putc
        ld      hl,req
        ld      b,REQ_SIZE
req_next:
        ld      a,(hl)
        cp      SLIP_END
        jr      z,req_esc
        cp      SLIP_ESC
        jr      nz,req_put
req_esc:
        ld      a,SLIP_ESC      ; END is ESC ESC_END, ESC is ESC ESC_ESC
        call    putc
        ld      a,(hl)
        cp      SLIP_END
        ld      a,SLIP_ESC_END
        jr      z,req_put
        ld      a,SLIP_ESC_ESC
req_put:
        call    putc
        inc     hl
        djnz    req_next
        ld      a,SLIP_END
        call    putc
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ret

; Send A, and wait for the ESP32 to take it
putc:
        out     (PORTA),a
putc_wait:
        in      a,(PORTC)
        rla
        jr      nc,putc_wait
        ret

; A reply into HL on, decoded; HL past it
recv:
        call    getc            ; to its first END
        jr      nz,recv
recv_next:
        call    getc
        ret     z
        cp      SLIP_ESC
        jr      nz,recv_put
        call    getc
        cp      SLIP_ESC_ESC
        sbc     a,a
        and     SLIP_END ^ SLIP_ESC
        xor     SLIP_ESC
recv_put:
        ld      (hl),a
        inc     hl
        jr      recv_next

; The next byte from the ESP32 into A. Z if it's an END.
getc:
        in      a,(PORTC)
        and     PC_IBF
        jr      z,getc
        in      a,(PORTA)
        cp      SLIP_END
        ret

; Is the reply at IX (a header, then 512 bytes) the disk's ACK of the right
; length, with a good checksum? Z if so.
check:
        ld      a,(ix+0)
        cp      DEV_DISK
        ret     nz
        ld      a,(ix+1)
        cp      REPLY_ACK
        ret     nz
        ld      a,(ix+2)
        cp      (6 + SECTOR) & 0xFF
        ret     nz
        ld      a,(ix+3)
        cp      (6 + SECTOR) >> 8
        ret     nz
        ld      e,(ix+4)        ; the checksum sent, which counts as 0
        ld      (ix+4),0
        push    ix
        pop     hl
        ld      bc,6 + SECTOR
        ld      d,0
        call    cksum
        ld      (ix+4),e
        ld      a,d
        cp      e
        ret

; D += BC bytes from HL, as an 8-bit sum with end-around carry
cksum:
        ld      a,b
        or      c
        ret     z
        ld      a,d
        add     a,(hl)
        adc     a,0
        ld      d,a
        inc     hl
        dec     bc
        jr      cksum

;-----------------------------------------------------------------------------
; The console
;-----------------------------------------------------------------------------

print:
        ld      a,(hl)
        or      a
        ret     z
        call    con_out
        inc     hl
        jr      print

con_out:
        push    af
con_wait:
        in      a,(CON_LSR)
        and     LSR_THRE
        jr      z,con_wait
        pop     af
        out     (CON_DATA),a
        ret

;-----------------------------------------------------------------------------

msg_boot:       defm    13, 10, "FujiNet boot ", 0
msg_bad:        defm    "bad boot sector", 0
msg_read:       defm    "read error", 0

req:            defb    DEV_DISK, CMD_READ, 7, 0
req_cksum:      defb    0
                defb    FIELDS_U8
req_sector:     defb    0
REQ_SIZE        equ     $ - req

sector:         defb    0
tries:          defb    0
reply_at:       defw    0

shim:
        binary  "shim.bin"
SHIM_SIZE       equ     $ - shim
        assert  SHIM_ORG + SHIM_SIZE <= SHIM_TOP, "the shim runs into HDOS's console bytes"
        assert  scall == SHIM_ORG

        assert  start - stage2 == 7, "tools/fnboot.py fills in the block at 2..6"
