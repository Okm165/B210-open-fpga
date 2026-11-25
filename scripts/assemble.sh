#!/usr/bin/env bash
# assemble.sh - FASM -> frames -> .bit -> FX3-loadable .bin (one place for it).
#
#   scripts/assemble.sh <in.fasm> <out.bin>      (paths relative to the repo)
#
# Runs the Project X-Ray tools of the container image (`just container`) against
# the device database in third_party/prjxray-db-openxc7.
#
# Every intermediate of a previous run is removed first and every step's exit
# status is checked, so an output that exists was produced by this run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:?usage: $0 <in.fasm> <out.bin>}"; OUT="${2:?usage: $0 <in.fasm> <out.bin>}"
PART=xc7k325tffg676-1
DB="${PRJXRAY_DB:-$ROOT/third_party/prjxray-db-openxc7}"
S="${OUT%.bin}"
cd "$ROOT"
[[ -s "$IN" ]] || { echo "assemble: no fasm at $IN" >&2; exit 2; }
[[ -d "$DB/kintex7/$PART" ]] || { echo "assemble: no prjxray database at $DB" >&2; exit 2; }
rm -f "$OUT" "$S.frames" "$S.bit" "$S.f2f.log"
podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -v "$DB:/opt/fpga/share/prjxray-db:z" \
  -w /work -e HOME=/work/build "${FPGA_IMAGE:-b210-open-fpga:0.3.0}" bash -euo pipefail -c "
  fasm2frames --db-root /opt/fpga/share/prjxray-db/kintex7 --part $PART $IN $S.frames > $S.f2f.log 2>&1 \
    || { tail -5 $S.f2f.log >&2; echo 'assemble: fasm2frames failed' >&2; exit 4; }
  if grep -q 'not found' $S.f2f.log; then grep 'not found' $S.f2f.log | tail -3 >&2; exit 4; fi
  xc7frames2bit --part_file /opt/fpga/share/prjxray-db/kintex7/$PART/part.yaml --part_name $PART \
    --frm_file $S.frames --output_file $S.bit >> $S.f2f.log 2>&1 || { echo 'assemble: xc7frames2bit failed' >&2; exit 5; }
  python3 scripts/bit2bin.py $S.bit $OUT >> $S.f2f.log 2>&1 || { echo 'assemble: bit2bin failed' >&2; exit 5; }
  [[ \"\$(bittool get_device_id $OUT)\" == 0x3651093 ]] || { echo 'assemble: bad device id in the bin' >&2; exit 5; }
"
