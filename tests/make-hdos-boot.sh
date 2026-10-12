#!/usr/bin/env bash
# An HDOS 2.0 boot disk with FN.DVD on it, from the one fujinet-go-h89-desktop
# ships: converted to .h8d, DK.DVD (the H47 driver) taken off to make room,
# FN.DVD put on, then booted once to see HDOS take it as a device.
#
#   tests/make-hdos-boot.sh OUT.h8d [--dvd FN.DVD] [--name FN.DVD] [--rig DIR]
#
# --name DK.DVD installs the driver as DK: (HDOS would mount it under that
# name if it refused another).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$1"; shift
DVD="${ROOT}/build/FN.DVD"
NAME="FN.DVD"
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dvd) DVD="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --rig) RIG="$2"; shift 2 ;;
        *) echo "usage: $0 OUT.h8d [--dvd FN.DVD] [--name FN.DVD] [--rig DIR]" >&2; exit 2 ;;
    esac
done
RUN="${RIG}/build/core/h89_session_run"
hdosfs() { python3 -I "${ROOT}/tools/hdosfs.py" "$@"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hdos-boot-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

hdosfs convert "${RIG}/tools/disks/boot/hdos-2.0.h17disk" "${WORK}/boot.h8d" >/dev/null
hdosfs rm "${WORK}/boot.h8d" DK.DVD
hdosfs put "${WORK}/boot.h8d" "${DVD}" --name "${NAME}" --flags C0
hdosfs ls "${WORK}/boot.h8d" --check >/dev/null

DEV="${NAME%%.*}"
cp "${WORK}/boot.h8d" "${WORK}/try.h8d"
"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 60 \
    --disk "h17:1=${WORK}/try.h8d" \
    --until 'H:' --type 'B\r' --wait 3000 --type ' ' --wait 500 --type ' ' \
    --prompt 'ACTION? <BOOT>' --type '\r' \
    --prompt 'DATE (DD-MMM-YY)?' --type '11-OCT-80\r' \
    --prompt '>' --type 'STAT\r' --wait 3000 --prompt '>' --screen > "${WORK}/boot.log" 2>&1 \
    || { tail -20 "${WORK}/boot.log" >&2; echo "the disk didn't boot" >&2; exit 1; }
SCREEN="$(sed -n '/---- screen ----/,/^\(\[fujinet\] \)\?----------------/p' "${WORK}/boot.log" | sed 's/^\[fujinet\] //')"
echo "${SCREEN}"
grep -q "^ *${DEV}" <<< "${SCREEN}" || { echo "HDOS didn't list ${DEV}:" >&2; exit 1; }

cp "${WORK}/boot.h8d" "${OUT}"
echo "wrote ${OUT}"
