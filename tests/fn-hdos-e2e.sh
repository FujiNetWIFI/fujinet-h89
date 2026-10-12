#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# FujiNet in-process): HDOS 2.0 with FN.DVD, CONFIG mounting images in the
# FujiNet's slots, and FN0: used as a disk.
#
#   tests/fn-hdos-e2e.sh --boot BOOT.h8d --config CONFIG.ABS [--rig DIR] [--keep DIR]
#
# BOOT.h8d comes from tests/make-hdos-boot.sh. CONFIG.ABS must be built with
# -DH89_RIG_KEYS (` stands in for ESC: the rig types only printable keys).
#
# Session A: an image read/write: LOAD FN:, MOUNT, CAT, TYPE, RUN from it,
# COPY onto it, DISMOUNT, MOUNT again; then on the host, the copy must be in
# the image byte for byte, and the memory HDOS gave the driver as reckoned;
# and CONFIG must still run with the driver in.
# Session B: read only, and the errors: an empty slot and a slot holding
# something that isn't an H17 disk.
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
        *) echo "usage: $0 --boot BOOT.h8d --config CONFIG.ABS [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${BOOT}" && -f "${CONFIG}" ]] || { echo "need --boot and --config" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
Z80ASM="${Z80ASM:-z88dk-z80asm}"
hdosfs() { python3 -I "${ROOT}/tools/hdosfs.py" "$@"; }

if [[ -n "${KEEP}" ]]; then WORK="${KEEP}"; rm -rf "${WORK}"; mkdir -p "${WORK}"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/fn-hdos-e2e-XXXXXX")"; trap 'rm -rf "${WORK}"' EXIT; fi

# SY1: holds CONFIG
hdosfs blank "${WORK}/tools.h8d" --label TOOLS
hdosfs put "${WORK}/tools.h8d" "${CONFIG}" --name CONFIG.ABS

# The test image: a text file and a program
mkdir -p "${WORK}/asm"
"${Z80ASM}" -b -O="${WORK}/asm" -o="${WORK}/asm/hello.bin" "${ROOT}/tests/hdos-hello.asm"
printf 'HELLO FROM A FUJINET DISK\nTHE SECOND LINE\n' > "${WORK}/hello.txt"
hdosfs blank "${WORK}/test.h8d" --label "FUJINET TEST DISK"
hdosfs put "${WORK}/test.h8d" "${WORK}/hello.txt" --name HELLO.TXT
hdosfs put "${WORK}/test.h8d" "${WORK}/asm/hello.bin" --name HELLO.ABS
head -c 102400 /dev/zero > "${WORK}/notdisk.img"

boot() {   # boot from a fresh copy of BOOT, SY1: = tools, then MOUNT SY1:
    cp "${BOOT}" "${WORK}/boot.h8d"
    printf '%s\n' --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools.h8d" \
        --until 'H:' --type 'B\r' --wait 3000 --type ' ' --wait 500 --type ' ' \
        --prompt 'ACTION? <BOOT>' --type '\r' --prompt 'DATE (DD-MMM-YY)?' --type '11-OCT-80\r' \
        --prompt '>' --type 'MOUNT SY1:\r' --wait 2000 --prompt '>'
}
screen() { sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "$1" | sed 's/^\[fujinet\] //'; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Session A: read/write ---
mkdir -p "${WORK}/a/data/fujinet/SD"
cp "${WORK}/test.h8d" "${WORK}/a/data/fujinet/SD/TEST.H8D"
mapfile -t BOOT_A < <(boot)
"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/a" --timeout 90 "${BOOT_A[@]}" \
    --debug 'mem 0x20d0 2' \
    --type 'RUN SY1:CONFIG.ABS\r' --until 'Drive Slots' --until 'Quit' --wait 1500 \
    --type '\r' --until 'TEST.H8D' --wait 2000 --type 'f' --until 'matching' --type 'TEST*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '1' --wait 300 --type 'w' \
    --until 'TEST.H8D' --wait 1500 --type '`' --until 'Mount drives' --wait 1500 --type '`' \
    --until 'FUJINET DRIVES' --prompt '>' --wait 500 \
    --type 'LOAD FN:\r' --wait 3000 --prompt '>' --debug 'mem 0x20d0 2' \
    --type 'STAT\r' --wait 2000 --prompt '>' \
    --type 'MOUNT FN0:\r' --until 'MOUNTED ON FN0:' --prompt '>' \
    --type 'CAT FN0:\r' --until 'HELLO' --prompt '>' \
    --type 'TYPE FN0:HELLO.TXT\r' --until 'THE SECOND LINE' --prompt '>' \
    --type 'RUN FN0:HELLO.ABS\r' --until 'HELLO FROM FN0' --prompt '>' \
    --type 'COPY FN0:PIP.ABS=SY0:PIP.ABS\r' --wait 3000 --prompt '>' \
    --type 'DISMOUNT FN0:\r' --until 'DISMOUNTED' --prompt '>' \
    --type 'MOUNT FN0:\r' --until 'MOUNTED ON FN0:' --prompt '>' \
    --type 'CAT FN0:\r' --until 'PIP' --prompt '>' --wait 500 --screen \
    --type 'DISMOUNT FN0:\r' --until 'DISMOUNTED' --prompt '>' \
    --type 'RUN SY1:CONFIG.ABS\r' --until 'Drive Slots' --until 'Quit' --wait 1000 --screen \
    > "${WORK}/a.log" 2>&1 || { grep -E 'timed out' "${WORK}/a.log" >&2 || true; screen "${WORK}/a.log" | tail -30 >&2; fail "session A stopped"; }
screen "${WORK}/a.log" | tail -42 | head -20

IMG="${WORK}/a/data/fujinet/SD/TEST.H8D"
hdosfs ls "${IMG}" --check >/dev/null || fail "the image's file system is damaged"
hdosfs get "${IMG}" PIP.ABS -o "${WORK}/pip-fn.abs"
hdosfs get "${WORK}/boot.h8d" PIP.ABS -o "${WORK}/pip-sy.abs"
cmp -s "${WORK}/pip-fn.abs" "${WORK}/pip-sy.abs" || fail "PIP.ABS in the image differs from SY0:'s"
echo "PASS: PIP.ABS copied through FN0: is in the image byte for byte"

# HDOS loads the driver just under its lower bound, its end page-aligned, its units' GRTs above
mapfile -t SYSM < <(grep -A1 -- '---- mem 0x20d0 2' "${WORK}/a.log" | grep -oE '20D0 +[0-9A-F]{2} [0-9A-F]{2}' | awk '{print $3$2}')
python3 -I - "${ROOT}/build/FN.DVD" "${SYSM[0]}" "${SYSM[1]}" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read()
before, after = int(sys.argv[2], 16), int(sys.argv[3], 16)
dvl, mnu = (d[4] | d[5] << 8) - 0x200, d[9]
end = (before - mnu * 256) & 0xFF00                 # the driver ends on a page, GRTs above
want = end - dvl
print('S.SYSM %04X -> %04X (driver %d bytes, %d units): expected %04X' % (before, after, dvl, mnu, want))
if after != want:
    sys.exit('FAIL: HDOS put the driver at %04X, not %04X' % (after, want))
print('PASS: the driver loaded where expected')
EOF

# --- Session B: read only, and the errors ---
mkdir -p "${WORK}/b/data/fujinet/SD"
cp "${WORK}/test.h8d" "${WORK}/b/data/fujinet/SD/TEST.H8D"
cp "${WORK}/notdisk.img" "${WORK}/b/data/fujinet/SD/NOTDISK.IMG"
SUM="$(sha256sum < "${WORK}/b/data/fujinet/SD/TEST.H8D")"
mapfile -t BOOT_B < <(boot)
"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/b" --timeout 90 "${BOOT_B[@]}" \
    --type 'RUN SY1:CONFIG.ABS\r' --until 'Drive Slots' --until 'Quit' --wait 1500 \
    --type '\r' --until 'TEST.H8D' --wait 2000 --type 'f' --until 'matching' --type 'TEST*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '1' --wait 300 --type '\r' \
    --until 'TEST.H8D' --wait 1500 --type 'f' --until 'matching' --key erase --wait 300 --type 'NOTDISK*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '3' --wait 300 --type '\r' \
    --until 'NOTDISK.IMG' --wait 1500 --type '`' --until 'Mount drives' --wait 1500 --type '`' \
    --until 'FUJINET DRIVES' --prompt '>' --wait 500 \
    --type 'MOUNT FN1:\r' --wait 4000 --prompt '>' \
    --type 'MOUNT FN2:\r' --wait 4000 --prompt '>' \
    --type 'MOUNT FN0:\r' --until 'MOUNTED ON FN0:' --prompt '>' \
    --type 'CAT FN0:\r' --until 'HELLO' --prompt '>' \
    --type 'COPY FN0:X.ABS=SY0:PIP.ABS\r' --wait 3000 --prompt '>' \
    --type 'DISMOUNT FN0:\r' --until 'DISMOUNTED' --prompt '>' --wait 500 --screen \
    > "${WORK}/b.log" 2>&1 || { grep -E 'timed out' "${WORK}/b.log" >&2 || true; screen "${WORK}/b.log" | tail -30 >&2; fail "session B stopped"; }
OUT="$(screen "${WORK}/b.log")"
echo "${OUT}" | tail -22
grep -A1 'MOUNT FN1:' <<< "${OUT}" | grep -qi 'not available' || fail "MOUNT FN1: (nothing in slot 2) didn't say the unit isn't available"
grep -A1 'MOUNT FN2:' <<< "${OUT}" | grep -qi 'unable to read' || fail "MOUNT FN2: (not an H17 disk) didn't say it can't read it"
# HDOS knows from the mount (the driver's answer to its write-protect probe)
grep -A2 'COPY FN0:X.ABS' <<< "${OUT}" | grep -qi 'incapable of write' || fail "COPY onto the read-only FN0: wasn't refused"
[[ "$(sha256sum < "${WORK}/b/data/fujinet/SD/TEST.H8D")" == "${SUM}" ]] || fail "the read-only image changed"
echo "PASS: read only, an empty slot and a non-disk each refused, the image untouched"
