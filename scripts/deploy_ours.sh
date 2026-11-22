#!/usr/bin/env bash
# deploy_ours.sh - end-to-end: recover the FX3 if needed, load OUR bitstream,
# probe it, and if the control path answers, capture dual/single RX.
#
# Usage: sudo -n ./scripts/deploy_ours.sh [bitstream]
set -uo pipefail
BIN="${1:-/tmp/opencode/ours_repack.bin}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

present() { lsusb | grep -q '2500:0020'; }

echo "== 1. recover FX3 =="
for attempt in 1 2 3 4 5 6; do
  if present; then
    if python3 - <<'PY'
import sys, usb.core
d = usb.core.find(idVendor=0x2500, idProduct=0x0020)
try:
    d.set_configuration()
    d.ctrl_transfer(0xC0, 0x83, 0, 0, 1, 2000)
except Exception:
    sys.exit(1)
PY
    then echo "   device responsive"; break; fi
  fi
  echo "   attempt $attempt: cycling xhci controller"
  for p in /sys/bus/pci/drivers/xhci_hcd/0000:09:00.3; do
    echo "$(basename "$p")" > /sys/bus/pci/drivers/xhci_hcd/unbind 2>/dev/null
    sleep 5
    echo "$(basename "$p")" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null
  done
  sleep 10
done
present || { echo "FX3 off bus - needs a physical power cycle"; exit 2; }

echo "== 2. load $BIN =="
python3 scripts/hw_load_direct.py "$BIN" || exit 3

echo "== 3. probe =="
OUT="$(timeout 200 uhd_usrp_probe --args="type=b200,serial=31B92DD,fpga=$BIN" 2>&1)"
echo "$OUT" | grep -iE "FPGA Version|loopback|wait_for_ack|Error" | head -6
if echo "$OUT" | grep -qi "FPGA Version"; then
  echo "== CONTROL PATH OK - capturing =="
  python3 scripts/rx_capture.py --args "type=b200,serial=31B92DD,fpga=$BIN" \
    --rate 30.72e6 --chans 2 --secs 0.25 --freq 100e6 --gain 30 \
    --out build/rx/ours_dual 2>&1 | grep -E "LO |OVERALL"
  python3 scripts/rx_capture.py --args "type=b200,serial=31B92DD,fpga=$BIN" \
    --rate 61.44e6 --chans 1 --secs 0.25 --freq 100e6 --gain 30 \
    --out build/rx/ours_single 2>&1 | grep -E "LO |OVERALL"
  echo "== DONE: our bitstream is live =="
else
  echo "== still silent with the repacked image =="
  exit 4
fi
