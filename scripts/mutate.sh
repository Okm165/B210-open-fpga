#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/mutate.sh [JOBS] [FILTER] - how much of the RTL the benches hold
# down. Each mutant (scripts/mutate.py list) is one small textual change;
# it is applied to a copy of fpga/rtl and the benches that read that file
# are run against the copy. A mutant the benches still pass is a gap in
# them or an equivalent change; the run prints every survivor so it can be
# classified (a gap gets a test, an equivalent gets a note).
#
# JOBS defaults to the CPU count; FILTER is a grep pattern on the manifest
# line (file name, line number, ...) to run a subset. Cases run as
# fpga/tests/run.sh does, so LIMIT applies.
set -u
cd "$(dirname "$0")/.."
MUT=build/mut

# The bench(es) that read a file. A mutant is killed when any of them gives a
# result other than the one it states (run.sh's exit status).
benches() {
  case $1 in
    ad9361_io.v)   echo ad9361_io ;;
    b210.v)        echo b210 ;;
    cdc_fifo.v)    echo cdc_fifo ;;
    command.v)     echo command ;;
    events.v)      echo events ;;
    fx3_master.v|fx3_pads.v) echo fx3_master ;;
    gray_sync.v)   echo sample_domain ;;
    packet_fifo.v) echo packet_fifo ;;
    packet_mux.v)  echo events ;;
    regs.v)        echo regs ;;
    rx_framer.v)   echo rx_framer ;;
    sample_domain.v) echo sample_domain ;;
    spi_master.v)  echo command ;;
    tx_deframer.v) echo tx_deframer ;;
    *)             echo "" ;;   # protocol.vh, unlisted files: not mutated here
  esac
}

# `mutate.sh --one ID FILE LINE OLD NEW` runs one mutant; the main path below
# feeds it through xargs, one process per mutant.
one() {
  id=$1 file=$2 line=$3 old=$4 new=$5
  dir=$MUT/$id
  mkdir -p "$dir"
  python3 scripts/mutate.py apply "$id" "$dir/rtl" || { echo "ERROR apply" > "$dir/log"; printf 'ERROR\t%s\t%s\t%s\t%s\t%s\n' "$id" "$file" "$line" "$old" "$new"; return; }
  ok=1
  for b in $(benches "$file"); do
    [ -n "$b" ] || continue
    RTL=$dir/rtl LIMIT=${LIMIT:-1500} sh fpga/tests/run.sh "^$b " >> "$dir/log" 2>&1 || ok=0
  done
  # every case gave the result it states: no bench noticed the change
  verdict=KILLED; [ "$ok" -eq 1 ] && verdict=SURVIVED
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$id" "$file" "$line" "$old" "$new"
}

if [ "${1:-}" = --one ]; then
  # one manifest line: fields are tab separated (a swap may contain spaces)
  line=$2
  one "$(printf '%s' "$line" | cut -f1)" "$(printf '%s' "$line" | cut -f2)" \
      "$(printf '%s' "$line" | cut -f3)" "$(printf '%s' "$line" | cut -f4)" \
      "$(printf '%s' "$line" | cut -f5)"
  exit
fi

JOBS=${1:-$(nproc)}
FILTER=${2:-.}
rm -rf "$MUT"
mkdir -p "$MUT"
python3 scripts/mutate.py list > "$MUT/manifest.tsv"
echo "mutants: $(wc -l < "$MUT/manifest.tsv"), jobs: $JOBS, filter: $FILTER"

grep -- "$FILTER" "$MUT/manifest.tsv" | \
  xargs -d '\n' -I{} -P "$JOBS" sh scripts/mutate.sh --one {} | sort > "$MUT/results.tsv"

k=$(grep -c '^KILLED' "$MUT/results.tsv" || true)
s=$(grep -c '^SURVIVED' "$MUT/results.tsv" || true)
e=$(grep -c '^ERROR' "$MUT/results.tsv" || true)
n=$((k + s + e))
printf 'killed %s, survived %s, error %s of %s (%s%% killed)\n' "$k" "$s" "$e" "$n" \
  "$(awk -v k="$k" -v n="$n" 'BEGIN { if (n) printf "%.1f", 100 * k / n; else print 0 }')"
grep -v '^KILLED' "$MUT/results.tsv" || true
[ "$s" -eq 0 ] && [ "$e" -eq 0 ]
