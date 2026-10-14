;-----------------------------------------------------------------------------
; LP.DVD: the FujiNet's printer as HDOS 2.0's LP:
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; An HDOS loadable device driver for a write-only character device. As
; Heath's LP: drivers do, it ends lines with CR LF (HDOS's are NL alone) and
; spaces out tabs; it drops the NULs that pad a file's last sector. Lines go
; to the FujiNet a whole one at a time (or 255 bytes, if longer).
;
; If a line doesn't go, the rest of the job (to CLOSE) fails at once: a
; printer that's turned off doesn't answer, and each try would wait 15 s.
;
; Assembled at origin 0 with its own PIC header; tools/mkpic.py makes the
; relocation table HDOS needs from two more assemblies at other origins.
; So: no 8-bit parts of addresses, no $-relative DEFS.
;-----------------------------------------------------------------------------

        DEFINE  FUJI_POLL               ; CTL-C can cut a wait short
        DEFINE  FUJI_DRAIN              ; a call given up is drained after

        include "h89.inc"
        include "hdos.inc"

TICKS           equ     TICCNT

PRN_SIZE        equ     255     ; the most the FujiNet takes in one packet
STACK_SIZE      equ     96

        public  dvd_entry, pic_end

;-----------------------------------------------------------------------------
; The PIC header (mkpic fills in LEN and PTR) and the driver's
;-----------------------------------------------------------------------------

        defb    0xFF, 0x01      ; a binary file, PIC
        defw    0               ; LEN
        defw    0               ; PTR
        defb    DVDFLV
        defb    DT_CW           ; capabilities: writes
        defb    1               ; mounted units: a character device always is
        defb    1               ; units
        defb    DT_CW, 0, 0, 0, 0, 0, 0, 0
        defb    0               ; no SET options
        defw    0               ; no INIT code
        defs    0x200 - 0x15    ; reserved, and where SET code would go

;-----------------------------------------------------------------------------
; Entry: A = function, BC = byte count, DE = buffer. Returns carry clear, or
; carry set and A = error.
;-----------------------------------------------------------------------------

dvd_entry:
        ld      (opcode),a
        ld      (io_count),bc
        ld      (io_buf),de

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
        defw    do_unable       ; DC.REA
        defw    do_write        ; DC.WRI
        defw    do_unable       ; DC.RER
        defw    do_unable       ; DC.OPR
        defw    do_open         ; DC.OPW
        defw    do_unable       ; DC.OPU
        defw    do_close        ; DC.CLO
        defw    do_abort        ; DC.ABT
        defw    do_unable       ; DC.MOU
        defw    do_ok           ; DC.LOD
        defw    do_ok           ; DC.RDY

do_illegal:
        ld      a,EC_ILR
        scf
        ret

do_unable:
        ld      a,EC_DNS
        scf
        ret

do_ok:
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
; A job: OPEN, WRITEs, CLOSE
;-----------------------------------------------------------------------------

; A second OPEN isn't refused: a program that never closed shouldn't keep
; LP: from everyone until the next boot. What it left goes first.
do_open:
        ld      a,(card)
        or      a
        jr      nz,open_card
        call    card_check
        ld      a,EC_UNA
        scf
        ret     z
open_card:
        ld      a,(prn_off)
        or      a
        call    z,flush
        xor     a
        ld      (prn_off),a
        ld      (prn_count),a
        ld      (column),a
        ret

do_close:
        ld      a,(prn_off)
        or      a
        jr      nz,do_abort     ; given up already, and said so
        call    flush
        push    af
        call    do_abort
        pop     af
        ret     z
        ld      a,EC_WF
        scf
        ret

do_abort:
        xor     a
        ld      (prn_off),a
        ld      (prn_count),a
        ret

; BC bytes from DE. On an error, as Heath's LP: drivers do: BC = the bytes
; not taken, DE = the next of them.
do_write:
        ld      a,(prn_off)
        or      a
        jr      nz,write_failed
write_next:
        ld      hl,(io_count)
        ld      a,h
        or      l
        ld      b,h             ; BC = 0: all taken
        ld      c,l
        ret     z
        dec     hl
        ld      (io_count),hl
        ld      hl,(io_buf)
        ld      a,(hl)
        inc     hl
        ld      (io_buf),hl
        call    put
        jr      z,write_next
        ld      hl,(io_count)   ; the byte that sent the buffer didn't go either
        inc     hl
        ld      (io_count),hl
        ld      hl,(io_buf)
        dec     hl
        ld      (io_buf),hl
write_failed:
        ld      bc,(io_count)
        ld      de,(io_buf)
        ld      a,(S_CAPEND)    ; given up for CTL-C?
        or      a
        ld      a,EC_DDA
        jr      nz,write_error
        ld      a,EC_WF
write_error:
        scf
        ret

; One character as Heath's LP: takes it. NZ if a line didn't go.
put:
        or      a
        ret     z               ; a sector's padding
        cp      10
        jr      z,put_nl
        cp      13
        jr      z,put_cr
        cp      12
        jr      z,put_ff
        cp      9
        jr      z,put_tab
        cp      ' '
        jr      c,emit          ; other controls as they are
        ld      hl,column
        inc     (hl)
        jr      emit
put_tab:
        ld      a,' '
        call    put
        ret     nz
        ld      a,(column)
        and     7
        jr      nz,put_tab
        ret
put_nl:
        ld      a,13
        call    emit
        ret     nz
        ld      a,10
        call    emit_column0
        ret     nz
        jr      flush
put_ff:
        call    emit_column0
        ret     nz
        jr      flush
put_cr:
emit_column0:
        ld      hl,column
        ld      (hl),0
        ; fall into emit

; A into the buffer, which goes out when it's full. NZ if it didn't.
emit:
        ld      hl,prn_count
        ld      e,(hl)
        inc     (hl)
        ld      d,0
        ld      hl,prn_buf
        add     hl,de
        ld      (hl),a
        ld      a,e
        cp      PRN_SIZE - 1
        jr      nc,flush
        xor     a
        ret

; What's in the buffer, to the FujiNet's printer. NZ if it didn't go: then
; the job's given up, and anything still to come of the reply drained.
flush:
        ld      a,(prn_count)
        or      a
        ret     z
        ld      a,(card)        ; with no card, every wait would see a byte
        or      a
        jr      z,flush_failed
        ld      a,(prn_count)
        ld      l,a
        ld      h,0
        ld      (req_dlen),hl
        ld      l,h
        ld      (rep_dlen),hl
        xor     a
        ld      (prn_count),a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      hl,CMD_WRITE * 256 + DEV_PRINTER    ; req_dev, req_cmd
        ld      (req_dev),hl
        ld      hl,prn_buf
        ld      (req_data),hl
        ld      a,1
        ld      (poll_ok),a
        call    fuji_call
        ld      a,0
        ld      (poll_ok),a
        ret     z
        ; FN.DVD drains only what it gave up itself
        call    drain
flush_failed:
        ld      a,1
        ld      (prn_off),a
        or      a
        ret

;-----------------------------------------------------------------------------
; Shared with FNDISK and FN.DVD
;-----------------------------------------------------------------------------

; The FujiBus wait loops call this: carry gives up the call. Only a print
; gives way to CTL-C.
fuji_poll:
        ld      a,(poll_ok)
        or      a
        ret     z
        ld      a,(S_CAPEND)
        or      a
        ret     z
        scf
        ret

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
prn_off:        defb    0       ; a line didn't go: the job's given up
prn_count:      defb    0
column:         defb    0
caller_sp:      defw    0
        include "fujibus-vars.inc"
prn_buf:        defs    PRN_SIZE
; fujibus.inc keeps a reply's data in buf, but no reply here has any
buf             equ     prn_buf
                defs    STACK_SIZE
stack_top:

pic_end:
