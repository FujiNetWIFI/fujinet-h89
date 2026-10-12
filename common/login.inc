;-----------------------------------------------------------------------------
; Login: only a slot the FujiNet has mounted, holding an H17 image, is a
; drive. That keeps the OS off the FujiNet's own boot image and off slots
; CONFIG has emptied. Returns A = 0 when the slot can be used.
;
; Uses slot, buf, cache_slot and fuji_call.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

login:
        ld      a,0xFF
        ld      (cache_slot),a  ; buf is used below

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
        ret     nz

        ld      hl,buf+1        ; the mode byte of slot 0's entry
        ld      de,SLOT_SIZE
        ld      a,(slot)
login_entry:
        or      a
        jr      z,login_mode
        add     hl,de
        dec     a
        jr      login_entry
login_mode:
        ld      a,(hl)
IFDEF LOGIN_MODE
        ld      (slot_mode),a   ; the includer keeps the slot's mode
ENDIF
        and     MODE_MOUNTED
        jr      z,login_no

        ld      a,CMD_DEVICE_PATH
        ld      (req_cmd),a
        ld      a,FIELDS_U8
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      a,(slot)
        ld      (req_aux),a
        ld      hl,256
        ld      (rep_dlen),hl
        call    fuji_call
        ret     nz

        ld      hl,buf
        ld      bc,256
        xor     a
        cpir                    ; to just past the name's NUL
        jr      nz,login_no
        dec     hl
        ld      de,buf+4
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,login_no      ; shorter than ".h8d"
        dec     hl
        ld      a,(hl)
        and     0xDF
        cp      'D'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        cp      '8'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        and     0xDF
        cp      'H'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        cp      '.'
        jr      nz,login_no
        xor     a
        ret
login_no:
        ld      a,1
        or      a
        ret
