#!/usr/bin/env bash
# build_b200_full.sh - build the full 2R2T b200 DOD image (clean flow).
# synth (existing b200.json is reused if present) -> pnr -> frames ->
# patch_full_design fixes -> bit -> bin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR=/work
FPGA_PART=xc7k325tffg676-1
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
SEED=${SEED:-1}
$CE run --rm -i --userns=keep-id -v "$ROOT:$CR:z" -w "$CR" -e HOME="$CR/build" \
  -e FPGA_PART=$FPGA_PART -e FPGA_HOME=$FPGA_HOME ${FPGA_IMAGE:-b210-open-fpga:0.1.0} bash -s <<EOF
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=\$FPGA_HOME/share/prjxray-db
OUT=\$CR/build/fpga/pnr
if [ ! -f \$CR/build/fpga/synth/b200.json ]; then
  echo "need b200.json first"; exit 1
fi
nextpnr-himbaechel --device \$FPGA_PART \\
  --chipdb \$FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \\
  --json \$CR/build/fpga/synth/b200.json \\
  -o xdc=\$CR/src/constraints/b210.xdc -o fasm=\$OUT/b200_seed${SEED}.fasm \\
  --seed ${SEED} > \$CR/build/fpga/logs/b200-seed${SEED}-pnr.log 2>&1 \\
  || { tail -40 \$CR/build/fpga/logs/b200-seed${SEED}-pnr.log; exit 1; }
echo "pnr ok"
fasm2frames --db-root \$PRJXRAY_DB/kintex7 --part \$FPGA_PART \\
  \$OUT/b200_seed${SEED}.fasm \$OUT/b200_seed${SEED}.frames \\
  > \$CR/build/fpga/logs/b200-seed${SEED}-f2f.log 2>&1 \\
  || { tail -40 \$CR/build/fpga/logs/b200-seed${SEED}-f2f.log; exit 1; }
python3 \$CR/build/patch_full_design.py \$OUT/b200_seed${SEED}.frames \$OUT/b200_seed${SEED}_fixed.frames
xc7frames2bit --part_file \$PRJXRAY_DB/kintex7/\$FPGA_PART/part.yaml \\
  --part_name \$FPGA_PART --frm_file \$OUT/b200_seed${SEED}_fixed.frames \\
  --output_file \$OUT/b200_seed${SEED}.bit \\
  > \$CR/build/fpga/logs/b200-seed${SEED}-bit.log 2>&1 \\
  || { tail -40 \$CR/build/fpga/logs/b200-seed${SEED}-bit.log; exit 1; }
python3 \$CR/scripts/bit2bin.py \$OUT/b200_seed${SEED}.bit \$OUT/b200_seed${SEED}.bin
idcode=\$(bittool get_device_id \$OUT/b200_seed${SEED}.bin)
echo "idcode: \$idcode (expect 0x3651093)"
echo "full b200 image ok: \$OUT/b200_seed${SEED}.bin"
EOF
