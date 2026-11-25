#!/usr/bin/env bash
# build.sh - Verilog -> FX3-loadable .bin through the one open flow.
#
#   scripts/build.sh                                         the B210 image
#   DESIGN=diag_echo NAME=echo PARAMS="IFCLK_STEPS=66" scripts/build.sh
#
#   DESIGN   top module (default b200: the full 2 RX + 2 TX design, sources
#            from scripts/sources.txt); any other top is src/top/$DESIGN.v on
#            top of the same sources
#   NAME     output name, default $DESIGN -> build/fpga/usrp_$NAME.bin
#   PARAMS   "K=V ..." top-level parameter overrides
#   SRCS     source list override
#   XDC      constraints override (default src/constraints/b210.xdc for
#            every top: lines about pins a design does not have are ignored)
#   ALLOW_TIMING_FAIL=1  still produce the image when a clock misses its
#            constraint; the build record says so and scripts/hw_gate.sh
#            refuses such an image.  For measurements only.
#   PNR_EXTRA="..."  extra nextpnr arguments, e.g. PNR_EXTRA="-o timing-opt=15"
#            (the timing-driven placement refinement).  Recorded in usrp_$NAME.txt.
#
# Outputs of an earlier run under the same NAME are removed before anything
# is built, so a .bin that exists afterwards came from this run; what it was
# built from is recorded beside it in usrp_$NAME.txt.
#
# Flow: yosys (container) -> nextpnr-himbaechel (host build from pinned
# sources, scripts/toolchain.sh) -> scripts/assemble.sh (frames/bit/bin).
# No seed knob: the seed was never the variable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="${DESIGN:-b200}"
NAME="${NAME:-$DESIGN}"
PART=xc7k325tffg676-1
NEXTPNR="${NEXTPNR:-$ROOT/.tools/nextpnr-himbaechel}"
CHIPDB="${CHIPDB:-$ROOT/.tools/chipdb-xc7k325t.bin}"
OUT=build/fpga
LOGS=build/fpga/logs
cd "$ROOT"
SRCS="${SRCS:-$(grep '^src/' scripts/sources.txt | tr '\n' ' ')}"
[[ "$DESIGN" == b200 || ! -f src/top/$DESIGN.v ]] || SRCS+=" src/top/$DESIGN.v"
XDC="${XDC:-src/constraints/b210.xdc}"
[[ -f "$XDC" ]] || { echo "build: no constraints file $XDC" >&2; exit 2; }
# What this image is built from is fixed now, before the first tool reads a
# file: the build takes hours and the repository moves on meanwhile.
SOURCE="$(git rev-parse HEAD)$([[ -z "$(git status --porcelain -- src fpga scripts container)" ]] || echo ' + uncommitted changes')"
for tool in "$NEXTPNR" "$CHIPDB"; do
  [[ -s "$tool" ]] || { echo "build: missing $tool (scripts/toolchain.sh builds it)" >&2; exit 2; }
done
mkdir -p $OUT/synth $OUT/pnr $LOGS
rm -f $OUT/synth/$NAME.json $OUT/pnr/$NAME.fasm $OUT/usrp_$NAME.bin $OUT/usrp_$NAME.txt
CHP=""; for kv in ${PARAMS:-}; do CHP+="chparam -set ${kv%%=*} ${kv#*=} $DESIGN; "; done

podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -w /work -e HOME=/work/build \
  "${FPGA_IMAGE:-b210-open-fpga:0.3.0}" bash -c \
  "yosys -p 'read_verilog -I src/rtl/control $SRCS; $CHP synth_xilinx -flatten -abc9 -family xc7 -top $DESIGN; write_json $OUT/synth/$NAME.json' > $LOGS/$NAME-synth.log 2>&1" \
  || { tail -20 $LOGS/$NAME-synth.log; exit 1; }

# A fixed thread count: the router splits the device by it, so the routed
# result is a function of this number and must not follow the host.
TFAIL=""; [[ "${ALLOW_TIMING_FAIL:-0}" == 1 ]] && TFAIL="--timing-allow-fail"
"$NEXTPNR" --device $PART --chipdb "$CHIPDB" --json $OUT/synth/$NAME.json --threads 16 \
  -o xdc=$XDC -o fasm=$OUT/pnr/$NAME.fasm $TFAIL ${PNR_EXTRA:-} > $LOGS/$NAME-pnr.log 2>&1 \
  || { grep -E "^ERROR|FAIL at" $LOGS/$NAME-pnr.log | tail -10; exit 1; }
# the routed result: the last report of each clock in the log
TIMING=$(grep -E "Max frequency for clock" $LOGS/$NAME-pnr.log | sed -E "s/^[A-Za-z]+: Max frequency for clock +//" \
  | awk -F"'" '{last[$2]=$0} END {for (c in last) print "timing   " last[c]}' | sort)
# Clock-domain crossings: nextpnr has no set_max_delay, it only reports the
# longest path of each.  The bounds are the set_max_delay lines of the XDC;
# a reported crossing without one is an error.
CROSSINGS=$(python3 - "$XDC" "$LOGS/$NAME-pnr.log" <<'PY'
import re, sys
bounds = []                                  # (from edge or None, from clock, to clock, ns)
for line in open(sys.argv[1]):
    m = re.match(r'\s*set_max_delay\b.*?-(fall_|rise_)?from\s+\[get_clocks\s+(\S+?)\]'
                 r'.*?-to\s+\[get_clocks\s+(\S+?)\]\s+([0-9.]+)\s*$', line)
    if m:
        edge = {'fall_': 'negedge', 'rise_': 'posedge', None: None}[m.group(1)]
        bounds.append((edge, m.group(2), m.group(3), float(m.group(4))))
last = {}                                    # the routed report is the last one in the log
for line in open(sys.argv[2], errors='replace'):
    m = re.match(r'\w+: Max delay (posedge|negedge) (\S+)\s+-> (posedge|negedge) (\S+)\s*: +([0-9.]+) ns', line)
    if m:
        last[m.group(1, 2, 3, 4)] = float(m.group(5))
for (e1, c1, e2, c2), ns in sorted(last.items()):
    limit = [b[3] for b in bounds if b[1] == c1 and b[2] == c2 and b[0] in (None, e1)]
    verdict = 'FAIL: no set_max_delay for this crossing' if not limit else \
              ('PASS' if ns <= min(limit) else 'FAIL') + ' at %.2f ns' % min(limit)
    print("timing   crossing %s %s -> %s %s: %.2f ns (%s)" % (e1, c1, e2, c2, ns, verdict))
PY
)
[[ -z "$CROSSINGS" ]] || TIMING+=$'\n'"$CROSSINGS"
echo "$TIMING" | sed 's/^timing /  /'
if grep -q "crossing.*FAIL" <<< "$TIMING" && [[ "${ALLOW_TIMING_FAIL:-0}" != 1 ]]; then
  echo "build: a clock-domain crossing misses its bound" >&2; exit 1
fi

scripts/assemble.sh $OUT/pnr/$NAME.fasm $OUT/usrp_$NAME.bin
{ echo "image    $(sha256sum $OUT/usrp_$NAME.bin | cut -d' ' -f1)"
  echo "design   $DESIGN ${PARAMS:-}"
  echo "xdc      $XDC"
  echo "source   $SOURCE"
  echo "nextpnr  $(sha256sum "$NEXTPNR" | cut -c1-16) chipdb $(sha256sum "$CHIPDB" | cut -c1-16)"
  echo "tools    ${FPGA_IMAGE:-b210-open-fpga:0.3.0} $(podman image inspect -f '{{.Id}}' "${FPGA_IMAGE:-b210-open-fpga:0.3.0}" | cut -c1-16)"
  [[ -z "${PNR_EXTRA:-}" ]] || echo "pnr opts $PNR_EXTRA"
  echo "$TIMING"
  echo "built    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > $OUT/usrp_$NAME.txt
echo "built: $OUT/usrp_$NAME.bin  (constraints: $XDC)"
