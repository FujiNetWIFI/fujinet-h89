;-----------------------------------------------------------------------------
; Set up the H89-ESP32 card's 82C55 and face it toward us, as fujinet-lib's
; port_init does. The ESP32 doesn't see the mode word (EN isn't wired), so
; every program sends it.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

card_on:
        ld      a,0xC2          ; port A mode 2, port B an input
        out     (PCTRL),a
        in      a,(PORTA)       ; drop anything latched before
        ld      a,OE_ON
        out     (PCTRL),a
        ld      a,DIR_TO_H89
        out     (PCTRL),a
        ret

; Is the card there and facing us? Z if so. Without a card the ports read
; FF, and every wait for a byte would see one at once, forever.
card_present:
        in      a,(PORTC)
        and     0x03            ; /OE, DIR
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
