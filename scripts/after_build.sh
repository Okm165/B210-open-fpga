#!/usr/bin/env bash
# after_build.sh - fires the end-to-end DOD chain as soon as OUR bitstream exists.
set -u
cd /home/bartosz/workshop/opensourcesdrlab || exit 1
BIN=build/deploy/usrp_b210_fpga.bin
HASH_FILE=/tmp/opencode/bin_hash_at_build_start

echo "[chain] waiting for build to finish ($(date))"
for i in $(seq 1 480); do   # up to 8 h
  if grep -q "^exit=" /tmp/opencode/build_fix3.log 2>/dev/null; then
    echo "[chain] build done: $(grep '^exit=' /tmp/opencode/build_fix3.log)"
    break
  fi
  sleep 60
done
if ! grep -q "^exit=0" /tmp/opencode/build_fix3.log 2>/dev/null; then
  echo "[chain] BUILD FAILED - not deploying"; exit 1
fi
ls -la "$BIN"

echo "[chain] === 1. load OUR image ==="
python3 scripts/hw_load.py "$BIN" 2>&1 | tail -4

echo "[chain] === 2. probe OUR image (control path alive?) ==="
OUT=$(timeout 180 uhd_usrp_probe --args="type=b200,serial=31B92DD,fpga=$PWD/$BIN" 2>&1)
echo "$OUT" | grep -iE "detected|operating|loopback|clock rate|Mboard|serial|FW Version|FPGA Version|Error|runtime" | head -20
if echo "$OUT" | grep -q "FPGA Version"; then
  echo "[chain] *** OUR FPGA IMAGE RESPONDS TO CONTROL PATH ***"
else
  echo "[chain] our image still silent on the control path"
  exit 2
fi

echo "[chain] === 3. 2 RX live (30.72 MSPS each) ==="
timeout 600 python3 scripts/rx_capture.py --args "type=b200,serial=31B92DD,fpga=$PWD/$BIN" \
  --rate 30.72e6 --chans 2 --secs 0.5 --freq 100e6 --gain 30 \
  --out build/rx/ours_dual 2>&1 | grep -vE "^\[INFO\]|^O+$" | tail -8

echo "[chain] === 4. 1 RX double speed (61.44 MSPS) ==="
timeout 600 python3 scripts/rx_capture.py --args "type=b200,serial=31B92DD,fpga=$PWD/$BIN" \
  --rate 61.44e6 --chans 1 --secs 0.3 --freq 100e6 --gain 30 --tag rx_single_61M_ours \
  --out build/rx/ours_single 2>&1 | grep -vE "^\[INFO\]|^O+$" | tail -6

echo "[chain] === done ($(date)) ==="
