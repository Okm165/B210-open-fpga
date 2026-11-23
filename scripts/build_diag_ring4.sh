#!/usr/bin/env bash
# build_diag_ctrl2.sh - build the minimal control-path diagnostic.
# Output: build/fpga/diag/usrp_diag_ctrl2.bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR=/work
FPGA_PART=xc7k325tffg676-1
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
$CE run --rm -i --userns=keep-id -v "$ROOT:$CR:z" -w "$CR" -e HOME="$CR/build" \
  -e FPGA_PART=$FPGA_PART -e FPGA_HOME=$FPGA_HOME -e SEED=${SEED:-1} ${FPGA_IMAGE:-b210-open-fpga:0.1.0} bash -s <<-'EOF'
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
OUT=$CR/build/fpga/ring2
SRCS="$CR/src/top/diag_ring4.v $CR/src/top/b200_clk_gen.v"
mkdir -p $OUT/synth $OUT/pnr $OUT/bitstream $CR/build/fpga/logs
yosys -p "read_verilog -I $CR/src/rtl/control $SRCS; synth_xilinx -flatten -abc9 -family xc7 -top diag_ring4; write_json $OUT/synth/diag_ring4.json; stat" \
  > $CR/build/fpga/logs/diagc-synth.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-synth.log; exit 1; }
echo "synth ok"
nextpnr-himbaechel --device $FPGA_PART \
  --chipdb $FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \
  --json $OUT/synth/diag_ring4.json \
  -o xdc=$CR/src/constraints/diag_pad.xdc -o fasm=$OUT/pnr/diag_ring4.fasm \
--ignore-loops --seed ${SEED:-1} > $CR/build/fpga/logs/diagc-pnr.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-pnr.log; exit 1; }
echo "pnr ok"
fasm2frames --db-root $PRJXRAY_DB/kintex7 --part $FPGA_PART \
  $OUT/pnr/diag_ring4.fasm $OUT/pnr/diag_ring4.frames \
  > $CR/build/fpga/logs/diagc-f2f.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-f2f.log; exit 1; }
xc7frames2bit --part_file $PRJXRAY_DB/kintex7/$FPGA_PART/part.yaml \
  --part_name $FPGA_PART --frm_file $OUT/pnr/diag_ring4.frames \
  --output_file $OUT/bitstream/diag_ring4.bit \
  > $CR/build/fpga/logs/diagc-bit.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-bit.log; exit 1; }
python3 $CR/scripts/bit2bin.py $OUT/bitstream/diag_ring4.bit $OUT/usrp_diag_ring4.bin \
  > $CR/build/fpga/logs/diagc-b2b.log 2>&1 \
  || { cat $CR/build/fpga/logs/diagc-b2b.log; exit 1; }
idcode=$(bittool get_device_id $OUT/usrp_diag_ring4.bin)
echo "idcode: $idcode (expect 0x3651093)"
echo "diag ctrl image ok: $OUT/usrp_diag_ring4.bin"
EOF
