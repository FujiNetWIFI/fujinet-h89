;-----------------------------------------------------------------------------
; The FujiNet sector cache
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Uses slot, lba, cache_slot, cache_lba, buf and fuji_call.
;-----------------------------------------------------------------------------

; Have FujiNet sector (lba) of the slot in buf. Z when it's there.
load_sector:
        ld      a,(cache_slot)
        ld      b,a
        ld      a,(slot)
        cp      b
        jr      nz,load_miss
        ld      hl,(cache_lba)
        ld      de,(lba)
        or      a
        sbc     hl,de
        ret     z
load_miss:
        ld      a,0xFF
        ld      (cache_slot),a
        ld      a,CMD_READ
        call    disk_request
        ld      hl,0
        ld      (req_dlen),hl
        ld      hl,SECTOR
        ld      (rep_dlen),hl
        call    fuji_call
        ret     nz
        ld      a,(slot)
        ld      (cache_slot),a
        ld      hl,(lba)
        ld      (cache_lba),hl
        xor     a
        ret

; A request for the slot's disk device: command A, sector (lba)
disk_request:
        ld      (req_cmd),a
        ld      a,(slot)
        add     a,DEV_DISK
        ld      (req_dev),a
        ld      a,FIELDS_U16
        ld      (req_desc),a
        ld      a,2
        ld      (req_auxn),a
        ld      hl,(lba)
        ld      (req_aux),hl
        ret
