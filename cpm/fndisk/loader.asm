;-----------------------------------------------------------------------------
; FNDISK.COM: puts the FujiNet drive slots on CP/M drives (Heath CP/M 2.2.04)
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
;   FNDISK          slots 1-8 on the first free drives (D: to K: on an H17
;                   system)
;   FNDISK x        slot 1 on drive x:, the rest after it
;
; Copies the resident part above the BIOS and points the BIOS jump table's
; disk entries at it, then warm boots so CP/M starts with the new drives.
; The resident part needs the room a 62K system leaves (MOVCPM17 62 *, then
; SYSGEN): the BIOS of a 64K one runs to the top of memory.
;-----------------------------------------------------------------------------

        include "h89.inc"
        include "resident.def"

BDOS            equ     5
B_CONOUT        equ     2
B_PRINT         equ     9

BIOS_VERSION    equ     0x33    ; Heath's BIOS: version byte, 04
BIOS_RAM_END    equ     0x4B    ; ...first byte above its RAM
BIOS_HOME       equ     0x18    ; HOME..WRITE: 7 jump table entries
BIOS_SELDSK     equ     0x1B
BIOS_DPH0       equ     0x52    ; its first drive's DPH

MODE_WRITE      equ     0x02

        org     0x100

start:
        ld      sp,stack_top
        ld      de,msg_banner
        call    print

        ; Heath's BIOS: its base is (0001) - 3, its version byte 04
        ld      hl,(1)
        ld      de,-3
        add     hl,de
        ld      (bios),hl
        ld      de,BIOS_VERSION
        add     hl,de
        ld      a,(hl)
        cp      4
        jp      nz,not_heath

        ; Already in? Then the BIOS's SELDSK entry jumps to us.
        ld      hl,(bios)
        ld      de,BIOS_SELDSK + 1
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,do_seldsk
        or      a
        sbc     hl,de
        jp      z,already

        ; Room above the BIOS?
        ld      hl,(bios)
        ld      de,BIOS_RAM_END
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,res_start
        or      a
        sbc     hl,de
        jp      c,no_room

        call    card_on

        ld      hl,image
        ld      de,res_start
        ld      bc,image_end - image
        ldir

        ; The BIOS's own HOME..WRITE entries, for the driver to pass calls on
        ld      hl,(bios)
        ld      de,BIOS_HOME
        add     hl,de
        ld      de,bios_jumps
        ld      bc,NHOOKS * 3
        ldir

        ; All drives share the BIOS's directory buffer
        ld      hl,(bios)
        ld      de,BIOS_DPH0 + DPH_DIRBUF
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,dph_table + DPH_DIRBUF
        ld      b,NDRIVES
set_dirbuf:
        ld      (hl),e
        inc     hl
        ld      (hl),d
        push    de
        ld      de,DPH_SIZE - 1
        add     hl,de
        pop     de
        djnz    set_dirbuf

        call    choose_drive
        jp      c,no_letters
        ld      (first_drive),a

        ; Hand the disk entries over
        ld      hl,hooks
        ex      de,hl
        ld      hl,(bios)
        ld      bc,BIOS_HOME
        add     hl,bc
        ex      de,hl
        ld      bc,NHOOKS * 3
        ldir

        ld      de,msg_installed
        call    print
        call    list_drives
        jp      0

already:
        ld      de,msg_already
        call    print
        call    list_drives
        jp      0

not_heath:
        ld      de,msg_not_heath
        jr      fail
no_room:
        ld      de,msg_no_room
        jr      fail
no_letters:
        ld      de,msg_no_letters
fail:
        call    print
        jp      0

;-----------------------------------------------------------------------------
; The CP/M drive for slot 1 into A: the letter given, or the first one the
; BIOS doesn't have. Carry if there's no room for eight more.
;-----------------------------------------------------------------------------

choose_drive:
        call    probe
        ret     c
        ld      (free_drive),a
        ld      hl,0x80         ; the command tail
        ld      b,(hl)
        inc     hl
arg_skip:
        ld      a,b
        or      a
        ld      a,(free_drive)
        ret     z               ; none: the first free drive
        ld      a,(hl)
        cp      ' '
        jr      nz,arg_letter
        inc     hl
        dec     b
        jr      arg_skip
arg_letter:
        sub     'A'
        jr      c,arg_bad
        ld      b,a
        ld      a,(free_drive)  ; not one of the BIOS's own
        dec     a
        cp      b
        jr      nc,arg_bad
        ld      a,b
        cp      16 - NDRIVES + 1
        ccf
        ret
arg_bad:
        scf
        ret

        ; Ask the BIOS (as a drive already logged in, so it does nothing to
        ; the disk) for each drive until it has none. The warm boot after
        ; puts BDOS and the BIOS back in step.
probe:
        ld      c,0
probe_next:
        push    bc
        ld      e,1
        call    bios_seldsk
        pop     bc
        ld      a,h
        or      l
        ld      a,c
        jr      z,probe_found
        inc     c
        ld      a,c
        cp      16 - NDRIVES + 1
        jr      c,probe_next
        scf
        ret
probe_found:
        cp      16 - NDRIVES + 1
        ccf
        ret

;-----------------------------------------------------------------------------
; Start the card if nothing has yet (as FNON does), and face it toward us
;-----------------------------------------------------------------------------

card_on:
        in      a,(PORTC)
        and     PC_EN
        jr      nz,card_ready
        ld      a,0xC0          ; port A mode 2, PC0-PC2 outputs (EN goes low)
        out     (PCTRL),a
        ld      a,0x06          ; EN=1, IO0=1
        out     (PORTC),a
        ld      a,0x02          ; EN=0 with IO0 high
        out     (PORTC),a
        call    tick
        call    tick
        ld      a,0x06          ; EN=1: boots from flash
        out     (PORTC),a
        ld      b,100           ; about 200 ms
card_wait:
        call    tick
        djnz    card_wait
card_ready:
        in      a,(PORTA)       ; drop anything latched while it started
        ld      a,OE_ON
        out     (PCTRL),a
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ret

; Wait for the next 2 ms tick
tick:
        ld      a,(TICKS)
        ld      c,a
tick_wait:
        ld      a,(TICKS)
        cp      c
        jr      z,tick_wait
        ret

;-----------------------------------------------------------------------------
; Which image is in each drive now
;-----------------------------------------------------------------------------

list_drives:
        ld      a,DEV_FUJI
        ld      (req_dev),a
        ld      a,CMD_DEVICE_SLOTS
        ld      (req_cmd),a
        xor     a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      hl,0
        ld      (req_dlen),hl
        ld      hl,SLOTS_SIZE
        ld      (rep_dlen),hl
        call    fuji_call
        jr      z,list_slots
        ld      de,msg_no_fujinet
        jp      print
list_slots:
        ld      hl,buf
        ld      b,0
list_next:
        push    bc
        push    hl
        ld      a,(first_drive)
        add     a,b
        add     a,'A'
        ld      (msg_letter),a
        ld      a,b
        add     a,'1'
        ld      (msg_slotno),a
        ld      de,msg_drive
        call    print
        pop     hl
        push    hl
        inc     hl
        ld      a,(hl)          ; mode
        inc     hl              ; name
        and     MODE_MOUNTED
        jr      nz,list_name
        ld      de,msg_empty
        call    print
        jr      list_eol
list_name:
        ld      b,SLOT_SIZE - 2
list_char:
        ld      a,(hl)
        or      a
        jr      z,list_rw
        push    bc
        push    hl
        ld      e,a
        ld      c,B_CONOUT
        call    BDOS
        pop     hl
        pop     bc
        inc     hl
        djnz    list_char
list_rw:
        pop     hl
        push    hl
        inc     hl
        ld      a,(hl)
        and     MODE_WRITE
        ld      de,msg_ro
        jr      z,list_mode
        ld      de,msg_rw
list_mode:
        call    print
list_eol:
        ld      de,msg_eol
        call    print
        pop     hl
        ld      de,SLOT_SIZE
        add     hl,de
        pop     bc
        inc     b
        ld      a,b
        cp      NDRIVES
        jr      c,list_next
        ret

print:
        ld      c,B_PRINT
        jp      BDOS

;-----------------------------------------------------------------------------

msg_banner:     defm    "FNDISK: FujiNet drives for H89 CP/M", 13, 10, "$"
msg_installed:  defm    "Installed.", 13, 10, "$"
msg_already:    defm    "Already installed.", 13, 10, "$"
msg_not_heath:  defm    "Needs Heath/Zenith CP/M 2.2.04.", 13, 10, "$"
msg_no_room:    defm    "No room above the BIOS. Make a 62K system", 13, 10
                defm    "(MOVCPM17 62 *, then SYSGEN) and boot that.", 13, 10, "$"
msg_no_letters: defm    "No 8 free drive letters there.", 13, 10, "$"
msg_no_fujinet: defm    "The FujiNet isn't answering.", 13, 10, "$"
msg_drive:      defm    "  "
msg_letter:     defm    "x: slot "
msg_slotno:     defm    "n  $"
msg_empty:      defm    "-$"
msg_ro:         defm    " (read only)$"
msg_rw:         defm    " (read/write)$"
msg_eol:        defm    13, 10, "$"

bios:           defw    0
free_drive:     defb    0

                defs    64
stack_top:

image:
        binary  "resident.bin"
image_end:
