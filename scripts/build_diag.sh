#!/usr/bin/env bash
# build_diag.sh - build the diagnostic LED image (diag_clock) with the same
# container toolchain as the real build, but standalone: no DSP/MMCM-netlist
# asserts, no gate, no deploy overwrite.  Output: build/fpga/diag/usrp_diag.bin
#
# The image answers, by eye alone, whether the 40 MHz reference reaches the
# FPGA (see src/top/diag_clock.v).  Load it with:
#   python3 scripts/hw_load.py build/fpga/diag/usrp_diag.bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR=/work
FPGA_PART=xc7k325tffg676-1
DIE=xc7k325t
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
$CE run --rm -i --userns=keep-id -v "$ROOT:$CR:z" -w "$CR" -e HOME="$CR/build" \
  -e FPGA_PART=$FPGA_PART -e FPGA_HOME=$FPGA_HOME b210-open-fpga:0.1.0 bash -s <<-'EOF'
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
OUT=$CR/build/fpga/diag
mkdir -p $OUT/synth $OUT/pnr $OUT/bitstream $CR/build/fpga/logs
yosys -p "read_verilog $CR/src/top/diag_clock.v; \
          synth_xilinx -flatten -abc9 -family xc7 -top diag_clock; \
          write_json $OUT/synth/diag_clock.json; stat" \
  > $CR/build/fpga/logs/diag-synth.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diag-synth.log; exit 1; }
grep -q '"type": "MMCME2_ADV"' $OUT/synth/diag_clock.json
echo "synth ok"
nextpnr-himbaechel --device $FPGA_PART \
  --chipdb $FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \
  --json $OUT/synth/diag_clock.json \
  -o xdc=$CR/src/constraints/diag_clock.xdc -o fasm=$OUT/pnr/diag_clock.fasm \
  --seed 1 > $CR/build/fpga/logs/diag-pnr.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diag-pnr.log; exit 1; }
echo "pnr ok"
fasm2frames --db-root $PRJXRAY_DB/kintex7 --part $FPGA_PART \
  $OUT/pnr/diag_clock.fasm $OUT/pnr/diag_clock.frames \
  > $CR/build/fpga/logs/diag-f2f.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diag-f2f.log; exit 1; }
xc7frames2bit --part_file $PRJXRAY_DB/kintex7/$FPGA_PART/part.yaml \
  --part_name $FPGA_PART --frm_file $OUT/pnr/diag_clock.frames \
  --output_file $OUT/bitstream/diag_clock.bit \
  > $CR/build/fpga/logs/diag-bit.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diag-bit.log; exit 1; }
python3 $CR/scripts/bit2bin.py $OUT/bitstream/diag_clock.bit $OUT/usrp_diag.bin \
  > $CR/build/fpga/logs/diag-b2b.log 2>&1 \
  || { cat $CR/build/fpga/logs/diag-b2b.log; exit 1; }
idcode=$(bittool get_device_id $OUT/usrp_diag.bin)
echo "idcode: $idcode (expect 0x3651093)"
sha256sum $OUT/usrp_diag.bin
echo "diag image ok: $OUT/usrp_diag.bin"
EOF
