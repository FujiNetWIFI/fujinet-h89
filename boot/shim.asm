;-----------------------------------------------------------------------------
; The HDOS system calls CONFIG makes, with no HDOS: what FNBOOT's stage 2
; leaves under it, at SHIM_ORG
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A system call is RST 38H then the function byte; the monitor sends RST 38H
; through UIVEC_RST7, which stage 2 points at scall. BC, DE and HL are kept,
; and carry is clear unless .SCIN has nothing.
;
;   .EXIT   back to the monitor, which starts afresh (RST 0)
;   .SCIN   a key from the console's 8250, as it comes: no echo, no editing
;           (the raw character mode CONFIG asks for)
;   .SCOUT  A to the 8250
;   others  nothing (.CONSL: CONFIG keeps the console bytes at 20D6H itself)
;-----------------------------------------------------------------------------

        include "mtr.inc"

        public  scall, shim_end

scall:
        ex      (sp),hl         ; HL -> the function byte, the caller's HL
        push    bc              ; on the stack where the return was
        ld      b,(hl)
        inc     hl
        ld      (scall_ret+1),hl ; back past it
        inc     b
        dec     b
        jr      nz,not_exit
        rst     0               ; .EXIT

not_exit:
        djnz    not_scin
        in      a,(CON_LSR)     ; .SCIN
        rrca
        ccf
        jr      c,scall_done    ; nothing yet
        in      a,(CON_DATA)
        and     0x7F
        jr      scall_done

not_scin:
        djnz    scall_ok
        push    af              ; .SCOUT
scout_wait:
        in      a,(CON_LSR)
        and     LSR_THRE
        jr      z,scout_wait
        pop     af
        out     (CON_DATA),a

scall_ok:
        or      a
scall_done:
        pop     bc
        pop     hl
scall_ret:
        jp      0

shim_end:
