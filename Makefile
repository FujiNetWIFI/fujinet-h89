# FujiNet for the Heathkit H89
#
#   make            FNDISK.COM, and an H17 CP/M disk with it on
#
# Needs z88dk (z88dk-z80asm, z88dk-appmake) on PATH.

Z80ASM  ?= z88dk-z80asm
APPMAKE ?= z88dk-appmake
BUILD   := build

# Where the resident part of FNDISK lives: above the BIOS of a 62K system,
# whose RAM ends at F711H, to the top of memory
FNDISK_ORG ?= 0xF720

FNDISK_SRC := cpm/fndisk
FN_SRC     := hdos/fn
FN_UNITS   ?= 8
COMMON     := $(wildcard common/*.inc)

all: $(BUILD)/FNDISK.COM $(BUILD)/fndisk-cpm.h8d $(BUILD)/FN.DVD $(BUILD)/fn-hdos.h8d

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

# The host tools, with no emulator
check:
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

.PHONY: all clean check tools-disk hdos-tools-disk
