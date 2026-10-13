# FujiNet for the Heathkit H89
#
#   make            FNDISK.COM, and an H17 CP/M disk with it on; FN.DVD, and
#                   an HDOS disk with it on; FNBOOT and its stage 2
#
# Needs z88dk (z88dk-z80asm, z88dk-appmake) on PATH.

Z80ASM  ?= z88dk-z80asm
APPMAKE ?= z88dk-appmake
BUILD   := build

# Where the resident part of FNDISK lives: above the BIOS of a 62K system,
# whose RAM ends at F711H, to the top of memory
FNDISK_ORG ?= 0xF720

# Where FNBOOT is assembled: the unused bytes at the end of MTR-90 (from
# 0F65H in 444-142, 0F25H in 444-84); 0x1000 for an EPROM of its own; or RAM
# clear of 2040H-BB68H, such as 0xC000
BOOT_ORG   ?= 0x0F80

FNDISK_SRC := cpm/fndisk
FN_SRC     := hdos/fn
BOOT_SRC   := boot
FN_UNITS   ?= 8
COMMON     := $(wildcard common/*.inc)
BOOT_INC   := $(wildcard $(BOOT_SRC)/*.inc) common/h89.inc

all: $(BUILD)/FNDISK.COM $(BUILD)/fndisk-cpm.h8d $(BUILD)/FN.DVD $(BUILD)/fn-hdos.h8d \
     $(BUILD)/fnboot.bin $(BUILD)/stage2.bin

$(BUILD)/resident.bin: $(FNDISK_SRC)/resident.asm $(COMMON)
	@mkdir -p $(BUILD)
	$(Z80ASM) -b -g -m -I=$(FNDISK_SRC) -I=common -O=$(BUILD) -r=$(FNDISK_ORG) -o=$@ $<
	@size=$$(stat -c %s $@); room=$$(( 0x10000 - $(FNDISK_ORG) )); \
	  echo "resident: $$size bytes at $(FNDISK_ORG), room for $$room"; \
	  test $$size -le $$room || { echo "resident part doesn't fit" >&2; exit 1; }

$(BUILD)/FNDISK.COM: $(FNDISK_SRC)/loader.asm $(COMMON) $(BUILD)/resident.bin
	$(Z80ASM) -b -m -I=$(FNDISK_SRC) -I=common -I=$(BUILD) -O=$(BUILD) -r=0x100 -o=$@ $<

# FNDISK.COM alone on a 100K H17 CP/M disk (hz89 format)
$(BUILD)/fndisk-cpm.h8d: $(BUILD)/FNDISK.COM tools/cpm-dir-fixup.py
	rm -rf $(BUILD)/disk && mkdir -p $(BUILD)/disk
	cp $< $(BUILD)/disk/FNDISK.COM
	cd $(BUILD)/disk && $(APPMAKE) +cpmdisk -f hz89 --container raw --no-com-file \
	  -b FNDISK.COM -o disk
	python3 -I tools/cpm-dir-fixup.py $(BUILD)/disk/disk
	mv $(BUILD)/disk/disk $@

# FN.DVD: assembled at three origins, which tools/mkpic.py turns into the
# PIC file HDOS loads (and checks the relocation table of)
FN_ASM = $(Z80ASM) -b -m -I=$(FN_SRC) -I=common -DFN_UNITS=$(FN_UNITS) $(FN_FLAGS)

$(BUILD)/FN.DVD: $(FN_SRC)/fndvd.asm $(FN_SRC)/hdos.inc $(COMMON) tools/mkpic.py
	@mkdir -p $(BUILD)/pic0 $(BUILD)/pic1 $(BUILD)/pic2
	$(FN_ASM) -O=$(BUILD)/pic0 -r=0x0000 -o=$(BUILD)/pic0/fndvd.bin $<
	$(FN_ASM) -O=$(BUILD)/pic1 -r=0x0101 -o=$(BUILD)/pic1/fndvd.bin $<
	$(FN_ASM) -O=$(BUILD)/pic2 -r=0xD137 -o=$(BUILD)/pic2/fndvd.bin $<
	python3 -I tools/mkpic.py --map $(BUILD)/pic0/fndvd.map -o $@ \
	  $(BUILD)/pic0/fndvd.bin $(BUILD)/pic1/fndvd.bin $(BUILD)/pic2/fndvd.bin

# FN.DVD on an HDOS disk, to COPY onto the system disk (then reboot)
$(BUILD)/fn-hdos.h8d: $(BUILD)/FN.DVD tools/hdosfs.py
	python3 -I tools/hdosfs.py blank $@.tmp --label "FujiNet FN: for HDOS 2.0"
	python3 -I tools/hdosfs.py put $@.tmp $(BUILD)/FN.DVD --name FN.DVD --flags C0
	python3 -I tools/hdosfs.py ls $@.tmp --check >/dev/null
	mv $@.tmp $@

# CONFIG.COM and FNDISK.COM on one H17 CP/M disk:
#   make tools-disk CONFIG=../fujinet-config/r2r/h89-cpm/config.com
tools-disk: $(BUILD)/FNDISK.COM tools/cpm-dir-fixup.py
	@test -n "$(CONFIG)" || { echo "set CONFIG=path/to/config.com" >&2; exit 1; }
	rm -rf $(BUILD)/tools && mkdir -p $(BUILD)/tools
	cp $(CONFIG) $(BUILD)/tools/CONFIG.COM
	cp $(BUILD)/FNDISK.COM $(BUILD)/tools/FNDISK.COM
	cd $(BUILD)/tools && $(APPMAKE) +cpmdisk -f hz89 --container raw --no-com-file \
	  -b CONFIG.COM -a FNDISK.COM -o disk
	python3 -I tools/cpm-dir-fixup.py $(BUILD)/tools/disk
	mv $(BUILD)/tools/disk $(BUILD)/fujinet-cpm.h8d

# FNBOOT, for BOOT_ORG (rebuilt when that changes). In the monitor's spare
# bytes it must end below 1000H.
$(BUILD)/fnboot.org: FORCE
	@mkdir -p $(BUILD)
	@echo $(BOOT_ORG) | cmp -s - $@ || echo $(BOOT_ORG) > $@

$(BUILD)/fnboot.bin: $(BOOT_SRC)/fnboot.asm $(BOOT_INC) $(BUILD)/fnboot.org
	$(Z80ASM) -b -m -I=$(BOOT_SRC) -I=common -O=$(BUILD) -r=$(BOOT_ORG) -o=$@ $<
	@org=$$(( $(BOOT_ORG) )); size=$$(stat -c %s $@); \
	  printf 'fnboot: %d bytes at %04XH..%04XH, G%03o%03o\n' $$size $$org $$(( org + size - 1 )) \
	    $$(( org >> 8 )) $$(( org & 255 )); \
	  test $$org -ge 4096 -o $$(( org + size )) -le 4096 || { echo "FNBOOT runs past the monitor ROM" >&2; rm -f $@; exit 1; }

# Stage 2, sector 0 of the boot image, with the shim it leaves under CONFIG
$(BUILD)/shim.bin: $(BOOT_SRC)/shim.asm $(BOOT_INC)
	@mkdir -p $(BUILD)
	$(Z80ASM) -b -g -m -I=$(BOOT_SRC) -I=common -O=$(BUILD) -r=0x2040 -o=$@ $<

$(BUILD)/stage2.bin: $(BOOT_SRC)/stage2.asm $(BOOT_INC) $(BUILD)/shim.bin
	$(Z80ASM) -b -m -I=$(BOOT_SRC) -I=common -I=$(BUILD) -O=$(BUILD) -r=0x2280 -o=$@ $<
	@echo "stage2: $$(stat -c %s $@) bytes (a sector is 512)"

# The boot image for the FujiNet's flash (/autorun.img): stage 2, then
# CONFIG.ABS:
#   make autorun CONFIG_ABS=../fujinet-config/r2r/h89-hdos/config.abs
autorun: $(BUILD)/stage2.bin tools/fnboot.py
	@test -n "$(CONFIG_ABS)" || { echo "set CONFIG_ABS=path/to/config.abs" >&2; exit 1; }
	python3 -I tools/fnboot.py image $(BUILD)/stage2.bin $(CONFIG_ABS) -o $(BUILD)/autorun.img

# FNBOOT in a copy of the monitor ROM, at BOOT_ORG:
#   make monitor-rom MTR=path/to/2732_444-142_mtr90.u518
monitor-rom: $(BUILD)/fnboot.bin tools/fnboot.py
	@test -n "$(MTR)" || { echo "set MTR=path/to/the monitor ROM image" >&2; exit 1; }
	python3 -I tools/fnboot.py patch $(MTR) $(BUILD)/fnboot.bin --at $(BOOT_ORG) -o $(BUILD)/monitor-fnboot.rom

# The host tools, with no emulator
check: $(BUILD)/stage2.bin $(BUILD)/fnboot.bin
	tests/host-tools.sh

# CONFIG.ABS and FN.DVD on one HDOS disk:
#   make hdos-tools-disk CONFIG_ABS=../fujinet-config/r2r/h89-hdos/config.abs
hdos-tools-disk: $(BUILD)/FN.DVD tools/hdosfs.py
	@test -n "$(CONFIG_ABS)" || { echo "set CONFIG_ABS=path/to/config.abs" >&2; exit 1; }
	python3 -I tools/hdosfs.py blank $(BUILD)/fujinet-hdos.h8d.tmp --label "FujiNet for HDOS"
	python3 -I tools/hdosfs.py put $(BUILD)/fujinet-hdos.h8d.tmp $(CONFIG_ABS) --name CONFIG.ABS
	python3 -I tools/hdosfs.py put $(BUILD)/fujinet-hdos.h8d.tmp $(BUILD)/FN.DVD --name FN.DVD --flags C0
	python3 -I tools/hdosfs.py ls $(BUILD)/fujinet-hdos.h8d.tmp --check
	mv $(BUILD)/fujinet-hdos.h8d.tmp $(BUILD)/fujinet-hdos.h8d

clean:
	rm -rf $(BUILD)

.PHONY: all clean check tools-disk hdos-tools-disk autorun monitor-rom FORCE
