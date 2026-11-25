# B210 open FPGA: build, simulate and accept the image, all from the terminal.
#
#   just              this list
#   just build        Verilog -> build/fpga/usrp_b200.bin and its build record
#   just gate         acceptance of that image on the connected board
#
# The flow itself is in scripts/; every recipe here is one call into it.

set shell := ["bash", "-euo", "pipefail", "-c"]
set quiet

image := env("FPGA_IMAGE", "b210-open-fpga:0.3.0")
bin := "build/fpga/usrp_b200.bin"
uhd := justfile_directory() / ".tools/uhd315"
host := "env LD_LIBRARY_PATH=" + uhd / "lib" + " UHD_IMAGES_DIR=" + uhd / "images"
container := "podman run --rm -i --userns=keep-id -v " + justfile_directory() + ":/work:z -w /work -e HOME=/work/build " + image
dev := "type=b200" + if env("SERIAL", "") == "" { "" } else { ",serial=" + env("SERIAL") }
run := "tests/run.sh"
sim := "build/sim"

[private]
default:
    just --list --unsorted

# --- setup ------------------------------------------------------------------

# Container image: Yosys and the Project X-Ray tools, from pinned sources
[group('setup')]
container:
    podman build --build-arg JOBS=$(nproc) -t {{ image }} -f container/Dockerfile container

# .tools/: place-and-route engine, chip database, UHD and the stock FX3 firmware
[group('setup')]
toolchain:
    scripts/toolchain.sh
    scripts/toolchain.sh uhd

# USB access to the board for this account: UHD's udev rule, once, as root
[group('setup')]
udev:
    sudo install -m 644 .tools/src/uhd/host/utils/uhd-usrp.rules /etc/udev/rules.d/10-usrp-uhd.rules
    sudo udevadm control --reload-rules && sudo udevadm trigger

# --- build ------------------------------------------------------------------

# Verilog -> build/fpga/usrp_b200.bin with its build record (.txt)
[group('build')]
build:
    scripts/build.sh

# Interactive shell in the container image
[group('build')]
shell:
    mkdir -p build
    podman run --rm -it --userns=keep-id -v "{{ justfile_directory() }}:/work:z" -w /work -e HOME=/work/build {{ image }} bash

# Remove build/
[group('build')]
clean:
    rm -rf -- build

# --- board ------------------------------------------------------------------

# Reboot the FX3, load the image, read every configuration layer over USB (no UHD)
[group('board')]
load img=bin:
    python3 scripts/fx3_raw_load.py {{ img }} --regs --peek 64

# UHD loads the image and initialises both radio cores
[group('board')]
probe img=bin:
    {{ host }} {{ uhd }}/bin/uhd_usrp_probe --args="{{ dev }},fpga=$(realpath {{ img }})"

# Stream for `secs` seconds: dir rx, tx or rxtx; chans 0, 1 or 0,1; otw sc16, sc12 or sc8
[group('board')]
stream dir="rx" chans="0,1" rate="30.72e6" otw="sc16" secs="10" img=bin:
    #!/usr/bin/env bash
    set -euo pipefail
    # Deep USB buffer pool, packets of 4088-4090 samples (the receive framer
    # delivers up to 4091 per packet cleanly); see scripts/hw_gate.sh.
    frame={{ if otw == "sc12" { "12264" } else if otw == "sc8" { "8176" } else { "16360" } }}
    args=()
    [[ {{ dir }} == rx || {{ dir }} == rxtx ]] && args+=(--rx_rate {{ rate }} --rx_otw {{ otw }})
    [[ {{ dir }} == tx || {{ dir }} == rxtx ]] && args+=(--tx_rate {{ rate }} --tx_otw {{ otw }})
    (( ${#args[@]} )) || { echo "dir is rx, tx or rxtx" >&2; exit 2; }
    rt=""; chrt -f 50 true 2>/dev/null && rt="chrt -f 50"
    {{ host }} $rt {{ uhd }}/bin/benchmark_rate --duration {{ secs }} --channels {{ chans }} "${args[@]}" \
      --args "{{ dev }},fpga=$(realpath {{ img }}),num_recv_frames=512,recv_frame_size=$frame,num_send_frames=256,send_frame_size=$frame"

# AD9361 interface eye scan at 61.44 MHz
[group('board')]
eye img=bin:
    scripts/eyescan.sh {{ img }} 61.44e6

# Full hardware acceptance (identity, raw USB, init, eye, samples, DSP, bus margin, throughput)
[group('board')]
gate img=bin:
    scripts/hw_gate.sh {{ img }}

# --- simulation ---------------------------------------------------------------
#
# tests/run.sh compiles one bench with the whole design, runs it and judges
# its log; --must-fail is a negative control (the bench with a fault switched
# on has to report it).  Every bench writes its own files in build/sim, so
# the groups run in parallel (just --jobs N limits them).  What is here
# guards what this repository wrote or what the open tools can silently
# break; unmodified Ettus logic is held to the upstream sources bit for bit
# by the golden benches, before and after synthesis.

# Every simulation bench
[group('test')]
[parallel]
test: test-elab test-yosys-read test-constraints test-clk-gen test-fifo test-io test-leds test-gpif test-usb-rate test-e2e test-dac-slice test-tx test-rx-saturate test-atr test-golden test-postsyn
    echo "PASS: every simulation bench"

# The whole design is legal Verilog for a simulator
[group('test')]
test-elab:
    mkdir -p {{ sim }}
    iverilog -g2005 -I src/rtl/control -s b200 -o {{ sim }}/b200_elab.vvp \
      $(grep '^src/' scripts/sources.txt) tests/sim/xilinx_prim_sim.v 2> {{ sim }}/b200_elab.log
    echo "PASS: full design elaborates ($(grep -c '^src/' scripts/sources.txt) sources)"

# Yosys reads every source and resolves the hierarchy (seconds, not a failed build)
[group('test')]
test-yosys-read:
    mkdir -p {{ sim }}
    {{ container }} yosys -q -p "read_verilog -lib +/xilinx/cells_sim.v +/xilinx/cells_xtra.v; read_verilog -I src/rtl/control $(grep '^src/' scripts/sources.txt | tr '\n' ' '); hierarchy -check -top b200" \
      > {{ sim }}/yosys_read.log 2>&1 || { grep -i error {{ sim }}/yosys_read.log | head -5; echo "FAIL: yosys does not read the design"; exit 1; }
    echo "PASS: yosys reads every source and resolves the hierarchy of b200"

# Every port has a pin and an I/O standard, no pin twice
[group('test')]
test-constraints:
    python3 tests/test_constraints.py

# The clock generator's outputs, phases and lock
[group('test')]
test-clk-gen:
    {{ run }} tb_b200_clk_gen tb_b200_clk_gen '^PASS:'

# The dual-clock FIFO flags: integrity at five clock relationships, throughput, capacity
[group('test')]
test-fifo:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ run }} -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_rate tb_axi_fifo_2clk_rate '^PASS:'
    {{ run }} -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_capacity tb_axi_fifo_2clk_capacity '^PASS:'
    n=0
    for clocks in "+TSLOW=8.138 +TFAST=5.0 +TPHASE=0.0" "+TSLOW=8.138 +TFAST=5.0 +TPHASE=2.5" \
                  "+TSLOW=9.09 +TFAST=4.55 +TPHASE=3.3" "+TSLOW=8.138 +TFAST=50.0 +TPHASE=1.7" \
                  "+TSLOW=4.0 +TFAST=5.0 +TPHASE=0.0"; do
      n=$((n + 1))
      {{ run }} tb_axi_fifo_2clk_cdc_$n tb_axi_fifo_2clk_cdc '^PASS:' $clocks
    done

# The AD9361 port: receive pairing in both modes, hand-over to radio_clk, transmit pins
[group('test')]
test-io:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ run }} tb_adc_pins tb_adc_pins '^ADC-PINS: PASS'
    for fault in NEG_SWAP NEG_DROP NEG_X; do
      {{ run }} --must-fail tb_adc_pins_$fault tb_adc_pins '^ADC-PINS: PASS' +$fault
    done
    {{ run }} tb_adc_mimo tb_adc_mimo '^ADC-MIMO: PASS'
    for fault in NEG_CHSWAP NEG_IQSWAP NEG_X; do
      {{ run }} --must-fail tb_adc_mimo_$fault tb_adc_mimo '^ADC-MIMO: PASS' +$fault
    done
    {{ run }} tb_tx_pins tb_tx_pins '^TX-PINS: PASS'
    for fault in NEG_SWAP NEG_X; do
      {{ run }} --must-fail tb_tx_pins_$fault tb_tx_pins '^TX-PINS: PASS' +$fault
    done
    {{ run }} tb_io_handover tb_io_handover '^PASS: samples cross to radio_clk whole'

# The LEDs in eleven situations; a transmitting port expected red has to fail
[group('test')]
test-leds:
    {{ run }} tb_leds tb_leds '^LEDS: PASS'
    {{ run }} --must-fail tb_leds_red tb_leds '^LEDS: PASS' +NEG_RED

# The FX3 bus module against the unmodified reference, every pad every cycle; the error checker
[group('test')]
test-gpif:
    {{ run }} tb_gpif_iob_equiv tb_gpif_iob_equiv '^PASS:' tests/ref/gpif2_slave_fifo32_ref.v +cycles=300000
    {{ run }} tb_gpif2_error tb_gpif2_error '^PASS:'

# The bus sustains the full USB rate; a slowed bus has to fail
[group('test')]
test-usb-rate:
    {{ run }} tb_usb_rate tb_usb_rate '^USB-RATE: PASS'
    {{ run }} --must-fail tb_usb_rate_slow tb_usb_rate '^USB-RATE: PASS' +NEG_SLOW

# Pins to FX3 with the bench as UHD: every sample, stalls, largest packet, overflow and restart
[group('test')]
test-e2e:
    {{ run }} tb_e2e_base tb_e2e_rx '^E2E: PASS'
    {{ run }} --must-fail tb_e2e_iqswap tb_e2e_rx '^E2E: PASS' +NEG_IQSWAP
    {{ run }} tb_e2e_stall tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=10000 -DSTALL_PERIOD=40000 -DE2E_RUNCLK=80000
    {{ run }} tb_e2e_stall30 tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=3000 -DSTALL_PERIOD=100000000 -DE2E_RUNCLK=100000 -DE2E_REPAID
    {{ run }} tb_e2e_oversize tb_e2e_rx '^E2E: PASS' -DE2E_SC8 -DNOISY -DE2E_MAXLEN=4080 -DE2E_RUNCLK=100000
    {{ run }} tb_e2e_overrun tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=80000 -DSTALL_PERIOD=100000000 -DE2E_MAXLEN=2040 -DE2E_RUNCLK=40000 -DE2E_OVERRUN

# The rounding 12-bit DAC word (the original truncates), all 2^24 codes
[group('test')]
test-dac-slice:
    {{ run }} tb_dac_slice tb_dac_slice 'DAC-SLICE: PASS'

# Transmit: DUC guard bit and clip; deframer: every sample once, odd lengths, timed start, late, underrun
[group('test')]
test-tx:
    {{ run }} tb_tx_dc tb_tx_dc 'TX-DC: PASS'
    {{ run }} tb_tx_pairing tb_tx_pairing 'TX-PAIR: PASS'
    {{ run }} tb_tx_timed tb_tx_timed 'TX-TIMED: PASS'
    {{ run }} tb_tx_underrun tb_tx_underrun 'TX-UNDERRUN: PASS'

# The receive chain saturates instead of wrapping
[group('test')]
test-rx-saturate:
    {{ run }} tb_rx_saturate tb_rx_saturate 'RX-SAT: PASS'

# The antenna switch pins (nothing on the board observes them)
[group('test')]
test-atr:
    {{ run }} tb_atr tb_atr 'ATR: PASS'

# The original Ettus DSP RTL, with its modules renamed, as the golden reference
[private]
ettus-ref:
    mkdir -p {{ sim }}
    python3 tests/mk_ettus_ref.py {{ sim }}/ettus_ref > /dev/null

# DSP chains against the Ettus RTL bit for bit, clock for clock; halfbands against their 47 taps
[group('test')]
test-golden: ettus-ref
    {{ run }} tb_hbdec tb_hbdec '^PASS:'
    {{ run }} tb_ddc_golden tb_ddc_golden '^PASS:' {{ sim }}/ettus_ref/*.v
    {{ run }} --must-fail tb_ddc_golden_rate tb_ddc_golden '^PASS:' {{ sim }}/ettus_ref/*.v +NEG_RATE_REG +NCFG=5
    {{ run }} tb_duc_golden tb_duc_golden '^PASS:' {{ sim }}/ettus_ref/*.v
    {{ run }} --must-fail tb_duc_golden_scale tb_duc_golden '^PASS:' {{ sim }}/ettus_ref/*.v +NEG_SCALE_REG +NCFG=4

# The same after synthesis with the build's flags, and the yosys DSP sign-bit fault check
[group('test')]
test-postsyn: ettus-ref
    #!/usr/bin/env bash
    set -euo pipefail
    P={{ sim }}/postsyn
    REF="src/rtl/dsp/hbdec47.v src/rtl/dsp/hbdec1.v src/rtl/dsp/hbdec2.v src/rtl/control/setting_reg.v src/ip/xilinx_macros.v"
    mkdir -p $P
    {{ container }} bash tests/postsyn.sh netlists $P
    ( {{ container }} bash tests/postsyn.sh design $P < /dev/null ) & design=$!
    iverilog -g2005 -s tb_yosys_dsp_signext -o {{ sim }}/tb_yosys_dsp_signext.vvp tests/yosys_dsp_signext.v \
      $P/signext_plain_syn.v $P/signext_rst_syn.v $P/signext_en_syn.v $P/cells_sim.v tests/tb_yosys_dsp_signext.v
    vvp -n -l {{ sim }}/tb_yosys_dsp_signext.log {{ sim }}/tb_yosys_dsp_signext.vvp > /dev/null
    python3 tests/check_dsp_packing.py reproducer $P {{ sim }}/tb_yosys_dsp_signext.log
    {{ run }} --no-design tb_hbdec_syn tb_hbdec '^PASS:' -DPOSTSYN $P/hbdec1_syn.v $P/hbdec2_syn.v $P/cells_sim.v +NCYC=6000
    {{ run }} --no-design tb_ddc_golden_syn tb_ddc_golden '^PASS:' -DPOSTSYN $P/ddc_chain_syn.v $P/cells_sim.v \
      {{ sim }}/ettus_ref/*.v $REF +CFGMASK=bf +NSETTLE=24 +NMEAS=8
    {{ run }} --no-design tb_duc_golden_syn tb_duc_golden '^PASS:' -DPOSTSYN $P/duc_chain_syn.v $P/cells_sim.v \
      {{ sim }}/ettus_ref/*.v $REF +CFGMASK=30bf +NSETTLE=24 +NMEAS=8
    wait $design
    python3 tests/check_dsp_packing.py design $P
