;-----------------------------------------------------------------------------
; FNDISK resident part: FujiNet drive slots as CP/M drives on the H89
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Lives at the top of memory, above the BIOS of a 62K (or smaller) Heath
; CP/M 2.2.04. The loader points the BIOS jump table's disk entries here;
; calls for the BIOS's own drives go straight on to it, calls for a FujiNet
; drive are served over FujiBus.
;
; The images are H17 disks (.h8d): 40 tracks of ten 256-byte sectors, laid
; out as Heath's CP/M lays out a hard-sectored disk, and the FujiNet serves
; them as 512-byte sectors. A CP/M record (128 bytes) is a quarter of one.
;-----------------------------------------------------------------------------

        include "h89.inc"

TICKS           equ     0x000B  ; the Heath BIOS's 2 ms tick counter

        public  res_start, res_end
        public  first_drive
        public  hooks, bios_jumps, bios_seldsk, NHOOKS, do_seldsk
        public  dph_table, DPH_SIZE, DPH_DIRBUF
        public  fuji_call, req_dev, req_cmd, req_desc, req_aux, req_auxn
        public  req_data, req_dlen, rep_dlen, buf


res_start:
        defm    "FNDISK"
        defb    1               ; version

first_drive:
        defb    3               ; CP/M drive number of slot 1 (the loader sets it)

; The loader copies these over the BIOS's HOME..WRITE entries
hooks:
        jp      do_home
        jp      do_seldsk
        jp      do_settrk
        jp      do_setsec
        jp      do_setdma
        jp      do_read
        jp      do_write
NHOOKS  equ     7

; ...and the BIOS's own entries here, so calls pass on with every register
bios_jumps:
bios_home:      jp      0
bios_seldsk:    jp      0
bios_settrk:    jp      0
bios_setsec:    jp      0
bios_setdma:    jp      0
bios_read:      jp      0
bios_write:     jp      0

;-----------------------------------------------------------------------------
; BIOS entries
;-----------------------------------------------------------------------------

do_home:
        ld      hl,0
        ld      (track),hl
        jp      bios_home

; Track, sector and DMA are kept for the FujiNet drives and passed on too:
; BDOS doesn't set them again just because it changes drives.
do_settrk:
        ld      (track),bc
        jp      bios_settrk

do_setsec:
        ld      (sector),bc
        jp      bios_setsec

do_setdma:
        ld      (dma),bc
        jp      bios_setdma

; C = drive, E bit 0 = 0 on the first select since a disk reset
do_seldsk:
        ld      a,c
        ld      (sel_drive),a
        ld      a,(first_drive)
        ld      b,a
        ld      a,c
        sub     b
        jr      c,sel_bios
        cp      NDRIVES
        jr      nc,sel_bios
        ld      (slot),a
        ld      a,1
        ld      (ours),a
        bit     0,e
        jr      nz,sel_dph
        ld      hl,login
        call    run
        or      a
        jr      nz,sel_fail
sel_dph:
        ld      a,(slot)
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; * DPH_SIZE
        ld      l,a
        ld      h,0
        ld      de,dph_table
        add     hl,de
        ret
sel_fail:
        xor     a
        ld      (ours),a
        ; As the BIOS does: don't leave the CCP's default drive on one that
        ; can't be selected, or every warm boot would fail on it again
        ld      a,(sel_drive)
        ld      c,a
        ld      a,(4)
        and     0x0F
        cp      c
        jr      nz,sel_none
        ld      a,(4)
        and     0xF0
        ld      (4),a
sel_none:
        ld      hl,0
        ret
sel_bios:
        xor     a
        ld      (ours),a
        jp      bios_seldsk

do_read:
        ld      a,(ours)
        or      a
        jp      z,bios_read
        ld      hl,read_record
        jr      run

do_write:
        ld      a,(ours)
        or      a
        jp      z,bios_write
        ld      hl,write_record
        ; fall into run

; Call (HL) on the driver's own stack (BDOS's is small); A comes back
run:
        ld      (caller_sp),sp
        ld      sp,stack_top
        call    jp_hl
        ld      sp,(caller_sp)
        ret
jp_hl:
        jp      (hl)

        include "login.inc"

;-----------------------------------------------------------------------------
; Records
;
; SECTRAN gave a 1-based record through Heath's table; record r of track t
; is half (r-1) AND 1 of H17 sector L = t*10 + (r-1)/2, and H17 sector L is
; half L AND 1 of FujiNet sector L/2.
;-----------------------------------------------------------------------------

locate:
        ld      a,(sector)
        dec     a
        ld      c,a             ; record in the track, from 0
        ld      hl,(track)
        add     hl,hl
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl
        add     hl,de           ; track * 10
        ld      a,c
        srl     a
        ld      e,a
        ld      d,0
        add     hl,de           ; L
        ld      a,l
        and     1
        ld      (offset+1),a    ; 256 for the second H17 sector of the pair
        ld      a,c
        and     1
        rrca
        ld      (offset),a      ; 128 for the second record of the sector
        srl     h
        rr      l
        ld      (lba),hl
        ret

        include "sector.inc"

read_record:
        call    locate
        call    load_sector
        jr      nz,record_error
        ld      hl,(offset)
        ld      de,buf
        add     hl,de
        ld      de,(dma)
        ld      bc,128
        ldir
        xor     a
        ret

; Write-through: the record goes into its sector, and the sector out at once
write_record:
        call    locate
        call    load_sector
        jr      nz,record_error
        ld      hl,(offset)
        ld      de,buf
        add     hl,de
        ex      de,hl
        ld      hl,(dma)
        ld      bc,128
        ldir
        ld      a,CMD_WRITE
        call    disk_request
        ld      hl,buf
        ld      (req_data),hl
        ld      hl,SECTOR
        ld      (req_dlen),hl
        ld      hl,0
        ld      (rep_dlen),hl
        call    fuji_call
        jr      nz,write_failed
        xor     a
        ret
write_failed:
        ld      a,0xFF          ; buf no longer matches the disk
        ld      (cache_slot),a
record_error:
        ld      a,1
        ret

        include "fujibus.inc"

;-----------------------------------------------------------------------------
; Disks: Heath's H17 format, the same for every slot
;-----------------------------------------------------------------------------

dpb:
        defw    20              ; SPT: 128-byte records a track
        defb    3, 7, 0         ; BSH, BLM, EXM: 1K blocks
        defw    91              ; DSM: 92 blocks
        defw    63              ; DRM: 64 directory entries
        defb    0xC0, 0         ; AL0, AL1: the directory's 2 blocks
        defw    16              ; CKS: removable, so check the directory
        defw    3               ; OFF: 3 system tracks

; Heath's sector translation (1-based records; pairs keep a sector together)
xlt:
        defb    1, 2, 9, 10, 17, 18, 5, 6, 13, 14
        defb    3, 4, 11, 12, 19, 20, 7, 8, 15, 16

; XLT, 3 words for BDOS, DIRBUF (the BIOS's, set by the loader), DPB, CSV, ALV
DPH_SIZE        equ     16
DPH_DIRBUF      equ     8
dph_table:
        defw    xlt, 0, 0, 0, 0, dpb, csv + 0 * 16, alv + 0 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 1 * 16, alv + 1 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 2 * 16, alv + 2 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 3 * 16, alv + 3 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 4 * 16, alv + 4 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 5 * 16, alv + 5 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 6 * 16, alv + 6 * 12
        defw    xlt, 0, 0, 0, 0, dpb, csv + 7 * 16, alv + 7 * 12

;-----------------------------------------------------------------------------
; State
;-----------------------------------------------------------------------------

ours:           defb    0       ; a FujiNet drive is selected
slot:           defb    0       ; ...this one, from 0
sel_drive:      defb    0
track:          defw    0
sector:         defw    0
dma:            defw    0x80
lba:            defw    0
offset:         defw    0
cache_slot:     defb    0xFF    ; slot whose sector cache_lba is in buf; FF = none
cache_lba:      defw    0

        include "fujibus-vars.inc"
caller_sp:      defw    0

alv:            defs    NDRIVES * 12
csv:            defs    NDRIVES * 16
buf:            defs    SECTOR
                defs    64
stack_top:

res_end:
