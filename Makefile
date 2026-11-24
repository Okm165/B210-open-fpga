# B210 open FPGA flow.
#
# Yosys synthesizes the B200/B210 Verilog RTL, nextpnr-himbaechel places and
# routes it for the Kintex-7 fabric, and Project X-Ray writes the bitstream.
# The flow itself lives in scripts/ (toolchain.sh, build.sh, hw_gate.sh); this
# file runs it and the simulation benches.

.DEFAULT_GOAL := help
.ONESHELL:
.NOTPARALLEL:
SHELL := /bin/bash
# Every recipe is one script (.ONESHELL); without -e such a script reports
# only the status of its LAST command and a failed step in the middle passes.
.SHELLFLAGS := -eu -o pipefail -c

ROOT       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  := $(ROOT)/build
FPGA_DIR   := $(BUILD_DIR)/fpga
SIM_DIR    := $(BUILD_DIR)/sim
SIM_DIR_REL:= build/sim

# The repository is mounted here inside the toolchain image. Keeping this
# path stable makes the Yosys netlist independent of the checkout location.
CR := /work

IVERILOG ?= iverilog
VVP      ?= vvp

CONTAINER_ENGINE ?= podman
TAG              ?= 0.2.0
BASE_IMAGE       ?= b210-open-fpga-base:$(TAG)
YOSYS_IMAGE      ?= b210-open-fpga-yosys:$(TAG)
PRJXRAY_IMAGE    ?= b210-open-fpga-prjxray:$(TAG)
FPGA_IMAGE       ?= b210-open-fpga:$(TAG)

ifeq ($(CONTAINER_ENGINE),podman)
CONTAINER_USER_FLAGS := --userns=keep-id
else
CONTAINER_USER_FLAGS := --user $(shell id -u):$(shell id -g)
endif

CONTAINER_RUN := $(CONTAINER_ENGINE) run --rm -i $(CONTAINER_USER_FLAGS) \
  -v "$(ROOT):$(CR):z" -w "$(CR)" -e HOME="$(CR)/build"
CONTAINER_BUILD := $(CONTAINER_ENGINE) build --build-arg JOBS=$(shell nproc)

TEST_SRCS := \
  $(ROOT)/src/rtl/control/bin2gray.v \
  $(ROOT)/src/rtl/control/gray2bin.v \
  $(ROOT)/tests/tb_gray_roundtrip.v

# The TX-side CIC bench (interpolator DC gain per rate).
CIC_TEST_SRCS := \
  $(ROOT)/src/rtl/dsp/cic_interp.v \
  $(ROOT)/src/rtl/dsp/cic_int_shifter.v \
  $(ROOT)/src/rtl/dsp/sign_extend.v \
  $(ROOT)/tests/tb_cic_interp.v

CDC_TEST_SRCS := \
  $(ROOT)/tests/tb_axi_fifo_2clk_cdc.v \
  $(ROOT)/src/rtl/fifo/axi_fifo_2clk_sim.v \
  $(ROOT)/src/rtl/fifo/axi_fifo_flop2.v \
  $(ROOT)/src/rtl/control/synchronizer.v \
  $(ROOT)/src/rtl/control/synchronizer_impl.v \
  $(ROOT)/src/rtl/control/bin2gray.v \
  $(ROOT)/src/rtl/control/gray2bin.v

RESET_TEST_SRCS := \
  $(ROOT)/src/rtl/control/reset_sync.v \
  $(ROOT)/src/rtl/control/synchronizer.v \
  $(ROOT)/src/rtl/control/synchronizer_impl.v \
  $(ROOT)/tests/tb_reset_sync.v


CLIP_TEST_SRCS := \
  $(ROOT)/src/rtl/dsp/clip.v \
  $(ROOT)/src/rtl/dsp/clip_reg.v \
  $(ROOT)/tests/tb_clip.v

CTRL_ABI_TEST_SRCS := \
  $(ROOT)/src/rtl/control_200/radio_ctrl_proc.v \
  $(ROOT)/src/rtl/timing/time_compare.v \
  $(ROOT)/tests/tb_ctrl_abi.v

CLK_GEN_TEST_SRCS := \
  $(ROOT)/src/top/b200_clk_gen.v \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_b200_clk_gen.v

# Whole-design elaboration.  Every manifest source plus the licence-clean
# primitive models, compiled with the real `b200` top.  This catches the class
# of defect synthesis tolerates silently (implicit nets, use before
# declaration) and takes well under a second.
ELAB_SRCS := $(shell cd $(ROOT) && grep '^src/' scripts/sources.txt | sed "s|^|$(ROOT)/|")

DDC_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_ddc_chain.v

GATE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/tb_axi_packet_gate.v

LOSSLESS_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_ddc_lossless.v

RX_STREAM_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_rx_stream.v

USB_RATE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_usb_rate.v
CTRL_FIFO_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_ctrl_fifo.v
ADC_PINS_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_adc_pins.v

ADC_MIMO_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_adc_mimo.v
# Received samples across the capture-clock -> radio_clk boundary, with the
# clock skew no tool constrains (0.2 .. 4.0 ns, both divider phases).
IO_HANDOVER_TEST_SRCS := \
  $(ROOT)/src/top/b200_io.v \
  $(ROOT)/src/rtl/control/synchronizer.v \
  $(ROOT)/src/rtl/control/synchronizer_impl.v \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_io_handover.v
E2E_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_e2e_rx.v
# The end-to-end cases, longest first, and how many are simulated at a time.
E2E_RUNS := overrun oversize stall30 stall base fs fslo two noisy
E2E_JOBS ?= 4

RX_CODES_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_rx_codes.v

# RX overload corner: a complex envelope above full scale must saturate.
RX_SAT_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_rx_saturate.v

DAC_SLICE_TEST_SRCS := $(ROOT)/src/rtl/dsp/dac_slice.v \
  $(ROOT)/tests/tb_dac_slice.v

TX_DC_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_dc.v

LATENCY_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_latency.v

PASSBAND_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_passband.v

TX_PINS_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_pins.v

# The bus module against its unmodified reference: 300000 randomized bus
# cycles here, 2 x 2000000 in the runs that qualified the rewrite (13 min).
GPIF_IOB_EQUIV_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/ref/gpif2_slave_fifo32_ref.v \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_gpif_iob_equiv.v

GPIF_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/tb_gpif2_error.v

# The FX3 interface across an asynchronous clock boundary (gpif_clk and
# fifo_clk are different oscillators on the board).
GPIF_CDC_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_gpif_cdc.v

# TX underrun: starving the host must never present a stale sample.
TX_UNDERRUN_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_underrun.v

# Timed transmit: a future-scheduled packet waits and fires on its tick; a
# packet whose time has passed reports TIME_ERROR and never starts the DAC.
TX_TIMED_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_timed.v

# TX sample pairing: even, odd-length and burst packets must deliver every
# host sample to the DUC exactly once, in order.
TX_PAIRING_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_pairing.v

# TX -> RX digital loopback: one gain, one phase convention, no conjugate.
# Two-channel bidirectional loopback: both datapaths, both directions, both
# channels at once.
LOOP2_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_loopback2.v

# Whole-radio loop with an explicit air model (delay, multipath, noise, coupling).
AIR_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_airloop.v
# MIMO clock-mux switch: glitch behaviour of BUFGCTRL across the switchover.
SPI_TEST_SRCS := \
  $(ROOT)/src/rtl/control/setting_reg.v \
  $(ROOT)/src/rtl/control/simple_spi_core.v \
  $(ROOT)/tests/tb_spi.v

ATR_TEST_SRCS := \
  $(ROOT)/src/rtl/control/setting_reg.v \
  $(ROOT)/src/rtl/control/gpio_atr.v \
  $(ROOT)/src/rtl/control/gpio_atr_io.v \
  $(ROOT)/tests/tb_atr.v

CLKMUX_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_clkmux.v

# Transmitter settings-write behaviour: LO retune and rate-register rewrite.
RETUNE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_tx_retune.v

# TX linear phase: the impulse response must be symmetric at every rate.
PHASE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_phase.v

DUC_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_duc_chain.v

# The radio DSP against the Ettus original.  tests/mk_ettus_ref.py writes the
# untouched upstream sources of tests/ref/ettus_dsp/ into $(SIM_DIR)/ettus_ref
# with their module names prefixed, and tb_ddc_golden / tb_duc_golden run that
# reference next to this design's chain: same registers (as UHD writes them),
# same stimulus, outputs compared bit for bit on every clock.
DSP_GOLDEN_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v

# The two receive halfband decimators (replacements for Xilinx FIR Compiler
# cores) against the filter's definition.
HBDEC_SRCS := \
  $(ROOT)/src/rtl/dsp/hbdec47.v \
  $(ROOT)/src/rtl/dsp/hbdec1.v \
  $(ROOT)/src/rtl/dsp/hbdec2.v

# What the reference chain of a golden bench needs besides its own sources
# when the device under test is a netlist: this design's halfband decimators
# (the Ettus receive chain instantiates them by name), the setting register
# and the multiplier macro.
POSTSYN_REF_SRCS := $(HBDEC_SRCS) \
  $(ROOT)/src/rtl/control/setting_reg.v \
  $(ROOT)/src/ip/xilinx_macros.v

# Optional: a UHD checkout's fpga/ directory.  It holds the two FIR Compiler
# netlists of the stock B200 image (usrp3/top/b200/coregen_dsp/hbdec[12].v),
# which are Xilinx's and are not kept here.  `make test-dsp-netlist
# UHD_FPGA=<uhd>/fpga` runs the halfbands, and the whole receive chain,
# against them.
UHD_FPGA ?=

# Two-channel symmetry: the RX and TX chains instantiated twice, compared
# byte for byte, with a third RX chain as an untouched reference.
PAIR_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_pair.v

FRAMER_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_rx_framer.v


.PHONY: help test test-data test-dsp test-dsp-postsyn test-dsp-netlist test-data2 elab sim tools tools-base tools-yosys tools-prjxray \
        shell toolchain build eye gate clean image-clean

help:
	@printf '%s\n' \
	  'B210 open FPGA flow (yosys + nextpnr-himbaechel + Project X-Ray)' \
	  '' \
	  '  make tools      Build the container image (yosys, Project X-Ray tools)' \
	  '  make toolchain  Build the place-and-route engine and the measuring UHD into .tools/' \
	  '  make build      Verilog -> build/fpga/usrp_b200.bin' \
	  '  make eye        AD9361 interface eye scan of that image on the board' \
	  '  make gate       Hardware acceptance of that image on the board' \
	  '  make test       Every simulation bench, the constraint check, the elaboration' \
	  '  make elab       Elaborate the complete design against the primitive models' \
	  '  make shell      Interactive shell in the container image' \
	  '  make clean      Remove this repository build/ directory' \
	  '  make image-clean  Remove the container images'

# ---------------------------------------------------------------------------
# Atomic toolchain images.
# ---------------------------------------------------------------------------

tools-base:
	$(CONTAINER_BUILD) -t $(BASE_IMAGE) \
	  -f $(ROOT)/container/base.Dockerfile $(ROOT)

tools-yosys: tools-base
	$(CONTAINER_BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(YOSYS_IMAGE) -f $(ROOT)/container/yosys.Dockerfile $(ROOT)

tools-prjxray: tools-base
	$(CONTAINER_BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(PRJXRAY_IMAGE) -f $(ROOT)/container/prjxray.Dockerfile $(ROOT)

tools: tools-yosys tools-prjxray
	$(CONTAINER_ENGINE) build \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  --build-arg YOSYS_IMAGE=$(YOSYS_IMAGE) \
	  --build-arg PRJXRAY_IMAGE=$(PRJXRAY_IMAGE) \
	  -t $(FPGA_IMAGE) -f $(ROOT)/container/toolchain.Dockerfile $(ROOT)

# ---------------------------------------------------------------------------
# The FPGA flow.  One path, three scripts:
#   scripts/toolchain.sh  place-and-route engine from pinned sources (.tools/)
#   scripts/build.sh      Verilog -> build/fpga/usrp_b200.bin
#   scripts/hw_gate.sh    hardware acceptance of that image on the board
# ---------------------------------------------------------------------------

toolchain:
	$(ROOT)/scripts/toolchain.sh
	$(ROOT)/scripts/toolchain.sh uhd

build:
	$(ROOT)/scripts/build.sh

eye:
	$(ROOT)/scripts/eyescan.sh $(FPGA_DIR)/usrp_b200.bin

gate:
	$(ROOT)/scripts/hw_gate.sh $(FPGA_DIR)/usrp_b200.bin

shell: tools
	@mkdir -p $(BUILD_DIR)
	@$(CONTAINER_RUN) -it $(FPGA_IMAGE) bash

test:
	@set -e   # .ONESHELL is on: without this the recipe only reports its LAST command
	@mkdir -p $(SIM_DIR)
	@rm -f $(SIM_DIR)/elab_iverilog.log $(SIM_DIR)/tb_gray_roundtrip.log \
	       $(SIM_DIR)/tb_cic_interp.log $(SIM_DIR)/tb_clip.log \
	       $(SIM_DIR)/tb_ctrl_abi.log $(SIM_DIR)/tb_b200_clk_gen.log \
	       $(SIM_DIR)/tb_axi_fifo_2clk_capacity.log \
	       $(SIM_DIR)/tb_axi_fifo_2clk_cdc.log $(SIM_DIR)/tb_axi_fifo_2clk_rate.log \
	       $(SIM_DIR)/tb_loopback2.log $(SIM_DIR)/tb_loopback2_rev.log
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -o elab_iverilog.vvp $(ELAB_SRCS) $(ROOT)/tests/sim/xilinx_prim_sim.v \
	  > elab_iverilog.log 2>&1 || \
	  { grep -v 'warning:' elab_iverilog.log | head -20; \
	    echo "ERROR: a source file is not legal Verilog-2005; see $(SIM_DIR)/elab_iverilog.log"; exit 1; }
	@echo "PASS: every source is legal Verilog-2005 (Icarus elaborates the full design)"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_gray_roundtrip \
	  -o tb_gray_roundtrip.vvp $(TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_gray_roundtrip.log tb_gray_roundtrip.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_gray_roundtrip.log || \
	  { echo "ERROR: Gray-code test failed; see $(SIM_DIR)/tb_gray_roundtrip.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_axi_fifo_2clk_cdc \
	  -o tb_axi_fifo_2clk_cdc.vvp $(CDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_axi_fifo_2clk_cdc.log tb_axi_fifo_2clk_cdc.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_axi_fifo_2clk_cdc.log || \
	  { echo "ERROR: CDC FIFO integrity test failed; see $(SIM_DIR)/tb_axi_fifo_2clk_cdc.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_axi_fifo_2clk_rate \
	  -o tb_axi_fifo_2clk_rate.vvp $(CDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_axi_fifo_2clk_rate.log tb_axi_fifo_2clk_rate.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_axi_fifo_2clk_rate.log || \
	  { echo "ERROR: CDC FIFO throughput test failed; see $(SIM_DIR)/tb_axi_fifo_2clk_rate.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_axi_fifo_2clk_capacity \
	  -o tb_axi_fifo_2clk_capacity.vvp $(CDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_axi_fifo_2clk_capacity.log tb_axi_fifo_2clk_capacity.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_axi_fifo_2clk_capacity.log || \
	  { echo "ERROR: CDC FIFO capacity/ordering test failed; see $(SIM_DIR)/tb_axi_fifo_2clk_capacity.log"; exit 1; }
	# Gray-pointer integrity must not depend on the two clocks' ratio or
	# phase: same bench, five relationships (nominal, quarter-phase, far
	# ratio, 10:1 slow bus, radio faster than bus).
	cd $(SIM_DIR) && for args in "" \
	    "+TSLOW=8.138 +TFAST=5.0 +TPHASE=2.5" \
	    "+TSLOW=9.09 +TFAST=4.55 +TPHASE=3.3" \
	    "+TSLOW=8.138 +TFAST=50.0 +TPHASE=1.7" \
	    "+TSLOW=4.0 +TFAST=5.0 +TPHASE=0.0"; do \
	  $(VVP) -l tb_cdc_phase.log tb_axi_fifo_2clk_cdc.vvp $$args; \
	  grep -q '^PASS:' tb_cdc_phase.log || \
	    { echo "ERROR: CDC integrity broken at $$args; see $(SIM_DIR)/tb_cdc_phase.log"; exit 1; }; \
	done
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_cic_interp \
	  -o tb_cic_interp.vvp $(CIC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_cic_interp.log tb_cic_interp.vvp
	@grep -q '^PASS: CIC interpolator' $(SIM_DIR)/tb_cic_interp.log || \
	  { echo "ERROR: CIC interpolator test failed; see $(SIM_DIR)/tb_cic_interp.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_clip \
	  -o tb_clip.vvp $(CLIP_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_clip.log tb_clip.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_clip.log || \
	  { echo "ERROR: clip test failed; see $(SIM_DIR)/tb_clip.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_reset_sync \
	  -o tb_reset_sync.vvp $(RESET_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_reset_sync.log tb_reset_sync.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_reset_sync.log || \
	  { echo "ERROR: reset synchroniser test failed; see $(SIM_DIR)/tb_reset_sync.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_ctrl_abi \
	  -o tb_ctrl_abi.vvp $(CTRL_ABI_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_ctrl_abi.log tb_ctrl_abi.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ctrl_abi.log || \
	  { echo "ERROR: control-ABI test failed; see $(SIM_DIR)/tb_ctrl_abi.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_b200_clk_gen \
	  -o tb_b200_clk_gen.vvp $(CLK_GEN_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_b200_clk_gen.log tb_b200_clk_gen.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_b200_clk_gen.log || \
	  { echo "ERROR: clock-plan test failed; see $(SIM_DIR)/tb_b200_clk_gen.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_usb_rate -o tb_usb_rate.vvp $(USB_RATE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_usb_rate.log tb_usb_rate.vvp
	@grep -q '^USB-RATE: PASS' $(SIM_DIR)/tb_usb_rate.log || \
	  { echo "ERROR: USB-level throughput or stream integrity below requirement; see $(SIM_DIR)/tb_usb_rate.log"; exit 1; }
	cd $(SIM_DIR) && $(VVP) -n -l tb_usb_rate_neg.log tb_usb_rate.vvp +NEG_SLOW > /dev/null
	@grep -q '^USB-RATE: FAIL' $(SIM_DIR)/tb_usb_rate_neg.log && ! grep -q '^USB-RATE: PASS' $(SIM_DIR)/tb_usb_rate_neg.log || \
	  { echo "ERROR: tb_usb_rate did not catch a link below the sample rate; see $(SIM_DIR)/tb_usb_rate_neg.log"; exit 1; }
	@echo "PASS: tb_usb_rate fails, as it must, on a link below the sample rate"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_gpif_iob_equiv -o tb_gpif_iob_equiv.vvp $(GPIF_IOB_EQUIV_SRCS)
	cd $(SIM_DIR) && $(VVP) -n -l tb_gpif_iob_equiv.log tb_gpif_iob_equiv.vvp +cycles=300000 > /dev/null
	@grep -q '^PASS:' $(SIM_DIR)/tb_gpif_iob_equiv.log || \
	  { echo "ERROR: gpif2_slave_fifo32 differs from its reference; see $(SIM_DIR)/tb_gpif_iob_equiv.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_adc_pins -o tb_adc_pins.vvp $(ADC_PINS_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_adc_pins.log tb_adc_pins.vvp
	@grep -q '^ADC-PINS: PASS' $(SIM_DIR)/tb_adc_pins.log || \
	  { echo "ERROR: AD9361 pin-level I/Q capture broken; see $(SIM_DIR)/tb_adc_pins.log"; exit 1; }
	@cd $(SIM_DIR) && for neg in NEG_SWAP NEG_DROP NEG_X; do \
	  $(VVP) -n -l tb_adc_pins_neg.log tb_adc_pins.vvp +$$neg > /dev/null; \
	  grep -q '^ADC-PINS: FAIL' tb_adc_pins_neg.log && ! grep -q '^ADC-PINS: PASS' tb_adc_pins_neg.log || \
	    { echo "ERROR: tb_adc_pins did not catch +$$neg; see $(SIM_DIR)/tb_adc_pins_neg.log"; exit 1; }; \
	done
	@echo "PASS: tb_adc_pins fails, as it must, on swapped I/Q, a lost sample and an undriven pin"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_adc_mimo -o tb_adc_mimo.vvp $(ADC_MIMO_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_adc_mimo.log tb_adc_mimo.vvp
	@grep -q '^ADC-MIMO: PASS' $(SIM_DIR)/tb_adc_mimo.log || \
	  { echo "ERROR: MIMO alternating capture broken; see $(SIM_DIR)/tb_adc_mimo.log"; exit 1; }
	@cd $(SIM_DIR) && for neg in NEG_CHSWAP NEG_IQSWAP NEG_X; do \
	  $(VVP) -n -l tb_adc_mimo_neg.log tb_adc_mimo.vvp +$$neg > /dev/null; \
	  grep -q '^ADC-MIMO: FAIL' tb_adc_mimo_neg.log && ! grep -q '^ADC-MIMO: PASS' tb_adc_mimo_neg.log || \
	    { echo "ERROR: tb_adc_mimo did not catch +$$neg; see $(SIM_DIR)/tb_adc_mimo_neg.log"; exit 1; }; \
	done
	@echo "PASS: tb_adc_mimo fails, as it must, on swapped channels, swapped I/Q and an undriven pin"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_io_handover -o tb_io_handover.vvp $(IO_HANDOVER_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_io_handover.log tb_io_handover.vvp
	@grep -q '^PASS: samples cross to radio_clk whole' $(SIM_DIR)/tb_io_handover.log || \
	  { echo "ERROR: receive hand-over to radio_clk broken; see $(SIM_DIR)/tb_io_handover.log"; exit 1; }
	# The whole receive path, ADC pins to USB words, with the bench in UHD's
	# place (tests/tb_e2e_rx.v).  Every case checks every received sample
	# against the pins and the sample count against what the DDC produced.
	#   stall     100 us stalls of the FX3 every 400 us: absorbed, nothing lost
	#   stall30   one 30 us stall, and it is repaid by the time of the stop
	#   oversize  4080 samples per packet, UHD's largest request by default
	#             (8176-byte frames, sc8 wire format): honoured as written,
	#             at the sample rate, nothing lost
	#   overrun   an 800 us stall, longer than the 630 us of samples the FIFOs
	#             hold at 61.44 MS/s: the stock sequence (packet closed, one
	#             error packet with code 8, streaming stops), then the stream
	#             command again, as UHD's overflow handler issues it, and the
	#             stream is back at the sample rate with 2040-sample packets
	#             (UHD's default for sc16)
	# The cases are compiled one after the other and simulated $(E2E_JOBS) at a
	# time, the long ones first.
	@cd $(SIM_DIR) && for run in $(E2E_RUNS); do \
	  case $$run in \
	    base)  flags="";; \
	    fs)    flags="-DAMP=2047";; \
	    fslo)  flags="-DAMP=2047 -DPHINC=536870912";; \
	    two)   flags="-DTWOTONE";; \
	    noisy) flags="-DNOISY";; \
	    stall) flags="-DSTALL -DSTALL_START=10000 -DSTALL_CLKS=10000 -DSTALL_PERIOD=40000 -DE2E_RUNCLK=80000";; \
	    stall30) flags="-DSTALL -DSTALL_START=10000 -DSTALL_CLKS=3000 -DSTALL_PERIOD=100000000 -DE2E_RUNCLK=100000 -DE2E_REPAID";; \
	    oversize) flags="-DE2E_SC8 -DNOISY -DE2E_MAXLEN=4080 -DE2E_RUNCLK=100000";; \
	    overrun) flags="-DSTALL -DSTALL_START=10000 -DSTALL_CLKS=80000 -DSTALL_PERIOD=100000000 -DE2E_MAXLEN=2040 -DE2E_RUNCLK=40000 -DE2E_OVERRUN";; \
	  esac; \
	  $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	    $$flags -s tb_e2e_rx -o tb_e2e_$$run.vvp $(E2E_TEST_SRCS) || exit 1; \
	  rm -f tb_e2e_$$run.log; \
	done
	@cd $(SIM_DIR) && rm -f tb_e2e_neg.log && \
	  { printf '%s\n' $(E2E_RUNS) | xargs -P $(E2E_JOBS) -I{} \
	      sh -c '$(VVP) -n -l tb_e2e_{}.log tb_e2e_{}.vvp > /dev/null' & runs=$$!; \
	    $(VVP) -n -l tb_e2e_neg.log tb_e2e_base.vvp +NEG_IQSWAP > /dev/null; \
	    wait $$runs; }
	@for run in $(E2E_RUNS); do \
	  grep -h '^E2E: PASS' $(SIM_DIR)/tb_e2e_$$run.log | sed "s/^E2E: PASS/PASS: e2e $$run/" || \
	    { grep -h '^E2E' $(SIM_DIR)/tb_e2e_$$run.log; \
	      echo "ERROR: end-to-end run $$run failed; see $(SIM_DIR)/tb_e2e_$$run.log"; exit 1; }; \
	done
	@grep -q '^E2E: FAIL' $(SIM_DIR)/tb_e2e_neg.log && ! grep -q '^E2E: PASS' $(SIM_DIR)/tb_e2e_neg.log || \
	  { echo "ERROR: tb_e2e_rx did not catch I and Q swapped at the pins; see $(SIM_DIR)/tb_e2e_neg.log"; exit 1; }
	@echo "PASS: tb_e2e_rx fails, as it must, with I and Q swapped at the pins"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_rx_codes -o tb_rx_codes.vvp $(RX_CODES_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_rx_codes.log tb_rx_codes.vvp
	@grep -q 'RX-CODES: PASS' $(SIM_DIR)/tb_rx_codes.log || \
	  { echo "ERROR: RX static transfer curve wrong; see $(SIM_DIR)/tb_rx_codes.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_rx_saturate -o tb_rx_saturate.vvp $(RX_SAT_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_rx_saturate.log tb_rx_saturate.vvp
	@grep -q 'RX-SAT: PASS' $(SIM_DIR)/tb_rx_saturate.log || \
	  { echo "ERROR: RX overload wraps instead of clipping; see $(SIM_DIR)/tb_rx_saturate.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 \
	  -s tb_dac_slice -o tb_dac_slice.vvp $(DAC_SLICE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_dac_slice.log tb_dac_slice.vvp
	@grep -q 'DAC-SLICE: PASS' $(SIM_DIR)/tb_dac_slice.log || \
	  { echo "ERROR: DAC pin quantiser wrong; see $(SIM_DIR)/tb_dac_slice.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_dc -o tb_tx_dc.vvp $(TX_DC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_dc.log tb_tx_dc.vvp
	@grep -q 'TX-DC: PASS' $(SIM_DIR)/tb_tx_dc.log || \
	  { echo "ERROR: TX DC gain, scale word or overload handling wrong; see $(SIM_DIR)/tb_tx_dc.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_latency -o tb_latency.vvp $(LATENCY_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_latency.log tb_latency.vvp
	@grep -q 'LATENCY: PASS' $(SIM_DIR)/tb_latency.log || \
	  { echo "ERROR: datapath latency outside its bounds; see $(SIM_DIR)/tb_latency.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_passband -o tb_tx_passband.vvp $(PASSBAND_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_passband.log tb_tx_passband.vvp
	@grep -q 'PASSBAND: PASS' $(SIM_DIR)/tb_tx_passband.log || \
	  { echo "ERROR: TX passband flatness wrong; see $(SIM_DIR)/tb_tx_passband.log"; exit 1; }
	cd $(ROOT) && $(MAKE) --no-print-directory test-data

# The data-path benches (end-to-end, RX/TX DSP, pins): kept in a separate
# target because .ONESHELL passes each target's recipe to a single shell, and
# this many benches overflow MAX_ARG_STRLEN (the measured failure: bash:
# Argument list too long).
test-data:
	@set -e
	mkdir -p $(SIM_DIR)
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_pins -o tb_tx_pins.vvp $(TX_PINS_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_pins.log tb_tx_pins.vvp
	@grep -q '^TX-PINS: PASS' $(SIM_DIR)/tb_tx_pins.log || \
	  { echo "ERROR: TX I/Q pin sequence broken; see $(SIM_DIR)/tb_tx_pins.log"; exit 1; }
	@cd $(SIM_DIR) && for neg in NEG_SWAP NEG_X; do \
	  $(VVP) -n -l tb_tx_pins_neg.log tb_tx_pins.vvp +$$neg > /dev/null; \
	  grep -q '^TX-PINS: FAIL' tb_tx_pins_neg.log && ! grep -q '^TX-PINS: PASS' tb_tx_pins_neg.log || \
	    { echo "ERROR: tb_tx_pins did not catch +$$neg; see $(SIM_DIR)/tb_tx_pins_neg.log"; exit 1; }; \
	done
	@echo "PASS: tb_tx_pins fails, as it must, on swapped I/Q and an undefined bit"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_rx_stream -o tb_rx_stream.vvp $(RX_STREAM_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_rx_stream.log tb_rx_stream.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_rx_stream.log || \
	  { echo "ERROR: RX stream integrity test failed; see $(SIM_DIR)/tb_rx_stream.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_lossless -o tb_ddc_lossless.vvp $(LOSSLESS_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_ddc_lossless.log tb_ddc_lossless.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_lossless.log || \
	  { echo "ERROR: lossless-path test failed; see $(SIM_DIR)/tb_ddc_lossless.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_chain -o tb_ddc_chain.vvp $(DDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_ddc_chain.log tb_ddc_chain.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_chain.log || \
	  { echo "ERROR: DDC chain test failed; see $(SIM_DIR)/tb_ddc_chain.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_duc_chain -o tb_duc_chain.vvp $(DUC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_duc_chain.log tb_duc_chain.vvp
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_pair -o tb_pair.vvp $(PAIR_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_pair.log tb_pair.vvp
	@grep -q '^PASS: channels byte identical' $(SIM_DIR)/tb_pair.log || \
	  { echo "ERROR: two-channel symmetry test failed; see $(SIM_DIR)/tb_pair.log"; exit 1; }
	@grep -q '^PASS:' $(SIM_DIR)/tb_duc_chain.log || \
	  { echo "ERROR: DUC chain test failed; see $(SIM_DIR)/tb_duc_chain.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_rx_framer -o tb_rx_framer.vvp $(FRAMER_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_rx_framer.log tb_rx_framer.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_rx_framer.log || \
	  { echo "ERROR: RX framer test failed; see $(SIM_DIR)/tb_rx_framer.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_gpif2_error -o tb_gpif2_error.vvp $(GPIF_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_gpif2_error.log tb_gpif2_error.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_gpif2_error.log || \
	  { echo "ERROR: GPIF error-checker test failed; see $(SIM_DIR)/tb_gpif2_error.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_gpif_cdc -o tb_gpif_cdc.vvp $(GPIF_CDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_gpif_cdc.log tb_gpif_cdc.vvp
	@grep -q 'GPIF-CDC: PASS' $(SIM_DIR)/tb_gpif_cdc.log || \
	  { echo "ERROR: FX3 async boundary corrupts packets; see $(SIM_DIR)/tb_gpif_cdc.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_underrun -o tb_tx_underrun.vvp $(TX_UNDERRUN_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_underrun.log tb_tx_underrun.vvp
	@grep -q 'TX-UNDERRUN: PASS' $(SIM_DIR)/tb_tx_underrun.log || \
	  { echo "ERROR: TX underrun can present stale samples; see $(SIM_DIR)/tb_tx_underrun.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_timed -o tb_tx_timed.vvp $(TX_TIMED_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_timed.log tb_tx_timed.vvp
	@grep -q 'TX-TIMED: PASS' $(SIM_DIR)/tb_tx_timed.log || \
	  { echo "ERROR: timed transmit broken; see $(SIM_DIR)/tb_tx_timed.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_pairing -o tb_tx_pairing.vvp $(TX_PAIRING_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_tx_pairing.log tb_tx_pairing.vvp
	@grep -q 'TX-PAIR: PASS' $(SIM_DIR)/tb_tx_pairing.log || \
	  { echo "ERROR: TX sample pairing broken; see $(SIM_DIR)/tb_tx_pairing.log"; exit 1; }
	cd $(ROOT) && $(MAKE) --no-print-directory test-dsp

# The radio DSP against its references (a separate target for the same
# MAX_ARG_STRLEN reason as above).
#
#   tb_hbdec        the receive halfband decimators against the 47-tap sum
#   tb_ddc_golden   receive chain against the Ettus original, every rate
#   tb_duc_golden   transmit chain against the Ettus original, every rate
#
# Each golden bench is then run once more with a deliberate defect in the
# chain under test only (the decimation word withheld; a scale word 1.69 dB
# off).  Those runs must FAIL: a bench that cannot fail proves nothing.
test-dsp:
	@set -e
	mkdir -p $(SIM_DIR)
	python3 $(ROOT)/tests/mk_ettus_ref.py $(SIM_DIR)/ettus_ref
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hbdec -o tb_hbdec.vvp \
	  $(HBDEC_SRCS) $(ROOT)/tests/tb_hbdec.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_hbdec.log tb_hbdec.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec.log || \
	  { echo "ERROR: receive halfband decimators differ from their definition; see $(SIM_DIR)/tb_hbdec.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_golden -o tb_ddc_golden.vvp $(DSP_GOLDEN_SRCS) ettus_ref/*.v $(ROOT)/tests/tb_ddc_golden.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_ddc_golden.log tb_ddc_golden.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_golden.log || \
	  { echo "ERROR: receive DSP differs from the Ettus original; see $(SIM_DIR)/tb_ddc_golden.log"; exit 1; }
	cd $(SIM_DIR) && $(VVP) -n -l tb_ddc_golden_neg.log tb_ddc_golden.vvp +NEG_RATE_REG +NCFG=5 > /dev/null
	@grep -q '^FAIL:' $(SIM_DIR)/tb_ddc_golden_neg.log && ! grep -q '^PASS:' $(SIM_DIR)/tb_ddc_golden_neg.log || \
	  { echo "ERROR: tb_ddc_golden did not catch a chain that ignores the decimation word; see $(SIM_DIR)/tb_ddc_golden_neg.log"; exit 1; }
	@echo "PASS: tb_ddc_golden fails, as it must, on a chain that ignores the decimation word"
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_duc_golden -o tb_duc_golden.vvp $(DSP_GOLDEN_SRCS) ettus_ref/*.v $(ROOT)/tests/tb_duc_golden.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_duc_golden.log tb_duc_golden.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_duc_golden.log || \
	  { echo "ERROR: transmit DSP differs from the Ettus original; see $(SIM_DIR)/tb_duc_golden.log"; exit 1; }
	cd $(SIM_DIR) && $(VVP) -n -l tb_duc_golden_neg.log tb_duc_golden.vvp +NEG_SCALE_REG +NCFG=4 > /dev/null
	@grep -q '^FAIL:' $(SIM_DIR)/tb_duc_golden_neg.log && ! grep -q '^PASS:' $(SIM_DIR)/tb_duc_golden_neg.log || \
	  { echo "ERROR: tb_duc_golden did not catch a chain 1.69 dB off the stock level; see $(SIM_DIR)/tb_duc_golden_neg.log"; exit 1; }
	@echo "PASS: tb_duc_golden fails, as it must, on a chain 1.69 dB off the stock level"
	cd $(ROOT) && $(MAKE) --no-print-directory test-dsp-postsyn

# The radio DSP once more, on what the board runs: the netlist yosys makes of
# it with the build's flags (tests/postsyn.sh, in the container).  A synthesis
# tool can get a signed product wrong where every RTL simulation is right;
# yosys 0.69 does (tests/yosys_dsp_signext.v), and it cost the old receive
# mixer its sign on hardware.
#
#   tb_yosys_dsp_signext   the reproducer: netlist against RTL, and yosys'
#                          `check` after DSP mapping, which must agree
#   tb_hbdec -DPOSTSYN     halfband decimator netlists, all 47 output bits
#   tb_ddc_golden -DPOSTSYN  receive chain netlist against the Ettus original
#   tb_duc_golden -DPOSTSYN  transmit chain netlist against the Ettus original
#                          (decimation / interpolation 1, 2, 3, 4, 8, 16, 128)
#   check_dsp_packing.py   the complete design: no register bit left dangling
#                          by the DSP mapping
#
# The three netlist simulations and the check of the complete design take a
# minute or two each and run side by side.
test-dsp-postsyn:
	@set -e
	mkdir -p $(SIM_DIR)/postsyn
	python3 $(ROOT)/tests/mk_ettus_ref.py $(SIM_DIR)/ettus_ref
	cd $(ROOT) && $(CONTAINER_RUN) $(FPGA_IMAGE) bash tests/postsyn.sh netlists $(SIM_DIR_REL)/postsyn
	( cd $(ROOT) && $(CONTAINER_RUN) $(FPGA_IMAGE) bash tests/postsyn.sh design $(SIM_DIR_REL)/postsyn < /dev/null ) & design=$$!
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_yosys_dsp_signext -o tb_yosys_dsp_signext.vvp \
	  $(ROOT)/tests/yosys_dsp_signext.v postsyn/signext_plain_syn.v postsyn/signext_rst_syn.v \
	  postsyn/signext_en_syn.v postsyn/cells_sim.v $(ROOT)/tests/tb_yosys_dsp_signext.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_yosys_dsp_signext.log tb_yosys_dsp_signext.vvp > /dev/null
	python3 $(ROOT)/tests/check_dsp_packing.py reproducer $(SIM_DIR)/postsyn $(SIM_DIR)/tb_yosys_dsp_signext.log
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -DPOSTSYN -s tb_hbdec -o tb_hbdec_syn.vvp \
	  postsyn/hbdec1_syn.v postsyn/hbdec2_syn.v postsyn/cells_sim.v $(ROOT)/tests/tb_hbdec.v
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -DPOSTSYN -s tb_ddc_golden -o tb_ddc_golden_syn.vvp \
	  postsyn/ddc_chain_syn.v postsyn/cells_sim.v ettus_ref/*.v $(POSTSYN_REF_SRCS) $(ROOT)/tests/tb_ddc_golden.v
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -DPOSTSYN -s tb_duc_golden -o tb_duc_golden_syn.vvp \
	  postsyn/duc_chain_syn.v postsyn/cells_sim.v ettus_ref/*.v $(POSTSYN_REF_SRCS) $(ROOT)/tests/tb_duc_golden.v
	( cd $(SIM_DIR) && $(VVP) -n -l tb_hbdec_syn.log tb_hbdec_syn.vvp +NCYC=6000 > /dev/null ) & hb=$$!
	( cd $(SIM_DIR) && $(VVP) -n -l tb_ddc_golden_syn.log tb_ddc_golden_syn.vvp +CFGMASK=bf +NSETTLE=24 +NMEAS=8 > /dev/null ) & rx=$$!
	( cd $(SIM_DIR) && $(VVP) -n -l tb_duc_golden_syn.log tb_duc_golden_syn.vvp +CFGMASK=30bf +NSETTLE=24 +NMEAS=8 > /dev/null ) & tx=$$!
	wait $$hb; wait $$rx; wait $$tx; wait $$design
	@grep -v 'finish called' $(SIM_DIR)/tb_hbdec_syn.log $(SIM_DIR)/tb_ddc_golden_syn.log $(SIM_DIR)/tb_duc_golden_syn.log | cut -d: -f2-
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec_syn.log || \
	  { echo "ERROR: synthesized halfband decimators differ from their definition; see $(SIM_DIR)/tb_hbdec_syn.log"; exit 1; }
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_golden_syn.log || \
	  { echo "ERROR: synthesized receive DSP differs from the Ettus original; see $(SIM_DIR)/tb_ddc_golden_syn.log"; exit 1; }
	@grep -q '^PASS:' $(SIM_DIR)/tb_duc_golden_syn.log || \
	  { echo "ERROR: synthesized transmit DSP differs from the Ettus original; see $(SIM_DIR)/tb_duc_golden_syn.log"; exit 1; }
	python3 $(ROOT)/tests/check_dsp_packing.py design $(SIM_DIR)/postsyn
	cd $(ROOT) && $(MAKE) --no-print-directory test-data2

# The receive halfbands, and the receive chain built on them, against the
# Xilinx FIR Compiler netlists of the stock image.  Not part of `make test`:
# the netlists are not in this repository, and gate-level simulation of both
# takes several minutes.
test-dsp-netlist:
	@set -e
	test -n "$(UHD_FPGA)" || { echo "usage: make test-dsp-netlist UHD_FPGA=<uhd checkout>/fpga"; exit 1; }
	mkdir -p $(SIM_DIR)
	python3 $(ROOT)/tests/mk_ettus_ref.py $(SIM_DIR)/ettus_ref_net \
	  --netlists $(UHD_FPGA)/usrp3/top/b200/coregen_dsp
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hbdec_netlist -o tb_hbdec_netlist.vvp \
	  $(HBDEC_SRCS) ettus_ref_net/ettus_hbdec1.v ettus_ref_net/ettus_hbdec2.v \
	  $(ROOT)/tests/sim/spartan6_prim_sim.v $(ROOT)/tests/tb_hbdec_netlist.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_hbdec_netlist.log tb_hbdec_netlist.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec_netlist.log || \
	  { echo "ERROR: halfband decimators differ from the vendor netlists; see $(SIM_DIR)/tb_hbdec_netlist.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_golden -o tb_ddc_golden_net.vvp $(DSP_GOLDEN_SRCS) ettus_ref_net/*.v \
	  $(ROOT)/tests/sim/spartan6_prim_sim.v $(ROOT)/tests/tb_ddc_golden.v
	cd $(SIM_DIR) && $(VVP) -n -l tb_ddc_golden_net.log tb_ddc_golden_net.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_golden_net.log || \
	  { echo "ERROR: receive DSP differs from the stock chain with its vendor halfbands; see $(SIM_DIR)/tb_ddc_golden_net.log"; exit 1; }

# The last block of data-path benches (loopback2, airloop, phase, retune,
# rates).  Chained after test-data.
test-data2:
	@set -e
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_loopback2 -o tb_loopback2.vvp $(LOOP2_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_loopback2.log tb_loopback2.vvp
	@grep -q 'LOOP2-FWD: PASS' $(SIM_DIR)/tb_loopback2.log || \
	  { echo "ERROR: two-channel TX->RX loopback failed; see $(SIM_DIR)/tb_loopback2.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -DREVERSE -I $(ROOT)/src/rtl/control \
	  -s tb_loopback2 -o tb_loopback2_rev.vvp $(LOOP2_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_loopback2_rev.log tb_loopback2_rev.vvp
	@grep -q 'LOOP2-REV: PASS' $(SIM_DIR)/tb_loopback2_rev.log || \
	  { echo "ERROR: two-channel RX->TX loopback failed; see $(SIM_DIR)/tb_loopback2_rev.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_airloop -o tb_airloop.vvp $(AIR_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_airloop.log tb_airloop.vvp
	@grep -q 'AIR-FWD: PASS' $(SIM_DIR)/tb_airloop.log || \
	  { echo "ERROR: air-path TX->RX loop failed; see $(SIM_DIR)/tb_airloop.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -DREVERSE -I $(ROOT)/src/rtl/control \
	  -s tb_airloop -o tb_airloop_rev.vvp $(AIR_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_airloop_rev.log tb_airloop_rev.vvp
	@grep -q 'AIR-REV: PASS' $(SIM_DIR)/tb_airloop_rev.log || \
	  { echo "ERROR: air-path RX->TX loop failed; see $(SIM_DIR)/tb_airloop_rev.log"; exit 1; }
	@cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_clkmux -o tb_clkmux.vvp $(CLKMUX_TEST_SRCS)
	@cd $(SIM_DIR) && $(VVP) -n tb_clkmux.vvp | tee tb_clkmux.log | grep -E 'CLKMUX'
	@grep -q 'CLKMUX: PASS - no pulse' $(SIM_DIR)/tb_clkmux.log || \
	  { echo "ERROR: MIMO clock mux produced runt pulses; see $(SIM_DIR)/tb_clkmux.log"; exit 1; }
	@grep -q 'CLKMUX: PASS - reverse switch also clean' $(SIM_DIR)/tb_clkmux.log || \
	  { echo "ERROR: MIMO clock mux reverse switch dirty; see $(SIM_DIR)/tb_clkmux.log"; exit 1; }
	@cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_atr -o tb_atr.vvp $(ATR_TEST_SRCS)
	@cd $(SIM_DIR) && $(VVP) -n tb_atr.vvp | tee tb_atr.log | grep -E 'ATR'
	@grep -q 'ATR: PASS' $(SIM_DIR)/tb_atr.log || \
	  { echo "ERROR: frontend ATR/PA-enable path wrong; see $(SIM_DIR)/tb_atr.log"; exit 1; }
	@cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_ctrl_fifo -o tb_ctrl_fifo.vvp $(CTRL_FIFO_TEST_SRCS)
	@cd $(SIM_DIR) && $(VVP) -n tb_ctrl_fifo.vvp | tee tb_ctrl_fifo.log | grep -E 'PASS: ctrl path|FAIL'
	@grep -q 'PASS: ctrl path' $(SIM_DIR)/tb_ctrl_fifo.log || \
	  { echo "ERROR: control path through the FX3 interface broken; see $(SIM_DIR)/tb_ctrl_fifo.log"; exit 1; }
	@cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_spi -o tb_spi.vvp $(SPI_TEST_SRCS)
	@cd $(SIM_DIR) && $(VVP) -n tb_spi.vvp | tee tb_spi.log | grep -E 'SPI'
	@grep -q 'SPI: PASS' $(SIM_DIR)/tb_spi.log || \
	  { echo "ERROR: SPI master cannot configure the codec; see $(SIM_DIR)/tb_spi.log"; exit 1; }
	@cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_tx_retune -o tb_tx_retune.vvp $(RETUNE_TEST_SRCS)
	@cd $(SIM_DIR) && $(VVP) -n tb_tx_retune.vvp | tee tb_tx_retune.log | grep -E 'RETUNE:'
	@grep -q 'RETUNE: PASS' $(SIM_DIR)/tb_tx_retune.log || \
	  { echo "ERROR: a transmitter settings write disturbs the stream; see $(SIM_DIR)/tb_tx_retune.log"; exit 1; }
	@cd $(ROOT) && python3 scripts/check_rates.py

# The second half of the data-path benches.  Split off test-data because
# .ONESHELL passes each recipe to one shell as a single argument, and the
# expanded source lists overflow MAX_ARG_STRLEN (the measured failure:
# bash: Argument list too long) once the recipe grew past it again.
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_phase -o tb_phase.vvp $(PHASE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_phase.log tb_phase.vvp
	@grep -q 'PHASE: PASS' $(SIM_DIR)/tb_phase.log || \
	  { echo "ERROR: TX chain is not linear phase; see $(SIM_DIR)/tb_phase.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s tb_axi_packet_gate -o tb_axi_packet_gate.vvp $(GATE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_axi_packet_gate.log tb_axi_packet_gate.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_axi_packet_gate.log || \
	  { echo "ERROR: packet-gate test failed; see $(SIM_DIR)/tb_axi_packet_gate.log"; exit 1; }
	@python3 $(ROOT)/tests/test_bit2bin.py
	@python3 $(ROOT)/tests/test_constraints.py
	@$(MAKE) --no-print-directory -C $(ROOT) elab

# Elaborate the complete design in the host simulator.  This is the cheapest
# guard that the repository still describes hardware a simulator can accept:
# it needs no vendor licence and no container.
elab:
	@mkdir -p $(SIM_DIR)
	cd $(ROOT) && $(IVERILOG) -g2005 -I $(ROOT)/src/rtl/control \
	  -s b200 -o $(SIM_DIR)/b200_elab.vvp $(ELAB_SRCS) $(ROOT)/tests/sim/xilinx_prim_sim.v \
	  2> $(SIM_DIR)/b200_elab.log
	@echo "PASS: full design elaborates ($(words $(ELAB_SRCS)) sources, 0 errors)"


sim: test

clean:
	@set -e
	target="$(BUILD_DIR)"
	expected="$(ROOT)/build"
	if [ "$$target" != "$$expected" ]; then
	  echo "ERROR: refusing to remove unexpected path: $$target"; exit 1
	fi
	if [ -d "$$target" ]; then rm -rf -- "$$target"; fi

image-clean:
	@$(CONTAINER_ENGINE) rmi -f $(FPGA_IMAGE) $(YOSYS_IMAGE) \
	  $(PRJXRAY_IMAGE) $(BASE_IMAGE) 2>/dev/null || true
