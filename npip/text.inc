;-----------------------------------------------------------------------------
; NPIP: what it says
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

; A = the FujiNet's error (0: it didn't answer): say what it is
net_errmsg:
        ld      c,a
        or      a
        ld      hl,t_noanswer
        jp      z,print
        ld      hl,net_errors
ne_find:
        ld      a,(hl)
        inc     hl
        or      a
        jr      z,ne_number
        cp      c
        jp      z,print
ne_skip:
        ld      a,(hl)
        inc     hl
        or      a
        jr      nz,ne_skip
        jr      ne_find
ne_number:
        push    bc
        ld      hl,t_error
        call    print
        pop     bc
        ld      a,c
        jp      pdec8

; The FujiNet's errors (its STATUS's last byte): the code, then the text
net_errors:
        defb    136
        defm    "end of file", 0
        defb    138
        defm    "timed out", 0
        defb    144
        defm    "failed", 0
        defb    146
        defm    "not supported", 0
        defb    151
        defm    "already there", 0
        defb    162
        defm    "no space", 0
        defb    165
        defm    "bad URL", 0
        defb    167
        defm    "access denied", 0
        defb    170
        defm    "not found", 0
        defb    200
        defm    "connection refused", 0
        defb    201
        defm    "network unreachable", 0
        defb    202
        defm    "timed out", 0
        defb    203
        defm    "network down", 0
        defb    204
        defm    "connection reset", 0
        defb    207
        defm    "not connected", 0
        defb    208
        defm    "server not running", 0
        defb    211
        defm    "connection aborted", 0
        defb    212
        defm    "bad user name or password", 0
        defb    214
        defm    "refused by the server", 0
        defb    215
        defm    "server error", 0
        defb    0

t_noanswer:     defm    "the FujiNet isn't answering", 0
t_error:        defm    "error ", 0
t_dash:         defm    " - ", 0
t_ctlc:         defm    "^C", 0
t_stopped:      defm    "Stopped.", 0
t_nocard:       defm    "No FujiNet card at 0D0H.", 0
t_wild:         defm    "no wildcards", 0
t_urlstar:      defm    "a URL can't have * in it", 0
t_baddev:       defm    "no such device", 0
t_devsrc:       defm    "can't read from a device", 0
t_nosrc:        defm    "name the file", 0
t_nodst:        defm    "name the destination", 0
t_toolong:      defm    "too long", 0
t_nothing:      defm    "nothing came for 30 seconds", 0
t_http:         defm    "HTTP"
t_barend:       defm    "] ", 0
t_unknown:      defm    "/?", 0
t_eol:          defb    27, 'K', 0      ; H19: erase to the end of the line
