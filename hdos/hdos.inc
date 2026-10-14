; HDOS 2.0, as a device driver or a program sees it (Heath's HOSEQU, ESINT,
; DVDDEF, DEVDEF, DDDEF, ECDEF and HOSDEF decks; the addresses in hex, not
; split octal)

TICCNT          equ     0x201B  ; the 2 ms tick counter
S_CAPEND        equ     0x20DC  ; S.CAADR+1: non-zero while a CTL-C abort waits
AIO_UNI         equ     0x2131  ; the unit a request is for

DVDFLV          equ     0xC7    ; marks a file as a device driver

; Device capabilities (DEV.FLG, DVD.CAP, DVD.UFL)
DT_DD           equ     0x01    ; directory device
DT_CR           equ     0x02    ; reads
DT_CW           equ     0x04    ; writes
DT_RN           equ     0x08    ; random access

; Driver function codes (A on entry)
DC_REA          equ     0
DC_WRI          equ     1
DC_RER          equ     2       ; read regardless of the volume number
DC_OPR          equ     3
DC_OPW          equ     4
DC_OPU          equ     5
DC_CLO          equ     6
DC_ABT          equ     7
DC_MOU          equ     8
DC_LOD          equ     9
DC_RDY          equ     10
DC_MAX          equ     11

; Error codes (A on return, with carry set), as ERRORMSG.SYS words them
EC_DNS          equ     5       ; Device is Not Capable of This Operation
EC_ILR          equ     10      ; Illegal Request
EC_RF           equ     18      ; Read Failure
EC_WF           equ     19      ; Write Failure
EC_WP           equ     21      ; Disk is Write Protected
EC_DDA          equ     23      ; Aborted by Device Driver
EC_UUN          equ     27      ; Unknown Unit
EC_UNA          equ     30      ; Unit Not Available
EC_DNR          equ     38      ; Unable to Read this Disk

; A program's system calls: RST 38H, then the function (Heath's HOSDEF)
SC_EXIT         equ     0x00
SC_SCIN         equ     0x01    ; a key, or carry if none waits
SC_SCOUT        equ     0x02
SC_READ         equ     0x04    ; A = channel, DE -> buffer, BC = bytes
SC_WRITE        equ     0x05
SC_CONSL        equ     0x06    ; A = which mode byte, B = bits, C = mask
SC_OPENR        equ     0x22    ; A = channel, HL -> name, DE -> defaults
SC_OPENW        equ     0x23
SC_CLOSE        equ     0x26
SC_POSIT        equ     0x27    ; A = channel, BC = sector
SC_DELETE       equ     0x28    ; HL -> name, DE -> defaults

USER_START      equ     0x2280  ; programs load here; SP here: no arguments
S_CSLMD         equ     0x20D6  ; the console's five mode bytes
CSL_ECH         equ     0x80    ; S.CSLMD: no echo
CSL_RAW         equ     0x04    ;   no CTL-C, -S, -O, -P
CSL_WRP         equ     0x02    ;   wrap at the width
CSL_CHR         equ     0x01    ;   a character at a time
CTP_MLI         equ     0x20    ; S.CONTY: capitals on input
CTP_MLO         equ     0x10    ;   capitals on output
CTP_BKM         equ     0x02    ;   backspace made rubout
EC_EOF          equ     1       ; End of File
