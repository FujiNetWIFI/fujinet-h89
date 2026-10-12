;-----------------------------------------------------------------------------
; FN.DVD: the FujiNet's drive slots as HDOS 2.0 disks, FN0: to FN7:
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; An HDOS loadable device driver. The images are H17 disks (.h8d): HDOS's
; 256-byte sectors in order, which the FujiNet serves as 512-byte sectors,
; so HDOS sector n is half n AND 1 of FujiNet sector n/2, and an HDOS group
; (two sectors from an even one) is exactly one FujiNet sector.
;
; Assembled at origin 0 with its own PIC header; tools/mkpic.py makes the
; relocation table HDOS needs from two more assemblies at other origins.
; So: no 8-bit parts of addresses, no $-relative DEFS.
;
; Build options: -DFN_UNITS=4 (four units, a K less memory), -DFN_READONLY.
;-----------------------------------------------------------------------------

        DEFINE  LOGIN_MODE              ; login keeps the slot's mode
        DEFINE  FUJI_POLL               ; CTL-C can cut a login short
        DEFINE  FUJI_DRAIN              ; a call given up is drained after

        include "h89.inc"
        include "hdos.inc"

TICKS           equ     TICCNT

IFNDEF FN_UNITS
        defc    FN_UNITS = 8
ENDIF

FN_CAP          equ     DT_DD + DT_CR + DT_CW + DT_RN
H17_SECTORS     equ     400     ; a label with no size: a 100K H17 disk
STACK_SIZE      equ     160

        public  dvd_entry, pic_end

;-----------------------------------------------------------------------------
; The PIC header (mkpic fills in LEN and PTR) and the driver's
;-----------------------------------------------------------------------------

        defb    0xFF, 0x01      ; a binary file, PIC
        defw    0               ; LEN
        defw    0               ; PTR
        defb    DVDFLV
        defb    FN_CAP          ; capabilities
        defb    0               ; mounted units
        defb    FN_UNITS        ; units
        defb    FN_CAP, FN_CAP, FN_CAP, FN_CAP
IF FN_UNITS > 4
        defb    FN_CAP, FN_CAP, FN_CAP, FN_CAP
ELSE
        defb    0, 0, 0, 0
ENDIF
        defb    0               ; no SET options
        defw    0               ; no INIT code
        defs    0x200 - 0x15    ; reserved, and where SET code would go

;-----------------------------------------------------------------------------
; Entry: A = function, BC = byte count, DE = buffer, HL = first sector; the
; unit in AIO.UNI. Returns carry clear, or carry set and A = error.
;-----------------------------------------------------------------------------

dvd_entry:
        ld      (opcode),a
        ld      (io_count),bc
        ld      (io_buf),de
        ld      (io_sector),hl

        ; Every wait times out on the 2 ms tick, so interrupts go on (and
        ; back as they were). LD A,I gives IFF2 in P/V; it's read twice
        ; because an interrupt during the first can clear P/V on an NMOS Z80.
        ld      a,i
        jp      pe,entry_on
        ld      a,i
        jp      pe,entry_on
        xor     a
        jr      entry_iff
entry_on:
        ld      a,1
entry_iff:
        ld      (iff_was),a
        ei

        ld      (caller_sp),sp
        ld      sp,stack_top
        call    dispatch
        ld      sp,(caller_sp)

        push    af
        ld      a,(iff_was)
        or      a
        jr      nz,entry_back
        di
entry_back:
        pop     af
        ret

dispatch:
        ; HDOS discards the answer to its first call after loading a driver,
        ; and that call isn't always DC.LOD: so start up on any first call
        ld      a,(inited)
        or      a
        call    z,first_call

        ld      a,(opcode)
        cp      DC_MAX
        jr      nc,do_illegal
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,dc_table
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        jp      (hl)

dc_table:
        defw    do_read         ; DC.REA
        defw    do_write        ; DC.WRI
        defw    do_read         ; DC.RER: a FujiNet image has no volume to disagree with
        defw    do_ok           ; DC.OPR
        defw    do_ok           ; DC.OPW
        defw    do_ok           ; DC.OPU
        defw    do_ok           ; DC.CLO
        defw    do_abort        ; DC.ABT
        defw    do_mount        ; DC.MOU
        defw    do_ok           ; DC.LOD
        defw    do_ok           ; DC.RDY: always ready, or MOUNT waits for it

do_illegal:
        ld      a,EC_ILR
        scf
        ret

do_ok:
        xor     a
        ret

do_abort:
        ld      a,0xFF
        ld      (cache_slot),a
        xor     a
        ret

first_call:
        ld      a,1
        ld      (inited),a
        call    card_on
        ; fall into card_check

; Note whether the card is there. Z if it isn't.
card_check:
        call    card_present
        ld      a,0
        jr      nz,card_none
        inc     a
card_none:
        ld      (card),a
        or      a
        ret

;-----------------------------------------------------------------------------
; Units
;-----------------------------------------------------------------------------

; The request's unit into slot. Carry and A = error if there's no such unit.
get_unit:
        ld      a,(AIO_UNI)
        cp      FN_UNITS
        jr      nc,unit_unknown
        ld      (slot),a
        or      a
        ret
unit_unknown:
        ld      a,EC_UUN
        scf
        ret

; HL = the slot's state byte: 0 = not logged in, else 80H, + 1 if writable
unit_state_hl:
        ld      a,(slot)
        ld      e,a
        ld      d,0
        ld      hl,unit_state
        add     hl,de
        ret

; HL = where the slot's size (in sectors) is kept
unit_size_hl:
        ld      a,(slot)
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,unit_size
        add     hl,de
        ret

do_mount:
        call    get_unit
        ret     c
        ld      hl,(io_sector)  ; HL = 0 begins a mount: log the slot in afresh
        ld      a,h
        or      l
        jr      nz,ensure_unit
        call    unit_state_hl
        ld      (hl),0
        ld      a,0xFF
        ld      (cache_slot),a
        ; fall into ensure_unit

; The slot logged in: an .h8d mounted in it, its size from its label.
; NC and A = its state, or carry and A = error. A failure isn't kept, so
; the next request tries again.
ensure_unit:
        call    unit_state_hl
        ld      a,(hl)
        or      a
        ret     nz
        ld      a,(card)
        or      a
        jr      nz,eu_login
        call    card_check
        ld      a,EC_UNA
        jr      z,eu_error
eu_login:
        ld      a,0xFF
        ld      (slot_mode),a
        ld      a,1
        ld      (poll_ok),a
        call    login
        push    af
        xor     a
        ld      (poll_ok),a
        pop     af
        jr      nz,eu_failed

        ; The label is sector 9: the second half of FujiNet sector 4
        ld      hl,4
        ld      (lba),hl
        call    load_sector
        jr      nz,eu_silent
        ld      hl,(buf + 256 + 12)     ; LAB.SIZ
        ld      a,h
        or      l
        jr      nz,eu_size
        ld      hl,H17_SECTORS
eu_size:
        push    hl
        call    unit_size_hl
        pop     de
        ld      (hl),e
        inc     hl
        ld      (hl),d

        ld      a,(slot_mode)
        and     0x03
        cp      2               ; read/write
        ld      a,0x80
        jr      nz,eu_state
IFNDEF FN_READONLY
        inc     a
ENDIF
eu_state:
        ld      b,a
        call    unit_state_hl
        ld      (hl),b
        ld      a,b
        or      a
        ret

eu_failed:
        ld      a,(slot_mode)
        cp      0xFF            ; never answered
        jr      z,eu_silent
        and     MODE_MOUNTED
        ld      a,EC_UNA        ; nothing in the slot
        jr      z,eu_error
        ld      a,EC_DNR        ; something, but not an H17 disk
        jr      eu_error
eu_silent:
        ld      a,EC_RF
eu_error:
        scf
        ret

; Carry if the request (io_sector, io_count bytes) runs past the disk
span:
        ld      hl,(io_count)
        ld      e,h
        ld      d,0
        ld      a,l
        or      a
        jr      z,span_whole
        inc     de              ; a part sector counts
span_whole:
        ld      hl,(io_sector)
        add     hl,de
        ex      de,hl           ; DE = the sector after the last
        push    de
        call    unit_size_hl
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        pop     de
        or      a
        sbc     hl,de           ; carry if the end is past the size
        ret

;-----------------------------------------------------------------------------
; Read: whole sectors, and a part one at the end if the count asks for it
;-----------------------------------------------------------------------------

do_read:
        call    get_unit
        ret     c
        ld      hl,(io_count)
        ld      a,h
        or      l
        ret     z
        call    ensure_unit
        ret     c
        call    span
        jr      c,read_failed
read_next:
        ld      hl,(io_sector)
        srl     h
        rr      l
        ld      (lba),hl
        call    load_sector
        jr      nz,read_failed

        ld      a,(io_sector)   ; its half of the FujiNet sector
        and     1
        ld      h,a
        ld      l,0
        ld      de,buf
        add     hl,de
        ld      bc,(io_count)
        ld      a,b
        or      a
        jr      z,read_copy     ; under a sector left: just that
        ld      bc,256
read_copy:
        ld      de,(io_buf)
        ldir
        ld      (io_buf),de

        ld      hl,(io_count)
        ld      a,h
        or      a
        jr      z,read_done     ; that was a part sector
        dec     h
        ld      (io_count),hl
        ld      a,h
        or      l
        jr      z,read_done
        ld      hl,(io_sector)
        inc     hl
        ld      (io_sector),hl
        jr      read_next
read_done:
        xor     a
        ret
read_failed:
        ld      a,EC_RF
        scf
        ret

;-----------------------------------------------------------------------------
; Write: whole sectors (the count rounded up). A byte count of 0 asks only
; whether the disk can be written, and writes nothing.
;-----------------------------------------------------------------------------

do_write:
        call    get_unit
        ret     c
        call    ensure_unit
        ret     c
        and     1
        jp      z,write_protected
        ld      hl,(io_count)
        ld      a,h
        or      l
        ret     z               ; the write-protect question: writable
        ld      a,l
        or      a
        jr      z,write_whole
        inc     h
        ld      l,0
        ld      (io_count),hl
write_whole:
        call    span
        jp      c,write_failed

write_next:
        ld      hl,(io_sector)
        ld      a,l
        srl     h
        rr      l
        ld      (lba),hl
        and     1
        jr      nz,write_half   ; an odd sector: the second half
        ld      a,(io_count+1)  ; sectors left
        cp      2
        jr      c,write_half    ; just the first half left

        ; A whole group: the FujiNet sector is all new, so no need to read it
        ld      a,0xFF
        ld      (cache_slot),a
        ld      hl,(io_buf)
        ld      de,buf
        ld      bc,SECTOR
        ldir
        ld      (io_buf),hl
        ld      b,2
        jr      write_out

write_half:
        call    load_sector
        jp      nz,write_failed
        ld      a,(io_sector)
        and     1
        ld      d,a
        ld      e,0
        ld      hl,buf
        add     hl,de
        ex      de,hl
        ld      hl,(io_buf)
        ld      bc,256
        ldir
        ld      (io_buf),hl
        ld      b,1

write_out:
        push    bc
        ld      a,CMD_WRITE
        call    disk_request
        ld      hl,buf
        ld      (req_data),hl
        ld      hl,SECTOR
        ld      (req_dlen),hl
        ld      hl,0
        ld      (rep_dlen),hl
        call    fuji_call
        pop     bc
        jp      nz,write_failed
        ld      a,(slot)        ; buf is the disk's again
        ld      (cache_slot),a
        ld      hl,(lba)
        ld      (cache_lba),hl

        ld      hl,(io_sector)
        ld      e,b
        ld      d,0
        add     hl,de
        ld      (io_sector),hl
        ld      a,(io_count+1)
        sub     b
        ld      (io_count+1),a
        jp      nz,write_next
        xor     a
        ret

write_protected:
        ld      a,EC_WP
        scf
        ret
write_failed:
        ld      a,0xFF
        ld      (cache_slot),a
        ld      a,EC_WF
        scf
        ret

;-----------------------------------------------------------------------------
; Shared with FNDISK
;-----------------------------------------------------------------------------

; The FujiBus wait loops call this: carry gives up the call. Only a login
; (during MOUNT) gives way to CTL-C; a transfer never does, since HDOS
; writes the GRT and directory through it on its way out.
fuji_poll:
        ld      a,(poll_ok)
        or      a
        ret     z
        ld      a,(S_CAPEND)
        or      a
        ret     z
        scf
        ret

        include "login.inc"
        include "sector.inc"
        include "fujibus.inc"
        include "card.inc"

;-----------------------------------------------------------------------------
; State: part of the image HDOS loads, so these start as written
;-----------------------------------------------------------------------------

inited:         defb    0
card:           defb    0       ; the card answered
poll_ok:        defb    0       ; CTL-C may cut the call short
iff_was:        defb    0
opcode:         defb    0
io_count:       defw    0
io_buf:         defw    0
io_sector:      defw    0
slot:           defb    0       ; the unit, from 0
slot_mode:      defb    0       ; its mode, as the login read it
lba:            defw    0
cache_slot:     defb    0xFF    ; slot whose sector cache_lba is in buf; FF = none
cache_lba:      defw    0
unit_state:     defs    FN_UNITS
unit_size:      defs    FN_UNITS * 2
caller_sp:      defw    0
        include "fujibus-vars.inc"
buf:            defs    SECTOR
                defs    STACK_SIZE
stack_top:

pic_end:
