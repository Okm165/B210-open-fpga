#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# fpga/tests/run.sh [FILTER] - run the FPGA benches; each case states the
# result it must give. An expected FAIL is a negative control: an injected
# fault, or an FX3 latency one cycle beyond the design's margin, that the
# bench has to catch. An unexpected PASS is as wrong as an unexpected FAIL.
# Cases run in parallel, each for at most LIMIT seconds (default 1500; a case
# that runs out reports ERROR); exit status 1 if any result differs.
set -eu
cd "$(dirname "$0")/../.."
# each run its own directory, so runs in parallel never mix
mkdir -p build/sim
SIM=$(mktemp -d build/sim/run.XXXXXX)

# bench  expect  parameters
CASES='
fx3_master PASS MODE=0 N=25 SEED=1
fx3_master PASS MODE=0 N=25 SEED=7
fx3_master PASS MODE=0 N=25 SEED=99
fx3_master PASS MODE=0 N=25 SWITCH=1
fx3_master PASS MODE=3 N=10 SWITCH=1
fx3_master FAIL MODE=0 N=25 SWITCH=0
fx3_master PASS MODE=0 N=25 SWITCH=500
fx3_master PASS MODE=1 N=20
fx3_master PASS MODE=2 N=20
fx3_master PASS MODE=3 N=20
fx3_master FAIL MODE=0 N=6 FAULT=1
fx3_master FAIL MODE=0 N=6 FAULT=2
fx3_master FAIL MODE=0 N=6 FAULT=3
fx3_master PASS MODE=0 N=25 RD_LAT=4
fx3_master FAIL MODE=3 N=10 RD_LAT=5
fx3_master PASS MODE=2 N=10 WR_LAT=5
fx3_master FAIL MODE=2 N=10 WR_LAT=6
fx3_master PASS MODE=0 N=25 ADDR_LAT=5
fx3_master FAIL MODE=0 N=25 ADDR_LAT=6
fx3_master PASS MODE=3 N=10 WM_LAT=2
fx3_master FAIL MODE=3 N=10 WM_LAT=3
packet_fifo PASS SEED=1
packet_fifo PASS SEED=2 WCLK=8138 RCLK=5000
packet_fifo PASS SEED=3 WCLK=5000 RCLK=5000
packet_fifo PASS SEED=4 GAPS=0
packet_fifo PASS SEED=5 GAPS=0 WCLK=8138 RCLK=5000
packet_fifo PASS SEED=6 AW=12 MAX=4096 N=40
packet_fifo PASS SEED=7 AW=8 MAX=256 N=200
packet_fifo FAIL SEED=1 FAULT=1
ctrl PASS SEED=1
ctrl PASS SEED=2
ctrl PASS SEED=3 N=600
ctrl FAIL SEED=1 FAULT=1
ctrl FAIL SEED=1 FAULT=2
rx_framer PASS SEED=1
rx_framer PASS SEED=2
rx_framer PASS SEED=3 STREAMS=80
rx_framer PASS SEED=4 SLOW=1
rx_framer PASS SEED=5 SLOW=1
rx_framer FAIL SEED=1 FAULT=1
rx_framer FAIL SEED=1 FAULT=2
tx_player PASS SEED=1
tx_player PASS SEED=2
tx_player PASS SEED=3 N=1500
tx_player FAIL SEED=1 FAULT=1
tx_player FAIL SEED=1 FAULT=2
sample_core PASS SEED=1 STB=1
sample_core PASS SEED=2 STB=2
sample_core PASS SEED=3 STB=1 BURSTS=300
sample_core PASS SEED=4 STB=2 BURSTS=300
sample_core FAIL SEED=1 FAULT=1
sample_core FAIL SEED=1 FAULT=2
events PASS SEED=1
events PASS SEED=2 INTERVAL=1
events PASS SEED=3 SLOW=1
events PASS SEED=4 SLOW=1 INTERVAL=10000 CYCLES=1000000
events FAIL SEED=1 FAULT=1
events FAIL SEED=1 FAULT=2
regs PASS SEED=1
regs PASS SEED=2 N=60000
regs FAIL SEED=1 FAULT=1
b210 PASS
b210 FAIL FAULT=1
packet_fifo FAIL SEED=1 FAULT=2 WCLK=8138 RCLK=5000
'

sources() {
  case $1 in
    fx3_master) echo fpga/tests/tb_fx3_master.v fpga/tests/fx3_model.v fpga/rtl/fx3_master.v fpga/rtl/fx3_pads.v ;;
    packet_fifo) echo fpga/tests/tb_packet_fifo.v fpga/rtl/packet_fifo.v ;;
    ctrl) echo fpga/tests/tb_ctrl.v fpga/rtl/ctrl.v fpga/rtl/packet_fifo.v ;;
    rx_framer) echo fpga/tests/tb_rx_framer.v fpga/rtl/rx_framer.v fpga/rtl/packet_fifo.v ;;
    tx_player) echo fpga/tests/tb_tx_player.v fpga/rtl/tx_player.v fpga/rtl/packet_fifo.v ;;
    sample_core) echo fpga/tests/tb_sample_core.v fpga/rtl/sample_core.v fpga/rtl/cdc_fifo.v fpga/rtl/gray_sync.v ;;
    events) echo fpga/tests/tb_events.v fpga/rtl/events.v fpga/rtl/packet_mux.v fpga/rtl/packet_fifo.v ;;
    regs) echo fpga/tests/tb_regs.v fpga/rtl/regs.v ;;
    b210) echo fpga/tests/tb_b210.v fpga/tests/fx3_model.v fpga/rtl/*.v ;;
  esac
  echo fpga/tests/prims.v
}

one() {   # bench expect params...
  bench=$1 expect=$2; shift 2
  tag=$(echo "$bench $*" | tr ' =' '_-')
  params=""; for p in "$@"; do params="$params -Ptb_$bench.$p"; done
  # shellcheck disable=SC2046,SC2086
  iverilog -g2005 -Wall -Wno-timescale -o "$SIM/$tag" -s "tb_$bench" $params $(sources "$bench") \
    > "$SIM/$tag.log" 2>&1 &&
  timeout "${LIMIT:-1500}" vvp -n "$SIM/$tag" >> "$SIM/$tag.log" 2>&1 || true
  got=$(sed -n "s/^RESULT: \([A-Z]*\).*/\1/p" "$SIM/$tag.log")
  [ -n "$got" ] || got=ERROR
  verdict=ok; [ "$got" = "$expect" ] || verdict=WRONG
  printf '%-5s %-6s %-4s %s %s  (%s)\n' "$verdict" "$bench" "$expect" "$*" \
    "$(grep -E '^bus:' "$SIM/$tag.log" | cut -d= -f2 | tr -d ' ')" "$SIM/$tag.log"
}

echo "$CASES" | grep -v '^$' | grep -- "${1:-}" | while read -r line; do
  # shellcheck disable=SC2086
  one $line &
done | sort > $SIM/results.txt
wait
cat $SIM/results.txt
n=$(grep -c . $SIM/results.txt)
bad=$(grep -c '^WRONG' $SIM/results.txt || true)
echo "$n cases, $bad wrong"
[ "$bad" -eq 0 ]
