#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): NPIP under CP/M. Copies between C: and the
# FujiNet's SD card (SD:/ URLs), both ways and SD to SD, at the * prompt
# and from the command line; a file over 64K, whose size comes from its
# directory; HTTP to and from a local server; errors; ^C in a download, an
# upload (to SD: and to HTTP, which must never see a PUT) and at the
# prompt; then LST: (FNDISK's UL1:, the FujiNet's printer) and CON:. On the
# host, every copy is checked byte for byte.
#
#   tests/npip-cpm-e2e.sh --boot CPM62.h8d [--rig DIR] [--keep DIR] [--tnfs-root DIR]
#
# CPM62.h8d is a 62K system (tests/make-62k-boot.sh), for FNDISK.
# --tnfs-root DIR: also copy to and from TNFS://127.0.0.1/, the tnfsd on
# this machine serving DIR (TNFS has no port in a URL: it's always 16384).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
BOOT=""; KEEP=""; TNFS_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot) BOOT="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        --tnfs-root) TNFS_ROOT="$2"; shift 2 ;;
        *) echo "usage: $0 --boot CPM62.h8d [--rig DIR] [--keep DIR] [--tnfs-root DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${BOOT}" ]] || { echo "need --boot" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
APPMAKE="${APPMAKE:-z88dk-appmake}"
NPIP="${ROOT}/build/NPIP.COM"
FNDISK="${ROOT}/build/FNDISK.COM"
[[ -f "${NPIP}" && -f "${FNDISK}" ]] || { echo "build NPIP.COM and FNDISK.COM first (make)" >&2; exit 2; }

if [[ -n "${KEEP}" ]]; then WORK="${KEEP}"; rm -rf "${WORK}"; mkdir -p "${WORK}"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/npip-cpm-e2e-XXXXXX")"; fi
PIDS=(); TNFS_DIR=""
finish() {
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
    [[ -z "${TNFS_DIR}" ]] || rm -rf "${TNFS_DIR}"
    [[ -n "${KEEP}" ]] || rm -rf "${WORK}"
}
trap finish EXIT

fixup() { python3 -I "${ROOT}/tools/cpm-dir-fixup.py" "$1"; }
cpmget() { python3 -I "${ROOT}/tests/cpm-get.py" "$@"; }

# The FujiNet's own files in HOME, with its printer on as RAW (every byte to
# SD/paper), as fndisk-e2e.sh does
printer_on() {
    local out="${FUJINET_LIB_DIR:-${RIG}/tools/fujinet/work/out}" fn="$1/data/fujinet"
    mkdir -p "${fn}"
    cp -r "${out}/fnconfig.ini" "${out}/data" "${out}/SD" "${fn}/"
    sed -i 's/^printer_enabled=0$/printer_enabled=1/' "${fn}/fnconfig.ini"
    printf '\n[Printer1]\ntype=0\n' >> "${fn}/fnconfig.ini"
}

# The SD card's files: HELLO.TXT isn't a whole number of records, BIG.BIN
# is over 64K, Long-Name-File.txt has a name only the * prompt can give,
# PRINT.TXT has a ^Z, where PIP and NPIP stop printing, and STOP.BIN is
# for ^C (its own name, so the wait for its progress line can't match an
# older one)
printer_on "${WORK}/home"
SD="${WORK}/home/data/fujinet/SD"
mkdir -p "${WORK}/web"
python3 -I - "${SD}" "${WORK}/web" <<'EOF'
import random, sys
sd, web = sys.argv[1:3]
random.seed(89)
open(sd + '/HELLO.TXT', 'wb').write(
    b''.join(b'Line %03d of HELLO.TXT, from the FujiNet SD card.\r\n' % i for i in range(20))[:1000])
open(sd + '/BIG.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/STOP.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/Long-Name-File.txt', 'wb').write(b'A file with a long name.\r\n')
open(sd + '/PRINT.TXT', 'wb').write(b'NPIP to LST:\r\nThe second line.\r\n\x1aNot printed\r\n')
open(web + '/WEB.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
EOF

# B: holds NPIP and FNDISK, and STOP.COM and HSTOP.COM to upload for ^C;
# C: is for what's copied (a stub, as appmake wants a file)
mkdir -p "${WORK}/tools" "${WORK}/data"
cp "${NPIP}" "${FNDISK}" "${WORK}/tools/"
cp "${NPIP}" "${WORK}/tools/STOP.COM"
cp "${NPIP}" "${WORK}/tools/HSTOP.COM"
(cd "${WORK}/tools" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b NPIP.COM -a FNDISK.COM -a STOP.COM -a HSTOP.COM -o disk >/dev/null)
fixup "${WORK}/tools/disk"
printf '\311' > "${WORK}/data/STUB.COM"
(cd "${WORK}/data" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b STUB.COM -o disk >/dev/null)
fixup "${WORK}/data/disk"
cp "${BOOT}" "${WORK}/boot.h8d"

# A web server that takes PUT too, for the HTTP copies, if one will start
HTTP=(); HTTP_STOP=()
PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I "${ROOT}/tests/http-put-server.py" "${PORT}" "${WORK}/web" "${WORK}/http.log" \
    >"${WORK}/http.err" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do
    if python3 -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/WEB.BIN').read()" 2>/dev/null; then
        H="http://127.0.0.1:${PORT}"
        HTTP=(--type "c:=${H}/WEB.BIN\\r" --until '/?' --screen --wait 500 --prompt '*'
              --type "${H}/=b:npip.com\\r" --wait 500 --prompt '*')
        HTTP_STOP=(--type "B:NPIP ${H^^}/HSTOP.COM=B:HSTOP.COM\\r" --until 'HSTOP.COM  ' --key ctrl-c
                   --until 'Stopped.' --prompt 'A>' --wait 300 --screen)
        break
    fi
    sleep 0.1
done
[[ ${#HTTP[@]} -gt 0 ]] || echo "SKIP: HTTP (no web server would start)"

# TNFS, with --tnfs-root: a directory of our own there
TNFS=()
if [[ -n "${TNFS_ROOT}" ]]; then
    TNFS_DIR="${TNFS_ROOT}/npip-e2e-$$"
    mkdir -p "${TNFS_DIR}"
    cp "${SD}/BIG.BIN" "${TNFS_DIR}/TBIG.BIN"
    T="tnfs://127.0.0.1/npip-e2e-$$"
    TNFS=(--type "${T}/=b:npip.com\\r" --wait 500 --prompt '*'
          --type "sd:/TBIG2.BIN=${T}/TBIG.BIN\\r" --wait 500 --prompt '*')
fi

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools/disk" --disk "h17:3=${WORK}/data/disk" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --type 'B:NPIP C:=SD:/HELLO.TXT\r' --until '1000/1000' --prompt 'A>' --wait 300 \
    --type 'B:NPIP\r' --prompt '*' \
    --type 'c:=sd:/Long-Name-File.txt\r' --wait 300 --prompt '*' \
    --type 'sd:/OUT.COM=b:fndisk.com\r' --wait 300 --prompt '*' \
    --type 'sd:/=b:npip.com\r' --wait 300 --prompt '*' \
    --type 'c:=sd:/BIG.BIN\r' --until '/70000' --screen --wait 500 --prompt '*' \
    --type 'sd:/BIG2.BIN=sd:/BIG.BIN\r' --wait 300 --prompt '*' \
    --type 'sd:/BACK.BIN=c:big.bin\r' --wait 300 --prompt '*' \
    --type 'c:=sd:/NOSUCH.TXT\r' --wait 300 --prompt '*' \
    --type 'xy:=sd:/HELLO.TXT\r' --wait 300 --prompt '*' \
    --type 'c:big.bin\r' --wait 300 --prompt '*' --screen \
    ${TNFS[@]+"${TNFS[@]}"} \
    --type '\r' --prompt 'A>' --type 'ERA C:BIG.BIN\r' --wait 1000 --prompt 'A>' \
    --type 'B:NPIP\r' --prompt '*' ${HTTP[@]+"${HTTP[@]}"} --type '\r' --prompt 'A>' --wait 300 \
    --type 'B:NPIP C:=SD:/STOP.BIN\r' --until 'STOP.BIN  ' --wait 500 --key ctrl-c --until 'Stopped.' --prompt 'A>' --wait 300 \
    --type 'B:NPIP SD:/UP.COM=B:STOP.COM\r' --until 'STOP.COM  ' --key ctrl-c --prompt 'A>' --wait 300 --screen \
    ${HTTP_STOP[@]+"${HTTP_STOP[@]}"} \
    --type 'B:NPIP\r' --prompt '*' --key ctrl-c --prompt 'A>' --wait 300 --screen \
    --type 'B:FNDISK\r' --until 'Installed' --prompt 'A>' --wait 500 \
    --type 'B:NPIP LST:=SD:/PRINT.TXT\r' --prompt 'A>' --wait 500 \
    --type 'B:NPIP CON:=SD:/HELLO.TXT\r' --until 'Line 019' --prompt 'A>' --wait 300 --screen \
    > "${WORK}/run.log" 2>&1 || { grep -E 'timed out|failed' "${WORK}/run.log" >&2 || true
        sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -30 >&2
        echo "FAIL: the run stopped" >&2; exit 1; }

sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -26

# What the screens showed
python3 -I - "${WORK}/run.log" "${#HTTP[@]}" <<'EOF'
import re, sys
log = re.sub(r'(?m)^\[fujinet\] ', '', open(sys.argv[1], errors='replace').read())
screens = re.findall(r'---- screen ----\n(.*?)\n----------------', log, re.S)
def after(cmd):
    for s in screens:
        ls = s.splitlines()
        for i, l in enumerate(ls):
            if l.endswith(cmd) and i + 1 < len(ls):
                return ls[i + 1]
    sys.exit('FAIL: no screen shows %r' % cmd)
def want(cmd, pattern, what):
    line = after(cmd)
    if not re.search(pattern, line):
        sys.exit('FAIL: %s: after %r the screen shows %r' % (what, cmd, line))
    print('PASS: %s' % what)
def lines(pattern, what):
    if not any(re.search(pattern, s, re.M) for s in screens):
        sys.exit('FAIL: %s: no screen shows it' % what)
    print('PASS: %s' % what)
m = re.search(r'\] +(\d+)/70000$', after('*c:=sd:/BIG.BIN'))
if not m or int(m.group(1)) >= 70000:
    sys.exit('FAIL: the size of a file over 64K: %r' % after('*c:=sd:/BIG.BIN'))
print('PASS: the size of a file over 64K came from its directory (%s/70000 as it copied)' % m.group(1))
want('*c:=sd:/NOSUCH.TXT', r'^sd:/NOSUCH.TXT - not found$', 'a missing file: not found')
want('*xy:=sd:/HELLO.TXT', r'^XY: - no such device$', 'an unknown device')
want('*c:big.bin', r'^NPIP dest=source', 'no =: how to use it')
if sys.argv[2] != '0':
    want('/WEB.BIN', r'\] +\d+/\?$', 'HTTP: the size not known (? as it copied)')
    lines(r'^A>B:NPIP HTTP://.*/HSTOP.COM=B:HSTOP.COM\nHSTOP.COM +\[.*\] +\d+/7168\nStopped\.\nA>',
          '^C in an HTTP upload: Stopped.')
lines(r'^A>B:NPIP C:=SD:/STOP.BIN\nSTOP.BIN +\[#*\.+\] +\d+/70000\nStopped\.\nA>',
      '^C in a download: Stopped.')
lines(r'^A>B:NPIP SD:/UP.COM=B:STOP.COM\nSTOP.COM +\[.*\] +\d+/7168\nStopped\.\nA>',
      '^C in an upload: Stopped.')
lines(r'^A>B:NPIP\n\*\^C\n\n?A>', '^C at the * prompt')
want('B:NPIP CON:=SD:/HELLO.TXT', r'^Line 000 of HELLO.TXT', 'CON:, with no progress line')
EOF

# What the copies hold, byte for byte (a CP/M file is whole records, the
# last filled out with ^Z; an upload sends the records as they are)
cpmget "${WORK}/data/disk" --ls > "${WORK}/c.ls"
for f in HELLO.TXT LONGNAME.TXT WEB.BIN; do
    [[ "$f" != WEB.BIN || ${#HTTP[@]} -gt 0 ]] || continue
    cpmget "${WORK}/data/disk" "$f" -o "${WORK}/c.$f"
done
for f in FNDISK.COM NPIP.COM; do cpmget "${WORK}/tools/disk" "$f" -o "${WORK}/b.$f"; done
python3 -I - "${WORK}" "${SD}" "${ROOT}/build" "${#HTTP[@]}" "${TNFS_DIR}" <<'EOF'
import os, sys
work, sd, build, http, tnfs = sys.argv[1:6]
def rd(p):
    return open(p, 'rb').read()
def padded(got, want, what, fill=0x1A):
    n = (len(want) + 127) // 128 * 128
    if got[:len(want)] != want or len(got) != n or set(got[len(want):]) - {fill}:
        sys.exit('FAIL: %s: %d bytes, not %d of the source then ^Z to %d' % (what, len(got), len(want), n))
    print('PASS: %s, %d bytes' % (what, len(want)))
padded(rd(work + '/c.HELLO.TXT'), rd(sd + '/HELLO.TXT'), 'SD:/HELLO.TXT to C: (from the command line)')
padded(rd(work + '/c.LONGNAME.TXT'), rd(sd + '/Long-Name-File.txt'), 'Long-Name-File.txt to C:LONGNAME.TXT')
def same(got, want, what):
    if got != want:
        sys.exit('FAIL: %s: %d bytes, not the %d of the source' % (what, len(got), len(want)))
    print('PASS: %s, %d bytes' % (what, len(want)))
same(rd(sd + '/OUT.COM'), rd(work + '/b.FNDISK.COM'), 'B:FNDISK.COM to SD:/OUT.COM')
same(rd(sd + '/NPIP.COM'), rd(work + '/b.NPIP.COM'), 'B:NPIP.COM to SD:/, named for it')
padded(rd(sd + '/BACK.BIN'), rd(sd + '/BIG.BIN'), 'SD:/BIG.BIN to C: and back')
same(rd(sd + '/BIG2.BIN'), rd(sd + '/BIG.BIN'), 'SD:/BIG.BIN to SD:/BIG2.BIN')
if http != '0':
    padded(rd(work + '/c.WEB.BIN'), rd(work + '/web/WEB.BIN'), 'HTTP to C:WEB.BIN')
    same(rd(work + '/web/NPIP.COM'), rd(work + '/b.NPIP.COM'), 'B:NPIP.COM to HTTP (a PUT)')
    log = open(work + '/http.log').read()
    if 'HSTOP' in log or os.path.exists(work + '/web/HSTOP.COM'):
        sys.exit('FAIL: ^C in an HTTP upload: the server saw %r' %
                 [l for l in log.splitlines() if 'HSTOP' in l])
    print('PASS: ^C in an HTTP upload: the server saw nothing (no PUT, no DELETE)')
if tnfs:
    same(rd(tnfs + '/NPIP.COM'), rd(work + '/b.NPIP.COM'), 'B:NPIP.COM to TNFS')
    same(rd(sd + '/TBIG2.BIN'), rd(tnfs + '/TBIG.BIN'), 'TNFS to SD:/TBIG2.BIN')
names = open(work + '/c.ls').read().split()
if any(n.startswith('STOP.') for n in names):
    sys.exit('FAIL: ^C in a download left %s on C:' % [n for n in names if n.startswith('STOP.')])
print('PASS: ^C in a download left nothing on C:')
if os.path.exists(sd + '/UP.COM'):
    sys.exit('FAIL: ^C in an upload left SD:/UP.COM')
print('PASS: ^C in an upload left nothing on the SD card')
text = rd(sd + '/PRINT.TXT').split(b'\x1a')[0]
try:
    paper = rd(sd + '/paper')
except FileNotFoundError:
    sys.exit('FAIL: LST: printed nothing')
if paper != text:
    sys.exit('FAIL: LST: printed %r, not %r' % (paper, text))
print('PASS: LST: (FNDISK\'s UL1:) printed PRINT.TXT to its ^Z')
EOF
