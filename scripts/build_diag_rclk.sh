#!/usr/bin/env bash
# build_diag_rclk.sh - build the raw-clock GPIF speaker (no MMCM, no ctrl).
# Output: build/fpga/diag/usrp_diag_rclk.bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR=/work
FPGA_PART=xc7k325tffg676-1
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
$CE run --rm -i --userns=keep-id -v "$ROOT:$CR:z" -w "$CR" -e HOME="$CR/build" \
  -e FPGA_PART=$FPGA_PART -e FPGA_HOME=$FPGA_HOME b210-open-fpga:0.1.0 bash -s <<-'EOF'
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
OUT=$CR/build/fpga/diag
SRCS="$CR/src/top/diag_rclk.v"
mkdir -p $OUT/synth $OUT/pnr $OUT/bitstream $CR/build/fpga/logs
yosys -p "read_verilog -I $CR/src/rtl/control $SRCS; synth_xilinx -flatten -abc9 -family xc7 -top diag_rclk; write_json $OUT/synth/diag_rclk.json; stat" \
  > $CR/build/fpga/logs/rclk-synth.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/rclk-synth.log; exit 1; }
echo "synth ok"
nextpnr-himbaechel --device $FPGA_PART \
  --chipdb $FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \
  --json $OUT/synth/diag_rclk.json \
  -o xdc=$CR/src/constraints/diag_ctrl.xdc -o fasm=$OUT/pnr/diag_rclk.fasm \
  --seed 1 > $CR/build/fpga/logs/rclk-pnr.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/rclk-pnr.log; exit 1; }
echo "pnr ok"
fasm2frames --db-root $PRJXRAY_DB/kintex7 --part $FPGA_PART \
  $OUT/pnr/diag_rclk.fasm $OUT/pnr/diag_rclk.frames \
  > $CR/build/fpga/logs/rclk-f2f.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/rclk-f2f.log; exit 1; }
xc7frames2bit --part_file $PRJXRAY_DB/kintex7/$FPGA_PART/part.yaml \
  --part_name $FPGA_PART --frm_file $OUT/pnr/diag_rclk.frames \
  --output_file $OUT/bitstream/diag_rclk.bit \
  > $CR/build/fpga/logs/rclk-bit.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/rclk-bit.log; exit 1; }
python3 $CR/scripts/bit2bin.py $OUT/bitstream/diag_rclk.bit $OUT/usrp_diag_rclk.bin \
  > $CR/build/fpga/logs/rclk-b2b.log 2>&1 \
  || { cat $CR/build/fpga/logs/rclk-b2b.log; exit 1; }
idcode=$(bittool get_device_id $OUT/usrp_diag_rclk.bin)
echo "idcode: $idcode (expect 0x3651093)"
echo "diag rclk image ok: $OUT/usrp_diag_rclk.bin"
EOF
