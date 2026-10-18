#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): boot a 62K CP/M, mount an H17 image in FujiNet
# slot 1 with FNCONFIG, load FNDISK, then read, write and warm boot on D:, and
# check on the host that the file written is in the image. Then print on
# UL1: (the FujiNet's printer) and on CRT:, and check what the printer got.
# First, check what FNDISK says where there's no room above the BIOS.
#
#   tests/fndisk-e2e.sh --boot CPM62.h8d --config FNCONFIG.COM [--rig DIR] [--keep DIR]
#
# FNCONFIG.COM must be built with -DH89_RIG_KEYS (` stands in for ESC: the
# rig types only printable keys).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
BOOT=""; CONFIG=""; KEEP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot) BOOT="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        *) echo "usage: $0 --boot CPM62.h8d --config FNCONFIG.COM [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${BOOT}" && -f "${CONFIG}" ]] || { echo "need --boot and --config" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
APPMAKE="${APPMAKE:-z88dk-appmake}"
FNDISK="${ROOT}/build/FNDISK.COM"
[[ -f "${FNDISK}" ]] || { echo "build FNDISK.COM first (make)" >&2; exit 2; }

if [[ -n "${KEEP}" ]]; then WORK="${KEEP}"; rm -rf "${WORK}"; mkdir -p "${WORK}"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/fndisk-e2e-XXXXXX")"; trap 'rm -rf "${WORK}"' EXIT; fi

fixup() { python3 -I "${ROOT}/tools/cpm-dir-fixup.py" "$1"; }

# The FujiNet's own files in HOME, with its printer on as RAW (every byte to
# SD/paper). The emulator's fnconfig.ini has the printer off, and is copied
# in, with the rest, only where there's no fnconfig.ini yet.
printer_on() {
    local out="${FUJINET_LIB_DIR:-${RIG}/tools/fujinet/work/out}" fn="$1/data/fujinet"
    mkdir -p "${fn}"
    cp -r "${out}/fnconfig.ini" "${out}/data" "${out}/SD" "${fn}/"
    sed -i 's/^printer_enabled=0$/printer_enabled=1/' "${fn}/fnconfig.ini"
    printf '\n[Printer1]\ntype=0\n' >> "${fn}/fnconfig.ini"
}

# B: holds FNCONFIG and FNDISK
mkdir -p "${WORK}/tools"
cp "${CONFIG}" "${WORK}/tools/FNCONFIG.COM"
cp "${FNDISK}" "${WORK}/tools/FNDISK.COM"
(cd "${WORK}/tools" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b FNCONFIG.COM -a FNDISK.COM -o disk >/dev/null)
fixup "${WORK}/tools/disk"

# No room above the BIOS: FNDISK has to say where the BIOS's RAM runs to and
# how many K smaller to make the system. The rig's 64K system; then the 62K
# one with the BIOS's RAM end (BIOS+4BH, the BIOS at E600H) poked to FB40H,
# as a BIOS with more drivers in it (CF, RTC, LPT) has, and to 0000H, a BIOS
# whose RAM runs to the top of memory.
no_room() {     # $1 = name, $2 = boot disk, $3 = RAM end to poke or "", $4 = its last byte, $5 = K
    local log="${WORK}/$1.log" poke=()
    cp "$2" "${WORK}/$1.h8d"
    [[ -z "$3" ]] || poke=(--debug 'radix hex' --debug 'mem 1 2'
                           --debug "poke 0xe64b \$${3:2:2} \$${3:0:2}")
    "${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/$1" --timeout 60 \
        --disk "h17:1=${WORK}/$1.h8d" --disk "h17:2=${WORK}/tools/disk" \
        --until 'H:' --type 'B\r' --until 'A>' --wait 1000 ${poke[@]+"${poke[@]}"} \
        --type 'B:FNDISK\r' --until 'boot that' --prompt 'A>' --wait 500 --screen \
        > "${log}" 2>&1 || { grep -E 'timed out|failed' "${log}" >&2 || true
            sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${log}" | sed 's/^\[fujinet\] //' | tail -8 >&2
            echo "FAIL: no room ($1): the run stopped" >&2; exit 1; }
    if [[ -n "$3" ]] && ! grep -Eq '^(\[fujinet\] )?0001 +03 E6' "${log}"; then
        echo "FAIL: no room ($1): the boot disk's BIOS isn't at E600H (make it with make-62k-boot.sh)" >&2; exit 1
    fi
    grep -q "its RAM runs to $4H, FNDISK's starts at F720H\." "${log}" \
        && grep -q "Make a system $5K smaller" "${log}" \
        || { grep -A2 'No room' "${log}" >&2; echo "FAIL: no room ($1): want $4H and ${5}K" >&2; exit 1; }
    echo "PASS: no room ($1): its RAM runs to $4H, ${5}K smaller"
}
no_room 64k "${RIG}/tools/disks/boot/cpm-2.2.04-64k.h8d" "" FF11 2
no_room bigger-bios "${BOOT}" FB40 FB3F 2
no_room to-the-top "${BOOT}" 0000 FFFF 3

# The FujiNet's SD card: an H17 CP/M disk with text files on it. PRINT.TXT
# has a line longer than FNDISK's print buffer, and a last one with no end,
# which goes out when PIP ends.
printer_on "${WORK}/home"
SD="${WORK}/home/data/fujinet/SD"
mkdir -p "${WORK}/test"
printf 'Hello from a FujiNet drive on the H89.\r\nThe second line.\r\n\032' > "${WORK}/test/HELLO.TXT"
printf 'A long line: %s\r\nNo line end here\032' "$(printf '0123456789%.0s' {1..15})" > "${WORK}/test/PRINT.TXT"
printf '\311' > "${WORK}/test/STUB.COM"
(cd "${WORK}/test" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b STUB.COM -a HELLO.TXT -a PRINT.TXT -o disk >/dev/null)
fixup "${WORK}/test/disk"
cp "${WORK}/test/disk" "${SD}/TEST.H8D"
cp "${BOOT}" "${WORK}/boot.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools/disk" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --prompt 'A>' --type 'B:FNCONFIG\r' --until 'Drive Slots' --until 'Quit' --wait 1500 \
    --type '\r' --until 'TEST.H8D' --wait 1500 \
    --type 'f' --until 'matching' --type 'TEST*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '1' --wait 300 --type 'w' \
    --until 'TEST.H8D' --wait 1500 --type '`' --until 'Mount drives' --wait 1500 \
    --type '`' --until 'FujiNet drives' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Installed' --until 'LST: is UL1:' --prompt 'A>' --wait 500 --screen \
    --type 'DIR D:\r' --until 'HELLO' --prompt 'A>' --wait 500 \
    --type 'TYPE D:HELLO.TXT\r' --until 'second line' --prompt 'A>' --wait 500 \
    --type 'PIP D:=B:FNDISK.COM\r' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Already installed' --prompt 'A>' --wait 500 \
    --type 'DIR D:\r' --until 'FNDISK' --prompt 'A>' --wait 500 \
    --type 'STAT D:\r' --until 'Bytes Remaining On D:' --prompt 'A>' --wait 500 \
    --type 'PIP LST:=D:HELLO.TXT\r' --prompt 'A>' --wait 500 \
    --type 'PIP LST:=D:PRINT.TXT\r' --prompt 'A>' --wait 500 \
    --type 'STAT LST:=CRT:\r' --prompt 'A>' --wait 500 \
    --type 'PIP LST:=D:HELLO.TXT\r' --prompt 'A>' --wait 500 \
    --type 'STAT LST:=UL1:\r' --prompt 'A>' --wait 500 --screen \
    --type 'DIR E:\r' --until 'Bdos Err On E: Select' --wait 500 --type '\r' --prompt 'A>' --wait 500 \
    --type 'DIR D:\r' --until 'A>DIR D:' --prompt 'A>' --wait 500 --screen \
    > "${WORK}/run.log" 2>&1 || { grep -E 'timed out|failed' "${WORK}/run.log" >&2 || true
        sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -30 >&2
        echo "FAIL: the run stopped" >&2; exit 1; }

sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -26

# The file PIP wrote must be in the image, byte for byte
python3 -I - "${SD}/TEST.H8D" "${FNDISK}" <<'EOF'
import sys
SKEW = [0, 4, 8, 2, 6, 1, 5, 9, 3, 7]
img = open(sys.argv[1], 'rb').read()
want = open(sys.argv[2], 'rb').read()
def lsec(ls):
    t, s = 3 + ls // 10, SKEW[ls % 10]
    o = (t * 10 + s) * 256
    return img[o:o + 256]
def block(b):
    return b''.join(lsec(b * 4 + i) for i in range(4))
d = block(0) + block(1)
exts = []
for e in range(64):
    ent = d[e * 32:e * 32 + 32]
    if ent[0] == 0 and ent[1:12] == b'FNDISK  COM':
        exts.append((ent[12], ent[15], [x for x in ent[16:32] if x]))
if not exts:
    sys.exit('FAIL: FNDISK.COM is not in the image')
data = b''
for ex, rc, blks in sorted(exts):
    data += b''.join(block(b) for b in blks)[:rc * 128]
pad = (len(want) + 127) // 128 * 128
if data[:len(want)] != want or len(data) != pad:
    sys.exit('FAIL: FNDISK.COM in the image differs (%d bytes, want %d)' % (len(data), pad))
print('PASS: FNDISK.COM read back from the image, %d bytes' % len(want))
EOF

# The printer got HELLO.TXT and PRINT.TXT, each to its ^Z; the third PIP, with
# LST: = CRT:, printed on the screen instead
python3 -I - "${WORK}/test/HELLO.TXT" "${WORK}/test/PRINT.TXT" "${SD}/paper" "${WORK}/run.log" <<'EOF'
import re, sys
hello, text = (open(p, 'rb').read().split(b'\x1a')[0] for p in sys.argv[1:3])
try:
    paper = open(sys.argv[3], 'rb').read()
except FileNotFoundError:
    sys.exit('FAIL: the printer got nothing')
if paper != hello + text:
    sys.exit('FAIL: the printer got %r, not %r' % (paper, hello + text))
log = re.sub(r'(?m)^\[fujinet\] ', '', open(sys.argv[4], errors='replace').read())
screen = log.split('STAT LST:=CRT:')[-1].splitlines()
if not any(a.endswith('PIP LST:=D:HELLO.TXT') and b.startswith('Hello from')
           for a, b in zip(screen, screen[1:])):
    sys.exit("FAIL: PIP LST: with LST: = CRT: didn't print on the screen")
print('PASS: printed on UL1: byte for byte (%d bytes, ending in a line with no end), and on CRT:'
      % len(paper))
EOF
