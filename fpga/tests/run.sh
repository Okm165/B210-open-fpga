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
# RTL: the directory the bench takes its RTL from (scripts/mutate.sh points it
# at a mutated copy); the benches and models always come from fpga/tests.
RTL=${RTL:-fpga/rtl}
# each run its own directory, so runs in parallel never mix; removed at the
# end unless KEEP=1 (a case that fails is rerun by hand from its log, which
# says what it did, so the directory is not needed)
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
packet_fifo PASS SEED=2 GAPS=0
packet_fifo PASS SEED=3
packet_fifo PASS SEED=4 GAPS=0
packet_fifo PASS SEED=5 AW=12 MAX=4096 N=40
packet_fifo PASS SEED=6 AW=12 MAX=4096 N=40 GAPS=0
packet_fifo PASS SEED=7 AW=8 MAX=256 N=200
packet_fifo PASS SEED=8 AW=10 MAX=64 N=80
packet_fifo FAIL SEED=1 FAULT=1
packet_fifo FAIL SEED=1 FAULT=2
packet_fifo FAIL SEED=1 FAULT=3
packet_fifo FAIL SEED=1 FAULT=4
command PASS SEED=1
command PASS SEED=2
command PASS SEED=3 N=600
command PASS SEED=4 H0=3 H1=3
command PASS SEED=5 N=120 H0=50 H1=5000
command FAIL SEED=1 FAULT=1
command FAIL SEED=1 FAULT=2
command FAIL SEED=1 FAULT=3
command FAIL SEED=1 FAULT=4
command FAIL SEED=1 FAULT=5
command FAIL SEED=1 FAULT=6
command FAIL SEED=1 FAULT=7
rx_framer PASS SEED=1
rx_framer PASS SEED=2
rx_framer PASS SEED=3 STREAMS=80
rx_framer PASS SEED=4 SLOW=1
rx_framer PASS SEED=5 SLOW=1
rx_framer PASS SEED=6 STREAMS=0
rx_framer FAIL SEED=1 FAULT=1
rx_framer FAIL SEED=1 FAULT=2
rx_framer FAIL SEED=1 FAULT=3
tx_deframer PASS SEED=1
tx_deframer PASS SEED=2
tx_deframer PASS SEED=3 N=1500
tx_deframer FAIL SEED=1 FAULT=1
tx_deframer FAIL SEED=1 FAULT=2
tx_deframer FAIL SEED=1 FAULT=3
tx_deframer FAIL SEED=1 FAULT=4
sample_domain PASS SEED=1 STB=1
sample_domain PASS SEED=2 STB=2
sample_domain PASS SEED=3 STB=1 BURSTS=300
sample_domain PASS SEED=4 STB=2 BURSTS=300
sample_domain FAIL SEED=1 FAULT=1
sample_domain FAIL SEED=1 FAULT=2
sample_domain FAIL SEED=1 FAULT=3
sample_domain FAIL SEED=1 FAULT=4
sample_domain FAIL SEED=1 FAULT=5
events PASS SEED=1
events PASS SEED=2 INTERVAL=1
events PASS SEED=3 SLOW=1
events PASS SEED=4 SLOW=1 INTERVAL=10000 CYCLES=1000000
events FAIL SEED=1 FAULT=1
events FAIL SEED=1 FAULT=2
regs PASS SEED=1
regs PASS SEED=2 N=60000
regs FAIL SEED=1 FAULT=1
ad9361_io PASS SEED=1
ad9361_io PASS SEED=2
ad9361_io PASS SEED=3 DLY=0.0
ad9361_io PASS SEED=4 DLY=5.0
ad9361_io FAIL SEED=1 DLY=5.2
ad9361_io FAIL SEED=1 FAULT=1
ad9361_io FAIL SEED=1 FAULT=2
ad9361_io FAIL SEED=1 FAULT=3
cdc_fifo PASS SEED=1
cdc_fifo PASS SEED=2 WCLK=5000 RCLK=8138
cdc_fifo FAIL SEED=1 FAULT=1
b210 PASS
b210 FAIL FAULT=1
'

sources() {
  case $1 in
    fx3_master) echo fpga/tests/tb_fx3_master.v fpga/tests/fx3_model.v fpga/rtl/fx3_master.v fpga/rtl/fx3_pads.v ;;
    cdc_fifo) echo fpga/tests/tb_cdc_fifo.v fpga/rtl/cdc_fifo.v ;;
    packet_fifo) echo fpga/tests/tb_packet_fifo.v fpga/rtl/packet_fifo.v ;;
    command) echo fpga/tests/tb_command.v fpga/tests/spi_model.v fpga/rtl/command.v fpga/rtl/spi_master.v fpga/rtl/packet_fifo.v ;;
    rx_framer) echo -I fpga/rtl fpga/tests/tb_rx_framer.v fpga/rtl/rx_framer.v fpga/rtl/packet_fifo.v ;;
    tx_deframer) echo fpga/tests/tb_tx_deframer.v fpga/rtl/tx_deframer.v fpga/rtl/packet_fifo.v ;;
    sample_domain) echo fpga/tests/tb_sample_domain.v fpga/rtl/sample_domain.v fpga/rtl/cdc_fifo.v fpga/rtl/gray_sync.v ;;
    events) echo fpga/tests/tb_events.v fpga/rtl/events.v fpga/rtl/packet_mux.v fpga/rtl/packet_fifo.v ;;
    regs) echo fpga/tests/tb_regs.v fpga/rtl/regs.v ;;
    ad9361_io) echo fpga/tests/tb_ad9361_io.v fpga/tests/ad9361_port_model.v fpga/rtl/ad9361_io.v ;;
    b210) echo fpga/tests/tb_b210.v fpga/tests/fx3_model.v fpga/tests/spi_model.v fpga/tests/ad9361_port_model.v fpga/rtl/*.v ;;
  esac
  echo fpga/tests/prims.v
}

one() {   # bench expect params...
  bench=$1 expect=$2; shift 2
  tag=$(echo "$bench $*" | tr ' =' '_-')
  params=""; for p in "$@"; do params="$params -Ptb_$bench.$p"; done
  # shellcheck disable=SC2046,SC2086
  iverilog -g2005 -Wall -Wno-timescale -I "$RTL" -o "$SIM/$tag" -s "tb_$bench" $params $(sources "$bench" | sed "s|fpga/rtl/|$RTL/|g") \
    > "$SIM/$tag.log" 2>&1 &&
  timeout "${LIMIT:-1500}" vvp -n "$SIM/$tag" >> "$SIM/$tag.log" 2>&1 || true
  got=$(sed -n "s/^RESULT: \([A-Z]*\).*/\1/p" "$SIM/$tag.log")
  [ -n "$got" ] || got=ERROR
  verdict=ok; [ "$got" = "$expect" ] || verdict=WRONG
  printf '%-5s %-13s %-4s %s %s  (%s)\n' "$verdict" "$bench" "$expect" "$*" \
    "$(grep -E '^bus:' "$SIM/$tag.log" | cut -d= -f2 | tr -d ' ')" "$SIM/$tag.log"
}

echo "$CASES" | grep -v '^$' | grep -- "${1:-}" | while read -r line; do
  # shellcheck disable=SC2086
  one $line &
done | sort > $SIM/results.txt
wait
cat $SIM/results.txt
n=$(grep -c . "$SIM/results.txt" || true)
bad=$(grep -c '^WRONG' $SIM/results.txt || true)
echo "$n cases, $bad wrong"
[ "$n" -gt 0 ] || echo "no case matches the filter" >&2
[ "${KEEP:-0}" = 1 ] || rm -rf "$SIM"
[ "$bad" -eq 0 ]
