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
; Copies the resident part, relocated to where it lands, to one of two places:
;   above the BIOS, at the very top of memory, when the BIOS's RAM ends below
;   that (a system made smaller with MOVCPM, such as 62K): the TPA keeps its
;   size; or
;   the top of the TPA, just below the CCP (or below whatever already lowered
;   the BDOS address at 0006H), on any other system, in whole pages, with
;   0006H lowered to it so programs stop short of it: about 4K off what they
;   had (2K of it the CCP they could have overwritten).
; Points the BIOS jump table's disk entries at it, and its LIST, LISTST and
; WBOOT, then sets LST: to UL1: and warm boots so CP/M starts with the new
; drives.
;-----------------------------------------------------------------------------

        include "h89.inc"

TICKS           equ     0x000B  ; the Heath BIOS's 2 ms tick counter
        include "resident.def"  ; offsets into the resident part

VERSION         equ     4
CCP_TO_BIOS     equ     0x1600  ; the CCP (800H) and BDOS (0E00H) below the BIOS

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

        ld      hl,(bios)
        ld      de,BIOS_SELDSK
        add     hl,de
        ld      (bios_seldsk_at),hl
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (seldsk_target),de

        ; Already in? Then the BIOS's SELDSK entry jumps to our do_seldsk, in
        ; a copy with the signature where this one's is.
        ex      de,hl
        ld      de,do_seldsk
        or      a
        sbc     hl,de           ; where that copy would start
        ld      (installed),hl
        ld      de,sig
        add     hl,de
        call    same_sig
        jr      nz,not_in
        ld      de,version - sig
        add     hl,de
        ld      a,(hl)
        cp      VERSION
        jp      nz,another
        jp      already
not_in:
        ; An FNDISK 1 or 2 has its signature first, at F720H
        ld      hl,(seldsk_target)
        ld      de,0xF720
        or      a
        sbc     hl,de
        jr      c,fresh
        ld      hl,0xF720
        call    same_sig
        jp      z,another
fresh:
        ; Above the BIOS if it left room: its RAM ends (an end that isn't
        ; above the BIOS is the top of memory) below the start of a copy that
        ; ends at the top of memory
        ld      hl,(bios)
        ld      de,BIOS_RAM_END
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,(bios)
        or      a
        sbc     hl,de
        jr      nc,below_ccp
        ld      hl,-res_end     ; 10000H - res_end
        or      a
        sbc     hl,de
        jr      c,below_ccp
        ld      hl,-res_end
        ld      (base),hl
        xor     a
        ld      (lowers),a
        jr      placed
below_ccp:
        ; The top of the TPA: below the CCP, or where 0006H points if that is
        ; lower (something else is in above us)
        ld      hl,(bios)
        ld      de,-CCP_TO_BIOS
        add     hl,de
        ld      de,(6)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,top_found     ; the CCP is lower
        ex      de,hl
top_found:
        ld      de,res_end
        or      a
        sbc     hl,de
        jp      c,no_memory
        ld      l,0             ; the page it can start on
        ld      de,buf_end + 64 ; clear of this program and its buffer
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jp      c,no_memory
        ld      (base),hl
        ld      a,1
        ld      (lowers),a
placed:
        call    card_on
        call    card_present
        jp      nz,no_card
        call    mount_all

        ; Fill in the image where it is: the BIOS's own HOME..LISTST, LIST
        ; and WBOOT entries, for the driver to pass calls on...
        ld      hl,(bios)
        ld      de,BIOS_HOME
        add     hl,de
        ld      de,image + bios_jumps
        ld      bc,NHOOKS * 3
        ldir
        ld      de,BIOS_LIST
        ld      hl,image + bios_list
        call    bios_entry
        ld      de,BIOS_WBOOT
        ld      hl,image + bios_wboot
        call    bios_entry

        ; ...the BDOS entry it goes on to...
        ld      hl,(6)
        ld      (image + bdos_entry + 1),hl

        ; ...and the BIOS's directory buffer, which all the drives share
        ld      hl,(bios)
        ld      de,BIOS_DPH0 + DPH_DIRBUF
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,image + dph_table + DPH_DIRBUF
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
        ld      (drive0),a
        ld      (image + first_drive),a
        ld      a,(lowers)
        ld      (image + lowered),a

        call    relocate

        ; In place, with its buffers cleared
        ld      hl,image
        ld      de,(base)
        ld      bc,res_bss
        ldir
        ld      hl,(base)
        ld      de,res_bss
        add     hl,de
        ld      (hl),0
        ld      d,h
        ld      e,l
        inc     de
        ld      bc,res_end - res_bss - 1
        ldir

        ; Hand the entries over (the relocated jumps in image)
        ld      hl,image + hooks
        ex      de,hl
        ld      hl,(bios)
        ld      bc,BIOS_HOME
        add     hl,bc
        ex      de,hl
        ld      bc,NHOOKS * 3
        ldir
        ld      de,BIOS_LIST
        ld      hl,image + list_hook
        call    hook_entry
        ld      de,BIOS_WBOOT
        ld      hl,image + wboot_hook
        call    hook_entry

        ld      a,(3)           ; LST: = UL1:, the FujiNet's printer
        or      0xC0
        ld      (3),a

        ld      a,(lowers)
        or      a
        jr      z,say_above
        ld      hl,(base)       ; programs stop short of it
        ld      (6),hl
        ld      de,msg_base
        call    hex_word
        ld      hl,(base)
        dec     hl
        ld      de,msg_tpa
        call    hex_word
        ld      de,msg_installed
        jr      say_where
say_above:
        ld      hl,(base)
        ld      de,msg_base2
        call    hex_word
        ld      de,msg_above
say_where:
        call    print
        call    list_drives
        ld      de,msg_printer
        call    print
        jp      0

; Add the address it is loading at to each word of the image that is an
; address: resident.bits has a bit for each byte of the image, set at the
; high byte of one
relocate:
        ld      hl,image
        ld      de,image_bits
        ld      b,(image_bits_end - image_bits) & 0xFF
reloc_group:
        ld      a,(de)
        inc     de
        ld      c,8
reloc_bit:
        rrca
        jr      nc,reloc_next
        push    af
        dec     hl
        ld      a,(base)
        add     a,(hl)
        ld      (hl),a
        inc     hl
        ld      a,(base + 1)
        adc     a,(hl)
        ld      (hl),a
        pop     af
reloc_next:
        inc     hl
        dec     c
        jr      nz,reloc_bit
        djnz    reloc_group
        ret

; Z if the six bytes at HL (kept) are "FNDISK"
same_sig:
        push    hl
        ld      de,sig_text
        ld      b,6
same_sig_next:
        ld      a,(de)
        cp      (hl)
        jr      nz,same_sig_done
        inc     hl
        inc     de
        djnz    same_sig_next
same_sig_done:
        pop     hl
        ret

already:
        ld      hl,(installed)
        ld      de,first_drive
        add     hl,de
        ld      a,(hl)
        ld      (drive0),a
        ld      hl,(installed)
        ld      de,msg_where
        call    hex_word
        ld      de,msg_already
        call    print
        call    card_on
        call    card_present
        jp      nz,no_card
        call    mount_all       ; again, if the FujiNet restarted since
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

no_memory:
        ld      de,msg_no_memory
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

bios_seldsk:
        ld      hl,(bios_seldsk_at)
        jp      (hl)

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
        include "fujibus.inc"

;-----------------------------------------------------------------------------
; Have the FujiNet mount the images in its slots: after it starts it knows
; them but has mounted none, and only a mounted slot logs in. A slot that
; won't mount is reported, and the rest still work.
;-----------------------------------------------------------------------------

mount_all:
        ld      a,DEV_FUJI
        ld      (req_dev),a
        ld      a,CMD_MOUNT_ALL
        ld      (req_cmd),a
        xor     a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      hl,0
        ld      (req_dlen),hl
        ld      (rep_dlen),hl
        call    fuji_call
        ret     z
        ld      de,msg_no_mount
        jp      print

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
        ld      a,(drive0)
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
msg_installed:  defm    "Installed at "
msg_base:       defm    "xxxxH; the TPA ends at "
msg_tpa:        defm    "xxxxH.", 13, 10, "$"
msg_above:      defm    "Installed at "
msg_base2:      defm    "xxxxH, above the BIOS; the TPA is unchanged.", 13, 10, "$"
msg_already:    defm    "Already installed at "
msg_where:      defm    "xxxxH.", 13, 10, "$"
msg_another:    defm    "Another FNDISK is installed. Boot again, then run this one.", 13, 10, "$"
msg_not_heath:  defm    "Needs Heath/Zenith CP/M 2.2.04.", 13, 10, "$"
msg_no_memory:  defm    "Not enough memory below the CCP, or above the BIOS.", 13, 10, "$"
msg_no_letters: defm    "No 8 free drive letters there.", 13, 10, "$"
msg_no_mount:   defm    "Not every slot would mount (FNCONFIG shows why).", 13, 10, "$"
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
sig_text:       defm    "FNDISK"

bios:           defw    0
bios_seldsk_at: defw    0
seldsk_target:  defw    0
installed:      defw    0       ; where our copy is, if it is
base:           defw    0       ; where this one is going
drive0:         defb    0       ; CP/M drive number of slot 1
free_drive:     defb    0
lowers:         defb    0       ; 0006H is to be lowered to it

                include "fujibus-vars.inc"

                defs    64
stack_top:

image:
        binary  "resident.bin"
image_end:
image_bits:
        binary  "resident.bits"
image_bits_end:
buf             equ     $
buf_end         equ     buf + SLOTS_SIZE
