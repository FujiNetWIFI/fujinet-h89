;-----------------------------------------------------------------------------
; NPIP.COM: copies files to and from the FujiNet, PIP's way (Heath CP/M
; 2.2.04)
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
;   NPIP dest=source        one copy
;   NPIP                    a * prompt, a copy a line; an empty line or ^C
;                           ends it
;
; Each side is d:NAME.EXT, or a URL (TNFS://HOST/PATH, SD:/NAME, ...); the
; destination can be CON:, LST: or PUN:, as with PIP, which stop at the
; first ^Z. This is CP/M's part: the console through the BIOS (BDOS's ^S
; check would swallow a ^C), files through BDOS. A file is written as
; NAME.$$$, which replaces NAME once it's whole.
;-----------------------------------------------------------------------------

        include "h89.inc"

TICKS           equ     0x000B  ; the Heath BIOS's 2 ms tick counter
OS_UNIT         equ     128     ; a CP/M record
OS_PAD          equ     0x1A    ; ^Z fills out the last

K_DISK          equ     0       ; a file
K_CON           equ     1       ; the console
K_DEV           equ     2       ; LST: or PUN:

BDOS            equ     5
B_PUNCH         equ     4
B_LIST          equ     5
B_OPEN          equ     15
B_CLOSE         equ     16
B_DELETE        equ     19
B_READ          equ     20
B_WRITE         equ     21
B_MAKE          equ     22
B_RENAME        equ     23
B_SETDMA        equ     26
B_SIZE          equ     35

BIOS_VERSION    equ     0x33    ; Heath's BIOS: its version byte, 04
CPM_TAIL        equ     0x80    ; the command tail: its length, then it

; The errors os_errmsg knows
E_NOTFOUND      equ     1
E_DIRFULL       equ     2
E_DISKFULL      equ     3
E_CLOSE         equ     4
E_BADNAME       equ     5

        org     0x100

start:
        ld      sp,stack_top
        ld      hl,CPM_TAIL     ; the arguments, before anything else
        ld      c,(hl)          ;   uses the buffer they're in
        ld      b,0
        inc     hl
        ld      de,line
        ld      a,c
        or      a
        jr      z,start_args
        ldir
start_args:
        xor     a
        ld      (de),a

        ld      hl,(1)          ; Heath's BIOS: its ticks are TICKS
        ld      de,BIOS_VERSION - 3
        add     hl,de
        ld      a,(hl)
        cp      4
        jr      nz,not_heath
        ld      hl,(1)          ; its CONST, CONIN and CONOUT entries
        inc     hl
        inc     hl
        inc     hl
        ld      (bios_const+1),hl
        ld      de,3
        add     hl,de
        ld      (bios_conin+1),hl
        add     hl,de
        ld      (bios_conout+1),hl
        ld      hl,line
        jp      npip_main

not_heath:
        ld      de,t_heath
        ld      c,9
        call    BDOS
        jp      0

t_heath:        defm    "NPIP needs Heath/Zenith CP/M 2.2.04.", 13, 10, "$"

os_usage:
        defm    "NPIP dest=source, or NPIP alone for a * prompt", 13, 10
        defm    "  d:NAME.EXT, or a URL:", 13, 10
        defm    "  B:=TNFS://HOST/DIR/FILE.TXT    to B:FILE.TXT", 13, 10
        defm    "  TNFS://HOST/DIR/=A:FILE.TXT    to HOST/DIR/FILE.TXT", 13, 10
        defm    "  LST:=SD:/README.TXT            to the list device (PUN:, CON:)", 13, 10
        defm    "The CCP makes a command line capitals; the * prompt doesn't.", 13, 10, 0

;-----------------------------------------------------------------------------
; The console, through the BIOS
;-----------------------------------------------------------------------------

bios_const:
        jp      0
bios_conin:
        jp      0
bios_conout:
        jp      0

os_conout:
        push    af
        push    bc
        push    de
        push    hl
        ld      c,a
        call    bios_conout
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
        call    bios_const
        or      a
        jr      z,gk_wait
        call    bios_conin
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
        call    bios_const
        or      a
        jr      z,ob_none
        call    bios_conin
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

os_exit:
        jp      0               ; a warm boot: FNDISK prints its last line

;-----------------------------------------------------------------------------
; Files and devices
;-----------------------------------------------------------------------------

; HL -> a spec: CON:, LST: and PUN: are devices; x:NAME, x: and NAME are
; files; any other xxx: isn't
os_kind:
        ld      de,t_con
        call    same
        ld      a,K_CON
        ret     z
        ld      de,t_lst
        call    same
        ld      a,K_DEV
        ld      c,B_LIST
        jr      z,ok_dev
        ld      de,t_pun
        call    same
        ld      a,K_DEV
        ld      c,B_PUNCH
        jr      z,ok_dev
        inc     hl              ; x: or no device at all
        ld      a,(hl)
        cp      ':'
        ld      a,K_DISK
        ret     z
        dec     hl
ok_colon:
        ld      a,(hl)
        or      a
        ret     z               ; (A = K_DISK, NC)
        inc     hl
        cp      ':'
        jr      nz,ok_colon
        scf
        ret
ok_dev:
        push    af
        ld      a,c
        ld      (dev_fn),a
        pop     af
        or      a
        ret

; Z if the string at HL is the one at DE. Keeps HL.
same:
        push    hl
same_next:
        ld      a,(de)
        cp      (hl)
        jr      nz,same_done
        inc     hl
        inc     de
        or      a
        jr      nz,same_next
same_done:
        pop     hl
        ret

t_con:  defm    "CON:", 0
t_lst:  defm    "LST:", 0
t_pun:  defm    "PUN:", 0

; HL -> "x:NAME.EXT" into the FCB at DE (cleared first). Carry if it isn't
; a name CP/M takes.
fcb_parse:
        push    hl
        push    de
        ld      h,d
        ld      l,e
        ld      (hl),0
        inc     hl
        ld      b,11
fp_blank:
        ld      (hl),' '
        inc     hl
        djnz    fp_blank
        ld      b,24
fp_zero:
        ld      (hl),0
        inc     hl
        djnz    fp_zero
        pop     de
        pop     hl
        inc     hl              ; x: the drive
        ld      a,(hl)
        dec     hl
        cp      ':'
        jr      nz,fp_name
        ld      a,(hl)
        sub     'A' - 1
        jr      c,fp_bad
        cp      17
        jr      nc,fp_bad
        ld      (de),a
        inc     hl
        inc     hl
fp_name:
        push    de
        inc     de
        ld      b,8
        call    fp_part
        pop     de
        jr      c,fp_bad
        ld      a,b
        cp      8
        jr      z,fp_bad        ; no name
        ld      a,(hl)
        or      a
        ret     z
        cp      '.'
        jr      nz,fp_bad
        inc     hl
        push    de
        ld      a,e
        add     a,9
        ld      e,a
        jr      nc,fp_ext
        inc     d
fp_ext:
        ld      b,3
        call    fp_part
        pop     de
        ret     c
        ld      a,(hl)
        or      a
        ret     z
fp_bad:
        scf
        ret

; Up to B of a name's characters from HL to DE, to a dot or the end. Carry
; if one isn't allowed. B = how many fewer than it could have had.
fp_part:
        ld      a,(hl)
        or      a
        ret     z
        cp      '.'
        ret     z
        ld      c,a
        ld      a,b
        or      a
        scf
        ret     z               ; too long
        ld      a,c
        cp      '!'
        ret     c               ; spaces, control characters
        push    hl
        push    bc
        ld      hl,t_notname
        ld      bc,t_notname_end - t_notname
        cpir
        pop     bc
        pop     hl
        scf
        ret     z
        ld      (de),a
        inc     hl
        inc     de
        dec     b
        jr      fp_part

t_notname:      defm    "<>,;:=?*[]|()/"
                defb    0x5C            ; backslash
t_notname_end:

; HL -> the file to read
os_ropen:
        ld      de,src_fcb
        call    fcb_parse
        ld      a,E_BADNAME
        ret     c
        ld      de,src_fcb
        ld      c,B_OPEN
        call    BDOS
        inc     a
        ld      a,E_NOTFOUND
        scf
        ret     z
        xor     a
        ld      (src_fcb+32),a  ; from its first record
        ld      de,src_fcb      ; its records into r0-r2
        ld      c,B_SIZE
        call    BDOS
        xor     a               ; lsize = them * 128
        ld      (lsize),a
        ld      hl,(src_fcb+33)
        ld      (lsize+1),hl
        ld      a,(src_fcb+35)
        ld      (lsize+3),a
        ld      hl,lsize
        call    shr32
        xor     a
        ret

; Up to 4 records into DE
os_read:
        ld      b,4
        ld      hl,0
or_record:
        push    bc
        push    de
        push    hl
        ld      c,B_SETDMA
        call    BDOS
        ld      de,src_fcb
        ld      c,B_READ
        call    BDOS
        pop     hl
        pop     de
        pop     bc
        or      a
        jr      nz,or_end       ; the end (or what can't be read)
        push    bc
        ld      bc,128
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        pop     bc
        djnz    or_record
or_end:
        ld      b,h
        ld      c,l
        or      a
        ret

os_rclose:
        ret

; HL -> the file or device to write, A = its kind: a file as NAME.$$$
os_wopen:
        ld      (dst_os_kind),a
        cp      K_DISK
        jr      z,ow_file
        call    os_kind         ; (dev_fn)
        or      a
        ret
ow_file:
        ld      de,dst_fcb
        call    fcb_parse
        ld      a,E_BADNAME
        ret     c
        ld      hl,dst_fcb
        ld      de,tmp_fcb
        ld      bc,36
        ldir
        ld      hl,tmp_fcb + 9
        ld      (hl),'$'
        inc     hl
        ld      (hl),'$'
        inc     hl
        ld      (hl),'$'
        ld      de,tmp_fcb
        ld      c,B_DELETE
        call    BDOS
        ld      de,tmp_fcb
        ld      c,B_MAKE
        call    BDOS
        inc     a
        ld      a,E_DIRFULL
        scf
        ret     z
        xor     a
        ld      (tmp_fcb+32),a
        ret

; HL -> BC bytes: a file's records, or a device's characters to a ^Z
os_write:
        ld      a,(dst_os_kind)
        cp      K_DISK
        jr      nz,ow_device
ow_record:
        ld      a,b
        or      c
        ret     z
        push    bc
        push    hl
        ex      de,hl
        ld      c,B_SETDMA
        call    BDOS
        ld      de,tmp_fcb
        ld      c,B_WRITE
        call    BDOS
        pop     hl
        pop     bc
        or      a
        jr      nz,ow_full
        ld      de,128
        add     hl,de
        push    hl
        ld      h,b
        ld      l,c
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        pop     hl
        jr      ow_record
ow_full:
        cp      1               ; 1: no directory entry for the next extent
        ld      a,E_DIRFULL
        scf
        ret     z
        ld      a,E_DISKFULL
        scf
        ret

ow_device:
        ld      a,b
        or      c
        ret     z
        ld      a,(hl)
        cp      0x1A
        jr      z,ow_eof
        push    bc
        push    hl
        ld      e,a
        ld      a,(dst_os_kind)
        cp      K_CON
        jr      z,ow_con
        ld      a,(dev_fn)
        ld      c,a
        call    BDOS
        jr      ow_next
ow_con:
        ld      c,e
        call    bios_conout
ow_next:
        pop     hl
        pop     bc
        inc     hl
        dec     bc
        jr      ow_device
ow_eof:
        ld      a,1
        or      a
        ret

; A whole file: NAME.$$$ closed, then renamed NAME (the old NAME deleted)
os_wclose:
        ld      a,(dst_os_kind)
        cp      K_DISK
        ret     nz
        ld      de,tmp_fcb
        ld      c,B_CLOSE
        call    BDOS
        inc     a
        ld      a,E_CLOSE
        scf
        ret     z
        ld      de,dst_fcb
        ld      c,B_DELETE
        call    BDOS
        ld      hl,dst_fcb
        ld      de,tmp_fcb + 16
        ld      bc,16
        ldir
        ld      de,tmp_fcb
        ld      c,B_RENAME
        call    BDOS
        inc     a
        ld      a,E_CLOSE
        scf
        ret     z
        xor     a
        ret

; NAME.$$$ goes; any old NAME stays
os_wabort:
        ld      a,(dst_os_kind)
        cp      K_DISK
        ret     nz
        ld      de,tmp_fcb
        ld      c,B_CLOSE
        call    BDOS
        ld      de,tmp_fcb
        ld      c,B_DELETE
        jp      BDOS

os_errmsg:
        ld      hl,os_errors
oe_find:
        ld      c,a
        ld      a,(hl)
        inc     hl
        or      a
        jr      z,oe_print
        cp      c
        jr      z,oe_print
oe_skip:
        ld      a,(hl)
        inc     hl
        or      a
        jr      nz,oe_skip
        ld      a,c
        jr      oe_find
oe_print:
        jp      print

os_errors:
        defb    E_NOTFOUND
        defm    "not found", 0
        defb    E_DIRFULL
        defm    "directory full", 0
        defb    E_DISKFULL
        defm    "disk full", 0
        defb    E_CLOSE
        defm    "can't close it", 0
        defb    E_BADNAME
        defm    "bad name", 0
        defb    0
        defm    "failed", 0

dst_os_kind:    defb    0
dev_fn:         defb    0       ; BDOS's LIST or PUNCH
src_fcb:        defs    36
dst_fcb:        defs    36
tmp_fcb:        defs    36

        include "core.inc"
        include "vars.inc"
