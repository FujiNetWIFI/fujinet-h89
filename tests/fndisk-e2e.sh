#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): boot a 62K CP/M, mount an H17 image in FujiNet
# slot 1 with CONFIG, load FNDISK, then read, write and warm boot on D:, and
# check on the host that the file written is in the image.
#
#   tests/fndisk-e2e.sh --boot CPM62.h8d --config CONFIG.COM [--rig DIR] [--keep DIR]
#
# CONFIG.COM must be built with -DH89_RIG_KEYS (` stands in for ESC: the
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
        *) echo "usage: $0 --boot CPM62.h8d --config CONFIG.COM [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
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

# B: holds CONFIG and FNDISK
mkdir -p "${WORK}/tools"
cp "${CONFIG}" "${WORK}/tools/CONFIG.COM"
cp "${FNDISK}" "${WORK}/tools/FNDISK.COM"
(cd "${WORK}/tools" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b CONFIG.COM -a FNDISK.COM -o disk >/dev/null)
fixup "${WORK}/tools/disk"

# The FujiNet's SD card: an H17 CP/M disk with a text file on it
SD="${WORK}/home/data/fujinet/SD"
mkdir -p "${SD}" "${WORK}/test"
printf 'Hello from a FujiNet drive on the H89.\r\nThe second line.\r\n\032' > "${WORK}/test/HELLO.TXT"
printf '\311' > "${WORK}/test/STUB.COM"
(cd "${WORK}/test" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b STUB.COM -a HELLO.TXT -o disk >/dev/null)
fixup "${WORK}/test/disk"
cp "${WORK}/test/disk" "${SD}/TEST.H8D"
cp "${BOOT}" "${WORK}/boot.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools/disk" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --prompt 'A>' --type 'B:CONFIG\r' --until 'Drive Slots' --until 'Quit' --wait 1500 \
    --type '\r' --until 'TEST.H8D' --wait 1500 \
    --type 'f' --until 'matching' --type 'TEST*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '1' --wait 300 --type 'w' \
    --until 'TEST.H8D' --wait 1500 --type '`' --until 'Mount drives' --wait 1500 \
    --type '`' --until 'FujiNet drives' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Installed' --prompt 'A>' --wait 500 --screen \
    --type 'DIR D:\r' --until 'HELLO' --prompt 'A>' --wait 500 \
    --type 'TYPE D:HELLO.TXT\r' --until 'second line' --prompt 'A>' --wait 500 \
    --type 'PIP D:=B:FNDISK.COM\r' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Already installed' --prompt 'A>' --wait 500 \
    --type 'DIR D:\r' --until 'FNDISK' --prompt 'A>' --wait 500 \
    --type 'STAT D:\r' --until 'Bytes Remaining On D:' --prompt 'A>' --wait 500 \
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
