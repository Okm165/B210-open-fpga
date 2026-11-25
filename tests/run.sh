#!/usr/bin/env bash
# run.sh - one simulation bench: compile, run, judge by its log.
#
#   tests/run.sh [--must-fail] [--no-design] [-b bench.v] NAME TOP PASS [arg...]
#
#   NAME   names the outputs, build/sim/NAME.vvp and build/sim/NAME.log
#   TOP    the bench module, in tests/TOP.v unless -b names another file
#   PASS   the pattern (grep -E) the log must contain
#   arg    *.v   one more source file
#          -D..  a macro for the compilation
#          +..   a plusarg for the simulation
#
# The bench is compiled with the whole design (scripts/sources.txt and the
# primitive models of tests/sim), of which the simulator keeps what TOP
# instantiates.  --no-design leaves those out, for a bench that runs against
# a synthesized netlist given as source files.
#
# --must-fail is a negative control: the same bench with a fault switched on
# has to report it.  Its log must not contain PASS and must contain the same
# pattern with FAIL in place of PASS.
set -euo pipefail
cd "$(dirname "$0")/.."

must_fail=0 design=1 bench=""
while [[ ${1:-} == -* ]]; do
  case $1 in
    --must-fail) must_fail=1 ;;
    --no-design) design=0 ;;
    -b) bench=$2; shift ;;
    *) echo "run.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
name=${1:?run.sh: NAME TOP PASS} top=${2:?} pass=${3:?}
shift 3
bench=${bench:-tests/$top.v}

sources=() macros=() plusargs=()
for arg in "$@"; do
  case $arg in
    -D*) macros+=("$arg") ;;
    +*)  plusargs+=("$arg") ;;
    *)   sources+=("$arg") ;;
  esac
done
if (( design )); then
  mapfile -t rtl < <(grep '^src/' scripts/sources.txt)
  sources+=("${rtl[@]}" tests/sim/xilinx_prim_sim.v)
fi

out=build/sim
mkdir -p $out
rm -f "$out/$name.log"
# Warnings stay in the file: the stock RTL has hundreds of width warnings.
"${IVERILOG:-iverilog}" -g2005 -I src/rtl/control "${macros[@]}" -s "$top" -o "$out/$name.vvp" \
    "${sources[@]}" "$bench" 2> "$out/$name.compile.log" \
  || { grep -v 'warning:' "$out/$name.compile.log" | head -20; echo "FAIL: $name does not compile"; exit 1; }
"${VVP:-vvp}" -n -l "$out/$name.log" "$out/$name.vvp" "${plusargs[@]}" > /dev/null

if (( must_fail )); then
  fail=${pass//PASS/FAIL}
  if grep -Eq "$fail" "$out/$name.log" && ! grep -Eq "$pass" "$out/$name.log"; then
    echo "PASS: $name reports the fault it was given"
  else
    echo "FAIL: $name did not report the fault it was given; see $out/$name.log"; exit 1
  fi
elif grep -E "$pass" "$out/$name.log"; then
  :
else
  tail -15 "$out/$name.log"
  echo "FAIL: $name; see $out/$name.log"; exit 1
fi
