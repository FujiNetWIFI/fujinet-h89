;-----------------------------------------------------------------------------
; FNDISK.COM: puts the FujiNet drive slots on CP/M drives (Heath CP/M 2.2.04),
; and its printer on UL1:
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
;   FNDISK          slots 1-8 on the first free drives (D: to K: on an H17
;                   system)
;   FNDISK x        slot 1 on drive x:, the rest after it
;
; Copies the resident part above the BIOS and points the BIOS jump table's
; disk entries at it, and its LIST, LISTST and WBOOT, then sets LST: to UL1:
; and warm boots so CP/M starts with the new drives.
; The resident part runs from res_start (F720H) to the top of memory, so the
; BIOS's RAM has to end below it. A stock 62K system's does (MOVCPM17 62 *,
; then SYSGEN); a BIOS with more in it (CF, RTC, LPT) needs a smaller
; system, and FNDISK says how many K smaller.
;-----------------------------------------------------------------------------

        include "h89.inc"

TICKS           equ     0x000B  ; the Heath BIOS's 2 ms tick counter
        include "resident.def"

BDOS            equ     5
B_CONOUT        equ     2
B_PRINT         equ     9

BIOS_WBOOT      equ     0x03    ; Heath's BIOS: its jump table entries...
BIOS_LIST       equ     0x0F
BIOS_VERSION    equ     0x33    ; ...version byte, 04
BIOS_RAM_END    equ     0x4B    ; ...first byte above its RAM
BIOS_HOME       equ     0x18    ; HOME..LISTST: 8 entries
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
        ; Somewhere else up there: another FNDISK, where this one would go
        ld      hl,res_start - 1
        or      a
        sbc     hl,de
        jp      c,another

        ; Room above the BIOS? An end that isn't above it wrapped: its RAM
        ; runs to the top of memory.
        ld      hl,(bios)
        ld      de,BIOS_RAM_END
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (ram_end),de
        ld      hl,(bios)
        or      a
        sbc     hl,de
        jr      c,ram_end_ok
        ld      hl,0
        ld      (ram_end),hl
        jp      no_room
ram_end_ok:
        ld      hl,res_start
        or      a
        sbc     hl,de
        jp      c,no_room

        call    card_on
        call    card_present
        jp      nz,no_card

        ld      hl,image
        ld      de,res_start
        ld      bc,image_end - image
        ldir

        ; The BIOS's own HOME..LISTST, LIST and WBOOT entries, for the driver
        ; to pass calls on
        ld      hl,(bios)
        ld      de,BIOS_HOME
        add     hl,de
        ld      de,bios_jumps
        ld      bc,NHOOKS * 3
        ldir
        ld      de,BIOS_LIST
        ld      hl,bios_list
        call    bios_entry
        ld      de,BIOS_WBOOT
        ld      hl,bios_wboot
        call    bios_entry

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

        ; Hand the entries over
        ld      hl,hooks
        ex      de,hl
        ld      hl,(bios)
        ld      bc,BIOS_HOME
        add     hl,bc
        ex      de,hl
        ld      bc,NHOOKS * 3
        ldir
        ld      de,BIOS_LIST
        ld      hl,list_hook
        call    hook_entry
        ld      de,BIOS_WBOOT
        ld      hl,wboot_hook
        call    hook_entry

        ld      a,(3)           ; LST: = UL1:, the FujiNet's printer
        or      0xC0
        ld      (3),a

        ld      de,msg_installed
        call    print
        call    list_drives
        ld      de,msg_printer
        call    print
        jp      0

already:
        ld      de,msg_already
        call    print
        call    list_drives
        jp      0

not_heath:
        ld      de,msg_not_heath
        jr      fail
another:
        ld      de,msg_another
        jr      fail
no_card:
        ld      de,msg_no_card
        jr      fail
no_letters:
        ld      de,msg_no_letters
fail:
        call    print
        jp      0

; Where the BIOS's RAM runs to, where ours starts, and how many K smaller a
; system has to be (MOVCPM17 moves it all 400H a K): the 1 to 3K the RAM end
; is past res_start, rounded up
no_room:
        ld      hl,(ram_end)
        dec     hl              ; its last byte
        ld      de,msg_ram_top
        call    hex_word
        ld      hl,res_start
        ld      de,msg_res_start
        call    hex_word
        ld      hl,(ram_end)
        ld      de,0x103FF - res_start
        add     hl,de
        ld      a,h
        srl     a
        srl     a
        add     a,'0'
        ld      (msg_smaller),a
        ld      de,msg_no_room
        jr      fail

; HL as 4 hex digits at DE
hex_word:
        ld      a,h
        call    hex_byte
        ld      a,l
hex_byte:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    hex_digit
        pop     af
hex_digit:
        and     0x0F
        add     a,0x90
        daa
        adc     a,0x40
        daa
        ld      (de),a
        inc     de
        ret

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

; Copy the BIOS's jump table entry at offset DE to HL
bios_entry:
        push    hl
        ld      hl,(bios)
        add     hl,de
        pop     de
        jr      copy_entry

; Copy the jump at HL over the BIOS's entry at offset DE
hook_entry:
        push    hl
        ld      hl,(bios)
        add     hl,de
        ex      de,hl
        pop     hl
copy_entry:
        ld      bc,3
        ldir
        ret

        include "card.inc"

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
msg_another:    defm    "Another FNDISK is installed. Boot again, then run this one.", 13, 10, "$"
msg_not_heath:  defm    "Needs Heath/Zenith CP/M 2.2.04.", 13, 10, "$"
msg_no_room:    defm    "No room above the BIOS: its RAM runs to "
msg_ram_top:    defm    "xxxxH, FNDISK's starts at "
msg_res_start:  defm    "xxxxH.", 13, 10
                defm    "Make a system "
msg_smaller:    defm    "nK smaller (MOVCPM17, then SYSGEN) and boot that.", 13, 10, "$"
msg_no_letters: defm    "No 8 free drive letters there.", 13, 10, "$"
msg_no_fujinet: defm    "The FujiNet isn't answering.", 13, 10, "$"
msg_no_card:    defm    "No FujiNet card (82C55 at 0D0H) found.", 13, 10, "$"
msg_printer:    defm    "LST: is UL1:, the FujiNet's printer (STAT LST:=LPT: for the BIOS's).", 13, 10, "$"
msg_drive:      defm    "  "
msg_letter:     defm    "x: slot "
msg_slotno:     defm    "n  $"
msg_empty:      defm    "-$"
msg_ro:         defm    " (read only)$"
msg_rw:         defm    " (read/write)$"
msg_eol:        defm    13, 10, "$"

bios:           defw    0
ram_end:        defw    0       ; first byte above the BIOS's RAM; 0 = the top
free_drive:     defb    0

                defs    64
stack_top:

image:
        binary  "resident.bin"
image_end:
