;-----------------------------------------------------------------------------
; Have the FujiNet mount the images in its slots. After it starts it knows
; them but has mounted none, and login (login.inc) skips a slot that isn't
; mounted. Z on success; NZ if some slot wouldn't mount (the others did).
;
; Uses fuji_call.
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

mount_call:
        ld      a,DEV_FUJI
        ld      (req_dev),a
        ld      a,CMD_MOUNT_ALL
        ld      (req_cmd),a
        xor     a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      hl,0
        ld      (req_dlen),hl
        ld      (rep_dlen),hl
        jp      fuji_call
