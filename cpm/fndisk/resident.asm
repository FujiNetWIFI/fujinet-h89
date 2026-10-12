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

        public  res_start, res_end
        public  first_drive
        public  hooks, bios_jumps, bios_seldsk, NHOOKS, do_seldsk
        public  dph_table, DPH_SIZE, DPH_DIRBUF
        public  fuji_call, req_dev, req_cmd, req_desc, req_aux, req_auxn
        public  req_data, req_dlen, rep_dlen, buf

TX_TIMEOUT      equ     500     ; 1 s for the ESP32 to take a byte
RX_FIRST        equ     7500    ; 15 s for the reply to start (TNFS can be slow)
RX_TIMEOUT      equ     500     ; 1 s between reply bytes

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

;-----------------------------------------------------------------------------
; Login: only a slot the FujiNet has mounted, holding an H17 image, is a
; drive. That keeps CP/M off the FujiNet's own boot image and off slots
; CONFIG has emptied. Returns A = 0 when the drive can be used.
;-----------------------------------------------------------------------------

login:
        ld      a,0xFF
        ld      (cache_slot),a  ; buf is used below

        ld      a,DEV_FUJI
        ld      (req_dev),a
        ld      a,CMD_DEVICE_SLOTS
        ld      (req_cmd),a
        xor     a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      hl,0
        ld      (req_dlen),hl
        ld      hl,SLOTS_SIZE
        ld      (rep_dlen),hl
        call    fuji_call
        ret     nz

        ld      hl,buf+1        ; the mode byte of slot 0's entry
        ld      de,SLOT_SIZE
        ld      a,(slot)
login_entry:
        or      a
        jr      z,login_mode
        add     hl,de
        dec     a
        jr      login_entry
login_mode:
        ld      a,(hl)
        and     MODE_MOUNTED
        jr      z,login_no

        ld      a,CMD_DEVICE_PATH
        ld      (req_cmd),a
        ld      a,FIELDS_U8
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      a,(slot)
        ld      (req_aux),a
        ld      hl,256
        ld      (rep_dlen),hl
        call    fuji_call
        ret     nz

        ld      hl,buf
        ld      bc,256
        xor     a
        cpir                    ; to just past the name's NUL
        jr      nz,login_no
        dec     hl
        ld      de,buf+4
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,login_no      ; shorter than ".h8d"
        dec     hl
        ld      a,(hl)
        and     0xDF
        cp      'D'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        cp      '8'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        and     0xDF
        cp      'H'
        jr      nz,login_no
        dec     hl
        ld      a,(hl)
        cp      '.'
        jr      nz,login_no
        xor     a
        ret
login_no:
        ld      a,1
        or      a
        ret

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

;-----------------------------------------------------------------------------
; FujiBus
;
; fuji_call sends the request in req_* (and req_dlen bytes from req_data),
; then takes the reply: its header into rep_hdr, up to rep_dlen bytes of data
; into buf. Z and A = 0 on an ACK of exactly rep_dlen bytes with a good
; checksum; NZ otherwise, after a timeout too. The whole reply is always
; read, to its closing END, so the next request starts clean.
;-----------------------------------------------------------------------------

fuji_call:
        ld      (abort_sp),sp

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
        ld      de,(rep_dlen)
        or      a
        sbc     hl,de
        jr      nz,rx_bad
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
        ld      bc,(rep_dlen)
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
        call    expired
        jr      nc,getc_poll
        jp      abort
getc_ready:
        pop     de
        pop     hl
getc_take:
        in      a,(PORTA)
        ret

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
caller_sp:      defw    0

alv:            defs    NDRIVES * 12
csv:            defs    NDRIVES * 16
buf:            defs    SECTOR
                defs    64
stack_top:

res_end:
