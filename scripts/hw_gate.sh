#!/usr/bin/env bash
# hw_gate.sh - hardware acceptance of an image built by this repository.
#
#   scripts/hw_gate.sh build/fpga/usrp_b200.bin
#
# Every step must pass, in this order.  Every requirement is absolute: no
# other image is loaded or compared with.  The host side is the UHD built from
# source by `scripts/toolchain.sh uhd` (.tools/uhd315, with the stock FX3
# firmware in .tools/uhd315/images).
#
#   identity    the image carries the build record scripts/build.sh wrote for
#               exactly these bytes: the full design, the board constraints,
#               all three clocks and every clock-domain crossing meeting
#               their constraints.
#   raw         FX3 reboot, FPGA load, the control path through every layer
#               (FPGA readback registers, a register written and read back,
#               the AD9361's product ID over the FPGA's SPI master), 64
#               control transactions and an 8 MB drain, with no UHD involved
#               (scripts/fx3_raw_load.py)
#   init        UHD loads THIS image and initialises both radio cores
#               (register loopback on each; UHD's codec loopback test raises
#               an error when it fails).
#   eye         at 61.44 MHz, the AD9361 interface is clean at UHD's
#               operating point with at least EYE_MIN_STEPS (8) delay steps
#               to the nearest data transition, on the receive and on the
#               transmit side (scripts/eyescan.sh).  UHD's point is the
#               AD9361's largest delay setting,
#               so there is a transition on one side of it only.
#   samples     known signals through both directions
#               (scripts/sample_check.py), each with the level, SFDR, SINAD,
#               DC and channel phase relation a healthy image gives: the
#               AD9361 test tone on both channels, on one channel at
#               61.44 MS/s and through the x4 decimation; host tones returned
#               by the AD9361 digital loopback through the x4 filters, at
#               2R2T x 30.72 MS/s in the 12-bit wire format and on one channel
#               at 61.44 MS/s in the 8-bit one.  Then the AD9361 pseudo-random
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
#               what else the host is doing, so a run counts only when the
#               host was quiet through it: the kernel's CPU pressure (share
#               of time some task waited for a CPU, /proc/pressure/cpu) below
#               QUIET_PSI (1) percent, both over the whole run and over its
#               last 10 s.  Every counted run must be clean, and two counted
#               runs per mode pass it, out of THROUGHPUT_TRIES (5).  Measured
#               here with the vendor image: nothing lost at 0.24 %, overflows
#               at 2 to 6 %.  If the host is never quiet the gate stops as
#               inconclusive (exit 3), which is not a pass.  WAIT_QUIET=<s>
#               waits, in all, up to that long for a quiet host before runs.
#
#               A run is clean when UHD counted no dropped sample, overflow,
#               underflow or sequence error.  The number of samples is no
#               loss measure: benchmark_rate streams for about 10 s by the
#               host's clock and clean runs differ by tens of thousands of
#               samples either way, so it is only required to be within 1 %
#               of the nominal count, which catches a stream that died.  A
#               sample lost inside a stream without a counter noticing is
#               what the bit-exact steps above exist for.
#
#               Every run uses UHD's deep USB buffer pool (num_recv_frames /
#               num_send_frames, see BUF16/BUF12): UHD's default 16 x 8176 B
#               keeps only 0.5 ms of receive data in flight, and any longer
#               host stall loses samples.  The frame sizes keep a packet
#               inside the range the receive framer delivers cleanly.
#
# The raw step reboots the FX3, which forgets the loaded image, so the UHD
# run that follows has to load the file named here; later steps name their
# image and UHD reloads whenever it differs from the one in the FPGA.
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=$(realpath "${1:?usage: hw_gate.sh <image.bin>}")
# One B2xx on the host needs no serial; SERIAL=<serial> picks among several.
DEV="type=b200${SERIAL:+,serial=$SERIAL}"
EYE_MIN_STEPS=${EYE_MIN_STEPS:-8}
# QUICK=1 (just check): the same checks, fewer of them, for day-to-day work;
# it ends in CHECK PASS, never GATE PASS.  The eye scan, the spectral
# checks, decimations 2-16, loopback x4 and the bus margin are left out.
QUICK=${QUICK:-0}
full() { (( ! QUICK )); }
PRBS_RUNS=${PRBS_RUNS:-$(full && echo 8 || echo 2)}
BUS_MARGIN_STEPS=${BUS_MARGIN_STEPS:-20}
THROUGHPUT_TRIES=${THROUGHPUT_TRIES:-$(full && echo 5 || echo 2)}
COUNTED=$(full && echo 2 || echo 1)   # clean runs on a quiet host needed per mode
UHD=$PWD/.tools/uhd315
[[ -x $UHD/bin/benchmark_rate && -s $UHD/images/usrp_b200_fw.hex ]] \
  || { echo "no host side in $UHD: run scripts/toolchain.sh uhd" >&2; exit 2; }
export UHD_IMAGES_DIR=$UHD/images LD_LIBRARY_PATH=$UHD/lib
ARGS="$DEV,fpga=${IMG}"
OUT="build/hw-$(full && echo gate || echo check)-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
fail() { echo "GATE FAIL ($1): $2" >&2; exit 1; }
inconclusive() { echo "GATE INCONCLUSIVE ($1): $2" >&2; exit 3; }
# Real-time priority for the streaming tools when the account may use it.
RT=""; chrt -f 50 true 2>/dev/null && RT="chrt -f 50"

echo "== identity =="
SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
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
# The four crossings of this design (receive hand-over in both edge senses,
# bus<->radio both ways).  Fewer means a bound no longer applies to anything.
N_CROSS=$(grep -c "^timing   crossing .*PASS" "$RECORD" || true)
[[ "${N_CROSS:-0}" -ge 4 ]] || fail identity "build record checked $N_CROSS clock-domain crossings, expected four"
! grep -q "^timing .*FAIL" "$RECORD" || fail identity "the build record shows a missed timing constraint"
! grep -q "uncommitted" "$RECORD" || fail identity "built from uncommitted sources: commit them and rebuild"

echo "== raw control and data path, no UHD =="
python3 scripts/fx3_raw_load.py "$IMG" --regs --peek 64 > "$OUT/01-raw.txt" 2>&1 \
  || { cat "$OUT/01-raw.txt"; fail raw "see $OUT/01-raw.txt"; }
cat "$OUT/01-raw.txt"

echo "== UHD init =="
timeout 240 "$UHD/bin/uhd_usrp_probe" --args="$ARGS" > "$OUT/02-init.txt" 2>&1 \
  || { tail -5 "$OUT/02-init.txt"; fail init "uhd_usrp_probe failed"; }
grep -q "Loading FPGA image: $IMG" "$OUT/02-init.txt" || fail init "UHD did not load $IMG"
[[ $(grep -c 'Register loopback test passed' "$OUT/02-init.txt") -eq 2 ]] \
  || fail init "expected two radio cores"
grep -E "Loading FPGA|loopback test passed|FPGA Version" "$OUT/02-init.txt" || true

if full; then
echo "== AD9361 interface eye at 61.44 MHz =="
scripts/eyescan.sh "$IMG" 61.44e6 > "$OUT/03-eye.txt" 2>&1 || true
tail -5 "$OUT/03-eye.txt"
grep -q '^RESULT: PASS' "$OUT/03-eye.txt" || fail eye "operating point is not clean, see $OUT/03-eye.txt"
# UHD's operating point is the AD9361's largest delay setting, so the scan
# has points on one side of it only: the margin is the distance to the data
# transition on that side.
for side in rx tx; do
  BELOW=$(sed -n "s/^  $side margin: \([0-9]*\) steps below.*/\1/p" "$OUT/03-eye.txt")
  [[ "${BELOW:-0}" -ge "$EYE_MIN_STEPS" ]] || fail eye "$side margin ${BELOW:-0} steps, need $EYE_MIN_STEPS"
done

fi
echo "== known signals through the sample paths =="
samples() {   # samples <name> <sample_check.py arguments...>
  local log="$OUT/04-samples-$1.txt" rc=0; shift
  python3 scripts/sample_check.py "$IMG" "$@" > "$log" 2>&1 || rc=$?
  sed 's/^/  /' "$log"
  [[ $rc -eq 0 ]] && grep -q '^RESULT: PASS' "$log" || fail samples "$* : see $log"
}
if full; then
echo " receive: AD9361 test tone"
# --sfdr/--sinad: what a healthy image gives in each mode, the worse channel of
# every recorded gate run (they repeat to 0.5 dB); 2 dB less fails.  The x4
# transmit numbers are this design's (dac_slice rounds where the vendor image
# truncates: SINAD 62.7 dB and DC -67 dBFS there); the 12- and 8-bit wire
# formats limit SINAD to their quantisation.
samples rx-tone-2ch   --tone --rate 30.72e6                                    --sfdr 73.4 --sinad 62.5
samples rx-tone-1ch   --tone --rate 61.44e6 --chans 0                          --sfdr 73.4 --sinad 62.5
samples rx-tone-dec4  --tone --rate 7.68e6 --mcr 30.72e6 --samples 1048576     --sfdr 81.2 --sinad 64.7
echo " transmit: host tones through the AD9361 digital loopback"
samples tx-x4         --loopback 300e3 --rate 7.68e6 --mcr 30.72e6 --samples 1048576 --sfdr 82.3 --sinad 73.6
samples tx-2r2t-sc12  --loopback 1e6 --rate 30.72e6 --otw sc12                 --sfdr 69.8 --sinad 58.6
samples tx-1ch-61     --loopback 2e6 --rate 61.44e6 --chans 0 --otw sc8        --sfdr 58.1 --sinad 43.7
fi
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
    env "UHD_AD936X_$source" \
      $RT timeout 120 "$UHD/bin/rx_dump" "$DEV,fpga=${EXACT_IMG:-$IMG},master_clock_rate=30.72e6" \
      "$rate" "$chans" "$count" "$prefix" 100e6 0 sc16 $tone > "$prefix.log" 2>&1 && break
  done
  python3 scripts/dsp_exact.py "$@" "$prefix" --chans "$chans" > "$log" 2>&1 || true
  { grep -E "^(SUMMARY|RESULT)" "$log" || tail -2 "$log"; } | sed "s/^/  $name: /"
  grep -q '^RESULT: PASS' "$log" || { echo "GATE FAIL (dsp): $name: see $log" >&2; return 1; }
}
exact rx-d1  BIST=0x09  30.72e6 0,1 1048576 "" rx --decim 1
if full; then
exact rx-d2  BIST=0x09  15.36e6 0,1 524288  "" rx --decim 2
exact rx-d3  BIST=0x09  10.24e6 0,1 524288  "" rx --decim 3
exact rx-d4  BIST=0x09  7.68e6  0,1 524288  "" rx --decim 4
exact rx-d8  BIST=0x09  3.84e6  0,1 262144  "" rx --decim 8
exact rx-d16 BIST=0x09  1.92e6  0,1 262144  "" rx --decim 16
fi
exact loop-x1 LOOPBACK=1 30.72e6 0  1048576 1e6   loop --interp 1 --dac round
if full; then
exact loop-x4 LOOPBACK=1 7.68e6  0,1 524288 300e3 loop --interp 4 --dac round
fi

if full; then
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
export OUT DEV RT IMG UHD
python3 scripts/bus_window.py "${FASM#$PWD/}" --around "$BUS_MARGIN_STEPS" --image "${IMG#$PWD/}" \
  --run "bash -c 'bus_check {bin}'" > "$OUT/06-bus-margin.txt" 2>&1 \
  || { tail -4 "$OUT/06-bus-margin.txt"; fail "bus margin" "see $OUT/06-bus-margin.txt and build/tmp/"; }
sed 's/^/  /' "$OUT/06-bus-margin.txt"

fi
echo "== throughput on a quiet host =="
# CPU pressure in percent: over a run from the kernel's cumulative stall time
# ("some ... total=", microseconds), over the last 10 s from its "avg10".
stall_us() { sed -n 's/^some .*total=\([0-9]*\)$/\1/p' /proc/pressure/cpu; }
avg10() { sed -n 's/^some avg10=\([0-9.]*\) .*/\1/p' /proc/pressure/cpu; }
below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
QUIET_PSI=${QUIET_PSI:-1}
DEADLINE=$((SECONDS + ${WAIT_QUIET:-0}))
# 512 x 16360 B = 8.4 MB receive and 256 x 16360 B = 4.2 MB transmit of
# queued USB buffers (UHD's limit is 16360 B per frame; usbfs allows 16 MB).
# 16360 / 4 = 4090 samples per packet for 16-bit data and 12264 / 3 = 4088 for
# 12-bit, both inside what the stock receive framer delivers without an
# overflow (4092 samples per packet is the first size that does not).
BUF16="num_recv_frames=512,recv_frame_size=16360,num_send_frames=256,send_frame_size=16360"
BUF12="num_recv_frames=512,recv_frame_size=12264,num_send_frames=256,send_frame_size=12264"
run() {   # run <image> <log> <rx samples due> <tx samples due> <benchmark args...>: prints "ok" or what went wrong
  local image=$1 log=$2 rx_due=$3 tx_due=$4; shift 4
  $RT timeout 120 "$UHD/bin/benchmark_rate" --args "$DEV,fpga=${image},${BUF}" --duration 10 "$@" > "$log" 2>&1 \
    || { echo "did not complete"; return; }
  # Counters that mean data was lost, and counters that only mean the host
  # waited for a metadata event: benchmark_rate reports two transmit metadata
  # timeouts at the end of a full-duplex run on the vendor image too, so they
  # are reported beside the verdict, never folded into it.
  awk -F: -v rx_due="$rx_due" -v tx_due="$tx_due" '
    /Num received samples/    {rx = $2}
    /Num transmitted samples/ {tx = $2}
    /Num (dropped samples|overruns detected|sequence errors \(Tx\)|sequence errors \(Rx\)|underruns detected)/ {loss += $2; counters++}
    /Num (late commands|timeouts \(Tx\)|timeouts \(Rx\))/ {meta += $2}
    END { if (counters != 5)          print "no result"
          else if (loss)              print "lost " loss
          else if (rx + 0 < 0.99 * rx_due || tx + 0 < 0.99 * tx_due)
            printf "stream died: %d received of %d, %d sent of %d", rx + 0, rx_due, tx + 0, tx_due
          else if (meta)              printf "ok (metadata events: %d)", meta
          else                        print "ok" }' "$log"
}
ok() { [[ $1 == ok || $1 == "ok ("* ]]; }
bench() {   # bench <name> <rx samples due> <tx samples due> <benchmark args...>
  local name=$1 rx_due=$2 tx_due=$3; shift 3
  local counted=0 try=0 verdict s0 t0 whole last
  while (( counted < COUNTED && try < THROUGHPUT_TRIES )); do
    try=$((try + 1))
    until below "$(avg10)" "$QUIET_PSI" || (( SECONDS >= DEADLINE )); do sleep 10; done
    s0=$(stall_us); t0=$(date +%s%6N)
    verdict=$(run "$IMG" "$OUT/07-$name-$try.txt" "$rx_due" "$tx_due" "$@")
    whole=$(awk -v s="$(( $(stall_us) - s0 ))" -v t="$(( $(date +%s%6N) - t0 ))" 'BEGIN { printf "%.2f", 100 * s / t }')
    last=$(avg10)
    echo "  $name run $try: CPU pressure $whole % over the run, $last % at its end: $verdict"
    if below "$whole" "$QUIET_PSI" && below "$last" "$QUIET_PSI"; then
      ok "$verdict" || fail throughput "$name: $verdict on a quiet host"
      counted=$((counted + 1))
    fi
  done
  (( counted >= COUNTED )) || inconclusive throughput "$name: $counted of $try runs on a quiet host; QUIET_PSI=$QUIET_PSI"
}
BUF=$BUF16 bench rx2    614400000 0         --rx_rate 30.72e6 --channels 0,1
BUF=$BUF16 bench tx2    0         614400000 --tx_rate 30.72e6 --channels 0,1
BUF=$BUF16 bench rx1    614400000 0         --rx_rate 61.44e6 --channels 0
BUF=$BUF12 bench 2r2t12 614400000 614400000 --rx_rate 30.72e6 --tx_rate 30.72e6 --channels 0,1 --rx_otw sc12 --tx_otw sc12

full || { echo "CHECK PASS: $IMG ($SHA), not an acceptance (just gate)  evidence in $OUT"; exit 0; }
echo "GATE PASS: $IMG ($SHA)  evidence in $OUT"
