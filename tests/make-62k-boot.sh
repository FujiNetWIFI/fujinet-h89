#!/usr/bin/env bash
# A 62K Heath CP/M 2.2.04 boot disk, made on the emulated H89 from the 64K
# one fujinet-go-h89-desktop ships: MOVCPM17 62 *, then SYSGEN onto it.
#
#   tests/make-62k-boot.sh OUT.h8d [--rig DIR]
set -euo pipefail

OUT="$1"; shift
RIG="${HOME}/Workspace/fujinet-go-h89-desktop"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rig) RIG="$2"; shift 2 ;;
        *) echo "usage: $0 OUT.h8d [--rig DIR]" >&2; exit 2 ;;
    esac
done
RUN="${RIG}/build/core/h89_session_run"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/h89-62k-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
cp "${RIG}/tools/disks/boot/cpm-2.2.04-64k.h8d" "${WORK}/cpm.h8d"

"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home" --timeout 120 \
    --disk "h17:1=${WORK}/cpm.h8d" \
    --until 'H:' --type 'B\r' --until 'A>' --wait 1000 \
    --prompt 'A>' --type 'MOVCPM17 62 *\r' --wait 15000 \
    --prompt 'A>' --type 'SYSGEN\r' \
    --prompt 'SOURCE DRIVE NAME (OR RETURN TO SKIP):' --type '\r' \
    --prompt 'DESTINATION DRIVE NAME (OR RETURN TO REBOOT):' --type 'A' \
    --prompt 'DESTINATION ON A, THEN TYPE RETURN' --type '\r' \
    --until 'FUNCTION COMPLETE' > "${WORK}/sysgen.log" 2>&1 \
    || { tail -20 "${WORK}/sysgen.log" >&2; echo "SYSGEN failed" >&2; exit 1; }

# Boot it and see the size
"${RUN}" --roms "${RIG}/tools/roms" --home "${WORK}/home2" --timeout 60 \
    --disk "h17:1=${WORK}/cpm.h8d" \
    --until 'H:' --type 'B\r' --until 'A>' --screen > "${WORK}/boot.log" 2>&1 \
    || { tail -20 "${WORK}/boot.log" >&2; echo "the new disk didn't boot" >&2; exit 1; }
grep -q '62K' "${WORK}/boot.log" || { grep -A12 -- '---- screen' "${WORK}/boot.log" >&2; echo "not a 62K system" >&2; exit 1; }

cp "${WORK}/cpm.h8d" "${OUT}"
echo "wrote ${OUT}"
