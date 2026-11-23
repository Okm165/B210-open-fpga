#!/usr/bin/env bash
# build_diag.sh - one parameterized build for every diagnostic design.
#
#   DESIGN=diag_ring13 ./scripts/build_diag.sh
#
# Inputs (conventional, no per-design scripts):
#   src/top/$DESIGN.v               the design
#   src/constraints/$DESIGN.xdc     constraints (falls back to diag_pad.xdc)
# Outputs:
#   build/fpga/ring2/{synth,pnr}/*  json/fasm/frames
#   build/fpga/ring2/usrp_$DESIGN.bin
#
# Env:
#   SEED=1        nextpnr seed
#   IGNORE_LOOPS=1 pass --ignore-loops (combinational ring designs)
#
# Engine: the rebuilt himbaechel binary (supports `set_property BEL`) plus its
# matching chipdb, and a segbits_riob18.db with the LVCMOS18 DRIVE aliases the
# stock DB lacks for every pin the GPIF bank uses.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="${DESIGN:?usage: DESIGN=<name> $0}"
CR=/work
FPGA_PART=xc7k325tffg676-1
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
[[ -f "$ROOT/src/top/$DESIGN.v" ]] || { echo "missing src/top/$DESIGN.v" >&2; exit 2; }
if [[ -f "$ROOT/src/constraints/$DESIGN.xdc" ]]; then
  XDC="$CR/src/constraints/$DESIGN.xdc"
else
  XDC="$CR/src/constraints/diag_pad.xdc"
fi

$CE run --rm -i --userns=keep-id \
  -v "$ROOT:$CR:z" \
  -v /tmp/opencode/segbits_riob18.db:/opt/fpga/share/prjxray-db/kintex7/segbits_riob18.db:z \
  -v /tmp/opencode/openxc7-nextpnr/build/nextpnr-himbaechel:/opt/fpga/bin/nextpnr-himbaechel:z \
  -v /tmp/opencode/openxc7-nextpnr/build/himbaechel/uarch/xilinx/chipdb-xc7k325t.bin:/opt/fpga/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin:z \
  -w "$CR" -e HOME="$CR/build" \
  -e DESIGN="$DESIGN" -e XDC="$XDC" \
  -e SEED="${SEED:-1}" -e IGNORE_LOOPS="${IGNORE_LOOPS:-0}" \
  ${FPGA_IMAGE:-b210-open-fpga:0.1.0} bash -s <<-'EOF'
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
OUT=$CR/build/fpga/ring2
LOGS=$CR/build/fpga/logs
mkdir -p "$OUT/synth" "$OUT/pnr" "$OUT/bitstream" "$LOGS"
LOOPS=""; [[ "$IGNORE_LOOPS" == "1" ]] && LOOPS="--ignore-loops"

yosys -p "read_verilog $CR/src/top/$DESIGN.v; synth_xilinx -flatten -abc9 -family xc7 -top $DESIGN; write_json $OUT/synth/$DESIGN.json; stat" \
  > "$LOGS/$DESIGN-synth.log" 2>&1

nextpnr-himbaechel --device $FPGA_PART \
  --chipdb $FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \
  --json "$OUT/synth/$DESIGN.json" \
  -o "xdc=$XDC" -o "fasm=$OUT/pnr/$DESIGN.fasm" $LOOPS --seed "$SEED" \
  > "$LOGS/$DESIGN-pnr.log" 2>&1 \
  || { tail -40 "$LOGS/$DESIGN-pnr.log"; exit 1; }

fasm2frames --db-root $PRJXRAY_DB/kintex7 --part $FPGA_PART \
  "$OUT/pnr/$DESIGN.fasm" "$OUT/pnr/$DESIGN.frames" \
  > "$LOGS/$DESIGN-f2f.log" 2>&1 \
  || { tail -40 "$LOGS/$DESIGN-f2f.log"; exit 1; }

xc7frames2bit --part_file $PRJXRAY_DB/kintex7/$FPGA_PART/part.yaml \
  --part_name $FPGA_PART --frm_file "$OUT/pnr/$DESIGN.frames" \
  --output_file "$OUT/bitstream/$DESIGN.bit" \
  > "$LOGS/$DESIGN-bit.log" 2>&1 \
  || { tail -40 "$LOGS/$DESIGN-bit.log"; exit 1; }

python3 "$CR/scripts/bit2bin.py" "$OUT/bitstream/$DESIGN.bit" "$OUT/usrp_$DESIGN.bin" \
  > "$LOGS/$DESIGN-b2b.log" 2>&1 \
  || { cat "$LOGS/$DESIGN-b2b.log"; exit 1; }

idcode=$(bittool get_device_id "$OUT/usrp_$DESIGN.bin")
[[ "$idcode" == "0x3651093" ]] || { echo "idcode $idcode != 0x3651093" >&2; exit 1; }
echo "built: $OUT/usrp_$DESIGN.bin (idcode $idcode)"
EOF
