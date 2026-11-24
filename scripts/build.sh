#!/usr/bin/env bash
# build_diag.sh - Verilog -> FX3-loadable .bin through the fixed open flow.
#
#   DESIGN=diag_rd NAME=diag_rdB PARAMS="MODE=1" scripts/build_diag.sh
#   DESIGN=b200_80 SRCS="$(scripts/full_sources.sh)" XDC=src/constraints/b210.xdc scripts/build_diag.sh
#
#   DESIGN   top module; default source is src/top/$DESIGN.v      (required)
#   NAME     output name, default $DESIGN -> build/fpga/ring2/usrp_$NAME.bin
#   PARAMS   "K=V ..." top-level parameter overrides
#   SRCS     source list override (default: the clock generators + the design)
#   XDC      default src/constraints/$DESIGN.xdc, else diag_pad.xdc
#   IGNORE_LOOPS=1   combinational-ring designs
#
# Flow: yosys (container) -> nextpnr-himbaechel (host build of openXC7/nextpnr
# main + the RIOI ZINV_T1 fix) -> scripts/assemble.sh (frames/bit/bin with the
# HP-bank glue fix).  See docs/DOD-STATUS.md section 49 for both fixes.
# No seed knob: the seed was never the variable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="${DESIGN:?usage: DESIGN=<top module> [NAME=..] [PARAMS=..] $0}"
NAME="${NAME:-$DESIGN}"
PART=xc7k325tffg676-1
NEXTPNR="${NEXTPNR:-/tmp/opencode/openxc7-nextpnr/build2/nextpnr-himbaechel}"
CHIPDB="${CHIPDB:-/tmp/opencode/openxc7-nextpnr/build2/share/himbaechel/xilinx/chipdb-xc7k325t.bin}"
OUT=build/fpga/ring2
LOGS=build/fpga/logs
SRCS="${SRCS:-src/top/b200_clk_gen.v src/top/b200_clk_gen80.v src/top/$DESIGN.v}"
XDC="${XDC:-src/constraints/$DESIGN.xdc}"
cd "$ROOT"
[[ -f "$XDC" ]] || XDC=src/constraints/diag_pad.xdc
mkdir -p $OUT/synth $OUT/pnr $OUT/bitstream $LOGS
CHP=""; for kv in ${PARAMS:-}; do CHP+="chparam -set ${kv%%=*} ${kv#*=} $DESIGN; "; done

podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -w /work -e HOME=/work/build \
  "${FPGA_IMAGE:-b210-open-fpga:0.1.0}" bash -c \
  "yosys -p 'read_verilog -I src/rtl/control $SRCS; $CHP synth_xilinx -flatten -abc9 -family xc7 -top $DESIGN; write_json $OUT/synth/$NAME.json' > $LOGS/$NAME-synth.log 2>&1" \
  || { tail -20 $LOGS/$NAME-synth.log; exit 1; }

LOOPS=""; [[ "${IGNORE_LOOPS:-0}" == 1 ]] && LOOPS="--ignore-loops"
"$NEXTPNR" --device $PART --chipdb "$CHIPDB" --json $OUT/synth/$NAME.json \
  -o xdc=$XDC -o fasm=$OUT/pnr/$NAME.fasm $LOOPS > $LOGS/$NAME-pnr.log 2>&1 \
  || { grep -E "^ERROR|FAIL at" $LOGS/$NAME-pnr.log | tail -10; exit 1; }
grep -E "Max frequency for clock" $LOGS/$NAME-pnr.log | tail -4 | sed 's/^Info: /  /' || true

scripts/assemble.sh $OUT/pnr/$NAME.fasm $OUT/usrp_$NAME.bin
echo "built: $OUT/usrp_$NAME.bin"
