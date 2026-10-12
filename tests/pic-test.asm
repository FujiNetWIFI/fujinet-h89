; A minimal PIC device driver, for tests/host-tools.sh to put mkpic.py
; through: assembled as is it must build; with -DBAD (half an address,
; which HDOS can't relocate) mkpic must refuse it.

        public  dvd_entry, pic_end

        defb    0xFF, 0x01
        defw    0, 0
        defb    0xC7, 0x0F, 0, 1, 0x0F, 0, 0, 0, 0, 0, 0, 0
        defb    0
        defw    0
        defs    0x200 - 0x15

dvd_entry:
        ld      hl,table
        jp      (hl)
IFDEF BAD
        ld      a,table / 256
ENDIF
table:
        defw    dvd_entry, table
        xor     a
        ret

pic_end:
