;-----------------------------------------------------------------------------
; NPIP: the FujiNet's network units (N1-N8, 71H-78H) over FujiBus
;
; Each call is Z on an ACK. On anything else NZ; bus_dead is set if nothing
; answered (and what came of a reply given up on is drained at once, so a
; disk driver's next call starts clean); a NAK leaves REPLY_NAK in
; rep_hdr+1, and net_why asks STATUS for the reason. ^C during a call ends
; NPIP (stop).
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

; A = unit, B = mode, HL -> the URL: OPEN it, no translation
net_open:
        ld      c,CMD_OPEN
        jr      net_spec

; The same, a directory as bare names (translation DIR_RAW)
net_open_raw:
        push    af
        ld      a,DIR_RAW
        ld      (open_xl),a
        pop     af
        jr      net_open

; A = unit, B = command (CMD_DELETE, CMD_LOCK), HL -> the URL
net_fsop:
        ld      c,b
        ld      b,MODE_WRITE    ; (a mode a file system takes)
; A = unit, C = command, B = its first field, HL -> the URL, sent with its NUL
net_spec:
        ld      (req_dev),a
        ld      a,c
        ld      (req_cmd),a
        ld      a,FIELDS_2U8
        ld      (req_desc),a
        ld      a,b
        ld      (req_aux),a
        ld      a,(open_xl)
        ld      (req_aux+1),a
        xor     a
        ld      (open_xl),a
        ld      a,2
        ld      (req_auxn),a
        ld      (req_data),hl
        call    strlen
        inc     bc
        ld      (req_dlen),bc
        ld      hl,0
        ld      (rep_dlen),hl
        jr      net_go

; A = unit: its STATUS into nstat (waiting, 16 bits; connected; error)
net_status:
        ld      c,CMD_STATUS
        ld      hl,4
        call    net_bare
        ret     nz
        ld      hl,(rep_got)
        ld      de,-4
        add     hl,de
        ld      a,h
        or      l
        ret     nz              ; not all four
        ld      hl,(buf)
        ld      (nstat),hl
        ld      hl,(buf+2)
        ld      (nstat+2),hl
        xor     a
        ret

; A = unit: CLOSE it
net_close:
        ld      c,CMD_CLOSE
        ld      hl,0
; A = unit, C = command, HL = reply bytes wanted; no fields, no data
net_bare:
        ld      (req_dev),a
        ld      a,c
        ld      (req_cmd),a
        xor     a
        ld      (req_desc),a
        ld      (req_auxn),a
        ld      (rep_dlen),hl
        ld      hl,0
        ld      (req_dlen),hl
        jr      net_go

; A = unit, HL = how many: READ up to that many into buf; BC = how many came
net_read:
        ld      (req_aux),hl
        ld      (rep_dlen),hl
        ld      hl,0
        ld      (req_dlen),hl
        ld      c,CMD_READ
        call    net_u16
        ld      bc,(rep_got)
        ret

; A = unit, HL -> BC bytes: WRITE them
net_write:
        ld      (req_aux),bc
        ld      (req_data),hl
        ld      (req_dlen),bc
        ld      hl,0
        ld      (rep_dlen),hl
        ld      c,CMD_WRITE
; A = unit, C = command, its one 16-bit field in req_aux
net_u16:
        ld      (req_dev),a
        ld      a,c
        ld      (req_cmd),a
        ld      a,FIELDS_U16
        ld      (req_desc),a
        ld      a,2
        ld      (req_auxn),a
; fuji_call, with ^C live
net_go:
        xor     a
        ld      (rep_hdr+1),a
        call    fuji_call
        ret     z
        ld      a,(brk)
        or      a
        jp      nz,stop
        ld      a,(bus_dirty)   ; given up on: no answer
        or      a
        jr      z,net_failed
        call    drain
        ld      a,1
        ld      (bus_dead),a
net_failed:
        or      1
        ret

; After a call on unit A failed: A = the FujiNet's reason, or 0 if it
; didn't answer (or answered nonsense)
net_why:
        ld      c,a
        ld      a,(bus_dead)
        or      a
        jr      nz,net_why_none
        ld      a,(rep_hdr+1)
        cp      REPLY_NAK
        jr      nz,net_why_none
        ld      a,c
        call    net_status
        jr      nz,net_why_none
        ld      a,(nstat+3)
        ret
net_why_none:
        xor     a
        ret

; Inside fuji_call's waits (keeps BC): carry gives up the call, on ^C.
; Looks once a tick at most; not while cleaning up.
fuji_poll:
        ld      a,(cleaning)
        or      a
        ret     nz
        push    hl
        ld      hl,poll_tick
        ld      a,(TICKS)
        cp      (hl)
        ld      (hl),a
        pop     hl
        ret     z
        call    os_break
        ret     nc
        ld      a,1
        ld      (brk),a
        scf
        ret

;-----------------------------------------------------------------------------
; The size of a network source, for the bar
;-----------------------------------------------------------------------------

; From the first STATUS: what's waiting is the whole file if it's under
; 65534 (a file system's) or 65535 (HTTP's Content-Length); for a larger
; file that isn't HTTP, the size the directory's listing gives
net_size:
        ld      hl,(credit)
        ld      a,(src_eof)
        or      a
        jr      nz,ns_known     ; nothing in it
        ld      de,65534
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,ns_known
        ld      hl,(src_spec)
        call    is_http
        or      a
        ret     nz
        jr      dir_size
ns_known:
        ld      (p_total),hl
        ld      hl,0
        ld      (p_total+2),hl
        ld      a,1
        ld      (tot_known),a
        ret

; The source's line in its directory, on N3: the same URL, opened as a
; directory, lists just that file. Columns 13-22 of the line are its size.
; If any of it fails, the size isn't known.
dir_size:
        ld      a,1             ; (first: a ^C during OPEN still closes it)
        ld      (dir_state),a
        ld      a,UNIT_DIR
        ld      b,MODE_DIR
        ld      hl,(src_spec)
        call    net_open
        jr      nz,ds_close
        ld      a,UNIT_DIR
        call    net_status
        jr      nz,ds_close
        ld      hl,(nstat)
        ld      a,h
        or      l
        jr      z,ds_close
        ld      de,LIST_MAX
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,ds_read
        ex      de,hl
ds_read:
        ld      a,UNIT_DIR
        call    net_read
        jr      nz,ds_close
        ld      hl,22           ; to column 22 at least
        or      a
        sbc     hl,bc
        jr      nc,ds_close
        ld      hl,0
        ld      (p_total),hl
        ld      (p_total+2),hl
        ld      hl,buf + 13
        ld      b,10
ds_space:
        ld      a,(hl)
        cp      ' '
        jr      nz,ds_digits
        inc     hl
        djnz    ds_space
        jr      ds_close
ds_digits:
        ld      c,b             ; columns left before the digits
ds_digit:
        ld      a,(hl)
        sub     '0'
        cp      10
        jr      nc,ds_end
        push    hl
        push    bc
        call    total_digit
        pop     bc
        pop     hl
        inc     hl
        djnz    ds_digit
ds_end:
        ld      a,b             ; digits came: then a space (column 23 is)
        cp      c
        jr      z,ds_close
        ld      a,(hl)
        cp      ' '
        jr      nz,ds_close
        ld      a,1
        ld      (tot_known),a
ds_close:
        xor     a
        ld      (dir_state),a
        ld      a,(bus_dead)
        or      a
        ret     nz
        ld      a,UNIT_DIR
        jp      net_close

; p_total = p_total * 10 + A
total_digit:
        push    af
        ld      hl,p_total
        ld      de,tmp32
        ld      bc,4
        ldir
        call    total_x2
        call    total_x2
        ld      hl,p_total      ; x 5
        ld      de,tmp32
        ld      b,4
        or      a
td_add:
        ld      a,(de)
        adc     a,(hl)
        ld      (hl),a
        inc     hl
        inc     de
        djnz    td_add
        call    total_x2        ; x 10
        pop     af
        ld      hl,p_total
        add     a,(hl)
        ld      (hl),a
        ret     nc
        ld      b,3
td_carry:
        inc     hl
        inc     (hl)
        ret     nz
        djnz    td_carry
        ret
total_x2:
        ld      hl,p_total
        sla     (hl)
        inc     hl
        rl      (hl)
        inc     hl
        rl      (hl)
        inc     hl
        rl      (hl)
        ret

;-----------------------------------------------------------------------------
; The files a URL with a * names
;-----------------------------------------------------------------------------

; The source URL opened as a directory on N4, in bare names, a line each.
; Each line that doesn't end in / (a directory) goes to list_add.
url_list:
        ld      a,1             ; (first: a ^C during OPEN still closes it)
        ld      (list_state),a
        ld      hl,(TICKS)
        ld      (wait_t0),hl
        ld      a,UNIT_LIST
        ld      b,MODE_DIR
        ld      hl,(src_spec)
        call    net_open_raw
        jr      nz,ul_fail
ul_next:
        ld      a,UNIT_LIST
        call    net_status
        jr      nz,ul_fail
        ld      hl,(nstat)
        ld      a,h
        or      l
        jr      z,ul_none
        ld      de,CHUNK        ; a CHUNK at most
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,ul_ask
        ex      de,hl
ul_ask:
        ld      a,UNIT_LIST
        call    net_read
        jr      nz,ul_refused
        ld      hl,(TICKS)
        ld      (wait_t0),hl
        ld      hl,buf
        call    ul_parse
        jr      ul_next
ul_none:
        ld      a,(nstat+3)
        cp      ERR_EOF
        jr      z,ul_end
        cp      2               ; 1 is all well
        jr      nc,ul_fail_a
        ld      a,(nstat+2)     ; gone, with nothing left: the end too
        or      a
        jr      z,ul_end
        call    wait_more
        jr      ul_next
ul_refused:
        ld      a,UNIT_LIST     ; refused: at the end, or an error
        call    net_why
        cp      ERR_EOF
        jr      z,ul_end
ul_fail_a:
        jp      fail_src_neta
ul_fail:
        ld      a,UNIT_LIST
        call    net_why
        jp      fail_src_neta
ul_end:
        ld      hl,lname        ; (a last line with no ending)
        call    ul_line
        xor     a
        ld      (list_state),a
        ld      a,(bus_dead)
        or      a
        ret     nz
        ld      a,UNIT_LIST
        jp      net_close

; HL -> BC bytes of the listing: lines into lname, each to ul_line at its end
ul_parse:
        ld      a,b
        or      c
        ret     z
        ld      a,(hl)
        inc     hl
        dec     bc
        cp      13
        jr      z,up_eol
        cp      10
        jr      z,up_eol
        push    hl
        push    bc
        call    ul_char
        pop     bc
        pop     hl
        jr      ul_parse
up_eol:
        push    hl
        push    bc
        call    ul_line
        pop     bc
        pop     hl
        jr      ul_parse

; A to the line so far. A line too long for lname is marked, and left out.
ul_char:
        ld      c,a
        ld      a,(ln_len)
        cp      LN_MAX
        jr      nc,uc_over
        ld      e,a
        ld      d,0
        ld      hl,lname
        add     hl,de
        ld      (hl),c
        inc     a
        ld      (ln_len),a
        ret
uc_over:
        ld      a,LN_MAX + 1
        ld      (ln_len),a
        ret

; The line is whole: a name, unless it's a directory (a / at its end)
ul_line:
        ld      a,(ln_len)
        or      a
        ret     z
        ld      c,a
        xor     a
        ld      (ln_len),a
        ld      a,c
        cp      LN_MAX + 1
        ret     nc              ; too long
        ld      e,c
        ld      d,0
        ld      hl,lname
        add     hl,de
        dec     hl
        ld      a,(hl)
        cp      '/'
        ret     z
        inc     hl
        ld      (hl),0
        ld      hl,lname
        jp      list_add
