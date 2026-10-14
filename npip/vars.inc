;-----------------------------------------------------------------------------
; NPIP's data. Include it last: npip_end follows it.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

cmd_sp:         defw    0       ; SP in command, for fail
card_ok:        defb    0       ; the card's been found
poll_tick:      defb    0       ; the tick fuji_poll last looked in

; A command's state, cleared as it starts (dst_kind's 0 is K_DISK)
state:
src_spec:       defw    0       ; the source as typed
dst_spec:       defw    0       ; the destination: as typed, or dspec
src_name:       defw    0       ; the source's name: the last part of it
src_url:        defb    0       ; 1: the source is a URL
dst_url:        defb    0
dst_kind:       defb    0       ; K_DISK, K_CON or K_DEV
dst_http:       defb    0       ; 1: the destination is HTTP
src_state:      defb    0       ; 0 closed, 1 open (or opening) on N1, 2 local
dst_state:      defb    0       ; 0 closed, 1 open on N2, 2 local, 3 opening
dir_state:      defb    0       ; 1: N3 open for the source's size
src_eof:        defb    0       ; STATUS said the end
credit:         defw    0       ; bytes STATUS said are waiting, not read yet
ocount:         defw    0       ; bytes in obuf
brk:            defb    0       ; ^C, seen in fuji_poll
cleaning:       defb    0       ; in cleanup: no ^C
bus_dead:       defb    0       ; a call had no answer
last_byte:      defb    0       ; the last byte copied
tot_known:      defb    0       ; p_total is the size
prog_on:        defb    0       ; the progress line is wanted
prog_shown:     defb    0       ; one is on the screen, unfinished
p_done:         defs    4       ; bytes copied
p_total:        defs    4       ; of how many
state_end:

wait_t0:        defw    0
last_draw:      defw    0
nstat:          defs    4       ; STATUS: waiting (16 bits), connected, error
lsize:          defs    4       ; os_ropen: the file's size
tmp32:          defs    4
tmp8:           defs    4
bf_t:           defs    4
bf_d:           defs    4
cr_dot:         defw    0
cr_end:         defw    0
numbuf:         defs    11

        include "fujibus-vars.inc"

line:           defs    256     ; the command line
dspec:          defs    256     ; a destination with the source's name added
buf:            defs    SECTOR  ; FujiBus replies, and a local source's data
obuf:           defs    CHUNK   ; a local file's data on its way
                defs    256     ; the stack
stack_top:
npip_end:
