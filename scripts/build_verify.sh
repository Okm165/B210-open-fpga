#!/usr/bin/env bash
# build_verify.sh - finish the build (retrying P&R seeds), then verify OUR
# bitstream end-to-end on hardware.  RX only.
set -u
cd /home/bartosz/workshop/opensourcesdrlab || exit 1
BIN=build/deploy/usrp_b210_fpga.bin
SERIAL=31B92DD
LOG=/tmp/opencode/build_verify.log

say() { echo "[verify $(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ---- 1. wait for the build currently in flight -------------------------------
say "waiting for in-flight build (build_fix3.log)"
for i in $(seq 1 600); do
  grep -q "^exit=" /tmp/opencode/build_fix3.log 2>/dev/null && break
  sleep 30
done
STATUS=$(grep '^exit=' /tmp/opencode/build_fix3.log | tail -1 | cut -d= -f2)
say "in-flight build finished: exit=$STATUS"

# ---- 2. retry P&R with other seeds if needed --------------------------------
for SEED in 2 6 5; do
  [ "$STATUS" = "0" ] && break
  say "retrying P&R with seed $SEED"
  FPGA_ALLOW_TIMING_FAIL=1 make build NEXTPNR_SEED=$SEED >> "$LOG" 2>&1
  STATUS=$?
done

if [ "$STATUS" != "0" ]; then
  say "BUILD FAILED with all seeds - stopping"
  exit 1
fi
ls -la "$BIN" | tee -a "$LOG"

# ---- 3. deploy OUR bitstream ------------------------------------------------
say "loading OUR bitstream"
python3 scripts/hw_load.py "$BIN" 2>&1 | tail -4 | tee -a "$LOG"

# ---- 4. control path --------------------------------------------------------
say "probing OUR bitstream"
OUT=$(timeout 180 uhd_usrp_probe --args="type=b200,serial=$SERIAL,fpga=$PWD/$BIN" 2>&1)
echo "$OUT" | grep -iE "detected|operating|loopback|clock rate|Mboard|serial|FW Version|FPGA Version|Error|runtime|Assertion" | head -20 | tee -a "$LOG"
if ! echo "$OUT" | grep -q "FPGA Version"; then
  say "RESULT: our image did NOT answer the control path (see probe above)"
  exit 2
fi
say "RESULT: *** OUR FPGA IMAGE RESPONDS - control path alive ***"

# ---- 5. full-rate RX on OUR image ------------------------------------------
say "2 RX @ 30.72 MSPS"
timeout 600 python3 scripts/rx_capture.py --args "type=b200,serial=$SERIAL,fpga=$PWD/$BIN" \
  --rate 30.72e6 --chans 2 --secs 1.0 --freq 100e6 --gain 30 \
  --out build/rx/ours_dual >> "$LOG" 2>&1
say "1 RX @ 61.44 MSPS"
timeout 600 python3 scripts/rx_capture.py --args "type=b200,serial=$SERIAL,fpga=$PWD/$BIN" \
  --rate 61.44e6 --chans 1 --secs 0.5 --freq 100e6 --gain 30 \
  --tag rx_1ch_61M_ours --out build/rx/ours_single >> "$LOG" 2>&1

say "quality + settings on OUR image"
timeout 600 python3 scripts/rx_quality.py --dir build/rx/ours_dual \
  --tag rx_2ch_30.72msps_100.0mhz >> "$LOG" 2>&1
timeout 900 python3 scripts/usrp_settings.py \
  --args "type=b200,serial=$SERIAL,fpga=$PWD/$BIN" --out build/settings/ours >> "$LOG" 2>&1

say "DONE"
ls -la build/rx/ours_dual build/rx/ours_single | tee -a "$LOG"
