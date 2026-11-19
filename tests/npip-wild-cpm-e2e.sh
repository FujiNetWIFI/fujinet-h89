#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): NPIP's wildcards under CP/M. A * in a URL's file
# name lists that directory on the FujiNet and copies each file to a drive or
# a directory; * and ? in a local name copy each file BDOS's search finds,
# to a directory on the SD card, or to the list device; and the refusals: a
# destination that isn't a drive or a directory, no match, a * in the
# directory part, a missing directory, HTTP. ^C in the middle of a batch
# stops it and leaves the FujiNet working. On the host, every copy is
# checked byte for byte.
#
#   tests/npip-wild-cpm-e2e.sh --boot CPM62.h8d [--rig DIR] [--keep DIR]
#
# CPM62.h8d is a 62K system (tests/make-62k-boot.sh), for FNDISK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
BOOT=""; KEEP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot) BOOT="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        *) echo "usage: $0 --boot CPM62.h8d [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${BOOT}" ]] || { echo "need --boot" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
APPMAKE="${APPMAKE:-z88dk-appmake}"
NPIP="${ROOT}/build/NPIP.COM"
FNDISK="${ROOT}/build/FNDISK.COM"
[[ -f "${NPIP}" && -f "${FNDISK}" ]] || { echo "build NPIP.COM and FNDISK.COM first (make)" >&2; exit 2; }

if [[ -n "${KEEP}" ]]; then WORK="${KEEP}"; rm -rf "${WORK}"; mkdir -p "${WORK}"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/npip-wild-cpm-XXXXXX")"; fi
finish() { [[ -n "${KEEP}" ]] || rm -rf "${WORK}"; }
trap finish EXIT

fixup() { python3 -I "${ROOT}/tools/cpm-dir-fixup.py" "$1"; }
cpmget() { python3 -I "${ROOT}/tests/cpm-get.py" "$@"; }

# The FujiNet's own files in HOME, with its printer on as RAW (every byte to
# SD/paper), as npip-cpm-e2e.sh does
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
for d in ('W', 'W/SUB', 'OUT', 'OUT2', 'BIG'):
    os.makedirs(sd + '/' + d, exist_ok=True)
for n in ('AA', 'AB', 'BA'):
    open('%s/W/%s.TXT' % (sd, n), 'wb').write(
        b''.join(b'Line %03d of %s.TXT\r\n' % (i, n.encode()) for i in range(12)))
open(sd + '/W/CC.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(3000)))
open(sd + '/W/Long-Name-File.txt', 'wb').write(b'A file with a long name.\r\n')
open(sd + '/W/SUB/IN.TXT', 'wb').write(b'inside\r\n')
open(sd + '/BIG/ONE.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
open(sd + '/BIG/TWO.BIN', 'wb').write(bytes(random.randrange(256) for _ in range(70000)))
EOF

# B: holds NPIP and FNDISK; C: is for what's copied (STUB.COM, as appmake
# wants a file)
mkdir -p "${WORK}/tools" "${WORK}/data"
cp "${NPIP}" "${FNDISK}" "${WORK}/tools/"
(cd "${WORK}/tools" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b NPIP.COM -a FNDISK.COM -o disk >/dev/null)
fixup "${WORK}/tools/disk"
printf '\311' > "${WORK}/data/STUB.COM"
(cd "${WORK}/data" && "${APPMAKE}" +cpmdisk -f hz89 --container raw --no-com-file \
    -b STUB.COM -o disk >/dev/null)
fixup "${WORK}/data/disk"
cp "${BOOT}" "${WORK}/boot.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/boot.h8d" --disk "h17:2=${WORK}/tools/disk" --disk "h17:3=${WORK}/data/disk" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --type 'B:NPIP C:=SD:/W/*.TXT\r' --until 'files copied' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP SD:/OUT/=C:A?.TXT\r' --until 'files copied' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP SD:/OUT2/=C:*.*\r' --until 'files copied' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP C:X.TXT=SD:/W/*.TXT\r' --prompt 'A>' --wait 300 \
    --type 'B:NPIP C:=SD:/W/*.ZZZ\r' --prompt 'A>' --wait 300 \
    --type 'B:NPIP C:=SD:/NODIR/*.TXT\r' --prompt 'A>' --wait 300 \
    --type 'B:NPIP C:=SD:/*/X.TXT\r' --prompt 'A>' --wait 300 \
    --type 'B:NPIP C:=HTTP://127.0.0.1/*\r' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP C:=C:*.ZZZ\r' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP SD:/OUT/C.TXT=SD:/W/C*.BIN\r' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP C:=SD:/BIG/*.BIN\r' --until '[#' --wait 300 --key ctrl-c --until 'Stopped.' --prompt 'A>' --wait 300 --screen \
    --type 'B:NPIP C:=SD:/W/AA.TXT\r' --until 'AA.TXT' --prompt 'A>' --wait 300 --screen \
    --type 'B:FNDISK\r' --until 'Installed' --prompt 'A>' --wait 500 \
    --type 'B:NPIP LST:=SD:/W/A*.TXT\r' --prompt 'A>' --wait 500 \
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
lines(r'^4 files copied\.$', 'C:=SD:/W/*.TXT: four files')
lines(r'^2 files copied\.$', 'SD:/OUT/=C:A?.TXT: two files')
lines(r'^5 files copied\.$', 'SD:/OUT2/=C:*.*: five files')
lines(r'^many files go to a drive or a directory$|C:X\.TXT - many files go to a drive or a directory', 'a file name for many files')
lines(r'SD:/W/\*\.ZZZ - no files match', 'no match')
lines(r'SD:/NODIR/\*\.TXT - not found', 'a missing directory')
lines(r'SD:/\*/X\.TXT - a \* can only be in the file name', 'a * in the directory part')
lines(r'HTTP://127\.0\.0\.1/\* - a URL can\'t have \* in it', 'HTTP: no list')
lines(r'C:\*\.ZZZ - no files match', 'a local pattern with no match')
lines(r'Stopped\.', '^C in a batch')
EOF

cpmget "${WORK}/data/disk" --ls > "${WORK}/c.ls"
python3 -I - "${WORK}" "${SD}" "${ROOT}" <<'EOF'
import os, subprocess, sys
work, sd, root = sys.argv[1:4]
def rd(p):
    return open(p, 'rb').read()
def cpm(name):
    out = work + '/c.' + name
    subprocess.run([sys.executable, '-I', root + '/tests/cpm-get.py', work + '/data/disk', name, '-o', out], check=True)
    return rd(out)
def padded(got, want, what, fill=0x1A):
    n = (len(want) + 127) // 128 * 128
    if got[:len(want)] != want or len(got) != n or set(got[len(want):]) - {fill}:
        sys.exit('FAIL: %s: %d bytes, not %d of the source then ^Z to %d' % (what, len(got), len(want), n))
    print('PASS: %s, %d bytes' % (what, len(want)))
def same(got, want, what):
    if got != want:
        sys.exit('FAIL: %s: %d bytes, not the %d of the source' % (what, len(got), len(want)))
    print('PASS: %s, %d bytes' % (what, len(want)))
names = open(work + '/c.ls').read().split()
for n in ('AA.TXT', 'AB.TXT', 'BA.TXT'):
    padded(cpm(n), rd(sd + '/W/' + n), 'SD:/W/%s to C: by *.TXT' % n)
padded(cpm('LONGNAME.TXT'), rd(sd + '/W/Long-Name-File.txt'), 'Long-Name-File.txt to C:LONGNAME.TXT (crunched)')
if 'CC.BIN' in names or 'IN.TXT' in names:
    sys.exit('FAIL: *.TXT copied more than the .TXT files: %s' % names)
print('PASS: *.TXT copied no .BIN and no directory')
for n in ('AA.TXT', 'AB.TXT'):
    same(rd(sd + '/OUT/' + n), rd(work + '/c.' + n), 'C:%s to SD:/OUT/ by A?.TXT' % n)
if os.path.exists(sd + '/OUT/BA.TXT'):
    sys.exit('FAIL: A?.TXT copied BA.TXT')
print('PASS: A?.TXT left out BA.TXT')
for n in ('AA.TXT', 'AB.TXT', 'BA.TXT', 'LONGNAME.TXT'):
    same(rd(sd + '/OUT2/' + n), rd(work + '/c.' + n), 'C:%s to SD:/OUT2/ by *.*' % n)
if not os.path.exists(sd + '/OUT2/STUB.COM'):
    sys.exit('FAIL: *.* did not copy STUB.COM')
print('PASS: *.* on C: copied STUB.COM too')
if os.path.exists(sd + '/OUT/C.TXT'):
    sys.exit('FAIL: a file name for many files copied anyway')
print('PASS: a file name for many files copied nothing')
left = [n for n in names if n.endswith('.$$$') or n.endswith('.BIN')]
if left:
    sys.exit('FAIL: ^C in a batch left %s on C:' % left)
print('PASS: ^C in a batch left nothing of the file on C:')
padded(cpm('AA.TXT'), rd(sd + '/W/AA.TXT'), 'a plain copy after ^C in a batch (N4 closed)')
paper = rd(sd + '/paper')
aa, ab = rd(sd + '/W/AA.TXT'), rd(sd + '/W/AB.TXT')
if paper not in (aa + ab, ab + aa):
    sys.exit('FAIL: LST:=SD:/W/A*.TXT printed %d bytes, not AA.TXT and AB.TXT (%d)' % (len(paper), len(aa + ab)))
print('PASS: LST: printed each file in turn')
EOF
