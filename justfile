# B210 open FPGA. `just` lists the commands; scripts/ holds the flow they call.

set shell := ["bash", "-euo", "pipefail", "-c"]
set quiet

bin := "build/fpga/usrp_b200.bin"
uhd := justfile_directory() / ".tools/uhd315"
host := "env LD_LIBRARY_PATH=" + uhd / "lib" + " UHD_IMAGES_DIR=" + uhd / "images"
image := env("FPGA_IMAGE", "b210-open-fpga:0.3.0")
podman := "podman run --rm --userns=keep-id -v " + justfile_directory() + ":/work:z -w /work -e HOME=/work/build"
dev := "type=b200" + if env("SERIAL", "") == "" { "" } else { ",serial=" + env("SERIAL") }
run := "tests/run.sh"

[private]
default:
    just --list --unsorted

# Build every tool from pinned sources: container, place and route, UHD + FX3 firmware
[group('setup')]
setup:
    podman build --build-arg JOBS=$(nproc) -t {{ image }} -f container/Dockerfile container
    scripts/toolchain.sh
    scripts/toolchain.sh uhd

# Give this account USB access to the board (once, as root)
[group('setup')]
udev:
    sudo install -m 644 .tools/src/uhd/host/utils/uhd-usrp.rules /etc/udev/rules.d/10-usrp-uhd.rules
    sudo udevadm control --reload-rules && sudo udevadm trigger

# Verilog -> build/fpga/usrp_b200.bin and its build record
[group('build')]
build:
    scripts/build.sh

# Shell in the tool container
[group('build')]
shell:
    mkdir -p build && {{ podman }} -it {{ image }} bash

# Delete build/
[group('build')]
clean:
    rm -rf -- build

# Load the image and read every configuration layer over USB, no UHD
[group('board')]
load img=bin:
    python3 scripts/fx3_raw_load.py {{ img }} --regs --peek 64

# UHD loads the image and initialises both radios
[group('board')]
probe img=bin:
    {{ host }} {{ uhd }}/bin/uhd_usrp_probe --args="{{ dev }},fpga=$(realpath {{ img }})"

# Stream and count lost samples: dir rx|tx|rxtx, otw sc16|sc12|sc8
[group('board')]
stream dir="rx" chans="0,1" rate="30.72e6" otw="sc16" secs="10" img=bin:
    #!/usr/bin/env bash
    set -euo pipefail
    frame={{ if otw == "sc12" { "12264" } else if otw == "sc8" { "8176" } else { "16360" } }}  # 4088-4090 samples
    args=()
    [[ {{ dir }} == *rx* ]] && args+=(--rx_rate {{ rate }} --rx_otw {{ otw }})
    [[ {{ dir }} == *tx* ]] && args+=(--tx_rate {{ rate }} --tx_otw {{ otw }})
    (( ${#args[@]} )) || { echo "dir: rx, tx or rxtx" >&2; exit 2; }
    rt=""; chrt -f 50 true 2>/dev/null && rt="chrt -f 50"
    {{ host }} $rt {{ uhd }}/bin/benchmark_rate --duration {{ secs }} --channels {{ chans }} "${args[@]}" \
      --args "{{ dev }},fpga=$(realpath {{ img }}),num_recv_frames=512,recv_frame_size=$frame,num_send_frames=256,send_frame_size=$frame"

# Python receiver/transmitter: just sdr rx|tx|fft|live [options] (host/sdr.py --help)
[group('board')]
sdr *args:
    python3 host/sdr.py {{ args }}

# AD9361 interface eye and its margin at 61.44 MHz
[group('board')]
eye img=bin:
    scripts/eyescan.sh {{ img }} 61.44e6

# Quick check (~5 min): same checks, fewer runs; never an acceptance
[group('board')]
check img=bin:
    QUICK=1 scripts/hw_gate.sh {{ img }}

# Full hardware acceptance; evidence in build/hw-gate-<UTC>/
[group('board')]
gate img=bin:
    scripts/hw_gate.sh {{ img }}

# v2 FPGA benches (fpga/tests/run.sh): every case with the result it must give; filter by text
[group('test')]
bench filter='':
    fpga/tests/run.sh '{{ filter }}'

# Simulation benches, all in parallel or some of: elab yosys-read constraints clk-gen fifo io leds gpif usb-rate e2e dac-slice tx rx-saturate atr golden postsyn
[group('test')]
test *names:
    if [[ -z "{{ names }}" ]]; then just _all; else just $(printf 't-%s ' {{ names }}); fi

[private]
[parallel]
_all: t-elab t-yosys-read t-constraints t-clk-gen t-fifo t-io t-leds t-gpif t-usb-rate t-e2e t-dac-slice t-tx t-rx-saturate t-atr t-golden t-postsyn
    echo "PASS: every simulation bench"

# Each bench below: tests/run.sh NAME TOP PASS-pattern [args]; --must-fail is a
# negative control (the bench with a fault switched on has to report it).

[private]
t-elab:
    mkdir -p build/sim
    iverilog -g2005 -I src/rtl/control -s b200 -o build/sim/b200_elab.vvp \
      $(grep '^src/' scripts/sources.txt) tests/sim/xilinx_prim_sim.v 2> build/sim/b200_elab.log
    echo "PASS: full design elaborates ($(grep -c '^src/' scripts/sources.txt) sources)"

[private]
t-yosys-read:
    mkdir -p build/sim
    {{ podman }} -i {{ image }} yosys -q -p "read_verilog -lib +/xilinx/cells_sim.v +/xilinx/cells_xtra.v; read_verilog -I src/rtl/control $(grep '^src/' scripts/sources.txt | tr '\n' ' '); hierarchy -check -top b200" \
      > build/sim/yosys_read.log 2>&1 || { grep -i error build/sim/yosys_read.log | head -5; echo "FAIL: yosys does not read the design"; exit 1; }
    echo "PASS: yosys reads every source and resolves the hierarchy of b200"

[private]
t-constraints:
    python3 tests/test_constraints.py

[private]
t-clk-gen:
    {{ run }} tb_b200_clk_gen tb_b200_clk_gen '^PASS:'

[private]
t-fifo:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ run }} -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_rate tb_axi_fifo_2clk_rate '^PASS:'
    {{ run }} -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_capacity tb_axi_fifo_2clk_capacity '^PASS:'
    n=0
    for clocks in "+TSLOW=8.138 +TFAST=5.0 +TPHASE=0.0" "+TSLOW=8.138 +TFAST=5.0 +TPHASE=2.5" \
                  "+TSLOW=9.09 +TFAST=4.55 +TPHASE=3.3" "+TSLOW=8.138 +TFAST=50.0 +TPHASE=1.7" \
                  "+TSLOW=4.0 +TFAST=5.0 +TPHASE=0.0"; do
      n=$((n + 1)); {{ run }} tb_axi_fifo_2clk_cdc_$n tb_axi_fifo_2clk_cdc '^PASS:' $clocks
    done

[private]
t-io:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ run }} tb_adc_pins tb_adc_pins '^ADC-PINS: PASS'
    for f in NEG_SWAP NEG_DROP NEG_X; do {{ run }} --must-fail tb_adc_pins_$f tb_adc_pins '^ADC-PINS: PASS' +$f; done
    {{ run }} tb_adc_mimo tb_adc_mimo '^ADC-MIMO: PASS'
    for f in NEG_CHSWAP NEG_IQSWAP NEG_X; do {{ run }} --must-fail tb_adc_mimo_$f tb_adc_mimo '^ADC-MIMO: PASS' +$f; done
    {{ run }} tb_tx_pins tb_tx_pins '^TX-PINS: PASS'
    for f in NEG_SWAP NEG_X; do {{ run }} --must-fail tb_tx_pins_$f tb_tx_pins '^TX-PINS: PASS' +$f; done
    {{ run }} tb_io_handover tb_io_handover '^PASS: samples cross to radio_clk whole'

[private]
t-leds:
    {{ run }} tb_leds tb_leds '^LEDS: PASS'
    {{ run }} --must-fail tb_leds_red tb_leds '^LEDS: PASS' +NEG_RED

[private]
t-gpif:
    {{ run }} tb_gpif_iob_equiv tb_gpif_iob_equiv '^PASS:' tests/ref/gpif2_slave_fifo32_ref.v +cycles=300000
    {{ run }} tb_gpif2_error tb_gpif2_error '^PASS:'

[private]
t-usb-rate:
    {{ run }} tb_usb_rate tb_usb_rate '^USB-RATE: PASS'
    {{ run }} --must-fail tb_usb_rate_slow tb_usb_rate '^USB-RATE: PASS' +NEG_SLOW

[private]
t-e2e:
    {{ run }} tb_e2e_base tb_e2e_rx '^E2E: PASS'
    {{ run }} --must-fail tb_e2e_iqswap tb_e2e_rx '^E2E: PASS' +NEG_IQSWAP
    {{ run }} tb_e2e_stall tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=10000 -DSTALL_PERIOD=40000 -DE2E_RUNCLK=80000
    {{ run }} tb_e2e_stall30 tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=3000 -DSTALL_PERIOD=100000000 -DE2E_RUNCLK=100000 -DE2E_REPAID
    {{ run }} tb_e2e_oversize tb_e2e_rx '^E2E: PASS' -DE2E_SC8 -DNOISY -DE2E_MAXLEN=4080 -DE2E_RUNCLK=100000
    {{ run }} tb_e2e_overrun tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=80000 -DSTALL_PERIOD=100000000 -DE2E_MAXLEN=2040 -DE2E_RUNCLK=40000 -DE2E_OVERRUN

[private]
t-dac-slice:
    {{ run }} tb_dac_slice tb_dac_slice 'DAC-SLICE: PASS'

[private]
t-tx:
    {{ run }} tb_tx_dc tb_tx_dc 'TX-DC: PASS'
    {{ run }} tb_tx_pairing tb_tx_pairing 'TX-PAIR: PASS'
    {{ run }} tb_tx_timed tb_tx_timed 'TX-TIMED: PASS'
    {{ run }} tb_tx_underrun tb_tx_underrun 'TX-UNDERRUN: PASS'

[private]
t-rx-saturate:
    {{ run }} tb_rx_saturate tb_rx_saturate 'RX-SAT: PASS'

[private]
t-atr:
    {{ run }} tb_atr tb_atr 'ATR: PASS'

[private]
ettus-ref:
    mkdir -p build/sim && python3 tests/mk_ettus_ref.py build/sim/ettus_ref > /dev/null

[private]
t-golden: ettus-ref
    {{ run }} tb_hbdec tb_hbdec '^PASS:'
    {{ run }} tb_ddc_golden tb_ddc_golden '^PASS:' build/sim/ettus_ref/*.v
    {{ run }} --must-fail tb_ddc_golden_rate tb_ddc_golden '^PASS:' build/sim/ettus_ref/*.v +NEG_RATE_REG +NCFG=5
    {{ run }} tb_duc_golden tb_duc_golden '^PASS:' build/sim/ettus_ref/*.v
    {{ run }} --must-fail tb_duc_golden_scale tb_duc_golden '^PASS:' build/sim/ettus_ref/*.v +NEG_SCALE_REG +NCFG=4

[private]
t-postsyn: ettus-ref
    #!/usr/bin/env bash
    set -euo pipefail
    P=build/sim/postsyn S=build/sim
    REF="src/rtl/dsp/hbdec47.v src/rtl/dsp/hbdec1.v src/rtl/dsp/hbdec2.v src/rtl/control/setting_reg.v src/ip/xilinx_macros.v"
    mkdir -p $P
    {{ podman }} -i {{ image }} bash tests/postsyn.sh netlists $P
    ( {{ podman }} -i {{ image }} bash tests/postsyn.sh design $P < /dev/null ) & design=$!
    iverilog -g2005 -s tb_yosys_dsp_signext -o $S/tb_yosys_dsp_signext.vvp tests/yosys_dsp_signext.v \
      $P/signext_plain_syn.v $P/signext_rst_syn.v $P/signext_en_syn.v $P/cells_sim.v tests/tb_yosys_dsp_signext.v
    vvp -n -l $S/tb_yosys_dsp_signext.log $S/tb_yosys_dsp_signext.vvp > /dev/null
    python3 tests/check_dsp_packing.py reproducer $P $S/tb_yosys_dsp_signext.log
    {{ run }} --no-design tb_hbdec_syn tb_hbdec '^PASS:' -DPOSTSYN $P/hbdec1_syn.v $P/hbdec2_syn.v $P/cells_sim.v +NCYC=6000
    {{ run }} --no-design tb_ddc_golden_syn tb_ddc_golden '^PASS:' -DPOSTSYN $P/ddc_chain_syn.v $P/cells_sim.v \
      $S/ettus_ref/*.v $REF +CFGMASK=bf +NSETTLE=24 +NMEAS=8
    {{ run }} --no-design tb_duc_golden_syn tb_duc_golden '^PASS:' -DPOSTSYN $P/duc_chain_syn.v $P/cells_sim.v \
      $S/ettus_ref/*.v $REF +CFGMASK=30bf +NSETTLE=24 +NMEAS=8
    wait $design
    python3 tests/check_dsp_packing.py design $P
