#!/usr/bin/env bash
# hw_gate.sh - hardware acceptance of an image built by this repository.
#
#   scripts/hw_gate.sh build/fpga/usrp_b200.bin
#
# Every step must pass, in this order.  The vendor image is the reference
# device under test: where a number depends on the board, the AD9361 or the
# host, it is measured on the vendor image in the same run.
#
#   identity    the image carries the build record scripts/build.sh wrote for
#               exactly these bytes: the full design, the board constraints,
#               all three clocks and every clock-domain crossing meeting
#               their constraints.  It is not the vendor image.
#   raw         FX3 reboot, FPGA load, 64 control transactions, 8 MB drain,
#               with no UHD involved (scripts/fx3_raw_load.py)
#   init        stock UHD loads THIS image and initialises both radio cores
#               (register loopback on each; UHD's codec loopback test raises
#               an error when it fails), then streams both channels at
#               30.72 MS/s and one at 61.44 MS/s through the stock Python API
#               with every sample delivered (scripts/rx_capture.py).  The
#               steps below use the measuring UHD 3.15 of scripts/toolchain.sh.
#   eye         at 61.44 MHz, the AD9361 interface is clean at UHD's
#               operating point with at least EYE_MIN_STEPS (8) delay steps
#               to the nearest data transition in both directions
#               (scripts/eyescan.sh; the vendor image has 2 on receive)
#   samples     known signals through both directions
#               (scripts/sample_check.py), each compared with the vendor
#               image: the AD9361 test tone on both channels, on one channel
#               at 61.44 MS/s and through the x4 decimation; host tones
#               returned by the AD9361 digital loopback through the x4
#               filters, at 2R2T x 30.72 MS/s in the 12-bit wire format and
#               on one channel at 61.44 MS/s.  Then the AD9361 pseudo-random
#               sequence, bit exact: PRBS_RUNS (8) separate sessions on two
#               channels, each with zero errors and the two channels sample
#               aligned, and one session at 61.44 MS/s.
#   dsp         the DSP chains on the board against the repository's RTL,
#               bit for bit (scripts/dsp_exact.py): the pseudo-random
#               sequence through decimation 1, 2, 3, 4, 8 and 16 on both
#               channels, and known transmit data through the AD9361 loopback
#               at interpolation and decimation 1 and 4.  Every sample must
#               be the one the RTL simulation produces.
#   bus margin  the FX3 bus with the forwarded clock BUS_MARGIN_STEPS (20,
#               2.1 ns) earlier and later than built: copies of this image
#               with only that changed (scripts/bus_window.py) must still
#               answer 64 control transactions, deliver the pseudo-random
#               sequence without an error and return transmit data bit for
#               bit.  The window is 5.9 ns wide and the design sits in its
#               middle; this shows it for the image under test.
#   throughput  UHD benchmark_rate, 10 s per run, at 2 RX x 30.72,
#               2 TX x 30.72, 1 RX x 61.44 MS/s and full-duplex
#               2R2T x 30.72 MS/s in the 12-bit wire format.  Loss depends on
#               what else the host is doing, so every run of this image is
#               taken between two runs of the vendor image and counts only
#               when both of those lost nothing; then this image must have
#               lost nothing either.  Two counted runs per mode pass it.  If
#               the host never stays quiet long enough the gate stops as
#               inconclusive (exit 3), which is not a pass.  WAIT_QUIET=<s>
#               waits up to that long for the host's load average to drop
#               below QUIET_LOAD (4) before this step starts.
#
# The raw step reboots the FX3, which forgets the loaded image, so the UHD
# run that follows has to load the file named here; later steps name their
# image and UHD reloads whenever it differs from the one in the FPGA.
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=$(realpath "${1:?usage: hw_gate.sh <image.bin>}")
SERIAL=${SERIAL:-31B92DD}
EYE_MIN_STEPS=${EYE_MIN_STEPS:-8}
PRBS_RUNS=${PRBS_RUNS:-8}
BUS_MARGIN_STEPS=${BUS_MARGIN_STEPS:-20}
VENDOR=/usr/share/uhd/images/usrp_b210_fpga.bin
BENCH=$PWD/.tools/uhd315/bin/benchmark_rate
ARGS="type=b200,serial=${SERIAL},fpga=${IMG}"
OUT="build/hw-gate-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
fail() { echo "GATE FAIL ($1): $2" >&2; exit 1; }
inconclusive() { echo "GATE INCONCLUSIVE ($1): $2" >&2; exit 3; }
# Real-time priority for the streaming tools when the account may use it.
RT=""; chrt -f 50 true 2>/dev/null && RT="chrt -f 50"

echo "== identity =="
SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
[[ "$SHA" != "$(sha256sum "$VENDOR" | cut -d' ' -f1)" ]] || fail identity "this is the vendor image"
RECORD="${IMG%.bin}.txt"
[[ -f "$RECORD" ]] && grep -q "^image    $SHA\$" "$RECORD" \
  || fail identity "no build record for these bytes at $RECORD"
tee "$OUT/00-identity.txt" < "$RECORD"
grep -q "^design   b200 *\$" "$RECORD" || fail identity "not the unmodified b200 design"
grep -q "^xdc      src/constraints/b210.xdc\$" "$RECORD" || fail identity "not built with the board constraints"
for clock in "'bus_clk': .* (PASS at 100.00 MHz)" "'radio_clk': .* (PASS at 61.44 MHz)" \
             "'b200_io_i0.rx_clk_bufr': .* (PASS at 61.44 MHz)"; do
  grep -q "^timing   $clock" "$RECORD" || fail identity "build record lacks: $clock"
done
grep -q "^timing   crossing .*PASS" "$RECORD" || fail identity "build record has no checked clock-domain crossing"
! grep -q "^timing .*FAIL" "$RECORD" || fail identity "the build record shows a missed timing constraint"
! grep -q "uncommitted" "$RECORD" || echo "  note: built from uncommitted sources"

echo "== raw control and data path, no UHD =="
python3 scripts/fx3_raw_load.py "$IMG" --peek 64 > "$OUT/01-raw.txt" 2>&1 \
  || { cat "$OUT/01-raw.txt"; fail raw "see $OUT/01-raw.txt"; }
cat "$OUT/01-raw.txt"

echo "== stock UHD init =="
timeout 240 uhd_usrp_probe --args="$ARGS" > "$OUT/02-init.txt" 2>&1 \
  || { tail -5 "$OUT/02-init.txt"; fail init "uhd_usrp_probe failed"; }
grep -q "Loading FPGA image: $IMG" "$OUT/02-init.txt" || fail init "UHD did not load $IMG"
[[ $(grep -c 'Register loopback test passed' "$OUT/02-init.txt") -eq 2 ]] \
  || fail init "expected two radio cores"
grep -E "Loading FPGA|loopback test passed|FPGA Version" "$OUT/02-init.txt" || true
stock_rx() {   # stock_rx <image> <log> <channels> <rate>
  $RT timeout 240 python3 scripts/rx_capture.py --args "type=b200,serial=${SERIAL},fpga=$1" \
    --chans "$3" --rate "$4" --secs 0.1 --out "$OUT/stock-rx" > "$2" 2>&1
}
for mode in "2 30.72e6" "1 61.44e6"; do
  set -- $mode
  # A capture cut short by the host is not a measurement: up to three
  # attempts, every one of them kept.  If none completes, the vendor image
  # decides between a fault of this image and a busy host.
  for attempt in 1 2 3 fail; do
    [[ $attempt != fail ]] || break
    LOG="$OUT/02-stock-rx-$1ch-$attempt.txt"
    if stock_rx "$IMG" "$LOG" "$1" "$2"; then break; fi
    { grep -E "rx_capture\] LO" "$LOG" || tail -1 "$LOG"; } | sed "s/^/  attempt $attempt: /"
  done
  if [[ $attempt == fail ]]; then
    stock_rx "$VENDOR" "$OUT/02-stock-rx-$1ch-vendor.txt" "$1" "$2" \
      || inconclusive init "stock UHD streaming, $1 channel(s) at $2: the vendor image does not complete either"
    fail init "stock UHD streaming, $1 channel(s) at $2: three incomplete captures, the vendor image completes"
  fi
  { grep -E "rx_capture\] (LO|OVERALL)" "$LOG" || true; } | sed "s/^/  attempt $attempt: /"
done

echo "== AD9361 interface eye at 61.44 MHz =="
scripts/eyescan.sh "$IMG" 61.44e6 > "$OUT/03-eye.txt" 2>&1 || true
tail -5 "$OUT/03-eye.txt"
grep -q '^RESULT: PASS' "$OUT/03-eye.txt" || fail eye "operating point is not clean, see $OUT/03-eye.txt"
for side in rx tx; do
  BELOW=$(sed -n "s/^  $side margin: \([0-9]*\) steps below.*/\1/p" "$OUT/03-eye.txt")
  [[ "${BELOW:-0}" -ge "$EYE_MIN_STEPS" ]] || fail eye "$side margin ${BELOW:-0} steps, need $EYE_MIN_STEPS"
done

echo "== known signals through the sample paths =="
samples() {   # samples <name> <sample_check.py arguments...>
  local log="$OUT/04-samples-$1.txt" rc=0; shift
  python3 scripts/sample_check.py "$IMG" "$@" > "$log" 2>&1 || rc=$?
  sed 's/^/  /' "$log"
  [[ $rc -ne 3 ]] || inconclusive samples "no capture from the vendor image: $*"
  [[ $rc -eq 0 ]] && grep -q '^RESULT: PASS' "$log" || fail samples "$* : see $log"
}
echo " receive: AD9361 test tone"
samples rx-tone-2ch   --ref "$VENDOR" --tone --rate 30.72e6
samples rx-tone-1ch   --ref "$VENDOR" --tone --rate 61.44e6 --chans 0
samples rx-tone-dec4  --ref "$VENDOR" --tone --rate 7.68e6 --mcr 30.72e6 --samples 1048576
echo " transmit: host tones through the AD9361 digital loopback"
samples tx-x4         --ref "$VENDOR" --loopback 300e3 --rate 7.68e6 --mcr 30.72e6 --samples 1048576
samples tx-2r2t-sc12  --ref "$VENDOR" --loopback 1e6 --rate 30.72e6 --otw sc12
samples tx-1ch-61     --ref "$VENDOR" --loopback 2e6 --rate 61.44e6 --chans 0 --otw sc8
echo " receive: AD9361 pseudo-random sequence, bit exact"
for run in $(seq 1 "$PRBS_RUNS"); do
  samples "rx-prbs-2ch-$run" --prbs --rate 30.72e6
done
samples rx-prbs-1ch --prbs --rate 61.44e6 --chans 0

echo "== DSP on the board against the RTL, bit for bit =="
exact() {   # exact <name> <BIST|LOOPBACK> <host rate> <channels> <samples> <tx tone or ""> <dsp_exact.py arguments...>
  local name=$1 source=$2 rate=$3 chans=$4 count=$5 tone=$6; shift 6
  local prefix="$OUT/dsp/$name" log="$OUT/05-dsp-$name.txt" attempt
  mkdir -p "$OUT/dsp"
  for attempt in 1 2 3 fail; do      # a capture cut short by the host is taken again
    [[ $attempt != fail ]] || { echo "GATE FAIL (dsp): $name: no complete capture, see $prefix.log" >&2; return 1; }
    env "UHD_AD936X_$source" LD_LIBRARY_PATH="$PWD/.tools/uhd315/lib" UHD_IMAGES_DIR=/usr/share/uhd/images \
      $RT timeout 120 .tools/uhd315/bin/rx_dump "type=b200,serial=${SERIAL},fpga=${EXACT_IMG:-$IMG},master_clock_rate=30.72e6" \
      "$rate" "$chans" "$count" "$prefix" 100e6 0 sc16 $tone > "$prefix.log" 2>&1 && break
  done
  python3 scripts/dsp_exact.py "$@" "$prefix" --chans "$chans" > "$log" 2>&1 || true
  { grep -E "^(SUMMARY|RESULT)" "$log" || tail -2 "$log"; } | sed "s/^/  $name: /"
  grep -q '^RESULT: PASS' "$log" || { echo "GATE FAIL (dsp): $name: see $log" >&2; return 1; }
}
exact rx-d1  BIST=0x09  30.72e6 0,1 1048576 "" rx --decim 1
exact rx-d2  BIST=0x09  15.36e6 0,1 524288  "" rx --decim 2
exact rx-d3  BIST=0x09  10.24e6 0,1 524288  "" rx --decim 3
exact rx-d4  BIST=0x09  7.68e6  0,1 524288  "" rx --decim 4
exact rx-d8  BIST=0x09  3.84e6  0,1 262144  "" rx --decim 8
exact rx-d16 BIST=0x09  1.92e6  0,1 262144  "" rx --decim 16
exact loop-x1 LOOPBACK=1 30.72e6 0  1048576 1e6   loop --interp 1 --dac round
exact loop-x4 LOOPBACK=1 7.68e6  0,1 524288 300e3 loop --interp 4 --dac round

echo "== FX3 bus with the forwarded clock $BUS_MARGIN_STEPS steps earlier and later =="
FASM="$(dirname "$IMG")/pnr/$(basename "$IMG" .bin | sed 's/^usrp_//').fasm"
[[ -s $FASM ]] || fail "bus margin" "no routed design at $FASM"
bus_check() {   # bus_check <image>: control, receive data and transmit data over the bus, each exact
  local image; image=$(realpath "$1")
  python3 scripts/fx3_raw_load.py "$image" --peek 64 --drain 0 || return 1
  python3 scripts/sample_check.py "$image" --prbs --rate 30.72e6 || return 1
  EXACT_IMG=$image exact "margin-$(basename "$image" .bin)" LOOPBACK=1 30.72e6 0 1048576 1e6 loop --interp 1 --dac round
}
export -f bus_check exact
export OUT SERIAL RT IMG
python3 scripts/bus_window.py "${FASM#$PWD/}" --around "$BUS_MARGIN_STEPS" --image "${IMG#$PWD/}" \
  --run "bash -c 'bus_check {bin}'" > "$OUT/06-bus-margin.txt" 2>&1 \
  || { tail -4 "$OUT/06-bus-margin.txt"; fail "bus margin" "see $OUT/06-bus-margin.txt and build/tmp/"; }
sed 's/^/  /' "$OUT/06-bus-margin.txt"

echo "== throughput, each run between two runs of the vendor image =="
[[ -x $BENCH ]] || fail throughput "no $BENCH (run scripts/toolchain.sh uhd)"
quiet() { awk -v max="${QUIET_LOAD:-4}" '{exit !($1 < max)}' /proc/loadavg; }
DEADLINE=$((SECONDS + ${WAIT_QUIET:-0}))
until quiet || (( SECONDS >= DEADLINE )); do sleep 20; done
echo "  host load average $(cut -d' ' -f1 /proc/loadavg)"
run() {   # run <image> <log> <rx samples due> <tx samples due> <benchmark args...>: prints "ok" or what went wrong
  local image=$1 log=$2 rx_due=$3 tx_due=$4; shift 4
  LD_LIBRARY_PATH=$PWD/.tools/uhd315/lib UHD_IMAGES_DIR=/usr/share/uhd/images \
    $RT timeout 120 "$BENCH" --args "type=b200,serial=${SERIAL},fpga=${image}" --duration 10 "$@" > "$log" 2>&1 \
    || { echo "did not complete"; return; }
  awk -F: -v rx_due="$rx_due" -v tx_due="$tx_due" '
    /Num received samples/    {rx = $2}
    /Num transmitted samples/ {tx = $2}
    /Num (dropped samples|overruns detected|sequence errors \(Tx\)|sequence errors \(Rx\)|underruns detected|late commands|timeouts \(Tx\)|timeouts \(Rx\))/ {loss += $2; counters++}
    END { if (counters != 8)                              print "no result"
          else if (loss)                                  print "lost " loss
          else if (rx < 0.99 * rx_due || tx < 0.99 * tx_due) print "short: " rx + 0 " received, " tx + 0 " sent"
          else                                            print "ok" }' "$log"
}
bench() {   # bench <name> <rx samples due> <tx samples due> <benchmark args...>
  local name=$1 rx_due=$2 tx_due=$3; shift 3
  local counted=0 try=0 before ours after
  before=$(run "$VENDOR" "$OUT/07-$name-vendor-0.txt" "$rx_due" "$tx_due" "$@")
  while (( counted < 2 && try < 5 )); do
    try=$((try + 1))
    ours=$(run "$IMG" "$OUT/07-$name-ours-$try.txt" "$rx_due" "$tx_due" "$@")
    after=$(run "$VENDOR" "$OUT/07-$name-vendor-$try.txt" "$rx_due" "$tx_due" "$@")
    echo "  $name run $try: vendor before: $before | this image: $ours | vendor after: $after"
    if [[ $before == ok && $after == ok ]]; then
      [[ $ours == ok ]] || fail throughput "$name: this image: $ours, between two clean runs of the vendor image"
      counted=$((counted + 1))
    fi
    before=$after
  done
  (( counted >= 2 )) || inconclusive throughput "$name: the vendor image itself kept losing samples; the host is busy"
}
bench rx2    614400000 0         --rx_rate 30.72e6 --channels 0,1
bench tx2    0         614400000 --tx_rate 30.72e6 --channels 0,1
bench rx1    614400000 0         --rx_rate 61.44e6 --channels 0
bench 2r2t12 614400000 614400000 --rx_rate 30.72e6 --tx_rate 30.72e6 --channels 0,1 --rx_otw sc12 --tx_otw sc12

echo "GATE PASS: $IMG ($SHA)  evidence in $OUT"
