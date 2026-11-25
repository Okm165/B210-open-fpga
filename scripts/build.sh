#!/usr/bin/env bash
# build.sh - the v2 FPGA (fpga/rtl, fpga/b210.xdc) -> FX3-loadable .bin.
#
#   scripts/build.sh                       build/fpga/usrp_v2.bin + usrp_v2.txt
#   NAME=try PARAMS="BUILD_NUMBER=7" scripts/build.sh
#
#   DESIGN   top module (default b210)
#   NAME     output name (default v2) -> build/fpga/usrp_$NAME.bin
#   PARAMS   "K=V ..." top-level parameter overrides.  BUILD_COMMIT defaults
#            to the first 8 hex digits of HEAD (as a decimal number)
#   SRCS     source list override (default fpga/rtl/*.v)
#   XDC      constraints override (default fpga/b210.xdc)
#   ALLOW_TIMING_FAIL=1  still produce the image when a clock misses its
#            constraint; the build record says so.  For measurements only.
#   PNR_EXTRA="..."  extra nextpnr arguments, e.g. PNR_EXTRA="-o timing-opt=15".
#   NEXTPNR, CHIPDB, PRJXRAY_DB, FPGA_IMAGE  tool overrides.
#
# Outputs of an earlier run under the same NAME are removed first, so a .bin
# that exists afterwards came from this run; what it was built from is
# recorded beside it in usrp_$NAME.txt.
#
# Flow: yosys (container image from container/Dockerfile) -> nextpnr-himbaechel
# (scripts/toolchain.sh) -> scripts/assemble.sh (frames/bit/bin).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="${DESIGN:-b210}"
NAME="${NAME:-v2}"
PART=xc7k325tffg676-1
NEXTPNR="${NEXTPNR:-$ROOT/.tools/nextpnr-himbaechel}"
CHIPDB="${CHIPDB:-$ROOT/.tools/chipdb-xc7k325t.bin}"
OUT=build/fpga
LOGS=build/fpga/logs
cd "$ROOT"
SRCS="${SRCS:-$(echo fpga/rtl/*.v)}"
XDC="${XDC:-fpga/b210.xdc}"
[[ -f "$XDC" ]] || { echo "build: no constraints file $XDC" >&2; exit 2; }
# What this image is built from is fixed now, before the first tool reads a
# file: the build takes hours and the repository moves on meanwhile.
HEAD="$(git rev-parse HEAD)"
SOURCE="$HEAD$([[ -z "$(git status --porcelain -- fpga scripts container)" ]] || echo ' + uncommitted changes')"
# The commit register: from git, never typed by hand.
[[ " ${PARAMS:-} " == *" BUILD_COMMIT="* ]] || PARAMS="BUILD_COMMIT=$((16#${HEAD:0:8}))${PARAMS:+ $PARAMS}"
for tool in "$NEXTPNR" "$CHIPDB"; do
  [[ -s "$tool" ]] || { echo "build: missing $tool (scripts/toolchain.sh builds it)" >&2; exit 2; }
done
mkdir -p $OUT/synth $OUT/pnr $LOGS
rm -f $OUT/synth/$NAME.json $OUT/pnr/$NAME.fasm $OUT/usrp_$NAME.bin $OUT/usrp_$NAME.txt
CHP=""; for kv in $PARAMS; do CHP+="chparam -set ${kv%%=*} ${kv#*=} $DESIGN; "; done

podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -w /work -e HOME=/work/build \
  "${FPGA_IMAGE:-b210-open-fpga:0.3.0}" bash -c \
  "yosys -p 'read_verilog -I fpga/rtl $SRCS; $CHP synth_xilinx -flatten -abc9 -family xc7 -top $DESIGN; write_json $OUT/synth/$NAME.json' > $LOGS/$NAME-synth.log 2>&1" \
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
