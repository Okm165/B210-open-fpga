#!/usr/bin/env bash
# hw_gate.sh - the only accepted hardware DOD gate.
#
# It refuses to test anything except the image given on the command line, and
# it proves that image itself answers, so a UHD fall-back to the vendor image
# can never produce a pass.
#
# Usage: ./scripts/hw_gate.sh build/fpga/bitstream/usrp_b210_fpga.bin
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=$(realpath "${1:?usage: hw_gate.sh <our-image.bin>}")
SERIAL=${SERIAL:-31B92DD}
VENDOR=/usr/share/uhd/images/usrp_b210_fpga.bin
OUT="build/hw-gate-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

echo "== identity =="
sha256sum "$IMG" "$VENDOR" | tee "$OUT/00-hashes.txt"
if [ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$(sha256sum "$VENDOR" | cut -d' ' -f1)" ]; then
  echo "FAIL: image is the vendor image; nothing of ours would be tested" >&2
  exit 1
fi

echo "== raw GPIF control path (image under test) =="
python3 scripts/gpif_rig.py "$IMG" --reads 3 --expect ace0ba5e 2>&1 | tee "$OUT/01-rig.txt"

echo "== UHD probe with fpga=<our image> =="
timeout 240 uhd_usrp_probe --args="type=b200,serial=${SERIAL},fpga=${IMG}" 2>&1 | tee "$OUT/02-probe.txt"
test "$(grep -ci 'loopback test passed' "$OUT/02-probe.txt")" -eq 2 || {
  echo "FAIL: expected 2 register loopback passes" >&2; exit 1; }

echo "== dual RX streaming =="
python3 scripts/rx_capture.py --args "type=b200,serial=${SERIAL},fpga=${IMG}" \
  --rate 30.72e6 --chans 2 --secs 1.0 --freq 100.6e6 --gain 30 2>&1 | tee "$OUT/03-dual.txt"
grep -q 'OVERALL: PASS' "$OUT/03-dual.txt" || { echo "FAIL: dual capture" >&2; exit 1; }

echo "DOD GATE PASS: $IMG ($(sha256sum "$IMG" | cut -d' ' -f1))"
