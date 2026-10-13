;-----------------------------------------------------------------------------
; Start the H89-ESP32 card if nothing has yet (as FNON does), and face it
; toward us. Uses TICKS.
;
; The mark in port B and EN high mean something set the card up and nothing
; has reset the 82C55 since. EN alone can't tell: after a reset the 82C55's
; bus hold can pull PC2 high while port A isn't in mode 2.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

card_on:
        in      a,(PORTB)
        cp      SETUP_MARK
        jr      nz,card_start
        in      a,(PORTC)
        and     PC_EN
        jr      nz,card_ready
card_start:
        ld      a,0xC0          ; port A mode 2, PC0-PC2 outputs (EN goes low)
        out     (PCTRL),a
        ld      a,0x06          ; EN=1, IO0=1 at once: a running ESP32 stays up
        out     (PORTC),a
        ld      b,100           ; about 200 ms with IO0 high, while a starting
card_wait:                      ; ESP32 reads its straps
        call    tick
        djnz    card_wait
        ld      a,SETUP_MARK
        out     (PORTB),a
card_ready:
        in      a,(PORTA)       ; drop anything latched while it started
        ld      a,OE_ON
        out     (PCTRL),a
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ret

; Is the card there, running and facing us? Z if so. Without a card the
; ports read FF, and every wait for a byte would see one at once, forever.
card_present:
        in      a,(PORTC)
        and     0x07            ; EN, /OE, DIR
        cp      PC_EN
        ret

; Wait for the next 2 ms tick
tick:
        ld      a,(TICKS)
        ld      c,a
tick_wait:
        ld      a,(TICKS)
        cp      c
        jr      z,tick_wait
        ret
