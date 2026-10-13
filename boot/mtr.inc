; The H89 monitor ROM (MTR-88, MTR-89 and MTR-90 alike at these addresses),
; as a program started with its Go command sees it. Go leaves interrupts on
; and the 2 ms clock running.

MTR_DLY         equ     0x002B  ; wait A x 2 ms on the clock (A = 0: 256 ticks)
TICCNT          equ     0x201B  ; the 2 ms tick counter
UIVEC_RST7      equ     0x2031  ; RST 38H jumps here: room for a JP

; While bit 7 of MFLAG is clear, every tick looks at the byte before the
; interrupted PC, and if it's 76H (HALT) rings the bell and enters the
; monitor; Go and RETURN carry on after it. An instruction that only ends in
; 76H (LD A,'v') trips it too, so a program of any size sets the bit.
MFLAG           equ     0x2008
MF_NOHALT       equ     0x80

; The console's 8250
CON_DATA        equ     0xE8
CON_LSR         equ     0xED
LSR_DR          equ     0x01    ; a byte has come
LSR_THRE        equ     0x20    ; room to send one
