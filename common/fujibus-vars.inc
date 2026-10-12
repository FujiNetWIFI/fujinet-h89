;-----------------------------------------------------------------------------
; FujiBus request and reply state
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

; The request as it goes out: header, then the aux bytes
req_dev:        defb    0
req_cmd:        defb    0
req_len:        defw    0
req_cks:        defb    0
req_desc:       defb    0
req_aux:        defw    0
req_auxn:       defb    0       ; how many aux bytes
req_data:       defw    0       ; data sent after them
req_dlen:       defw    0
rep_dlen:       defw    0       ; data expected back, into buf
rep_hdr:        defs    6
rx_count:       defw    0
rx_cks:         defb    0
t0:             defw    0
tlimit:         defw    0
abort_sp:       defw    0
IFDEF FUJI_DRAIN
bus_dirty:      defb    0       ; a call was given up before its reply ended
ENDIF
