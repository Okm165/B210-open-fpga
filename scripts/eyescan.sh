#!/usr/bin/env bash
# eyescan.sh - measure the FPGA <-> AD9361 sample-interface eye of an image.
#
#   scripts/eyescan.sh <image.bin> [rate_hz]
#
# UHD programs fixed AD9361 interface delays on a B200/B210 (reg 0x006 = 0x0F,
# 0x007 = 0x0F) and its codec loopback self test is a single pass/fail at that
# point.  This runs the same loopback over every relative clock/data delay on
# both sides (31 x 31) and reports how far the operating point is from the
# data transitions, i.e. the timing margin of the capture and launch paths in
# the image under test.  The vendor image is the reference:
#
#   scripts/eyescan.sh /usr/share/uhd/images/usrp_b210_fpga.bin
#
# The measuring UHD is a patched 3.15 in .tools/uhd315, built by
# `scripts/toolchain.sh uhd` (the scan lives in ad936x_manager behind the
# UHD_AD936X_EYESCAN environment variable).  rate_hz, when given, retunes the
# codec clock before the scan (default: the 50 MHz the driver initialises to).
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=$(realpath "${1:?usage: eyescan.sh <image.bin> [rate_hz]}")
RATE=${2:-}
SERIAL=${SERIAL:-31B92DD}
UHD=${UHD_EYESCAN:-$PWD/.tools/uhd315}
PROBE=$UHD/bin/uhd_usrp_probe
[[ -x $PROBE ]] || { echo "no $PROBE (run scripts/toolchain.sh uhd)" >&2; exit 2; }
grep -qa UHD_AD936X_EYESCAN "$UHD/lib/libuhd.so" \
  || { echo "$UHD/lib/libuhd.so lacks the eyescan patch" >&2; exit 2; }

OUT=build/eye/$(basename "$IMG" .bin)${RATE:+-$RATE}-$(sha256sum "$IMG" | cut -c1-8).txt
mkdir -p build/eye
# The probe exits non-zero when the stock self test that follows the scan
# fails; the scan lines are the result here, so judge by them.
env LD_LIBRARY_PATH="$UHD/lib" UHD_IMAGES_DIR="${UHD_IMAGES_DIR:-/usr/share/uhd/images}" \
  UHD_AD936X_EYESCAN=2d ${RATE:+UHD_AD936X_EYESCAN_RATE=$RATE} \
  timeout 600 "$PROBE" --args="type=b200,serial=$SERIAL,fpga=$IMG" > "$OUT" 2>&1 || true
[[ $(grep -c '^EYE' "$OUT") -ge 961 ]] \
  || { echo "FAIL: no complete scan, see $OUT" >&2; tail -5 "$OUT" >&2; exit 1; }
echo "image: $IMG"
grep -E '^EYERATE|CODEC loopback' "$OUT" || true
python3 scripts/eyeplot.py "$OUT"
