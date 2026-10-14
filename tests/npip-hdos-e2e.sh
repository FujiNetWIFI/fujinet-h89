#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): NPIP under HDOS 2.0. Copies between SY2: and
# the FujiNet's SD card (SD:/ URLs), both ways, at the * prompt and from
# the command line; a file over 64K, whose size comes from its directory;
# errors; TT: and LP: (LP.DVD, the FujiNet's printer); ^C in a download, an
# upload and at the prompt; and the console as it was after. On the host,
# every copy is checked byte for byte.
#
#   tests/npip-hdos-e2e.sh --boot BOOT.h8d [--rig DIR] [--keep DIR]
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
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/npip-hdos-e2e-XXXXXX")"; trap 'rm -rf "${WORK}"' EXIT; fi

# The FujiNet's own files in HOME, with its printer on as RAW (every byte to
# SD/paper), as fn-hdos-e2e.sh does
printer_on() {
    local out="${FUJINET_LIB_DIR:-${RIG}/tools/fujinet/work/out}" fn="$1/data/fujinet"
    mkdir -p "${fn}"
    cp -r "${out}/fnconfig.ini" "${out}/data" "${out}/SD" "${fn}/"
    sed -i 's/^printer_enabled=0$/printer_enabled=1/' "${fn}/fnconfig.ini"
    printf '\n[Printer1]\ntype=0\n' >> "${fn}/fnconfig.ini"
}

# The SD card's files: HELLO.TXT isn't a whole number of sectors, BIG.BIN
# is over 64K, Long-Name-File.txt has a name only the * prompt can give,
# PRINT.TXT is HDOS text (NL alone, and a tab), and STOP.BIN is for ^C (its
# own name, so the wait for its progress line can't match an older one)
printer_on "${WORK}/home"
SD="${WORK}/home/data/fujinet/SD"
python3 -I - "${SD}" <<'EOF'
import random, sys
sd = sys.argv[1]
random.seed(89)
open(sd + '/HELLO.TXT', 'wb').write(
    b''.join(b'Line %03d of HELLO.TXT, from the FujiNet SD card.\r\n' % i for i in range(20))[:1000])
open(sd + '/BIG.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/STOP.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/Long-Name-File.txt', 'wb').write(b'A file with a long name.\r\n')
open(sd + '/PRINT.TXT', 'wb').write(b'NPIP to LP:\n\tA tab\nThe last line.\n')
EOF

# SY1: holds NPIP, and STOP.ABS to upload for ^C; SY2: is for what's copied
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
    --type 'RUN SY1:NPIP.ABS SY2:=SD:/HELLO.TXT\r' --until '1000/1000' --prompt '>' --wait 300 \
    --type 'SY1:NPIP\r' --prompt '*' \
    --type 'sy2:=sd:/Long-Name-File.txt\r' --wait 300 --prompt '*' \
    --type 'sd:/=sy1:npip.abs\r' --wait 300 --prompt '*' \
    --type 'sy2:=sd:/BIG.BIN\r' --until '/70000' --screen --wait 500 --prompt '*' \
    --type 'sd:/BACK.BIN=sy2:big.bin\r' --wait 300 --prompt '*' \
    --type 'sy2:=sd:/NOSUCH.TXT\r' --wait 300 --prompt '*' \
    --type 'xy:=sd:/HELLO.TXT\r' --wait 300 --prompt '*' \
    --type 'lp:=sd:/PRINT.TXT\r' --wait 300 --prompt '*' \
    --type 'tt:=sd:/PRINT.TXT\r' --until 'The last line.' --prompt '*' --screen \
    --type '\r' --prompt '>' \
    --type 'SY1:NPIP SY2:=SD:/STOP.BIN\r' --until 'STOP.BIN  ' --wait 500 --key ctrl-c --until 'Stopped.' --prompt '>' --wait 300 \
    --type 'SY1:NPIP SD:/UP.ABS=SY1:STOP.ABS\r' --until 'STOP.ABS  ' --key ctrl-c --prompt '>' --wait 300 --screen \
    --type 'SY1:NPIP\r' --prompt '*' --key ctrl-c --prompt '>' --wait 300 \
    --type 'cat sy2:\r' --until 'FILES' --prompt '>' --screen \
    > "${WORK}/run.log" 2>&1 || { grep -E 'timed out|failed' "${WORK}/run.log" >&2 || true
        sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -30 >&2
        echo "FAIL: the run stopped" >&2; exit 1; }

sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/run.log" | sed 's/^\[fujinet\] //' | tail -26

# What the screens showed
python3 -I - "${WORK}/run.log" <<'EOF'
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
m = re.search(r'\] +(\d+)/70000$', after('*sy2:=sd:/BIG.BIN'))
if not m or int(m.group(1)) >= 70000:
    sys.exit('FAIL: the size of a file over 64K: %r' % after('*sy2:=sd:/BIG.BIN'))
print('PASS: the size of a file over 64K came from its directory (%s/70000 as it copied)' % m.group(1))
want('*sy2:=sd:/NOSUCH.TXT', r'^sd:/NOSUCH.TXT - not found$', 'a missing file: not found')
want('*xy:=sd:/HELLO.TXT', r'^XY: - no such device$', 'an unknown device')
lines(r'^\*tt:=sd:/PRINT.TXT\nNPIP to LP:\n {8}A tab\nThe last line\.\n\*',
      "TT:, HDOS's NL lines each at the left, with no progress line")
lines(r'^>SY1:NPIP SY2:=SD:/STOP.BIN\nSTOP.BIN +\[#*\.+\] +\d+/70000\nStopped\.\n\n?>',
      '^C in a download: Stopped.')
lines(r'^>SY1:NPIP SD:/UP.ABS=SY1:STOP.ABS\nSTOP.ABS +\[.*\] +\d+/7168\nStopped\.\n\n?>',
      '^C in an upload: Stopped.')
lines(r'^>SY1:NPIP\n\*\^C\n\n?>', '^C at the * prompt')
lines(r'^>CAT SY2:$', 'the console as it was after (lower case typed, capitals seen)')
EOF

# What the copies hold, byte for byte (an HDOS file is whole sectors, the
# last filled out with NULs; an upload sends the sectors as they are)
for f in HELLO.TXT LONGNAME.TXT BIG.BIN; do hdosfs get "${WORK}/data.h8d" "$f" -o "${WORK}/sy2.$f"; done
hdosfs get "${WORK}/tools.h8d" NPIP.ABS -o "${WORK}/sy1.NPIP.ABS"
hdosfs ls "${WORK}/data.h8d" > "${WORK}/sy2.ls"
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
padded(rd(work + '/sy2.HELLO.TXT'), rd(sd + '/HELLO.TXT'), 'SD:/HELLO.TXT to SY2: (from the command line)')
padded(rd(work + '/sy2.LONGNAME.TXT'), rd(sd + '/Long-Name-File.txt'), 'Long-Name-File.txt to SY2:LONGNAME.TXT')
padded(rd(work + '/sy2.BIG.BIN'), rd(sd + '/BIG.BIN'), 'SD:/BIG.BIN to SY2:')
padded(rd(sd + '/BACK.BIN'), rd(sd + '/BIG.BIN'), 'SY2:BIG.BIN back to SD:/BACK.BIN')
if rd(sd + '/NPIP.ABS') != rd(work + '/sy1.NPIP.ABS'):
    sys.exit('FAIL: SY1:NPIP.ABS to SD:/ differs')
print('PASS: SY1:NPIP.ABS to SD:/, named for it')
if re.search(r'(?m)^\s*STOP\s*\.', open(work + '/sy2.ls').read()):
    sys.exit('FAIL: ^C in a download left STOP.BIN on SY2:')
print('PASS: ^C in a download left nothing on SY2:')
if os.path.exists(sd + '/UP.ABS'):
    sys.exit('FAIL: ^C in an upload left SD:/UP.ABS')
print('PASS: ^C in an upload left nothing on the SD card')
text = rd(sd + '/PRINT.TXT').decode('ascii')
want = text.expandtabs(8).replace('\n', '\r\n').encode('ascii')
try:
    paper = rd(sd + '/paper')
except FileNotFoundError:
    sys.exit('FAIL: LP: printed nothing')
if paper != want:
    sys.exit('FAIL: LP: printed %r, not %r' % (paper, want))
print('PASS: LP: printed PRINT.TXT as LP.DVD puts it')
EOF
