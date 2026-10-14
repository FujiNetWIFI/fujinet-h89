;-----------------------------------------------------------------------------
; NPIP: the progress line, redrawn in place, 71 columns at most:
;
;   BOOT.ZX        [################................] 20480/40960
;   DATA.BIN       [................................] 12345/?
;
; The source's name, a bar of BAR cells, then the bytes copied of how many.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

NAME_W          equ     14      ; columns of the name
BAR             equ     32      ; cells in the bar
DRAW_TICKS      equ     250     ; redrawn every 0.5 s (a line is 75 ms at
                                ;   9600 baud)

prog_start:
        ld      hl,0
        ld      (p_done),hl
        ld      (p_done+2),hl
        jr      prog_draw

; BC more bytes copied
prog_add:
        ld      hl,(p_done)
        add     hl,bc
        ld      (p_done),hl
        jr      nc,pa_more
        ld      hl,(p_done+2)
        inc     hl
        ld      (p_done+2),hl
pa_more:
        ld      a,(tot_known)   ; more than the size: it wasn't
        or      a
        jr      z,pa_time
        call    past_total
        jr      nc,pa_time
        xor     a
        ld      (tot_known),a
pa_time:
        ld      hl,(TICKS)
        ld      de,(last_draw)
        or      a
        sbc     hl,de
        ld      de,DRAW_TICKS
        or      a
        sbc     hl,de
        ret     c
        jr      prog_draw

; All copied: the size is what was
prog_end:
        ld      hl,(p_done)
        ld      (p_total),hl
        ld      hl,(p_done+2)
        ld      (p_total+2),hl
        ld      a,1
        ld      (tot_known),a
        call    prog_draw
; End the line, if one's showing
prog_break:
        ld      a,(prog_shown)
        or      a
        ret     z
        xor     a
        ld      (prog_shown),a
        jp      os_crlf

prog_draw:
        ld      a,(prog_on)
        or      a
        ret     z
        ld      (prog_shown),a
        ld      hl,(TICKS)
        ld      (last_draw),hl
        ld      a,13
        call    os_conout
        ld      hl,(src_name)
        ld      b,NAME_W
pd_name:
        ld      a,(hl)
        call    name_end
        jr      z,pd_pad
        call    os_conout
        inc     hl
        djnz    pd_name
pd_pad:
        inc     b
pd_space:
        ld      a,' '
        call    os_conout
        djnz    pd_space
        ld      a,'['
        call    os_conout
        call    bar_fill
        ld      c,a
        ld      b,BAR
pd_cell:
        ld      a,'.'
        inc     c
        dec     c
        jr      z,pd_dot
        dec     c
        ld      a,'#'
pd_dot:
        call    os_conout
        djnz    pd_cell
        ld      hl,t_barend
        call    print
        ld      a,(tot_known)
        or      a
        jr      z,pd_unknown
        ld      hl,p_total      ; copied, right-aligned under the size
        call    dec32
        ld      c,b
        ld      hl,p_done
        call    dec32
        ld      a,c
        sub     b
        jr      z,pd_done
        ld      b,a
pd_lead:
        ld      a,' '
        call    os_conout
        djnz    pd_lead
pd_done:
        ld      hl,numbuf
        call    print
        ld      a,'/'
        call    os_conout
        ld      hl,p_total
        call    dec32
        ld      hl,numbuf
        call    print
        jr      pd_eol
pd_unknown:
        ld      hl,p_done
        call    dec32
        ld      hl,numbuf
        call    print
        ld      hl,t_unknown
        call    print
pd_eol:
        ld      hl,t_eol        ; the rest of the line erased
        jp      print

; A = the bar's cells filled: p_done / p_total of BAR. Both are shifted
; down until the size fits 11 bits, so done * 32 fits 16.
bar_fill:
        ld      a,(tot_known)
        or      a
        ret     z
        call    past_total
        jr      c,bf_full
        ld      hl,p_total
        ld      de,bf_t
        ld      bc,4
        ldir
        ld      hl,p_done
        ld      de,bf_d
        ld      bc,4
        ldir
bf_scale:
        ld      a,(bf_t+3)
        ld      hl,bf_t+2
        or      (hl)
        jr      nz,bf_shift
        ld      a,(bf_t+1)
        cp      8
        jr      c,bf_div
bf_shift:
        ld      hl,bf_t
        call    shr32
        ld      hl,bf_d
        call    shr32
        jr      bf_scale
bf_div:
        ld      de,(bf_t)
        ld      a,d
        or      e
        jr      z,bf_full       ; nothing to copy
        ld      hl,(bf_d)
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      b,0
bf_sub:
        or      a
        sbc     hl,de
        jr      c,bf_got
        inc     b
        jr      bf_sub
bf_got:
        ld      a,b
        ret
bf_full:
        ld      a,BAR
        ret

; Carry if p_done is past p_total
past_total:
        ld      hl,p_total
        ld      de,p_done
        ld      b,4
        or      a
pt_byte:
        ld      a,(hl)
        ex      de,hl
        sbc     a,(hl)
        ex      de,hl
        inc     hl
        inc     de
        djnz    pt_byte
        ret

; The 32 bits at HL, one place right
shr32:
        inc     hl
        inc     hl
        inc     hl
        srl     (hl)
        dec     hl
        rr      (hl)
        dec     hl
        rr      (hl)
        dec     hl
        rr      (hl)
        ret

; The 32 bits at HL in decimal: numbuf, NUL-terminated; B = its digits
dec32:
        ld      de,tmp32
        ld      bc,4
        ldir
        ld      b,0
d32_digit:
        push    bc
        ld      hl,tmp32 + 3    ; tmp32 / 10, a byte at a time from the top
        xor     a
        ld      e,4
d32_byte:
        ld      c,(hl)
        ld      d,8
d32_bit:
        sla     c
        rla
        cp      10
        jr      c,d32_low
        sub     10
        inc     c
d32_low:
        dec     d
        jr      nz,d32_bit
        ld      (hl),c
        dec     hl
        dec     e
        jr      nz,d32_byte
        pop     bc
        add     a,'0'           ; the remainder is the next digit up
        push    af
        inc     b
        ld      hl,(tmp32)
        ld      a,h
        or      l
        ld      hl,(tmp32+2)
        or      h
        or      l
        jr      nz,d32_digit
        ld      hl,numbuf
        ld      c,b
d32_out:
        pop     af
        ld      (hl),a
        inc     hl
        djnz    d32_out
        ld      (hl),0
        ld      b,c
        ret

; A in decimal
pdec8:
        ld      hl,tmp8
        ld      (hl),a
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ld      hl,tmp8
        call    dec32
        ld      hl,numbuf
        jp      print
