;-----------------------------------------------------------------------------
; NPIP's core: PIP's dest=source, each side a local file or device or a
; FujiNet URL. Each system's NPIP includes it after its own part, which
; defines TICKS, OS_UNIT (its files grow by this much: 128 or 256), OS_PAD
; (what fills out the last one), K_DISK, K_CON, K_DEV and the os_ routines:
;
;   os_conout   A out. Keeps BC, DE, HL.
;   os_crlf     CR LF. Keeps BC, DE, HL.
;   os_getkey   waits; A = the key; carry if ^C. Keeps BC, DE, HL.
;   os_break    carry if ^C was typed; never waits; drops other keys.
;               Keeps BC, DE, HL.
;   os_exit     back to the system
;   os_kind     HL -> a local spec: A = K_DISK, K_CON or K_DEV; carry if
;               it's no device the system has
;   os_ropen    HL -> a file: opens it to read; lsize = its size, A = 0 if
;               that's known. Carry: A = the system's error.
;   os_read     DE -> 512 bytes: BC = bytes read into it, 0 at the end, a
;               multiple of OS_UNIT. Carry: A = the system's error.
;   os_rclose
;   os_wopen    HL -> a file or device, A = its kind: opens it to write.
;   os_write    HL -> BC bytes, a multiple of OS_UNIT for a K_DISK. A = 1
;               if a device found the end of the text (^Z) in them.
;   os_wclose   the copy is whole: close it. Carry: A = the system's error.
;   os_wabort   the copy is not: close it and take it away
;   os_errmsg   A = a system error: say what it is
;
; Copyright (C) 2026 Thomas Cherryhomes
; SPDX-License-Identifier: GPL-3.0-or-later
;-----------------------------------------------------------------------------

        DEFINE  FUJI_POLL               ; ^C can cut a wait short
        DEFINE  FUJI_DRAIN              ; a call given up is drained after
        DEFINE  FUJI_SHORT              ; a network READ gets what is there

LINE_MAX        equ     254     ; characters at the * prompt
CHUNK           equ     512     ; bytes moved at once
UNIT_SRC        equ     DEV_NETWORK     ; N1: a network source
UNIT_DST        equ     DEV_NETWORK + 1 ; N2: a network destination
UNIT_DIR        equ     DEV_NETWORK + 2 ; N3: its directory, for the size
MODE_READ       equ     4
MODE_DIR        equ     6
MODE_WRITE      equ     8
ERR_EOF         equ     136     ; STATUS: the end of the data
WAIT_TICKS      equ     15000   ; 30 s with nothing coming: give up
LIST_MAX        equ     64      ; bytes of the directory's listing read

;-----------------------------------------------------------------------------
; HL -> the command line's arguments, NUL-terminated, in line. With some,
; do them and leave; with none, a * prompt until an empty line or ^C.
;-----------------------------------------------------------------------------

npip_main:
        call    skip_sp
        or      a
        jr      z,prompt
        call    command
        jp      os_exit

prompt:
        ld      a,'*'
        call    os_conout
        call    getline
        jr      c,prompt_ctlc
        ld      hl,line
        call    skip_sp
        or      a
        jp      z,os_exit
        call    command
        jr      prompt
prompt_ctlc:
        ld      hl,t_ctlc
        call    print
        call    os_crlf
        jp      os_exit

; A line into line, echoed. Carry if ^C ended it.
getline:
        ld      hl,line
        ld      b,0
gl_key:
        call    os_getkey
        ret     c
        cp      13
        jr      z,gl_done
        cp      10
        jr      z,gl_done
        cp      8
        jr      z,gl_rub
        cp      127
        jr      z,gl_rub
        cp      21              ; ^U
        jr      z,gl_kill
        cp      24              ; ^X
        jr      z,gl_kill
        cp      ' '
        jr      c,gl_key
        ld      c,a
        ld      a,b
        cp      LINE_MAX
        jr      nc,gl_full
        ld      (hl),c
        inc     hl
        inc     b
        ld      a,c
        call    os_conout
        jr      gl_key
gl_full:
        ld      a,7
        call    os_conout
        jr      gl_key
gl_rub:
        call    gl_back
        jr      gl_key
gl_kill:
        ld      a,b
        or      a
        jr      z,gl_key
        call    gl_back
        jr      gl_kill
gl_back:
        ld      a,b
        or      a
        ret     z
        dec     hl
        dec     b
        ld      a,8
        call    os_conout
        ld      a,' '
        call    os_conout
        ld      a,8
        jp      os_conout
gl_done:
        ld      (hl),0
        call    os_crlf
        or      a
        ret

;-----------------------------------------------------------------------------
; One copy: dest=source at HL. Returns when it's done, or when it has said
; why it couldn't be (fail returns from here, whatever the depth).
;-----------------------------------------------------------------------------

command:
        ld      (cmd_sp),sp
        push    hl
        ld      hl,state
        ld      b,state_end - state
        xor     a
cmd_clear:
        ld      (hl),a
        inc     hl
        djnz    cmd_clear
        pop     hl

        ; dest=source
        ld      (dst_spec),hl
cmd_eq:
        ld      a,(hl)
        or      a
        jp      z,usage
        cp      '='
        jr      z,cmd_split
        inc     hl
        jr      cmd_eq
cmd_split:
        ld      (hl),0
        inc     hl
        call    skip_sp
        ld      (src_spec),hl
        call    trim
        ld      hl,(dst_spec)
        call    trim
        ld      hl,(dst_spec)
        ld      a,(hl)
        or      a
        jp      z,usage
        ld      hl,(src_spec)
        ld      a,(hl)
        or      a
        jp      z,usage

        ; The source: a URL, or a file
        call    is_url
        ld      (src_url),a
        or      a
        jr      nz,cmd_src_url
        ld      hl,(src_spec)
        call    local_check
        ld      hl,(src_spec)
        call    os_kind
        ld      hl,t_baddev
        jp      c,fail_src_at
        cp      K_DISK
        ld      hl,t_devsrc
        jp      nz,fail_src_at
        ld      hl,(src_spec)
        call    local_name
        ld      (src_name),hl
        ld      a,(hl)
        or      a
        ld      hl,t_nosrc
        jp      z,fail_src_at
        ld      hl,(src_spec)
        call    os_ropen
        jp      c,fail_src_os
        push    af
        ld      a,2
        ld      (src_state),a
        pop     af
        or      a
        jr      nz,cmd_dst      ; its size unknown
        ld      hl,lsize
        ld      de,p_total
        ld      bc,4
        ldir
        ld      a,1
        ld      (tot_known),a
        jr      cmd_dst

cmd_src_url:
        ld      hl,(src_spec)
        call    url_check
        ld      hl,(src_spec)
        call    url_name
        ld      (src_name),hl
        call    need_card
        ld      a,1             ; (first: a ^C during OPEN still closes it)
        ld      (src_state),a
        ld      a,UNIT_SRC
        ld      b,MODE_READ
        ld      hl,(src_spec)
        call    net_open
        jp      nz,fail_src_net
        call    src_fill        ; the first STATUS: what's waiting
        call    net_size        ; and from that, the size

        ; The destination: a URL, or a file or device
cmd_dst:
        ld      hl,(dst_spec)
        call    is_url
        ld      (dst_url),a
        or      a
        jr      nz,cmd_dst_url
        ld      hl,(dst_spec)
        call    local_check
        ld      hl,(dst_spec)
        call    os_kind
        ld      hl,t_baddev
        jp      c,fail_dst_at
        ld      (dst_kind),a
        cp      K_DISK
        jr      nz,cmd_dst_open
        ld      hl,(dst_spec)
        call    local_name
        ld      a,(hl)
        or      a
        call    z,name_local    ; a drive alone: the source's name on it
cmd_dst_open:
        ld      hl,(dst_spec)
        ld      a,(dst_kind)
        call    os_wopen
        jp      c,fail_dst_os
        ld      a,2
        ld      (dst_state),a
        jr      cmd_go

cmd_dst_url:
        ld      hl,(dst_spec)
        call    url_check
        call    name_url        ; a directory or a host: the source's name
        ld      hl,(dst_spec)
        call    is_http
        ld      (dst_http),a
        call    need_card
        ld      a,3             ; opening: a ^C now leaves it unknown
        ld      (dst_state),a
        ld      a,UNIT_DST
        ld      b,MODE_WRITE
        ld      hl,(dst_spec)
        call    net_open
        jr      z,cmd_dst_opened
        ld      a,UNIT_DST      ; refused: nothing to undo
        call    net_why
        push    af
        xor     a
        ld      (dst_state),a
        pop     af
        ld      de,(dst_spec)
        jp      fail_net
cmd_dst_opened:
        ld      a,1
        ld      (dst_state),a

        ; Copy, with the progress line (but not over text on the console)
cmd_go:
        ld      a,(dst_kind)
        cp      K_CON
        ld      a,0
        jr      z,cmd_prog
        inc     a
cmd_prog:
        ld      (prog_on),a
        call    prog_start
cmd_copy:
        call    src_get         ; HL -> BC bytes, none at the end
        ld      a,b
        or      c
        jr      z,cmd_end
        push    hl
        add     hl,bc
        dec     hl
        ld      a,(hl)
        ld      (last_byte),a
        pop     hl
        push    bc
        call    dst_put
        pop     bc
        push    af
        call    prog_add
        pop     af
        or      a               ; a device found the end of the text
        jr      nz,cmd_end
        call    os_break
        jp      c,stop
        jr      cmd_copy
cmd_end:
        call    dst_finish
        call    src_close
        call    prog_end
        ld      a,(dst_kind)    ; text on the console: end its last line
        cp      K_CON
        ret     nz
        ld      a,(last_byte)
        cp      10
        call    nz,os_crlf
        ret

usage:
        ld      hl,os_usage
        call    print
        jp      fail_quiet

;-----------------------------------------------------------------------------
; The source: open in command; read; closed
;-----------------------------------------------------------------------------

; HL -> BC bytes of it; BC = 0 at the end
src_get:
        ld      a,(src_state)
        cp      1
        jr      z,sg_net
        ld      de,buf
        call    os_read
        jp      c,fail_src_os
        ld      hl,buf
        ret
sg_net:
        ld      hl,(credit)     ; what STATUS last said is waiting
        ld      a,h
        or      l
        jr      nz,sg_read
        ld      a,(src_eof)
        or      a
        jr      nz,sg_end
        call    src_fill
        jr      sg_net
sg_read:
        ld      de,CHUNK        ; a CHUNK at most
        or      a
        sbc     hl,de
        add     hl,de
        jr      c,sg_ask
        ex      de,hl
sg_ask:
        ld      a,UNIT_SRC
        call    net_read
        jr      nz,sg_refused
        ld      hl,(credit)
        or      a
        sbc     hl,bc
        jr      nc,sg_credit
        ld      hl,0
sg_credit:
        ld      (credit),hl
        ld      a,b
        or      c
        jr      z,sg_none
        ld      hl,buf
        ret
sg_none:
        ld      hl,0            ; nothing came: ask STATUS again
        ld      (credit),hl
        jr      sg_net
sg_refused:
        ld      a,UNIT_SRC      ; refused: at the end, or an error
        call    net_why
        cp      ERR_EOF
        jp      nz,fail_src_neta
sg_end:
        ld      bc,0
        ret

; STATUS until the source has something waiting (credit), or src_eof at its
; end. Waits up to 30 s for it, with ^C live.
src_fill:
        ld      hl,(TICKS)
        ld      (wait_t0),hl
sf_ask:
        ld      a,UNIT_SRC
        call    net_status
        jp      nz,fail_src_net
        ld      hl,(nstat)
        ld      a,h
        or      l
        jr      z,sf_none
        ld      (credit),hl
        ret
sf_none:
        ld      a,(nstat+3)
        cp      ERR_EOF
        jr      z,sf_eof
        cp      2               ; 1 is all well
        jp      nc,fail_src_neta
        ld      a,(nstat+2)     ; gone, with nothing left: the end too
        or      a
        jr      z,sf_eof
        ld      hl,(TICKS)
        ld      de,(wait_t0)
        or      a
        sbc     hl,de
        ld      de,WAIT_TICKS
        or      a
        sbc     hl,de
        ld      hl,t_nothing
        jp      nc,fail_src_at
        call    pause
        jr      sf_ask
sf_eof:
        ld      a,1
        ld      (src_eof),a
        ret

src_close:
        ld      a,(src_state)
        cp      1
        jr      nz,sc_local
        ld      a,UNIT_SRC
        call    net_close
        jr      sc_done
sc_local:
        or      a
        call    nz,os_rclose
sc_done:
        xor     a
        ld      (src_state),a
        ret

;-----------------------------------------------------------------------------
; The destination: open in command; written; finished
;-----------------------------------------------------------------------------

; HL -> BC bytes for it. A = 1 if a device found the end of the text.
dst_put:
        ld      a,(dst_state)
        cp      1
        jr      z,dp_net
        ld      a,(dst_kind)
        cp      K_DISK
        jr      z,dp_disk
        call    os_write        ; a device, or the console: as they come
        jp      c,fail_dst_os
        ret
dp_net:
        ld      a,UNIT_DST
        call    net_write
        jp      nz,fail_dst_net
        xor     a
        ret

; A file: through obuf, a CHUNK at a time
dp_disk:
        ld      a,b
        or      c
        ret     z
        push    hl
        push    bc
        ld      hl,CHUNK        ; room left in obuf
        ld      de,(ocount)
        or      a
        sbc     hl,de
        pop     bc
        push    bc
        or      a               ; n = the less of the room and BC
        sbc     hl,bc
        add     hl,bc
        jr      c,dp_n
        ld      h,b
        ld      l,c
dp_n:
        ld      b,h
        ld      c,l
        pop     hl              ; what's left after these n
        or      a
        sbc     hl,bc
        ex      (sp),hl         ; (and HL -> them)
        push    bc
        ld      de,(ocount)
        push    hl
        ld      hl,obuf
        add     hl,de
        ex      de,hl
        pop     hl
        ldir
        pop     bc
        push    hl
        ld      hl,(ocount)
        add     hl,bc
        ld      (ocount),hl
        ld      de,CHUNK
        or      a
        sbc     hl,de
        jr      nz,dp_more
        ld      (ocount),hl     ; full: to the file
        ld      hl,obuf
        ld      bc,CHUNK
        call    os_write
        jp      c,fail_dst_os
dp_more:
        pop     hl
        pop     bc
        jr      dp_disk

; Everything's in: what's left in obuf, out to a whole OS_UNIT; then close
dst_finish:
        ld      a,(dst_state)
        cp      1
        jr      z,df_net
        ld      a,(dst_kind)
        cp      K_DISK
        jr      nz,df_close
        ld      hl,(ocount)
        ld      a,h
        or      l
        jr      z,df_close
df_pad:
        ld      a,l
        and     OS_UNIT - 1
        jr      z,df_write
        push    hl
        ld      de,obuf
        add     hl,de
        ld      (hl),OS_PAD
        pop     hl
        inc     hl
        jr      df_pad
df_write:
        ld      b,h
        ld      c,l
        ld      hl,obuf
        call    os_write
        jp      c,fail_dst_os
df_close:
        call    os_wclose
        jp      c,fail_dst_os
        xor     a
        ld      (dst_state),a
        ret
df_net:
        ld      a,UNIT_DST      ; (an HTTP PUT goes now)
        call    net_close
        jp      nz,fail_dst_net
        xor     a
        ld      (dst_state),a
        ret

;-----------------------------------------------------------------------------
; Giving up: say why, close what's open, take away a partial copy
;-----------------------------------------------------------------------------

; ^C: stop, and leave NPIP
stop:
        xor     a
        ld      (brk),a
        call    prog_break
        call    cleanup
        ld      hl,t_stopped
        call    print
        call    os_crlf
        jp      os_exit

fail_src_net:
        ld      a,UNIT_SRC
        call    net_why
fail_src_neta:
        ld      de,(src_spec)
        jr      fail_net
fail_dst_net:
        ld      a,UNIT_DST
        call    net_why
        ld      de,(dst_spec)
        jr      fail_net
fail_src_os:
        ld      de,(src_spec)
        jr      fail_os
fail_dst_os:
        ld      de,(dst_spec)
        jr      fail_os
fail_src_at:
        ld      de,(src_spec)
        jr      fail_at
fail_dst_at:
        ld      de,(dst_spec)
        jr      fail_at

; DE -> the spec, A = the FujiNet's error (0: no answer)
fail_net:
        push    af
        call    fail_head
        pop     af
        call    net_errmsg
        jr      fail_tail
; DE -> the spec, A = the system's error
fail_os:
        push    af
        call    fail_head
        pop     af
        call    os_errmsg
        jr      fail_tail
; DE -> the spec (or 0), HL -> what's wrong
fail_at:
        push    hl
        call    fail_head
        pop     hl
        call    print
fail_tail:
        call    os_crlf
        call    cleanup
fail_quiet:
        ld      sp,(cmd_sp)
        ret

; "spec - ", on a line of its own
fail_head:
        call    prog_break
        ld      a,d
        or      e
        ret     z
        ex      de,hl
        call    print
        ld      hl,t_dash
        jp      print

; Close what's open. A partial copy goes: on the FujiNet, a file system's
; is deleted; an HTTP PUT, held until CLOSE, is dropped unsent by a LOCK,
; which HTTP doesn't have but which ends the channel (DELETE would delete
; what the server has). A destination given up on while opening is
; deleted only if STATUS shows it open for writing.
cleanup:
        ld      a,1
        ld      (cleaning),a
        ld      a,(bus_dirty)
        or      a
        call    nz,drain
        ld      a,(dir_state)
        or      a
        jr      z,cu_src_go
        xor     a
        ld      (dir_state),a
        ld      a,(bus_dead)
        or      a
        ld      a,UNIT_DIR
        call    z,net_close
cu_src_go:
        ld      a,(src_state)
        cp      1
        jr      nz,cu_src
        ld      a,(bus_dead)
        or      a
        jr      nz,cu_src_done
        ld      a,UNIT_SRC
        call    net_close
        jr      cu_src_done
cu_src:
        or      a
        call    nz,os_rclose
cu_src_done:
        xor     a
        ld      (src_state),a
        ld      a,(dst_state)
        cp      1
        jr      z,cu_net
        cp      3
        jr      nz,cu_dst
cu_net:
        ld      a,(bus_dead)
        or      a
        jr      nz,cu_dst_done
        ld      a,(dst_http)
        or      a
        ld      b,CMD_LOCK
        jr      nz,cu_fsop
        ld      a,(dst_state)
        cp      1
        jr      z,cu_close
        ld      a,UNIT_DST      ; did the OPEN happen?
        call    net_status
        jr      nz,cu_dst_done
        ld      a,(nstat+3)
        cp      1
        jr      nz,cu_dst_done
cu_close:
        ld      a,UNIT_DST
        call    net_close
        ld      a,(bus_dead)
        or      a
        jr      nz,cu_dst_done
        ld      b,CMD_DELETE
cu_fsop:
        ld      a,UNIT_DST
        ld      hl,(dst_spec)
        call    net_fsop
        jr      cu_dst_done
cu_dst:
        or      a
        call    nz,os_wabort
cu_dst_done:
        xor     a
        ld      (dst_state),a
        ld      (cleaning),a
        ret

; The card, once: started if nothing has, and there
need_card:
        ld      a,(card_ok)
        or      a
        ret     nz
        call    card_on
        call    card_present
        ld      de,0
        ld      hl,t_nocard
        jp      nz,fail_at
        ld      a,1
        ld      (card_ok),a
        ret

; About 100 ms, with ^C live
pause:
        ld      b,50
pause_tick:
        push    bc
        call    tick
        call    os_break
        pop     bc
        jp      c,stop
        djnz    pause_tick
        ret

;-----------------------------------------------------------------------------
; Specs
;-----------------------------------------------------------------------------

; A = 1 if HL is a URL: after an optional N: or Nn:, a scheme of two or
; more letters, digits, + - and ., then :/ (SD:/X, TNFS://H/X). A: and SY0:
; are drives and LST: and LP: devices: neither system has / in a name.
is_url:
        call    skip_n
        ld      a,(hl)
        call    is_alpha
        jr      nc,iu_no
        ld      b,0
iu_scheme:
        inc     b
        inc     hl
        ld      a,(hl)
        cp      ':'
        jr      z,iu_colon
        call    is_alnum
        jr      c,iu_scheme
        cp      '+'
        jr      z,iu_scheme
        cp      '-'
        jr      z,iu_scheme
        cp      '.'
        jr      z,iu_scheme
iu_no:
        xor     a
        ret
iu_colon:
        ld      a,b
        cp      2
        jr      c,iu_no
        inc     hl
        ld      a,(hl)
        cp      '/'
        jr      nz,iu_no
        ld      a,1
        ret

; A = 1 if the URL at HL is HTTP: or HTTPS:
is_http:
        call    skip_n
        ld      de,t_http
        ld      b,4
ih_cmp:
        ld      a,(hl)
        and     0xDF
        ex      de,hl
        cp      (hl)
        ex      de,hl
        jr      nz,iu_no
        inc     hl
        inc     de
        djnz    ih_cmp
        ld      a,(hl)
        cp      ':'
        jr      z,ih_yes
        and     0xDF
        cp      'S'
        jr      nz,iu_no
        inc     hl
        ld      a,(hl)
        cp      ':'
        jr      nz,iu_no
ih_yes:
        ld      a,1
        ret

; HL past an N: or Nn: in front
skip_n:
        ld      a,(hl)
        and     0xDF
        cp      'N'
        ret     nz
        push    hl
        inc     hl
        ld      a,(hl)
        cp      ':'
        jr      z,sn_yes
        sub     '0'
        cp      10
        jr      nc,sn_no
        inc     hl
        ld      a,(hl)
        cp      ':'
        jr      nz,sn_no
sn_yes:
        inc     hl
        inc     sp              ; (not back)
        inc     sp
        ret
sn_no:
        pop     hl
        ret

; Carry if A is a letter (or for is_alnum, a digit). Keep A.
is_alpha:
        cp      'A'
        ccf
        ret     nc
        cp      'Z' + 1
        ret     c
        cp      'a'
        ccf
        ret     nc
        cp      'z' + 1
        ret
is_alnum:
        call    is_alpha
        ret     c
        cp      '0'
        ccf
        ret     nc
        cp      '9' + 1
        ret

; A local spec at HL: capitals, and no wildcards
local_check:
        ld      d,h
        ld      e,l
lc_char:
        ld      a,(hl)
        or      a
        ret     z
        cp      '*'
        jr      z,lc_wild
        cp      '?'
        jr      z,lc_wild
        cp      'a'
        jr      c,lc_next
        cp      'z' + 1
        jr      nc,lc_next
        sub     0x20
        ld      (hl),a
lc_next:
        inc     hl
        jr      lc_char
lc_wild:
        ld      hl,t_wild
        jp      fail_at

; A URL at HL: no * (the FujiNet ends it there)
url_check:
        ld      d,h
        ld      e,l
uc_char:
        ld      a,(hl)
        or      a
        ret     z
        inc     hl
        cp      '*'
        jr      nz,uc_char
        ld      hl,t_urlstar
        jp      fail_at

; HL -> the file's name in a local spec: after its device or drive
local_name:
        ld      d,h
        ld      e,l
ln_char:
        ld      a,(hl)
        or      a
        jr      z,un_done
        inc     hl
        cp      ':'
        jr      nz,ln_char
        ld      d,h
        ld      e,l
        jr      ln_char

; HL -> the last part of a URL's path (it ends at a NUL, ? or #)
url_name:
        ld      d,h
        ld      e,l
un_char:
        ld      a,(hl)
        call    name_end
        jr      z,un_done
        inc     hl
        cp      '/'
        jr      nz,un_char
        ld      d,h
        ld      e,l
        jr      un_char
un_done:
        ex      de,hl
        ret

; Z if A ends a name: NUL, ? or #
name_end:
        or      a
        ret     z
        cp      '?'
        ret     z
        cp      '#'
        ret

; The destination is a drive alone: dspec = it, then the source's name
; (from a URL, made a local one)
name_local:
        ld      hl,(dst_spec)
        ld      de,dspec
        call    strcpy
        ld      hl,(src_name)
        ld      a,(src_url)
        or      a
        jr      nz,nl_crunch
        call    strcpy
        jr      nl_set
nl_crunch:
        call    crunch
        jr      z,nl_none
nl_set:
        ld      hl,dspec
        ld      (dst_spec),hl
        ret
nl_none:
        ld      hl,t_nodst
        jp      fail_dst_at

; The destination URL ends in / or names only a host: dspec = it, (a /),
; then the source's name
name_url:
        ld      hl,(dst_spec)
        call    strend
        dec     hl
        ld      c,0
        ld      a,(hl)
        cp      '/'
        jr      z,nu_append
        ld      hl,(dst_spec)   ; :// and then no /?
nu_find:
        ld      a,(hl)
        or      a
        ret     z
        inc     hl
        cp      ':'
        jr      nz,nu_find
        ld      a,(hl)
        cp      '/'
        jr      nz,nu_find
        inc     hl
        ld      a,(hl)
        cp      '/'
        jr      nz,nu_find
nu_host:
        inc     hl
        ld      a,(hl)
        or      a
        jr      z,nu_slash
        cp      '/'
        ret     z
        jr      nu_host
nu_slash:
        ld      c,'/'
nu_append:
        ld      hl,(src_name)
        ld      a,(hl)
        call    name_end
        ld      hl,t_nodst
        jp      z,fail_dst_at
        ld      hl,(dst_spec)
        ld      de,dspec
        call    strcpy
        ld      a,c
        or      a
        jr      z,nu_name
        ld      (de),a
        inc     de
nu_name:
        ld      hl,(src_name)
nu_char:
        ld      a,(hl)
        call    name_end
        jr      z,nu_end
        push    hl
        ld      hl,dspec + 255  ; room for it and the NUL?
        or      a
        sbc     hl,de
        pop     hl
        jr      c,nu_long
        jr      z,nu_long
        ld      (de),a
        inc     hl
        inc     de
        jr      nu_char
nu_long:
        ld      hl,t_toolong
        jp      fail_dst_at
nu_end:
        xor     a
        ld      (de),a
        ld      hl,dspec
        ld      (dst_spec),hl
        ret

; The name at HL (to a NUL, ? or #) to DE as a local one: capitals, letters
; and digits only, 8 of them before the last dot and 3 after. NZ if it made
; one; DE -> its NUL.
crunch:
        ld      (cr_dot),hl     ; (until a dot's found)
        push    hl
        ld      bc,0
cr_find:
        ld      a,(hl)
        call    name_end
        jr      z,cr_found
        cp      '.'
        jr      nz,cr_fnext
        ld      b,h
        ld      c,l
cr_fnext:
        inc     hl
        jr      cr_find
cr_found:
        ld      (cr_end),hl
        ld      a,b
        or      c
        jr      nz,cr_dotted
        ld      b,h             ; no dot: the name runs to the end
        ld      c,l
cr_dotted:
        ld      (cr_dot),bc
        pop     hl
        ld      b,8
        call    cr_part         ; the name, to the dot
        ld      a,b
        cp      8
        ret     z               ; none of it was a letter or digit
        ld      hl,(cr_dot)
        ld      a,(hl)
        call    name_end
        jr      z,cr_done       ; no dot
        inc     hl
        ld      a,'.'
        ld      (de),a
        inc     de
        push    hl
        ld      hl,(cr_end)
        ld      (cr_dot),hl
        pop     hl
        ld      b,3
        call    cr_part         ; the extension, to the end
        ld      a,b
        cp      3
        jr      nz,cr_done
        dec     de              ; none: no dot either
cr_done:
        xor     a
        ld      (de),a
        inc     a               ; NZ
        ret

; From HL up to (cr_dot), at most B letters and digits to DE, capitals
cr_part:
        push    de
        ld      de,(cr_dot)
        or      a
        sbc     hl,de
        add     hl,de
        pop     de
        ret     nc
        ld      a,(hl)
        inc     hl
        cp      'a'
        jr      c,cr_up
        sub     0x20
cr_up:
        call    is_alnum
        jr      nc,cr_part
        ld      (de),a
        inc     de
        djnz    cr_part
        ret

;-----------------------------------------------------------------------------
; Strings
;-----------------------------------------------------------------------------

; HL past spaces; A = the next character
skip_sp:
        ld      a,(hl)
        cp      ' '
        ret     nz
        inc     hl
        jr      skip_sp

; The string at HL without its trailing spaces
trim:
        ld      d,h
        ld      e,l
        call    strend
trim_back:
        or      a
        sbc     hl,de
        add     hl,de
        ret     z
        dec     hl
        ld      a,(hl)
        cp      ' '
        ret     nz
        ld      (hl),0
        jr      trim_back

; HL -> the NUL ending the string at HL
strend:
        ld      a,(hl)
        or      a
        ret     z
        inc     hl
        jr      strend

; BC = the length of the string at HL. Keeps HL.
strlen:
        push    hl
        ld      bc,0
strlen_next:
        ld      a,(hl)
        or      a
        jr      z,strlen_done
        inc     hl
        inc     bc
        jr      strlen_next
strlen_done:
        pop     hl
        ret

; The string at HL to DE, with its NUL; DE -> that NUL
strcpy:
        ld      a,(hl)
        ld      (de),a
        or      a
        ret     z
        inc     hl
        inc     de
        jr      strcpy

; The string at HL out
print:
        ld      a,(hl)
        or      a
        ret     z
        call    os_conout
        inc     hl
        jr      print

        include "net.inc"
        include "progress.inc"
        include "text.inc"
        include "fujibus.inc"
        include "card.inc"
