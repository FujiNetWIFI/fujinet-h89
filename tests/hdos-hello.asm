; HELLO.ABS: says hello, for RUN FN0:HELLO.ABS in tests/fn-hdos-e2e.sh.
; Padded to end part way through its third sector.

        org     0x2278          ; the ABS header, then the program at 2280H

        defb    0xFF, 0x00      ; an absolute binary
        defw    start           ; load address
        defw    end - start     ; length
        defw    start           ; entry

start:
        ld      hl,message
next:
        ld      a,(hl)
        or      a
        jr      z,done
        push    hl
        rst     0x38
        defb    2               ; .SCOUT
        pop     hl
        inc     hl
        jr      next
done:
        xor     a
        rst     0x38
        defb    0               ; .EXIT

message:
        defm    "HELLO FROM FN0", 10, 0
        defs    700, 0x55
end:
