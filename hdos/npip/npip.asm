;-----------------------------------------------------------------------------
; NPIP.ABS: copies files to and from the FujiNet, PIP's way (HDOS 2.0)
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
;   NPIP dest=source        one copy
;   NPIP                    a * prompt, a copy a line; an empty line or ^C
;                           ends it
;
; Each side is dev:NAME.EXT, or a URL (TNFS://HOST/PATH, SD:/NAME, ...); the
; destination can be a device, LP: or TT:. This is HDOS's part: the console
; raw while NPIP runs (^C comes as a key, not as HDOS's abort), files and
; devices through HDOS's channels.
;-----------------------------------------------------------------------------

        include "h89.inc"
        include "hdos.inc"

TICKS           equ     TICCNT
OS_UNIT         equ     256     ; an HDOS sector
OS_PAD          equ     0       ; NULs fill out the last, as HDOS's own do

K_DISK          equ     0       ; a file
K_CON           equ     1       ; TT:
K_DEV           equ     2       ; LP:, AT:, ... named alone

CH_SRC          equ     0       ; the channels
CH_DST          equ     1

macro SCALL fn
        rst     0x38
        defb    fn
endm

        org     USER_START - 8
        defb    0xFF, 0x00      ; an absolute binary
        defw    start           ; load address
        defw    npip_end - start
        defw    start           ; entry

start:
        ld      (arg_sp),sp     ; HDOS leaves the arguments at SP, to 227FH
        ld      sp,stack_top
        ld      hl,(arg_sp)
        ld      de,USER_START
        or      a
        sbc     hl,de
        add     hl,de
        ld      de,line
        jr      z,start_args    ; SP at 2280H: none
        ld      b,255
start_char:
        ld      a,(hl)
        or      a
        jr      z,start_args
        ld      (de),a
        inc     hl
        inc     de
        djnz    start_char
start_args:
        xor     a
        ld      (de),a

        ld      hl,S_CSLMD      ; the console raw: no echo, no CTL-C, a key
        ld      de,con_saved    ;   at a time; no capitals; no width
        ld      bc,5
        ldir
        xor     a
        ld      b,CSL_ECH + CSL_RAW + CSL_CHR
        ld      c,CSL_ECH + CSL_RAW + CSL_WRP + CSL_CHR
        SCALL   SC_CONSL
        ld      a,1
        ld      b,0
        ld      c,CTP_MLI + CTP_MLO + CTP_BKM
        SCALL   SC_CONSL
        ld      a,3
        ld      b,255
        ld      c,0xFF
        SCALL   SC_CONSL
        ld      hl,line
        jp      npip_main

os_usage:
        defm    "NPIP dest=source, or NPIP alone for a * prompt", 13, 10
        defm    "  dev:NAME.EXT, or a URL:", 13, 10
        defm    "  SY1:=TNFS://HOST/DIR/FILE.TXT   to SY1:FILE.TXT", 13, 10
        defm    "  TNFS://HOST/DIR/=SY1:FILE.TXT   to HOST/DIR/FILE.TXT", 13, 10
        defm    "  LP:=SD:/README.TXT              to LP: (TT: the screen)", 13, 10
        defm    "HDOS makes a command line capitals; the * prompt doesn't.", 13, 10, 0

;-----------------------------------------------------------------------------
; The console
;-----------------------------------------------------------------------------

os_conout:
        push    af
        push    bc
        push    de
        push    hl
        SCALL   SC_SCOUT
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret

os_crlf:
        push    af
        ld      a,13
        call    os_conout
        ld      a,10
        call    os_conout
        pop     af
        ret

os_getkey:
        push    bc
        push    de
        push    hl
gk_wait:
        SCALL   SC_SCIN
        jr      c,gk_wait
        pop     hl
        pop     de
        pop     bc
        and     0x7F
        cp      3
        scf
        ret     z
        or      a
        ret

os_break:
        push    bc
        push    de
        push    hl
        SCALL   SC_SCIN
        jr      c,ob_none
        and     0x7F
        cp      3
        scf
        jr      z,ob_done
ob_none:
        or      a
ob_done:
        pop     hl
        pop     de
        pop     bc
        ret

; The console as it was (the cursor's column at 0: NPIP ends a line last)
os_exit:
        ld      a,(con_saved)
        ld      b,a
        xor     a
        ld      c,0xFF
        SCALL   SC_CONSL
        ld      a,(con_saved+1)
        ld      b,a
        ld      a,1
        ld      c,0xFF
        SCALL   SC_CONSL
        ld      a,2
        ld      b,0
        ld      c,0xFF
        SCALL   SC_CONSL
        ld      a,(con_saved+3)
        ld      b,a
        ld      a,3
        ld      c,0xFF
        SCALL   SC_CONSL
        xor     a
        SCALL   SC_EXIT

;-----------------------------------------------------------------------------
; Files and devices
;-----------------------------------------------------------------------------

; HL -> a spec: TT: is the console; a device with no unit number, named
; alone, is a device (LP:, AT:), but for the disks' SY:, DK: and FN:;
; anything else is a file
os_kind:
        ld      d,h
        ld      e,l
ok_colon:
        ld      a,(hl)
        or      a
        jr      z,ok_file       ; no device
        inc     hl
        cp      ':'
        jr      nz,ok_colon
        ld      bc,t_tt         ; DE -> the device, HL -> after its colon
        call    ok_is
        ld      a,K_CON
        ret     z
        ld      a,(hl)
        or      a
        jr      nz,ok_file      ; a name after it
        dec     hl
        dec     hl
        ld      a,(hl)          ; a unit number
        sub     '0'
        cp      10
        jr      c,ok_file
        ld      bc,t_disks
ok_disk:
        ld      a,(bc)
        or      a
        jr      z,ok_dev
        call    ok_is
        jr      z,ok_file
        inc     bc
        inc     bc
        jr      ok_disk
ok_dev:
        ld      a,K_DEV
        or      a
        ret
ok_file:
        xor     a
        ret

; Z if the device at DE is the two letters at BC
ok_is:
        ld      a,(bc)
        ex      de,hl
        cp      (hl)
        inc     hl
        inc     bc
        jr      nz,ok_is_done
        ld      a,(bc)
        cp      (hl)
ok_is_done:
        dec     hl
        dec     bc
        ex      de,hl
        ret

t_tt:           defm    "TT"
t_disks:        defm    "SYDKFN", 0

; HL -> the file to read, on channel 0. Its size: positioned past its end,
; HDOS says how many sectors short of there it fell.
os_ropen:
        ld      a,CH_SRC
        ld      de,defaults
        SCALL   SC_OPENR
        ret     c
        ld      a,CH_SRC
        ld      bc,0xFFFF
        SCALL   SC_POSIT
        ld      d,1             ; not known
        jr      nc,ro_start
        cp      EC_EOF
        jr      nz,ro_start
        ld      hl,0xFFFF
        or      a
        sbc     hl,bc
        ld      (lsize+1),hl
        xor     a
        ld      (lsize),a
        ld      (lsize+3),a
        ld      d,a             ; known
ro_start:
        push    de
        ld      a,CH_SRC        ; back to its start
        ld      bc,0
        SCALL   SC_POSIT
        pop     de
        ret     c
        ld      a,d
        or      a
        ret

; Up to two sectors into DE
os_read:
        ld      hl,0
        ld      b,2
rd_sector:
        push    bc
        push    de
        push    hl
        ld      a,CH_SRC
        ld      bc,256
        SCALL   SC_READ
        pop     hl
        pop     de
        pop     bc
        jr      c,rd_end
        inc     h
        inc     d
        djnz    rd_sector
rd_done:
        ld      b,h
        ld      c,l
        or      a
        ret
rd_end:
        cp      EC_EOF
        jr      z,rd_done
        scf
        ret

os_rclose:
        ld      a,CH_SRC
        SCALL   SC_CLOSE
        ret

; HL -> the file or device to write, A = its kind: on channel 1
os_wopen:
        ld      (dst_os_kind),a
        ld      (dst_os_name),hl
        cp      K_CON
        ret     z
        ld      a,CH_DST
        ld      de,defaults
        SCALL   SC_OPENW
        ret

; HL -> BC bytes
os_write:
        ld      a,(dst_os_kind)
        cp      K_CON
        jr      z,ow_con
        ld      a,b
        or      c
        ret     z
        ex      de,hl
        ld      a,CH_DST
        SCALL   SC_WRITE
        ret     c
        xor     a
        ret

; To the screen, raw: HDOS's text ends lines in NL alone, so a CR before a
; NL that hasn't one
ow_con:
        ld      a,b
        or      c
        ret     z
        ld      a,(hl)
        cp      10
        jr      nz,ow_char
        ld      a,(con_last)
        cp      13
        ld      a,13
        call    nz,os_conout
        ld      a,10
ow_char:
        ld      (con_last),a
        call    os_conout
        inc     hl
        dec     bc
        jr      ow_con

os_wclose:
        ld      a,(dst_os_kind)
        cp      K_CON
        ret     z
        ld      a,CH_DST
        SCALL   SC_CLOSE
        ret

; Closed, and a file deleted (HDOS replaced any old one at OPEN)
os_wabort:
        ld      a,(dst_os_kind)
        cp      K_CON
        ret     z
        push    af
        ld      a,CH_DST
        SCALL   SC_CLOSE
        pop     af
        cp      K_DISK
        ret     nz
        ld      hl,(dst_os_name)
        ld      de,defaults
        SCALL   SC_DELETE
        ret

; A = an HDOS error: what ERRORMSG.SYS says, shorter
os_errmsg:
        ld      c,a
        ld      hl,os_errors
oe_find:
        ld      a,(hl)
        inc     hl
        or      a
        jr      z,oe_number
        cp      c
        jp      z,print
oe_skip:
        ld      a,(hl)
        inc     hl
        or      a
        jr      nz,oe_skip
        jr      oe_find
oe_number:
        push    bc
        ld      hl,t_hdoserr
        call    print
        pop     bc
        ld      a,c
        jp      pdec8

os_errors:
        defb    1
        defm    "end of file", 0
        defb    2
        defm    "disk full", 0
        defb    5
        defm    "the device can't do that", 0
        defb    6
        defm    "bad device name", 0
        defb    7
        defm    "bad file name", 0
        defb    12
        defm    "not found", 0
        defb    13
        defm    "no such device", 0
        defb    15
        defm    "directory full", 0
        defb    18
        defm    "read failure", 0
        defb    19
        defm    "write failure", 0
        defb    20
        defm    "write protected", 0
        defb    21
        defm    "disk write protected", 0
        defb    22
        defm    "already there", 0
        defb    24
        defm    "locked", 0
        defb    27
        defm    "no such unit", 0
        defb    28
        defm    "name the file", 0
        defb    29
        defm    "the device can't write", 0
        defb    30
        defm    "unit not available", 0
        defb    34
        defm    "no disk mounted", 0
        defb    0
t_hdoserr:      defm    "HDOS error ", 0

defaults:       defm    "SY0", 0, 0, 0  ; SY0:, no extension
arg_sp:         defw    0
con_saved:      defs    5       ; the console's mode bytes at the start
con_last:       defb    0       ; the last byte to TT:
dst_os_kind:    defb    0
dst_os_name:    defw    0

        include "core.inc"
        include "vars.inc"
