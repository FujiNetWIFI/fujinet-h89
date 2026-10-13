#!/usr/bin/env bash
# End to end on the emulated H89 (fujinet-go-h89-desktop's h89_session_run,
# with FujiNet in-process): FNBOOT, put in RAM at 0C000H (the emulator only
# takes stock ROMs) and started with Go, boots CONFIG from the image in the
# FujiNet's flash; ESC in CONFIG (mount the drives and exit) goes back to the
# monitor. Then, with no image in flash, Go comes back to the monitor.
#
#   tests/fnboot-e2e.sh --config CONFIG.ABS [--rig DIR] [--keep DIR]
#
# CONFIG.ABS is the HDOS build (fujinet-config, make h89-hdos/r2r).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
CONFIG=""; KEEP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        *) echo "usage: $0 --config CONFIG.ABS [--rig DIR] [--keep DIR]" >&2; exit 2 ;;
    esac
done
[[ -f "${CONFIG}" ]] || { echo "need --config" >&2; exit 2; }
RUN="${RIG}/build/core/h89_session_run"
ASSETS="${RIG}/tools/fujinet/work/out"
Z80ASM="${Z80ASM:-z88dk-z80asm}"
STAGE2="${ROOT}/build/stage2.bin"
[[ -f "${STAGE2}" ]] || { echo "build stage2.bin first (make)" >&2; exit 2; }

if [[ -n "${KEEP}" ]]; then rm -rf "${KEEP}"; mkdir -p "${KEEP}"; WORK="$(cd "${KEEP}" && pwd)"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/fnboot-e2e-XXXXXX")"; trap 'rm -rf "${WORK}"' EXIT; fi

# FNBOOT in RAM, for the debugger to poke in
"${Z80ASM}" -b -I="${ROOT}/boot" -I="${ROOT}/common" -O="${WORK}" -r=0xC000 \
    -o="${WORK}/fnboot.bin" "${ROOT}/boot/fnboot.asm"
POKE="poke 0xc000$(od -An -v -tx1 "${WORK}/fnboot.bin" | tr -s ' \n' ' ' | sed 's/ \([0-9a-f]\)/ $\1/g; s/ $//')"
GO='G300000\r'                  # 0C000H in split octal

python3 -I "${ROOT}/tools/fnboot.py" image "${STAGE2}" "${CONFIG}" -o "${WORK}/autorun.img"

# A FujiNet of its own: set up as the desktop would on its first run, then
# the boot image in its flash (or none)
fujinet() {     # $1 = home, $2 = the image for /autorun.img, or ""
    local fn="$1/data/fujinet"
    mkdir -p "${fn}"
    cp "${ASSETS}/fnconfig.ini" "${fn}/"
    cp -r "${ASSETS}/data" "${ASSETS}/SD" "${fn}/"
    rm -f "${fn}/data/autorun.img"
    [[ -z "$2" ]] || cp "$2" "${fn}/data/autorun.img"
}

screen() {      # the last screen in a log
    sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "$1" | sed 's/^\[fujinet\] //' | tail -26
}

run() {         # $1 = log, the rest the steps
    local log="$1"; shift
    "${RUN}" --roms "${RIG}/tools/roms" --timeout 60 "$@" > "${log}" 2>&1 || {
        grep -E 'timed out|failed' "${log}" >&2 || true
        screen "${log}" >&2
        echo "FAIL: the run stopped (${log##*/})" >&2; exit 1; }
}

# CONFIG from flash, and back to the monitor: ESC is the HDOS console's
# raw input (and CONFIG's wait for more of a key, on the monitor's tick),
# and the exit is .EXIT
fujinet "${WORK}/boot" "${WORK}/autorun.img"
run "${WORK}/boot.log" --home "${WORK}/boot" \
    --until 'H:' --debug "${POKE}" --type "${GO}" \
    --until 'FujiNet boot' --until 'Drive Slots' --until 'Quit' --wait 1500 --screen \
    --key esc --until 'no drives mounted' --prompt 'H:' --wait 500 --screen
grep -q "$(stat -c %s "${WORK}/fnboot.bin") bytes at C000" "${WORK}/boot.log" \
    || { echo "FAIL: the poke didn't take" >&2; exit 1; }
screen "${WORK}/boot.log"
echo "PASS: FNBOOT booted CONFIG from the FujiNet's flash, and ESC went back to the monitor"

# No image: a NAK, so FNBOOT HALTs, and the monitor says H (with a bell)
fujinet "${WORK}/none" ""
run "${WORK}/none.log" --home "${WORK}/none" \
    --until 'H:' --debug "${POKE}" --type "${GO}" --prompt 'H:' --wait 500 --screen
screen "${WORK}/none.log" | grep -A1 'Go 300000' | tail -1 | grep -qx 'H' \
    || { screen "${WORK}/none.log" >&2; echo "FAIL: with no image, no HALT back to the monitor" >&2; exit 1; }
if grep -q 'FujiNet boot' "${WORK}/none.log"; then
    echo "FAIL: with no image, something ran" >&2; exit 1
fi
echo "PASS: with no image in flash, Go comes back to the monitor"
