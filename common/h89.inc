; The H89-ESP32 FujiNet card and FujiBus, as the driver and its loader use them.

; 82C55 at 0D0H: port A carries the bytes, port C has the handshake
PORTA           equ     0xD0
PORTB           equ     0xD1    ; wired to nothing: holds SETUP_MARK
PORTC           equ     0xD2
PCTRL           equ     0xD3

; Left in port B by whatever sets up the 82C55, as fujinet-lib's port_init
; does. A reset makes port B an input that reads FF, and any other mode word
; clears it or makes it an input.
SETUP_MARK      equ     0xA5

PC_OBF          equ     0x80    ; /OBF: 1 = the byte we wrote has been taken
PC_IBF          equ     0x20    ; IBF: 1 = a byte from the ESP32 is waiting
PC_EN           equ     0x04    ; PC2: ESP32 enable (the card is running)

DIR_TO_H89      equ     0x00    ; port C bit set/reset: PC0=0, the 245 drives toward the H89
DIR_TO_ESP      equ     0x01    ; PC0=1, toward the ESP32
OE_ON           equ     0x02    ; PC1=0, the 245 enabled

; SLIP
SLIP_END        equ     0xC0
SLIP_ESC        equ     0xDB
SLIP_ESC_END    equ     0xDC
SLIP_ESC_ESC    equ     0xDD

; FujiBus
DEV_FUJI        equ     0x70
DEV_DISK        equ     0x31    ; slot n is DEV_DISK + n
CMD_READ        equ     0x52    ; 'R': one 512-byte sector
CMD_WRITE       equ     0x57    ; 'W'
CMD_DEVICE_SLOTS equ    0xF2    ; 8 x {hostSlot, mode, name[36]}
CMD_DEVICE_PATH equ     0xDA    ; a slot's full path, 256 bytes
REPLY_ACK       equ     0x06
FIELDS_U8       equ     1
FIELDS_U16      equ     5

MODE_MOUNTED    equ     0x40
SLOT_SIZE       equ     38
SLOTS_SIZE      equ     8 * SLOT_SIZE

NDRIVES         equ     8       ; FujiNet drive slots, one CP/M drive each
SECTOR          equ     512     ; FujiNet sector
