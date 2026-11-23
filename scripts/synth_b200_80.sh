#!/usr/bin/env bash
# synth_b200_80.sh - synthesize the full 2R2T b200 top with the 80 MHz clock gen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -w /work -e HOME=/work/build \
  b210-open-fpga:0.1.0 bash -s <<'EOF'
set -euo pipefail
cd /work
SRCS=$(tr '\n' ' ' < build/srcs80_abs.txt)
yosys -p "read_verilog -I /work/src/rtl/control $SRCS; synth_xilinx -flatten -abc9 -D TARGET_B210 -family xc7 -top b200_80; write_json /work/build/fpga/synth/b200_80.json; stat" \
  > build/fpga/logs/b200_80-synth.log 2>&1
tail -n 5 build/fpga/logs/b200_80-synth.log
echo "b200_80 synth ok"
EOF
