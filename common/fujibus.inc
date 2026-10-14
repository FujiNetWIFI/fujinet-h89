;-----------------------------------------------------------------------------
; FujiBus over the H89-ESP32 card's 82C55
;
; fuji_call sends the request in req_* (and req_dlen bytes from req_data),
; then takes the reply: its header into rep_hdr, up to rep_dlen bytes of data
; into buf. Z and A = 0 on an ACK of exactly rep_dlen bytes with a good
; checksum; NZ otherwise, after a timeout too. The whole reply is always
; read, to its closing END, so the next request starts clean.
;
; With FUJI_SHORT, an ACK of up to rep_dlen bytes will do (a network READ
; gets what is there), and rep_got says how many came.
;
; The includer defines TICKS (the OS's 2 ms tick counter) and buf (SECTOR
; bytes), and includes fujibus-vars.inc among its data.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

TX_TIMEOUT      equ     500     ; 1 s for the ESP32 to take a byte
RX_FIRST        equ     7500    ; 15 s for the reply to start (TNFS can be slow)
RX_TIMEOUT      equ     500     ; 1 s between reply bytes

fuji_call:
        ld      (abort_sp),sp
IFDEF FUJI_DRAIN
        ld      a,(bus_dirty)
        or      a
        call    nz,drain
ENDIF

        ld      a,(req_auxn)
        add     a,6
        ld      l,a
        ld      h,0
        ld      de,(req_dlen)
        add     hl,de
        ld      (req_len),hl

        xor     a
        ld      (req_cks),a
        ld      d,a
        ld      hl,req_dev
        ld      a,(req_auxn)
        add     a,6
        ld      c,a
        ld      b,0
        call    cksum
        ld      hl,(req_data)
        ld      bc,(req_dlen)
        call    cksum
        ld      a,d
        ld      (req_cks),a

        ; Send: one END, the packet, one END
        ld      a,OE_ON
        out     (PCTRL),a
        ld      a,DIR_TO_ESP
        out     (PCTRL),a
        ld      hl,TX_TIMEOUT
        ld      (tlimit),hl
        ld      a,SLIP_END
        call    putc
        ld      hl,req_dev
        ld      a,(req_auxn)
        add     a,6
        ld      c,a
        ld      b,0
        call    slip_send
        ld      hl,(req_data)
        ld      bc,(req_dlen)
        call    slip_send
        ld      a,SLIP_END
        call    putc
        call    tx_wait
        ld      a,DIR_TO_H89
        out     (PCTRL),a

        ; Receive: skip to an END, past any more, then decode to the next
        ld      hl,RX_FIRST
        ld      (tlimit),hl
rx_sync:
        call    getc
        cp      SLIP_END
        jr      nz,rx_sync
        ld      hl,RX_TIMEOUT
        ld      (tlimit),hl
rx_skip:
        call    getc
        cp      SLIP_END
        jr      z,rx_skip
        ld      hl,0
        ld      (rx_count),hl
rx_loop:
        cp      SLIP_END
        jr      z,rx_done
        cp      SLIP_ESC
        jr      nz,rx_store
        call    getc
        cp      SLIP_ESC_END
        jr      nz,rx_esc_esc
        ld      a,SLIP_END
        jr      rx_store
rx_esc_esc:
        cp      SLIP_ESC_ESC
        jr      nz,rx_store
        ld      a,SLIP_ESC
rx_store:
        call    store
        call    getc
        jr      rx_loop

rx_done:
        ld      hl,(rx_count)   ; as long as its header says
        ld      de,(rep_hdr+2)
        or      a
        sbc     hl,de
        jr      nz,rx_bad
        ld      hl,(rx_count)   ; with the data asked for
        ld      de,6
        or      a
        sbc     hl,de
        jr      c,rx_bad
IFDEF FUJI_SHORT
        ld      (rep_got),hl    ; or less: what came
        ex      de,hl
        ld      hl,(rep_dlen)
        or      a
        sbc     hl,de
        jr      c,rx_bad
ELSE
        ld      de,(rep_dlen)
        or      a
        sbc     hl,de
        jr      nz,rx_bad
ENDIF
        ld      a,(req_dev)     ; from the device asked
        ld      hl,rep_hdr
        cp      (hl)
        jr      nz,rx_bad
        ld      a,(rep_hdr+1)   ; an ACK
        cp      REPLY_ACK
        jr      nz,rx_bad
        ld      a,(rep_hdr+4)   ; and its checksum right
        ld      (rx_cks),a
        xor     a
        ld      (rep_hdr+4),a
        ld      d,a
        ld      hl,rep_hdr
        ld      bc,6
        call    cksum
        ld      hl,buf
IFDEF FUJI_SHORT
        ld      bc,(rep_got)
ELSE
        ld      bc,(rep_dlen)
ENDIF
        call    cksum
        ld      a,(rx_cks)
        cp      d
        jr      nz,rx_bad
        xor     a
        ret
rx_bad:
        ld      a,1
        or      a
        ret

; A timeout anywhere in a call: give up on it
abort:
IFDEF FUJI_DRAIN
        ld      a,1
        ld      (bus_dirty),a   ; its reply may still be coming
ENDIF
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ld      sp,(abort_sp)
        ld      a,1
        or      a
        ret

; D += BC bytes from HL, as an 8-bit sum with end-around carry
cksum:
        ld      a,b
        or      c
        ret     z
        ld      a,d
        add     a,(hl)
        adc     a,0
        ld      d,a
        inc     hl
        dec     bc
        jr      cksum

; A reply byte: the first 6 into rep_hdr, then up to rep_dlen into buf
store:
        push    bc
        ld      c,a
        ld      hl,(rx_count)
        inc     hl
        ld      (rx_count),hl
        dec     hl
        ld      de,6
        or      a
        sbc     hl,de
        jr      nc,store_data
        add     hl,de
        ld      de,rep_hdr
        add     hl,de
        ld      (hl),c
        pop     bc
        ret
store_data:
        ld      de,(rep_dlen)
        ld      a,l
        sub     e
        ld      a,h
        sbc     a,d
        jr      nc,store_done   ; more than was asked for: counted, not kept
        ld      de,buf
        add     hl,de
        ld      (hl),c
store_done:
        pop     bc
        ret

; BC bytes from HL, SLIP-escaped
slip_send:
        ld      a,b
        or      c
        ret     z
        ld      a,(hl)
        cp      SLIP_END
        jr      z,slip_end
        cp      SLIP_ESC
        jr      z,slip_esc
        call    putc
        jr      slip_next
slip_end:
        ld      a,SLIP_ESC
        call    putc
        ld      a,SLIP_ESC_END
        call    putc
        jr      slip_next
slip_esc:
        ld      a,SLIP_ESC
        call    putc
        ld      a,SLIP_ESC_ESC
        call    putc
slip_next:
        inc     hl
        dec     bc
        jr      slip_send

; Carry set once (TICKS - t0) has reached tlimit. Uses HL, DE.
expired:
        ld      hl,(TICKS)
        ld      de,(t0)
        or      a
        sbc     hl,de
        ld      de,(tlimit)
        or      a
        sbc     hl,de
        ccf
        ret

; Wait for the ESP32 to have taken the last byte (/OBF high). Keeps BC, DE, HL.
tx_wait:
        in      a,(PORTC)
        and     PC_OBF
        ret     nz
        push    hl
        push    de
        ld      hl,(TICKS)
        ld      (t0),hl
tx_wait_poll:
        in      a,(PORTC)
        and     PC_OBF
        jr      nz,tx_wait_done
IFDEF FUJI_POLL
        call    fuji_poll       ; the includer's: carry gives up the call
        jp      c,abort
ENDIF
        call    expired
        jr      nc,tx_wait_poll
        jp      abort
tx_wait_done:
        pop     de
        pop     hl
        ret

; Send A. Keeps BC, DE, HL.
putc:
        push    af
        call    tx_wait
        pop     af
        out     (PORTA),a
        ret

; The next byte from the ESP32 into A. Keeps BC, DE, HL.
getc:
        in      a,(PORTC)
        and     PC_IBF
        jr      nz,getc_take
        push    hl
        push    de
        ld      hl,(TICKS)
        ld      (t0),hl
getc_poll:
        in      a,(PORTC)
        and     PC_IBF
        jr      nz,getc_ready
IFDEF FUJI_POLL
        call    fuji_poll
        jp      c,abort
ENDIF
        call    expired
        jr      nc,getc_poll
        jp      abort
getc_ready:
        pop     de
        pop     hl
getc_take:
        in      a,(PORTA)
        ret

IFDEF FUJI_DRAIN
; After a call given up part way, the ESP32 may still be sending its reply:
; take bytes until none has come for 100 ms (and at most 2048, in case a
; missing card reads as an endless stream)
DRAIN_QUIET     equ     50

drain:
        xor     a
        ld      (bus_dirty),a
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ld      hl,DRAIN_QUIET
        ld      (tlimit),hl
        ld      bc,2048
drain_restart:
        ld      hl,(TICKS)
        ld      (t0),hl
drain_poll:
        in      a,(PORTC)
        and     PC_IBF
        jr      z,drain_idle
        in      a,(PORTA)
        dec     bc
        ld      a,b
        or      c
        ret     z
        jr      drain_restart
drain_idle:
        call    expired
        jr      nc,drain_poll
        ret
ENDIF
