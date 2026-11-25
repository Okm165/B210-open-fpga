# B210 open FPGA flow.
#
# Yosys synthesizes the B200/B210 Verilog RTL, nextpnr-himbaechel places and
# routes it for the Kintex-7 fabric, and Project X-Ray writes the bitstream.
# The flow itself lives in scripts/ (toolchain.sh, build.sh, hw_gate.sh); this
# file runs it and the simulation benches.

.DEFAULT_GOAL := help
.ONESHELL:
SHELL := /bin/bash
# Every recipe is one script (.ONESHELL); without -e such a script reports
# only the status of its LAST command and a failed step in the middle passes.
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SIM  := build/sim
# The same default as scripts/build.sh and scripts/assemble.sh.
FPGA_IMAGE ?= b210-open-fpga:0.3.0
IN_IMAGE := podman run --rm -i --userns=keep-id -v "$(ROOT):/work:z" -w /work -e HOME=/work/build $(FPGA_IMAGE)

.PHONY: help tools toolchain build eye gate shell test elab clean image-clean

help:
	@printf '%s\n' \
	  'B210 open FPGA flow (yosys + nextpnr-himbaechel + Project X-Ray)' \
	  '' \
	  '  make tools      Build the container image (yosys, Project X-Ray tools)' \
	  '  make toolchain  Build the place-and-route engine and the measuring UHD into .tools/' \
	  '  make build      Verilog -> build/fpga/usrp_b200.bin' \
	  '  make gate       Hardware acceptance of that image on the board' \
	  '  make eye        AD9361 interface eye scan of that image on the board' \
	  '  make test       The simulation benches (needs the container image; TEST_JOBS at a time)' \
	  '  make elab       Elaborate the complete design against the primitive models' \
	  '  make shell      Interactive shell in the container image' \
	  '  make clean      Remove build/' \
	  '  make image-clean  Remove the container image'

tools:
	podman build --build-arg JOBS=$(shell nproc) -t $(FPGA_IMAGE) -f container/Dockerfile container

toolchain:
	scripts/toolchain.sh
	scripts/toolchain.sh uhd

build:
	scripts/build.sh

gate:
	scripts/hw_gate.sh build/fpga/usrp_b200.bin

eye:
	scripts/eyescan.sh build/fpga/usrp_b200.bin 61.44e6

shell:
	@mkdir -p build
	podman run --rm -it --userns=keep-id -v "$(ROOT):/work:z" -w /work -e HOME=/work/build $(FPGA_IMAGE) bash

clean:
	rm -rf -- "$(ROOT)/build"

image-clean:
	@podman rmi -f $(FPGA_IMAGE) 2>/dev/null || true

# ---------------------------------------------------------------------------
# Simulation.  tests/run.sh compiles one bench with the whole design, runs it
# and judges its log; --must-fail is a negative control (the bench with a
# fault switched on has to report it).  Every target writes its own files in
# build/sim, so they run TEST_JOBS at a time.
#
# What is here guards what this repository wrote or what the open tools can
# silently break.  Unmodified Ettus logic is held to the upstream sources bit
# for bit by the two golden benches, before and after synthesis, and to the
# board by scripts/hw_gate.sh.
# ---------------------------------------------------------------------------
RUN := tests/run.sh
TEST_JOBS ?= 8

TESTS := t-elab t-yosys-read t-constraints t-clk-gen t-fifo t-io t-leds t-gpif t-usb-rate t-e2e \
         t-dac-slice t-tx t-rx-saturate t-atr t-golden t-postsyn
.PHONY: $(TESTS) tests-all

test:
	@$(MAKE) --no-print-directory --output-sync=target -j $(TEST_JOBS) tests-all
	echo "PASS: every simulation bench"
tests-all: $(TESTS)

# The whole design is legal Verilog for a simulator (synthesis tolerates
# implicit nets and use before declaration).
elab t-elab:
	@mkdir -p $(SIM)
	iverilog -g2005 -I src/rtl/control -s b200 -o $(SIM)/b200_elab.vvp \
	  $$(grep '^src/' scripts/sources.txt) tests/sim/xilinx_prim_sim.v 2> $(SIM)/b200_elab.log
	echo "PASS: full design elaborates ($$(grep -c '^src/' scripts/sources.txt) sources)"

# Yosys reads every source and resolves the hierarchy: what Icarus accepts
# and Yosys does not (initial values in a port list, say) fails here in
# seconds instead of at the start of a build.
t-yosys-read:
	@$(IN_IMAGE) yosys -q -p "read_verilog -lib +/xilinx/cells_sim.v +/xilinx/cells_xtra.v; read_verilog -I src/rtl/control $$(grep '^src/' scripts/sources.txt | tr '\n' ' '); hierarchy -check -top b200" \
	  > $(SIM)/yosys_read.log 2>&1 || { grep -i error $(SIM)/yosys_read.log | head -5; echo "FAIL: yosys does not read the design"; exit 1; }
	echo "PASS: yosys reads every source and resolves the hierarchy of b200"

# Every port has a pin and an I/O standard, no pin twice: the engine places an
# unconstrained port silently.
t-constraints:
	@python3 tests/test_constraints.py

t-clk-gen:
	@$(RUN) tb_b200_clk_gen tb_b200_clk_gen '^PASS:'

# The dual-clock FIFO's flags (rewritten here): integrity at five clock
# relationships, throughput, capacity.
t-fifo:
	@$(RUN) -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_rate tb_axi_fifo_2clk_rate '^PASS:'
	$(RUN) -b tests/tb_axi_fifo_2clk_cdc.v tb_axi_fifo_2clk_capacity tb_axi_fifo_2clk_capacity '^PASS:'
	n=0
	for clocks in "+TSLOW=8.138 +TFAST=5.0 +TPHASE=0.0" "+TSLOW=8.138 +TFAST=5.0 +TPHASE=2.5" \
	              "+TSLOW=9.09 +TFAST=4.55 +TPHASE=3.3" "+TSLOW=8.138 +TFAST=50.0 +TPHASE=1.7" \
	              "+TSLOW=4.0 +TFAST=5.0 +TPHASE=0.0"; do
	  n=$$((n + 1))
	  $(RUN) tb_axi_fifo_2clk_cdc_$$n tb_axi_fifo_2clk_cdc '^PASS:' $$clocks
	done

# The AD9361 port (b200_io.v): receive pairing in both modes, the hand-over to
# radio_clk under skew, the transmit pins.
t-io:
	@$(RUN) tb_adc_pins tb_adc_pins '^ADC-PINS: PASS'
	for fault in NEG_SWAP NEG_DROP NEG_X; do
	  $(RUN) --must-fail tb_adc_pins_$$fault tb_adc_pins '^ADC-PINS: PASS' +$$fault
	done
	$(RUN) tb_adc_mimo tb_adc_mimo '^ADC-MIMO: PASS'
	for fault in NEG_CHSWAP NEG_IQSWAP NEG_X; do
	  $(RUN) --must-fail tb_adc_mimo_$$fault tb_adc_mimo '^ADC-MIMO: PASS' +$$fault
	done
	$(RUN) tb_tx_pins tb_tx_pins '^TX-PINS: PASS'
	for fault in NEG_SWAP NEG_X; do
	  $(RUN) --must-fail tb_tx_pins_$$fault tb_tx_pins '^TX-PINS: PASS' +$$fault
	done
	$(RUN) tb_io_handover tb_io_handover '^PASS: samples cross to radio_clk whole'

# The LEDs show what src/top/b200_leds.v says they show, in eleven
# situations; a transmitting port expected red instead of amber has to fail.
t-leds:
	@$(RUN) tb_leds tb_leds '^LEDS: PASS'
	$(RUN) --must-fail tb_leds_red tb_leds '^LEDS: PASS' +NEG_RED

# The FX3 bus module with its registers in the I/O blocks against the
# unmodified reference, every pad and stream, every cycle; and the error
# checker's defined behaviour.
t-gpif:
	@$(RUN) tb_gpif_iob_equiv tb_gpif_iob_equiv '^PASS:' tests/ref/gpif2_slave_fifo32_ref.v +cycles=300000
	$(RUN) tb_gpif2_error tb_gpif2_error '^PASS:'

t-usb-rate:
	@$(RUN) tb_usb_rate tb_usb_rate '^USB-RATE: PASS'
	$(RUN) --must-fail tb_usb_rate_slow tb_usb_rate '^USB-RATE: PASS' +NEG_SLOW

# Pins to FX3 through the real core and bus module, the bench acting as UHD:
# every sample, sequence number and time stamp; a stalled host; the largest
# packet UHD asks for; the stock overflow sequence and the restart after it.
t-e2e:
	@$(RUN) tb_e2e_base tb_e2e_rx '^E2E: PASS'
	$(RUN) --must-fail tb_e2e_iqswap tb_e2e_rx '^E2E: PASS' +NEG_IQSWAP
	$(RUN) tb_e2e_stall tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=10000 -DSTALL_PERIOD=40000 -DE2E_RUNCLK=80000
	$(RUN) tb_e2e_stall30 tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=3000 -DSTALL_PERIOD=100000000 -DE2E_RUNCLK=100000 -DE2E_REPAID
	$(RUN) tb_e2e_oversize tb_e2e_rx '^E2E: PASS' -DE2E_SC8 -DNOISY -DE2E_MAXLEN=4080 -DE2E_RUNCLK=100000
	$(RUN) tb_e2e_overrun tb_e2e_rx '^E2E: PASS' -DSTALL -DSTALL_START=10000 -DSTALL_CLKS=80000 -DSTALL_PERIOD=100000000 -DE2E_MAXLEN=2040 -DE2E_RUNCLK=40000 -DE2E_OVERRUN

# The rounding 12-bit DAC word (ours; the original truncates), all 2^24 codes.
t-dac-slice:
	@$(RUN) tb_dac_slice tb_dac_slice 'DAC-SLICE: PASS'

# Transmit: the guard bit and clip of the DUC (the one declared deviation of
# the chain), and the deframer and control: every sample once, odd lengths,
# timed start, late packet, underrun.
t-tx:
	@$(RUN) tb_tx_dc tb_tx_dc 'TX-DC: PASS'
	$(RUN) tb_tx_pairing tb_tx_pairing 'TX-PAIR: PASS'
	$(RUN) tb_tx_timed tb_tx_timed 'TX-TIMED: PASS'
	$(RUN) tb_tx_underrun tb_tx_underrun 'TX-UNDERRUN: PASS'

t-rx-saturate:
	@$(RUN) tb_rx_saturate tb_rx_saturate 'RX-SAT: PASS'

# The antenna switch pins: nothing on the board observes them.
t-atr:
	@$(RUN) tb_atr tb_atr 'ATR: PASS'

# The DSP chains against the original Ettus RTL (tests/ref/ettus_dsp, renamed
# by mk_ettus_ref.py), bit for bit and clock for clock: 16 receive and 14
# transmit configurations; and the halfband decimators against their 47-tap
# definition.
$(SIM)/ettus_ref/.done: tests/mk_ettus_ref.py $(wildcard tests/ref/ettus_dsp/*)
	@mkdir -p $(SIM)
	python3 tests/mk_ettus_ref.py $(SIM)/ettus_ref > /dev/null
	touch $@

t-golden: $(SIM)/ettus_ref/.done
	@$(RUN) tb_hbdec tb_hbdec '^PASS:'
	$(RUN) tb_ddc_golden tb_ddc_golden '^PASS:' $(SIM)/ettus_ref/*.v
	$(RUN) --must-fail tb_ddc_golden_rate tb_ddc_golden '^PASS:' $(SIM)/ettus_ref/*.v +NEG_RATE_REG +NCFG=5
	$(RUN) tb_duc_golden tb_duc_golden '^PASS:' $(SIM)/ettus_ref/*.v
	$(RUN) --must-fail tb_duc_golden_scale tb_duc_golden '^PASS:' $(SIM)/ettus_ref/*.v +NEG_SCALE_REG +NCFG=4

# The same after synthesis with the build's flags (tests/postsyn.sh, in the
# container): the netlists of the DSP chains against the Ettus RTL, and the
# reproducer and whole-design check of the yosys fault that drops the sign
# bits of a DSP48 product register (tests/check_dsp_packing.py).
POSTSYN_REF := src/rtl/dsp/hbdec47.v src/rtl/dsp/hbdec1.v src/rtl/dsp/hbdec2.v \
               src/rtl/control/setting_reg.v src/ip/xilinx_macros.v
t-postsyn: $(SIM)/ettus_ref/.done
	@P=$(SIM)/postsyn
	mkdir -p $$P
	$(IN_IMAGE) bash tests/postsyn.sh netlists $$P
	( $(IN_IMAGE) bash tests/postsyn.sh design $$P < /dev/null ) & design=$$!
	iverilog -g2005 -s tb_yosys_dsp_signext -o $(SIM)/tb_yosys_dsp_signext.vvp tests/yosys_dsp_signext.v \
	  $$P/signext_plain_syn.v $$P/signext_rst_syn.v $$P/signext_en_syn.v $$P/cells_sim.v tests/tb_yosys_dsp_signext.v
	vvp -n -l $(SIM)/tb_yosys_dsp_signext.log $(SIM)/tb_yosys_dsp_signext.vvp > /dev/null
	python3 tests/check_dsp_packing.py reproducer $$P $(SIM)/tb_yosys_dsp_signext.log
	$(RUN) --no-design tb_hbdec_syn tb_hbdec '^PASS:' -DPOSTSYN $$P/hbdec1_syn.v $$P/hbdec2_syn.v $$P/cells_sim.v +NCYC=6000
	$(RUN) --no-design tb_ddc_golden_syn tb_ddc_golden '^PASS:' -DPOSTSYN $$P/ddc_chain_syn.v $$P/cells_sim.v \
	  $(SIM)/ettus_ref/*.v $(POSTSYN_REF) +CFGMASK=bf +NSETTLE=24 +NMEAS=8
	$(RUN) --no-design tb_duc_golden_syn tb_duc_golden '^PASS:' -DPOSTSYN $$P/duc_chain_syn.v $$P/cells_sim.v \
	  $(SIM)/ettus_ref/*.v $(POSTSYN_REF) +CFGMASK=30bf +NSETTLE=24 +NMEAS=8
	wait $$design
	python3 tests/check_dsp_packing.py design $$P
