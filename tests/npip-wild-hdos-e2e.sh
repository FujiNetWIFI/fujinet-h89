#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): NPIP's wildcards under HDOS 2.0. A * in a URL's
# file name lists that directory on the FujiNet and copies each file to a
# device or a directory; * and ? in a local name copy each file DIRECT.SYS
# names that matches (not the system's own), to a directory on the SD card,
# or to LP:; and the refusals. ^C in the middle of a batch stops it and
# leaves the FujiNet working. On the host, every copy is checked byte for
# byte.
#
#   tests/npip-wild-hdos-e2e.sh --boot BOOT.h8d [--rig DIR] [--keep DIR]
#
# BOOT.h8d comes from tests/make-hdos-boot.sh (it has LP.DVD).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
BOOT=""; KEEP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot) BOOT="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        *) echo "usage: $0 --boot BOOT.h8d [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${BOOT}" ]] || { echo "need --boot" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
NPIP="${ROOT}/build/NPIP.ABS"
[[ -f "${NPIP}" ]] || { echo "build NPIP.ABS first (make)" >&2; exit 2; }
hdosfs() { python3 -I "${ROOT}/tools/hdosfs.py" "$@"; }

if [[ -n "${KEEP}" ]]; then WORK="${KEEP}"; rm -rf "${WORK}"; mkdir -p "${WORK}"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/npip-wild-hdos-XXXXXX")"; trap 'rm -rf "${WORK}"' EXIT; fi

# The FujiNet's own files in HOME, with its printer on as RAW (every byte to
# SD/paper), as npip-hdos-e2e.sh does
printer_on() {
    local out="${FUJINET_LIB_DIR:-${RIG}/tools/fujinet/work/out}" fn="$1/data/fujinet"
    mkdir -p "${fn}"
    cp -r "${out}/fnconfig.ini" "${out}/data" "${out}/SD" "${fn}/"
    sed -i 's/^printer_enabled=0$/printer_enabled=1/' "${fn}/fnconfig.ini"
    printf '\n[Printer1]\ntype=0\n' >> "${fn}/fnconfig.ini"
}

# SD:/W/ holds the files a * names: AA.TXT AB.TXT BA.TXT, CC.BIN, a directory
# SUB/ (a * must leave it out) and Long-Name-File.txt (crunched to 8.3).
# SD:/BIG/ holds two files over 64K, for ^C.
printer_on "${WORK}/home"
SD="${WORK}/home/data/fujinet/SD"
python3 -I - "${SD}" <<'EOF'
import os, random, sys
sd = sys.argv[1]
random.seed(89)
for d in ('W', 'W/SUB', 'OUT', 'OUT2', 'OUT4', 'BIG'):
    os.makedirs(sd + '/' + d, exist_ok=True)
for n in ('AA', 'AB', 'BA'):
    open('%s/W/%s.TXT' % (sd, n), 'wb').write(
        b''.join(b'Line %03d of %s.TXT\n' % (i, n.encode()) for i in range(12)))
open(sd + '/W/CC.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(3000)))
open(sd + '/W/Long-Name-File.txt', 'wb').write(b'A file with a long name.\n')
open(sd + '/W/SUB/IN.TXT', 'wb').write(b'inside\n')
open(sd + '/BIG/ONE.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/BIG/TWO.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
EOF

# SY1: holds NPIP and STOP.ABS; SY2: is for what's copied
hdosfs blank "${WORK}/tools.h8d" --label TOOLS >/dev/null
hdosfs put "${WORK}/tools.h8d" "${NPIP}" --name NPIP.ABS
hdosfs put "${WORK}/tools.h8d" "${NPIP}" --name STOP.ABS
hdosfs blank "${WORK}/data.h8d" --label DATA >/dev/null
cp "${BOOT}" "${WORK}/boot.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools.h8d" --disk "h17:3=${WORK}/data.h8d" \
    --until 'H:' --type 'B\r' --wait 3000 --type ' ' --wait 500 --type ' ' \
    --prompt 'ACTION? <BOOT>' --type '\r' --prompt 'DATE (DD-MMM-YY)?' --type '11-OCT-80\r' \
    --prompt '>' --type 'MOUNT SY1:\r' --wait 2000 --prompt '>' \
    --type 'MOUNT SY2:\r' --wait 2000 --prompt '>' \
    --type 'RUN SY1:NPIP.ABS SY2:=SD:/W/*.TXT\r' --until 'files copied' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SD:/OUT/=SY2:A?.TXT\r' --until 'files copied' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SD:/OUT2/=SY2:*.*\r' --until 'files copied' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SD:/OUT4/=SY1:*.ABS\r' --until 'files copied' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SY2:X.TXT=SD:/W/*.TXT\r' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SY2:=SD:/W/*.ZZZ\r' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SY2:=SD:/NODIR/*.TXT\r' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SY2:=SD:/*/X.TXT\r' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SY2:=HTTP://127.0.0.1/*\r' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SY2:=SY2:*.ZZZ\r' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SD:/OUT/C.TXT=SD:/W/C*.BIN\r' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SY2:=SD:/BIG/*.BIN\r' --until '[#' --wait 300 --key ctrl-c --until 'Stopped.' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP SY2:=SD:/W/AA.TXT\r' --until 'AA.TXT' --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP LP:=SD:/W/A*.TXT\r' --prompt '>' --wait 500 \
    > "${WORK}/run.log" 2>&1 || { grep -E 'timed out|failed' "${WORK}/run.log" >&2 || true
        sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -40 >&2
        echo "FAIL: the run stopped" >&2; exit 1; }

sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -24

python3 -I - "${WORK}/run.log" <<'EOF'
import re, sys
log = re.sub(r'(?m)^\[fujinet\] ', '', open(sys.argv[1], errors='replace').read())
screens = re.findall(r'---- screen ----\n(.*?)\n----------------', log, re.S)
def lines(pattern, what):
    if not any(re.search(pattern, s, re.M) for s in screens):
        sys.exit('FAIL: %s: no screen shows %r' % (what, pattern))
    print('PASS: %s' % what)
lines(r'^4 files copied\.$', 'SY2:=SD:/W/*.TXT: four files')
lines(r'^2 files copied\.$', 'SD:/OUT/=SY2:A?.TXT: two files')
lines(r'^4 files copied\.$', 'SD:/OUT2/=SY2:*.*: four files, not the system\'s')
lines(r'^2 files copied\.$', 'SD:/OUT4/=SY1:*.ABS: two files')
lines(r'SY2:X\.TXT - many files go to a drive or a directory', 'a file name for many files')
lines(r'SD:/W/\*\.ZZZ - no files match', 'no match')
lines(r'SD:/NODIR/\*\.TXT - not found', 'a missing directory')
lines(r'SD:/\*/X\.TXT - a \* can only be in the file name', 'a * in the directory part')
lines(r'HTTP://127\.0\.0\.1/\* - a URL can\'t have \* in it', 'HTTP: no list')
lines(r'SY2:\*\.ZZZ - no files match', 'a local pattern with no match')
lines(r'Stopped\.', '^C in a batch')
EOF

hdosfs ls "${WORK}/data.h8d" > "${WORK}/sy2.ls"
for f in AA.TXT AB.TXT BA.TXT LONGNAME.TXT; do hdosfs get "${WORK}/data.h8d" "$f" -o "${WORK}/sy2.$f"; done
python3 -I - "${WORK}" "${SD}" <<'EOF'
import os, re, sys
work, sd = sys.argv[1:3]
def rd(p):
    return open(p, 'rb').read()
def padded(got, want, what):
    n = (len(want) + 255) // 256 * 256
    if got[:len(want)] != want or len(got) != n or set(got[len(want):]) - {0}:
        sys.exit('FAIL: %s: %d bytes, not %d of the source then NULs to %d' % (what, len(got), len(want), n))
    print('PASS: %s, %d bytes' % (what, len(want)))
def same(got, want, what):
    if got != want:
        sys.exit('FAIL: %s: %d bytes, not the %d of the source' % (what, len(got), len(want)))
    print('PASS: %s, %d bytes' % (what, len(want)))
for n in ('AA.TXT', 'AB.TXT', 'BA.TXT'):
    padded(rd(work + '/sy2.' + n), rd(sd + '/W/' + n), 'SD:/W/%s to SY2: by *.TXT' % n)
padded(rd(work + '/sy2.LONGNAME.TXT'), rd(sd + '/W/Long-Name-File.txt'), 'Long-Name-File.txt to SY2:LONGNAME.TXT (crunched)')
ls = open(work + '/sy2.ls').read()
if re.search(r'(?m)^\s*(CC\s*\.BIN|IN\s*\.TXT)', ls):
    sys.exit('FAIL: *.TXT copied more than the .TXT files:\n%s' % ls)
print('PASS: *.TXT copied no .BIN and no directory')
for n in ('AA.TXT', 'AB.TXT'):
    same(rd(sd + '/OUT/' + n), rd(work + '/sy2.' + n), 'SY2:%s to SD:/OUT/ by A?.TXT' % n)
if os.path.exists(sd + '/OUT/BA.TXT'):
    sys.exit('FAIL: A?.TXT copied BA.TXT')
print('PASS: A?.TXT left out BA.TXT')
got = sorted(os.listdir(sd + '/OUT2'))
if got != ['AA.TXT', 'AB.TXT', 'BA.TXT', 'LONGNAME.TXT']:
    sys.exit('FAIL: *.* on SY2: copied %s (the system files are not for it)' % got)
for n in got:
    same(rd(sd + '/OUT2/' + n), rd(work + '/sy2.' + n), 'SY2:%s to SD:/OUT2/ by *.*' % n)
print('PASS: *.* left out the system files')
got = sorted(os.listdir(sd + '/OUT4'))
if got != ['NPIP.ABS', 'STOP.ABS']:
    sys.exit('FAIL: *.ABS on SY1: copied %s' % got)
print('PASS: SY1:*.ABS to SD:/OUT4/: NPIP.ABS and STOP.ABS')
if os.path.exists(sd + '/OUT/C.TXT'):
    sys.exit('FAIL: a file name for many files copied anyway')
print('PASS: a file name for many files copied nothing')
if re.search(r'(?m)^\s*(ONE|TWO)\s*\.', ls):
    sys.exit('FAIL: ^C in a batch left a BIG file on SY2:')
print('PASS: ^C in a batch left nothing of the file on SY2:')
aa, ab = rd(sd + '/W/AA.TXT'), rd(sd + '/W/AB.TXT')
nl = lambda b: b.replace(b'\n', b'\r\n')
paper = rd(sd + '/paper')
if paper not in (nl(aa + ab), nl(ab + aa)):
    sys.exit('FAIL: LP:=SD:/W/A*.TXT printed %d bytes, not AA.TXT and AB.TXT' % len(paper))
print('PASS: LP: printed each file in turn')
EOF
