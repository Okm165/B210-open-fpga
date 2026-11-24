#!/usr/bin/env bash
# assemble.sh - FASM -> frames -> .bit -> FX3-loadable .bin (one place for it).
#
#   scripts/assemble.sh <in.fasm> <out.bin>      (paths relative to the repo)
#
# Applies one fix to the image's fasm2frames before running it:
#
#   The tool auto-injects RIOB18/LIOB18 `OBUF_HP_BANK_GLUE` for every HP-bank
#   pad that has a DRIVE feature.  Those three bits are not IOB bits at all:
#   they are the neighbouring OLOGIC's OQUSED, DATA_RATE_TQ.BUF and OMUX.D1
#   (openXC7/nextpnr#79).  nextpnr already writes them itself for a plain
#   output, so the injection is redundant there - and on a pad whose OLOGIC
#   holds an ODDR it forces OMUX.D1, the combinational bypass, so the pad
#   outputs the constant on D1 instead of the register.  That is what kept
#   the forwarded IFCLK (an ODDR on bank 34) static in every build.
#
# fasm2frames exits non-zero on a harmless antlr import warning, so success is
# judged by an explicit unknown-feature scan and by the device id of the .bin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:?usage: $0 <in.fasm> <out.bin>}"; OUT="${2:?usage: $0 <in.fasm> <out.bin>}"
PART=xc7k325tffg676-1
DB="${PRJXRAY_DB:-/tmp/opencode/prjxray-db-full}"
S="${OUT%.bin}"
cd "$ROOT"
rm -f "$OUT"
podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -v "$DB:/opt/fpga/share/prjxray-db:z" \
  -w /work -e HOME=/work/build "${FPGA_IMAGE:-b210-open-fpga:0.1.0}" bash -c "
  F=\$(python3 -c 'import utils.fasm2frames as m; print(m.__file__)')
  sed \"s/^            if kind\\['out'\\]:\$/            if False:  # OBUF_HP_BANK_GLUE aliases OLOGIC bits (nextpnr#79)/\" \$F > /tmp/fasm2frames_fixed.py
  grep -q 'if False:  # OBUF_HP_BANK_GLUE' /tmp/fasm2frames_fixed.py || { echo 'fasm2frames glue fix did not apply' >&2; exit 3; }
  python3 /tmp/fasm2frames_fixed.py --db-root /opt/fpga/share/prjxray-db/kintex7 --part $PART $IN $S.frames > $S.f2f.log 2>&1
  if grep -q 'not found' $S.f2f.log; then grep 'not found' $S.f2f.log | tail -3 >&2; exit 4; fi
  xc7frames2bit --part_file /opt/fpga/share/prjxray-db/kintex7/$PART/part.yaml --part_name $PART \
    --frm_file $S.frames --output_file $S.bit > /dev/null 2>&1
  python3 scripts/bit2bin.py $S.bit $OUT > /dev/null 2>&1
  [[ \"\$(bittool get_device_id $OUT)\" == 0x3651093 ]] || { echo 'bad or missing bin' >&2; exit 5; }
"
