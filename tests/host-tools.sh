#!/usr/bin/env bash
# The host tools, with no emulator: hdosfs.py on Heath's own HDOS 2.0 boot
# disk and on disks it makes, and mkpic.py on a good driver and a bad one.
#
#   tests/host-tools.sh [--rig DIR]     (make check)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
[[ "${1:-}" == --rig ]] && RIG="$2"
Z80ASM="${Z80ASM:-z88dk-z80asm}"
hdosfs() { python3 -I "${ROOT}/tools/hdosfs.py" "$@"; }
mkpic() { python3 -I "${ROOT}/tools/mkpic.py" "$@"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/host-tools-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Heath's boot disk: converted, read, a file taken off and put back
BOOT17="${RIG}/tools/disks/boot/hdos-2.0.h17disk"
if [[ -f "${BOOT17}" ]]; then
    hdosfs convert "${BOOT17}" "${WORK}/boot.h8d" >/dev/null
    out="$(hdosfs ls "${WORK}/boot.h8d" --check)"
    [[ "$(grep -c '^  ' <<< "${out}")" == 23 ]] || fail "the boot disk should list 23 files"
    grep -q '^0 groups free' <<< "${out}" || fail "the boot disk should be full"
    hdosfs get "${WORK}/boot.h8d" DK.DVD -o "${WORK}/dk1"
    hdosfs rm "${WORK}/boot.h8d" DK.DVD
    grep -q '^8 groups free' <<< "$(hdosfs ls "${WORK}/boot.h8d")" || fail "DK.DVD should free 8 groups"
    hdosfs put "${WORK}/boot.h8d" "${WORK}/dk1" --name DK.DVD --flags C0
    hdosfs get "${WORK}/boot.h8d" DK.DVD -o "${WORK}/dk2"
    cmp -s "${WORK}/dk1" "${WORK}/dk2" || fail "DK.DVD changed on the way off and back"
    hdosfs ls "${WORK}/boot.h8d" --check >/dev/null
    echo "PASS: the HDOS 2.0 boot disk converts, reads and takes a file off and back"
else
    echo "SKIP: no ${BOOT17}"
fi

# A disk made here: a file of an odd length in and out
hdosfs blank "${WORK}/data.h8d" --label TEST
head -c 1000 /dev/urandom > "${WORK}/odd.bin"
hdosfs put "${WORK}/data.h8d" "${WORK}/odd.bin" --name ODD.BIN
hdosfs ls "${WORK}/data.h8d" --check >/dev/null
hdosfs get "${WORK}/data.h8d" ODD.BIN -o "${WORK}/odd.out"
cmp -s <(head -c 1000 "${WORK}/odd.out") "${WORK}/odd.bin" || fail "ODD.BIN didn't come back"
[[ "$(stat -c %s "${WORK}/odd.out")" == 1024 ]] || fail "ODD.BIN should be 4 sectors"
echo "PASS: a blank disk takes a file and gives it back"

# mkpic: a good driver builds, half an address is refused
pic() {   # $1 = name, $2.. = extra assembler options
    local n="$1"; shift
    for org in 0x0000 0x0101 0xD137; do
        mkdir -p "${WORK}/${n}${org}"
        "${Z80ASM}" -b -m "$@" -O="${WORK}/${n}${org}" -r="${org}" -o="${WORK}/${n}${org}/p.bin" "${ROOT}/tests/pic-test.asm"
    done
    mkpic --map "${WORK}/${n}0x0000/p.map" -o "${WORK}/${n}.dvd" \
        "${WORK}/${n}0x0000/p.bin" "${WORK}/${n}0x0101/p.bin" "${WORK}/${n}0xD137/p.bin"
}
pic good >/dev/null || fail "mkpic refused a good driver"
python3 -I - "${WORK}/good.dvd" <<'EOF' || fail "the good driver's relocation table is wrong"
import sys
d = open(sys.argv[1], 'rb').read()
ptr = d[4] | d[5] << 8
table = [d[i] | d[i + 1] << 8 for i in range(ptr, len(d), 2)]
assert table == [0x201, 0x204, 0x206, 0], table         # ld hl,table; defw dvd_entry, table
assert (d[2] | d[3] << 8) == len(d)
EOF
if pic bad -DBAD >/dev/null 2>&1; then fail "mkpic took half an address"; fi
echo "PASS: mkpic builds a driver's relocation table, and refuses half an address"
