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

all: $(BUILD)/FNDISK.COM $(BUILD)/fndisk-cpm.h8d

$(BUILD)/resident.bin: $(FNDISK_SRC)/resident.asm $(FNDISK_SRC)/h89.inc
	@mkdir -p $(BUILD)
	$(Z80ASM) -b -g -m -I=$(FNDISK_SRC) -O=$(BUILD) -r=$(FNDISK_ORG) -o=$@ $<
	@size=$$(stat -c %s $@); room=$$(( 0x10000 - $(FNDISK_ORG) )); \
	  echo "resident: $$size bytes at $(FNDISK_ORG), room for $$room"; \
	  test $$size -le $$room || { echo "resident part doesn't fit" >&2; exit 1; }

$(BUILD)/FNDISK.COM: $(FNDISK_SRC)/loader.asm $(FNDISK_SRC)/h89.inc $(BUILD)/resident.bin
	$(Z80ASM) -b -m -I=$(FNDISK_SRC) -I=$(BUILD) -O=$(BUILD) -r=0x100 -o=$@ $<

# FNDISK.COM alone on a 100K H17 CP/M disk (hz89 format)
$(BUILD)/fndisk-cpm.h8d: $(BUILD)/FNDISK.COM tools/cpm-dir-fixup.py
	rm -rf $(BUILD)/disk && mkdir -p $(BUILD)/disk
	cp $< $(BUILD)/disk/FNDISK.COM
	cd $(BUILD)/disk && $(APPMAKE) +cpmdisk -f hz89 --container raw --no-com-file \
	  -b FNDISK.COM -o disk
	python3 -I tools/cpm-dir-fixup.py $(BUILD)/disk/disk
	mv $(BUILD)/disk/disk $@

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

clean:
	rm -rf $(BUILD)

.PHONY: all clean tools-disk
