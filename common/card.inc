;-----------------------------------------------------------------------------
; Set up the H89-ESP32 card's 82C55, as fujinet-lib's port_init does. The
; ESP32 doesn't see the mode word (EN isn't wired), so every program sends
; it. Port A runs straight to the ESP32, which drives it through /ACK, so
; there is no direction to set.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

card_on:
        ld      a,0xC2          ; port A mode 2, port B an input
        out     (PCTRL),a
        in      a,(PORTA)       ; drop anything latched before
        ret

; Is the card there? Z if so: PC0 and PC1 read back the zeros the mode word
; left in them. Without a card the ports read FF, and every wait for a byte
; would see one at once, forever.
card_present:
        in      a,(PORTC)
        and     0x03            ; PC1, PC0
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
