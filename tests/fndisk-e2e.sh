#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): boot a 62K CP/M, mount an H17 image in FujiNet
# slot 1 with FNCONFIG, load FNDISK, then read, write and warm boot on D:, and
# check on the host that the file written is in the image. Then print on
# UL1: (the FujiNet's printer) and on CRT:, and check what the printer got.
# First, check where FNDISK puts itself on a 64K system (below the CCP), a 62K
# one (above the BIOS) and one with something already below the CCP.
#
#   tests/fndisk-e2e.sh --config FNCONFIG.COM [--boot CPM62.h8d] [--rig DIR] [--keep DIR]
#
# The main run is on the rig's 64K CP/M; --boot is a 62K one (make it with
# make-62k-boot.sh), which is also checked if given.
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
        *) echo "usage: $0 --config FNCONFIG.COM [--boot CPM62.h8d] [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
RUN="${RIG}/build/core/h89_session_run"
BOOT64="${RIG}/tools/disks/boot/cpm-2.2.04-64k.h8d"
[[ -f "${BOOT64}" && -f "${CONFIG}" ]] || { echo "need --config (and the rig's 64K CP/M)" >&2; exit 2; }
[[ -z "${BOOT}" || -f "${BOOT}" ]] || { echo "no such --boot ${BOOT}" >&2; exit 2; }
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

# Where it goes: just below the CCP (BIOS - 1600H), or below where 0006H
# points if that is lower, in whole pages, and 0006H follows it: after
# installing, and after a warm boot and a second run (which says where it is).
# The resident part and its buffers are res_end bytes (make prints it).
#   $1 = name, $2 = boot disk, $3 = poke to 0007H or "", $4 = base's high byte
install_at() {
    local log="${WORK}/$1.log" poke=() hi="$4" top="${4:0:2}"
    cp "$2" "${WORK}/$1.h8d"
    [[ -z "$3" ]] || poke=(--debug "poke 0x7 \$$3"       # and an RSX's entry there: JP E006H
                           --debug "poke 0x$306 \$c3 \$06 \$e0")
    "${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/$1" --timeout 90 \
        --disk "h17:1=${WORK}/$1.h8d" --disk "h17:2=${WORK}/tools/disk" \
        --until 'H:' --type 'B\r' --until 'A>' --wait 1000 --debug 'radix hex' \
        ${poke[@]+"${poke[@]}"} \
        --type 'B:FNDISK\r' --until 'Installed at' --prompt 'A>' --wait 500 --screen \
        --debug 'mem 6 2' \
        --type '\x03' --wait 1500 \
        --type 'B:FNDISK\r' --until 'Already installed at' --prompt 'A>' --wait 500 --screen \
        --debug 'mem 6 2' \
        > "${log}" 2>&1 || { grep -E 'timed out|failed' "${log}" >&2 || true
            sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${log}" | sed 's/^\[fujinet\] //' | tail -8 >&2
            echo "FAIL: install at ($1): the run stopped" >&2; exit 1; }
    grep -q "Installed at ${hi}00H; the TPA ends at $(printf '%02X' $((0x${hi} - 1)))FFH\." "${log}" \
        && grep -q "Already installed at ${hi}00H\." "${log}" \
        || { grep -E 'nstalled|Not enough' "${log}" >&2; echo "FAIL: install at ($1): want ${hi}00H" >&2; exit 1; }
    # 0006H holds 00 ${hi} (little-endian)
    [[ $(grep -cE "^(\[fujinet\] )?0006 +00 ${hi}" "${log}") -ge 2 ]] \
        || { grep -E '^(\[fujinet\] )?0006' "${log}" >&2
             echo "FAIL: install at ($1): 0006H isn't ${hi}00H after install and warm boot" >&2; exit 1; }
    echo "PASS: install at ($1): ${hi}00H, 0006H lowered to it, kept by the warm boot"
}
# the 64K system: BIOS EE00H, CCP D800H, so CF00H
install_at 64k "${BOOT64}" "" CF
# something already lowered the BDOS address to C0xxH: below that, B700H
install_at below-an-rsx "${BOOT64}" c0 B7

# A 62K system's BIOS RAM ends at F712H: the resident part goes above it, to
# the top of memory (its res_end bytes), and 0006H stays the BDOS's own (BIOS
# E600H less 0DFAH), through the warm boot and a second run.
install_above() {
    local log="${WORK}/$1.log" res_end base
    res_end=$((0x$(sed -n 's/^DEFC res_end *= \$\([0-9A-Fa-f]*\)/\1/p' "${ROOT}/build/fndisk/resident.def")))
    base=$(printf '%04X' $((0x10000 - res_end)))
    cp "$2" "${WORK}/$1.h8d"
    "${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/$1" --timeout 90 \
        --disk "h17:1=${WORK}/$1.h8d" --disk "h17:2=${WORK}/tools/disk" \
        --until 'H:' --type 'B\r' --until 'A>' --wait 1000 --debug 'radix hex' \
        --type 'B:FNDISK\r' --until 'Installed at' --prompt 'A>' --wait 500 --screen \
        --debug 'mem 6 2' \
        --type '\x03' --wait 1500 \
        --type 'B:FNDISK\r' --until 'Already installed at' --prompt 'A>' --wait 500 --screen \
        --debug 'mem 6 2' \
        > "${log}" 2>&1 || { grep -E 'timed out|failed' "${log}" >&2 || true
            echo "FAIL: install above ($1): the run stopped" >&2; exit 1; }
    grep -q "Installed at ${base}H, above the BIOS; the TPA is unchanged\." "${log}" \
        && grep -q "Already installed at ${base}H\." "${log}" \
        || { grep -E 'nstalled|Not enough' "${log}" >&2; echo "FAIL: install above ($1): want ${base}H" >&2; exit 1; }
    # 0006H holds 06 D8
    [[ $(grep -cE "^(\[fujinet\] )?0006 +06 D8" "${log}") -ge 2 ]] \
        || { grep -E '^(\[fujinet\] )?0006' "${log}" >&2
             echo "FAIL: install above ($1): 0006H isn't D806H after install and warm boot" >&2; exit 1; }
    echo "PASS: install above ($1): ${base}H, 0006H still D806H, through the warm boot"
}
[[ -z "${BOOT}" ]] || install_above 62k "${BOOT}"

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
cp "${BOOT64}" "${WORK}/boot.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools/disk" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --prompt 'A>' --type 'B:FNCONFIG\r' --until 'Drive Slots' --until 'Quit' --wait 1500 \
    --type '\r' --until 'TEST.H8D' --wait 1500 \
    --type 'f' --until 'matching' --type 'TEST*\r' --wait 3000 \
    --type '\r' --until 'Put it in which' --wait 1000 --type '1' --wait 300 --type 'w' \
    --until 'TEST.H8D' --wait 1500 --type '`' --until 'Mount drives' --wait 1500 \
    --type '`' --until 'FujiNet drives' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Installed at' --until 'LST: is UL1:' --prompt 'A>' --wait 500 --screen \
    --type 'DIR D:\r' --until 'HELLO' --prompt 'A>' --wait 500 \
    --type 'TYPE D:HELLO.TXT\r' --until 'second line' --prompt 'A>' --wait 500 \
    --type 'PIP D:=B:FNDISK.COM\r' --prompt 'A>' --wait 500 \
    --type 'B:FNDISK\r' --until 'Already installed at' --prompt 'A>' --wait 500 \
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
