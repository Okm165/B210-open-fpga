# B210 Open FPGA build.
#
# Yosys synthesizes the B200/B210 Verilog RTL, nextpnr-himbaechel places and
# routes it for the Kintex-7 fabric, and Project X-Ray writes the bitstream.
# The container images are atomic; see container/.

.DEFAULT_GOAL := help
.ONESHELL:
.NOTPARALLEL:
SHELL := /bin/bash

ROOT       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  := $(ROOT)/build
FPGA_DIR   := $(BUILD_DIR)/fpga
SIM_DIR    := $(BUILD_DIR)/sim
SIM_DIR_REL:= build/sim

# The repository is mounted here inside the toolchain image. Keeping this
# path stable makes the Yosys netlist independent of the checkout location.
CR := /work

TOP                     ?= b200
FPGA_PART               ?= xc7k325tffg676-1
FPGA_ALLOW_TIMING_FAIL  ?= 0
FPGA_HOME               ?= /opt/fpga
DIE                     := $(shell printf '%s\n' '$(FPGA_PART)' | sed -E 's/^(xc7[azkv][0-9]+t?).*/\1/')
CHIPDB                  ?= $(FPGA_HOME)/share/nextpnr/himbaechel/xilinx/chipdb-$(DIE).bin
PRJXRAY_DB              ?= $(FPGA_HOME)/share/prjxray-db

CFPGA      := $(CR)/build/fpga
CSYNTH_JSON := $(CFPGA)/synth/$(TOP).json
CFASM      := $(CFPGA)/pnr/$(TOP).fasm
CFRAMES    := $(CFPGA)/pnr/$(TOP).frames
CBIT       := $(CFPGA)/bitstream/$(TOP).bit
CBIN       := $(CFPGA)/bitstream/$(TOP).bin
CUHD_BIN   := $(CFPGA)/bitstream/usrp_b210_fpga.bin
CXDC       := $(CR)/src/constraints/b210.xdc
CSOURCES   := $(addprefix $(CR)/,$(shell cat $(ROOT)/scripts/sources.txt 2>/dev/null))

IVERILOG ?= iverilog
VVP      ?= vvp

CONTAINER_ENGINE ?= podman
TAG              ?= 0.1.0
BASE_IMAGE       ?= b210-open-fpga-base:$(TAG)
YOSYS_IMAGE      ?= b210-open-fpga-yosys:$(TAG)
NEXTPNR_IMAGE    ?= b210-open-fpga-nextpnr:$(TAG)
PRJXRAY_IMAGE    ?= b210-open-fpga-prjxray:$(TAG)
FPGA_IMAGE       ?= b210-open-fpga:$(TAG)

ifeq ($(CONTAINER_ENGINE),podman)
CONTAINER_USER_FLAGS := --userns=keep-id
else
CONTAINER_USER_FLAGS := --user $(shell id -u):$(shell id -g)
endif

CONTAINER_RUN := $(CONTAINER_ENGINE) run --rm -i $(CONTAINER_USER_FLAGS) \
  -v "$(ROOT):$(CR):z" -w "$(CR)" -e HOME="$(CR)/build"
CONTAINER_ENV := -e FPGA_PART=$(FPGA_PART) -e FPGA_HOME=$(FPGA_HOME)
CONTAINER_BUILD := $(CONTAINER_ENGINE) build --build-arg JOBS=$(shell nproc)

TEST_SRCS := \
  $(ROOT)/src/rtl/control/bin2gray.v \
  $(ROOT)/src/rtl/control/gray2bin.v \
  $(ROOT)/tests/tb_gray_roundtrip.v

HB_TEST_SRCS := \
  $(ROOT)/src/ip/hbdec.v \
  $(ROOT)/tests/tb_hbdec_impulse.v

HB_RATE_TEST_SRCS := \
  $(ROOT)/src/ip/hbdec.v \
  $(ROOT)/tests/tb_hbdec_rate.v

CIC_TEST_SRCS := \
  $(ROOT)/src/rtl/dsp/cic_decim.v \
  $(ROOT)/src/rtl/dsp/cic_dec_shifter.v \
  $(ROOT)/src/rtl/dsp/sign_extend.v \
  $(ROOT)/tests/tb_cic_decim.v

CIC_INT_TEST_SRCS := \
  $(ROOT)/src/rtl/dsp/cic_interp.v \
  $(ROOT)/src/rtl/dsp/cic_int_shifter.v \
  $(ROOT)/src/rtl/dsp/sign_extend.v \
  $(ROOT)/tests/tb_cic_interp.v

CDC_TEST_SRCS := \
  $(ROOT)/tests/tb_axi_fifo_2clk_cdc.v \
  $(ROOT)/src/rtl/fifo/axi_fifo_2clk_sim.v \
  $(ROOT)/src/rtl/control/synchronizer.v \
  $(ROOT)/src/rtl/control/synchronizer_impl.v \
  $(ROOT)/src/rtl/control/bin2gray.v \
  $(ROOT)/src/rtl/control/gray2bin.v

RESET_TEST_SRCS := \
  $(ROOT)/src/rtl/control/reset_sync.v \
  $(ROOT)/src/rtl/control/synchronizer.v \
  $(ROOT)/src/rtl/control/synchronizer_impl.v \
  $(ROOT)/tests/tb_reset_sync.v

CORDIC_TEST_SRCS := \
  $(ROOT)/src/rtl/dsp/cordic_z24.v \
  $(ROOT)/src/rtl/dsp/cordic_stage.v \
  $(ROOT)/tests/tb_cordic.v

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

HELLO_TEST_SRCS := \
  $(ROOT)/tests/hello_world/hello_led.v \
  $(ROOT)/tests/hello_world/tb_hello_led.v

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

DDC_SINE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_ddc_sine.v

DUC_SINE_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_duc_sine.v

GPIF_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/tb_gpif2_error.v

DUC_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_duc_chain.v

FRAMER_TEST_SRCS := $(ELAB_SRCS) \
  $(ROOT)/tests/sim/xilinx_prim_sim.v \
  $(ROOT)/tests/tb_rx_framer.v

# The hello world is a second, tiny target that exercises exactly the same
# tools, flags and images as the B200 flow.  It proves the flow itself works.
HELLO_DIR   := $(BUILD_DIR)/hello
CHELLO      := $(CR)/build/hello

.PHONY: help doctor verify test elab equiv stages sim tools tools-base tools-yosys tools-nextpnr tools-prjxray \
        shell build synth pnr bitstream hello analyze timing clean image-clean

help:
	@printf '%s\n' \
	  'B210 Open FPGA build (Yosys + nextpnr + Project X-Ray)' \
	  '' \
	  '  make tools      Build the atomic images and the final toolchain' \
	  '  make build      Synthesize, place, route, and write the bitstream' \
	  '  make synth      Yosys synthesis only' \
	  '  make pnr        Place and route only (requires make synth)' \
	  '  make bitstream  FASM -> frames -> .bit/.bin (requires make pnr)' \
	  '  make analyze    Yosys netlist analysis' \
	  '  make timing     Print the nextpnr timing/utilization summary' \
	  '  make test       Run every bench, the constraint check, and the elaboration' \
	  '  make elab       Elaborate the complete design against the primitive models' \
	  '  make hello      Compile the hello world through the whole toolchain' \
	  '  make doctor     Check host tools and the toolchain image' \
	  '  make verify     Check the committed source state' \
	  '  make shell      Interactive shell in the toolchain image' \
	  '  make clean      Remove only this repository build/ directory' \
	  '  make image-clean # remove all toolchain images' \
	  '' \
	  'Overrides: CONTAINER_ENGINE=podman|docker FPGA_PART=... FPGA_ALLOW_TIMING_FAIL=1'

# ---------------------------------------------------------------------------
# Atomic toolchain images.
# ---------------------------------------------------------------------------

tools-base:
	$(CONTAINER_BUILD) -t $(BASE_IMAGE) \
	  -f $(ROOT)/container/base.Dockerfile $(ROOT)

tools-yosys: tools-base
	$(CONTAINER_BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(YOSYS_IMAGE) -f $(ROOT)/container/yosys.Dockerfile $(ROOT)

tools-nextpnr: tools-base
	$(CONTAINER_BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(NEXTPNR_IMAGE) -f $(ROOT)/container/nextpnr.Dockerfile $(ROOT)

tools-prjxray: tools-base
	$(CONTAINER_BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(PRJXRAY_IMAGE) -f $(ROOT)/container/prjxray.Dockerfile $(ROOT)

tools: tools-yosys tools-nextpnr tools-prjxray
	$(CONTAINER_ENGINE) build \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  --build-arg YOSYS_IMAGE=$(YOSYS_IMAGE) \
	  --build-arg NEXTPNR_IMAGE=$(NEXTPNR_IMAGE) \
	  --build-arg PRJXRAY_IMAGE=$(PRJXRAY_IMAGE) \
	  -t $(FPGA_IMAGE) -f $(ROOT)/container/toolchain.Dockerfile $(ROOT)

# ---------------------------------------------------------------------------
# Build stages. Each stage runs in the final image with the repository at
# /work, so the netlist does not depend on the host checkout path.
# ---------------------------------------------------------------------------

build: synth pnr bitstream analyze

synth: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) $(FPGA_IMAGE) bash -s <<-'EOF'
	set -euo pipefail
	mkdir -p $(CFPGA)/synth $(CFPGA)/logs $(CFPGA)/reports
	test -s $(CR)/scripts/sources.txt || { echo "ERROR: missing scripts/sources.txt"; exit 1; }
	for f in $(CSOURCES); do
	  test -f "$$f" || { echo "ERROR: missing source $$f"; exit 1; }
	done
	yosys -p "read_verilog -I $(CR)/src/rtl/control -D TARGET_B210 $(CSOURCES); synth_xilinx -flatten -abc9 -family xc7 -top $(TOP); write_json $(CSYNTH_JSON); stat" \
	  > $(CFPGA)/logs/synth.log 2>&1 || { tail -40 $(CFPGA)/logs/synth.log; exit 1; }
	! grep -q '^ERROR:' $(CFPGA)/logs/synth.log
	test -s $(CSYNTH_JSON)
	grep -q 'hbdec1' $(CSYNTH_JSON)
	grep -q 'hbdec2' $(CSYNTH_JSON)
	grep -q '"type": "MMCME2_ADV"' $(CSYNTH_JSON)
	grep -q '"type": "DSP48E1"' $(CSYNTH_JSON)
	awk '/Printing statistics/{seen=1} seen' $(CFPGA)/logs/synth.log \
	  > $(CFPGA)/reports/synth-stat.txt
	echo "synthesis ok: $(CSYNTH_JSON)"
	EOF

# Full-chain per-stage capture (2^21 clocks, ~6 min): writes I/Q dumps for
# every DDC stage to $(SIM_DIR)/stages for external spectral analysis.
# Analysis tooling is deliberately NOT in this repo (see bench header).
stages: tools
	@mkdir -p $(SIM_DIR)/stages
	@iverilog -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control -s tb_ddc_stages \
	  -o $(SIM_DIR)/ddc_stages.vvp $(addprefix $(ROOT)/,$(shell cat scripts/sources.txt)) \
	  $(ROOT)/tests/sim/xilinx_prim_sim.v $(ROOT)/tests/tb_ddc_stages.v
	cd $(SIM_DIR) && $(VVP) -n -l ddc_stages.log ddc_stages.vvp +DIR=$(SIM_DIR)/stages
	@grep -q '^PASS:' $(SIM_DIR)/ddc_stages.log || \
	  { echo "ERROR: stage capture failed; see $(SIM_DIR)/ddc_stages.log"; exit 1; }
	@echo "PASS: per-stage capture written to $(SIM_DIR)/stages"

equiv:
	podman run --rm --userns=keep-id -v "$$PWD:/work:z" -w /work b210-open-fpga:$(TAG) yosys -q scripts/equiv_cordic.ys
	@echo "PASS: cordic_stage formally equivalent to its synthesized netlist"

pnr: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) \
	  -e FPGA_ALLOW_TIMING_FAIL=$(FPGA_ALLOW_TIMING_FAIL) \
	  $(FPGA_IMAGE) bash -s <<-'EOF'
	set -euo pipefail
	mkdir -p $(CFPGA)/pnr $(CFPGA)/logs $(CFPGA)/reports
	test -s $(CSYNTH_JSON) || { echo "ERROR: missing netlist; run make synth"; exit 1; }
	test -s $(CHIPDB) || { echo "ERROR: missing chip database: $(CHIPDB)"; exit 1; }
	test -s $(CXDC) || { echo "ERROR: missing constraints: $(CXDC)"; exit 1; }
	python3 $(CR)/scripts/check_netlist.py $(CSYNTH_JSON)
	args=(--device "$(FPGA_PART)" --chipdb "$(CHIPDB)" --json "$(CSYNTH_JSON)" \
	  -o "xdc=$(CXDC)" -o "fasm=$(CFASM)" \
	  --report "$(CFPGA)/reports/pnr-report.json" --detailed-timing-report)
	if [ "$(FPGA_ALLOW_TIMING_FAIL)" = "1" ]; then args+=(--timing-allow-fail); fi
	set +e
	nextpnr-himbaechel "$${args[@]}" 2>&1 | tee $(CFPGA)/logs/pnr.log
	rc=$${PIPESTATUS[0]}
	set -e
	test $$rc -eq 0 || { echo "ERROR: nextpnr failed (rc=$$rc)"; exit 1; }
	! grep -q '^ERROR:' $(CFPGA)/logs/pnr.log
	test -s $(CFASM)
	{ echo "# NOTE: the FIRST block is the pre-route estimate and is not signoff."; \
	  echo "#       The LAST block is post-route. Compare that one to the constraint."; \
	  echo "#       I/O timing (GPIF to the FX3, codec DDR) is not constrained by"; \
	  echo "#       this flow; nextpnr has no set_input_delay/set_output_delay."; \
	  grep -E 'Max frequency|Critical path|slack|Device utilisation' \
	  $(CFPGA)/logs/pnr.log; } > $(CFPGA)/reports/pnr-timing.txt || true
	echo "place and route ok: $(CFASM)"
	EOF

bitstream: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) $(FPGA_IMAGE) bash -s <<-'EOF'
	set -euo pipefail
	mkdir -p $(CFPGA)/bitstream $(CFPGA)/logs
	test -s $(CFASM) || { echo "ERROR: missing FASM; run make pnr"; exit 1; }
	test -s $(PRJXRAY_DB)/kintex7/$(FPGA_PART)/part.yaml || \
	  { echo "ERROR: missing part data: $(PRJXRAY_DB)/kintex7/$(FPGA_PART)/part.yaml"; exit 1; }
	fasm2frames --db-root $(PRJXRAY_DB)/kintex7 --part $(FPGA_PART) \
	  $(CFASM) $(CFRAMES) > $(CFPGA)/logs/fasm2frames.log 2>&1 || \
	  { tail -40 $(CFPGA)/logs/fasm2frames.log; exit 1; }
	xc7frames2bit \
	  --part_file $(PRJXRAY_DB)/kintex7/$(FPGA_PART)/part.yaml \
	  --part_name $(FPGA_PART) \
	  --frm_file $(CFRAMES) \
	  --output_file $(CBIT) \
	  > $(CFPGA)/logs/xc7frames2bit.log 2>&1 || \
	  { tail -40 $(CFPGA)/logs/xc7frames2bit.log; exit 1; }
	test -s $(CBIT)
	python3 $(CR)/scripts/bit2bin.py $(CBIT) $(CBIN) \
	  > $(CFPGA)/logs/bit2bin.log 2>&1 || \
	  { cat $(CFPGA)/logs/bit2bin.log; exit 1; }
	test -s $(CBIN)
	idcode=$$(bittool get_device_id $(CBIN) 2>>$(CFPGA)/logs/bit2bin.log) || \
	  { echo "ERROR: bittool could not read the raw bitstream"; exit 1; }
	if [[ "$(FPGA_PART)" == xc7k325t* ]]; then
	  test "$$idcode" = "0x3651093" || \
	    { echo "ERROR: unexpected device IDCODE $$idcode (expected 0x3651093)"; exit 1; }
	fi
	cp $(CBIN) $(CUHD_BIN)
	echo "bitstream ok: $(CBIT)"
	stat -c '  bit size: %s bytes' $(CBIT)
	sha256sum $(CBIT) | sed 's/^/  bit sha256: /'
	stat -c '  bin size: %s bytes' $(CBIN)
	sha256sum $(CBIN) | sed 's/^/  bin sha256: /'
	echo "  idcode:   $$idcode"
	EOF

analyze: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) $(FPGA_IMAGE) bash -s <<-'EOF'
	set -euo pipefail
	mkdir -p $(CFPGA)/reports
	test -s $(CSYNTH_JSON) || { echo "ERROR: missing netlist; run make synth"; exit 1; }
	yosys -p "read_json $(CSYNTH_JSON); stat; check" \
	  > $(CFPGA)/reports/analysis.txt 2>&1 || \
	  { tail -40 $(CFPGA)/reports/analysis.txt; exit 1; }
	echo "report: $(CFPGA)/reports/analysis.txt"
	grep -E '^===|Number of cells|Number of wires|CARRY4|DSP48E1|RAMB36E1|FDRE|LUT[1-6]' \
	  $(CFPGA)/reports/analysis.txt | tail -40 || true
	EOF

# ---------------------------------------------------------------------------
# Host-side targets.
# ---------------------------------------------------------------------------

shell: tools
	@mkdir -p $(BUILD_DIR)
	@$(CONTAINER_RUN) -it $(FPGA_IMAGE) bash

timing:
	@test -s $(FPGA_DIR)/reports/pnr-report.json || \
	  { echo "ERROR: missing pnr-report.json; run make pnr first"; exit 1; }
	@python3 $(ROOT)/scripts/pnr-report.py $(FPGA_DIR)/reports/pnr-report.json

doctor:
	@mkdir -p $(BUILD_DIR)
	ok=1
	if [ -r /etc/os-release ]; then . /etc/os-release; echo "Host: $$PRETTY_NAME"; else uname -srm; fi
	for tool in git python3 $(IVERILOG) $(VVP) $(CONTAINER_ENGINE); do
	  if command -v $$tool >/dev/null 2>&1; then
	    echo "$$tool: $$(command -v $$tool)"
	  else
	    echo "ERROR: required tool not found: $$tool"; ok=0
	  fi
	done
	if $(CONTAINER_ENGINE) image inspect $(FPGA_IMAGE) >/dev/null 2>&1; then
	  echo "toolchain image: $(FPGA_IMAGE) (present)"
	  $(CONTAINER_RUN) $(FPGA_IMAGE) bash -lc 'set -e; yosys -V; nextpnr-himbaechel --version 2>/dev/null || nextpnr-himbaechel --help >/dev/null; fasm2frames --help >/dev/null 2>&1; test -x "$$(command -v xc7frames2bit)"; test -x "$$(command -v bittool)"; test -s "$$NEXTPNR_CHIPDB"; echo "chipdb: $$NEXTPNR_CHIPDB"'
	else
	  echo "MISSING: toolchain image $(FPGA_IMAGE); run make tools"; ok=0
	fi
	if [ $$ok -ne 1 ]; then exit 1; fi

verify:
	@set -e   # .ONESHELL is on: without this the recipe only reports its LAST command
	@cd $(ROOT) && git diff --exit-code HEAD -- src scripts tests container third_party .github Makefile README.md .gitignore .gitattributes .dockerignore LICENSE
	@cd $(ROOT) && test "$$(wc -l < scripts/sources.txt)" -eq 93
	@cd $(ROOT) && test "$$(sort -u scripts/sources.txt | wc -l)" -eq 93
	@cd $(ROOT) && bash -c 'diff -u <(find src -name "*.v" -printf "%p\n" | sort) <(sort scripts/sources.txt)'
	@cd $(ROOT) && while IFS= read -r f; do \
	  test -f "$$f" || { echo "ERROR: missing source $$f"; exit 1; }; \
	done < scripts/sources.txt
	@cd $(ROOT) && grep -q '^`define TARGET_B210' src/Define.vh
	@cd $(ROOT) && ! git ls-files | grep -v '^third_party/' | grep -E '\.(bit|bin|fasm|frames|bba|dcp|log|jou|vcd|fst|lxt|lxt2|wdb|pb|str)$$' || \
	  { echo "ERROR: generated artifact is tracked"; exit 1; }
	@cd $(ROOT) && ! git ls-files build | grep -q . || \
	  { echo "ERROR: build/ content is tracked"; exit 1; }
	@echo "source state ok"

test:
	@set -e   # .ONESHELL is on: without this the recipe only reports its LAST command
	@mkdir -p $(SIM_DIR)
	@rm -f $(SIM_DIR)/tb_gray_roundtrip.log $(SIM_DIR)/tb_hbdec_impulse.log \
	       $(SIM_DIR)/tb_hbdec_rate.log $(SIM_DIR)/tb_cic_decim.log \
	       $(SIM_DIR)/tb_cic_interp.log $(SIM_DIR)/tb_clip.log \
	       $(SIM_DIR)/tb_ctrl_abi.log $(SIM_DIR)/tb_b200_clk_gen.log $(SIM_DIR)/tb_hello_led.log \
	       $(SIM_DIR)/tb_axi_fifo_2clk_cdc.log $(SIM_DIR)/tb_axi_fifo_2clk_rate.log \
	       $(SIM_DIR)/tb_ddc_sine.log $(SIM_DIR)/tb_duc_sine.log
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -o elab_iverilog.vvp $(ELAB_SRCS) $(ROOT)/tests/sim/xilinx_prim_sim.v \
	  > elab_iverilog.log 2>&1 || \
	  { grep -v 'warning:' elab_iverilog.log | head -20; \
	    echo "ERROR: a source file is not legal Verilog-2005; see $(SIM_DIR)/elab_iverilog.log"; exit 1; }
	@echo "PASS: every source is legal Verilog-2005 (Icarus elaborates the full design)"
	cd $(SIM_DIR) && $(CONTAINER_RUN) $(FPGA_IMAGE) bash -c "yosys -q -p 'read_verilog $(CR)/tests/hello_world/hello_led.v; chparam -set WIDTH 4 hello_led_core; synth -top hello_led_core; write_verilog -noattr $(CR)/$(SIM_DIR_REL)/hello_postsynth.v' > $(CR)/$(SIM_DIR_REL)/hello_postsynth.log 2>&1 && cp /opt/fpga/share/yosys/simcells.v $(CR)/$(SIM_DIR_REL)/" || \
	  { tail -5 $(SIM_DIR)/hello_postsynth.log; echo "ERROR: post-synthesis netlist generation failed"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hello_led_postsynth \
	  -o tb_hello_led_postsynth.vvp hello_postsynth.v simcells.v \
	  $(ROOT)/tests/tb_hello_led_postsynth.v
	cd $(SIM_DIR) && $(VVP) -l tb_hello_led_postsynth.log tb_hello_led_postsynth.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hello_led_postsynth.log || \
	  { echo "ERROR: post-synthesis netlist does not match RTL; see $(SIM_DIR)/tb_hello_led_postsynth.log"; exit 1; }
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
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hbdec_impulse \
	  -o tb_hbdec_impulse.vvp $(HB_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_hbdec_impulse.log tb_hbdec_impulse.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec_impulse.log || \
	  { echo "ERROR: halfband test failed; see $(SIM_DIR)/tb_hbdec_impulse.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hbdec_rate \
	  -o tb_hbdec_rate.vvp $(HB_RATE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_hbdec_rate.log tb_hbdec_rate.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec_rate.log || \
	  { echo "ERROR: halfband rate test failed; see $(SIM_DIR)/tb_hbdec_rate.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_cic_decim \
	  -o tb_cic_decim.vvp $(CIC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_cic_decim.log tb_cic_decim.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_cic_decim.log || \
	  { echo "ERROR: CIC decimator test failed; see $(SIM_DIR)/tb_cic_decim.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_cic_interp \
	  -o tb_cic_interp.vvp $(CIC_INT_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_cic_interp.log tb_cic_interp.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_cic_interp.log || \
	  { echo "ERROR: CIC interpolator test failed; see $(SIM_DIR)/tb_cic_interp.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_clip \
	  -o tb_clip.vvp $(CLIP_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_clip.log tb_clip.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_clip.log || \
	  { echo "ERROR: clip test failed; see $(SIM_DIR)/tb_clip.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_cordic \
	  -o tb_cordic.vvp $(CORDIC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_cordic.log tb_cordic.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_cordic.log || \
	  { echo "ERROR: CORDIC test failed; see $(SIM_DIR)/tb_cordic.log"; exit 1; }
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
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hello_led \
	  -o tb_hello_led.vvp $(HELLO_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_hello_led.log tb_hello_led.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hello_led.log || \
	  { echo "ERROR: hello-world test failed; see $(SIM_DIR)/tb_hello_led.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_sine -o tb_ddc_sine.vvp $(DDC_SINE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_ddc_sine.log tb_ddc_sine.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_sine.log || \
	  { echo "ERROR: DDC tone-fidelity test failed; see $(SIM_DIR)/tb_ddc_sine.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_duc_sine -o tb_duc_sine.vvp $(DUC_SINE_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_duc_sine.log tb_duc_sine.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_duc_sine.log || \
	  { echo "ERROR: DUC tone-fidelity test failed; see $(SIM_DIR)/tb_duc_sine.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_ddc_chain -o tb_ddc_chain.vvp $(DDC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_ddc_chain.log tb_ddc_chain.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_ddc_chain.log || \
	  { echo "ERROR: DDC chain test failed; see $(SIM_DIR)/tb_ddc_chain.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_duc_chain -o tb_duc_chain.vvp $(DUC_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_duc_chain.log tb_duc_chain.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_duc_chain.log || \
	  { echo "ERROR: DUC chain test failed; see $(SIM_DIR)/tb_duc_chain.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_rx_framer -o tb_rx_framer.vvp $(FRAMER_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_rx_framer.log tb_rx_framer.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_rx_framer.log || \
	  { echo "ERROR: RX framer test failed; see $(SIM_DIR)/tb_rx_framer.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s tb_gpif2_error -o tb_gpif2_error.vvp $(GPIF_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_gpif2_error.log tb_gpif2_error.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_gpif2_error.log || \
	  { echo "ERROR: GPIF error-checker test failed; see $(SIM_DIR)/tb_gpif2_error.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
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
	cd $(ROOT) && $(IVERILOG) -g2005 -D TARGET_B210 -I $(ROOT)/src/rtl/control \
	  -s b200 -o $(SIM_DIR)/b200_elab.vvp $(ELAB_SRCS) $(ROOT)/tests/sim/xilinx_prim_sim.v \
	  2> $(SIM_DIR)/b200_elab.log
	@echo "PASS: full design elaborates ($(words $(ELAB_SRCS)) sources, 0 errors)"


# Compile the hello world through the real toolchain, end to end.
# Same stages, flags and images as `make synth|pnr|bitstream`, different inputs.
hello: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) $(FPGA_IMAGE) bash -s <<-'EOF'
	set -eo pipefail
	mkdir -p $(CHELLO)
	echo "[1/6] yosys";        yosys -p "read_verilog $(CR)/tests/hello_world/hello_led.v; synth_xilinx -flatten -abc9 -family xc7 -top hello_led_top; write_json $(CHELLO)/hello.json" > $(CHELLO)/synth.log
	echo "[2/6] nextpnr";      nextpnr-himbaechel --device $(FPGA_PART) --chipdb $(CHIPDB) --json $(CHELLO)/hello.json -o xdc=$(CR)/tests/hello_world/hello_led.xdc -o fasm=$(CHELLO)/hello.fasm --report $(CHELLO)/report.json > $(CHELLO)/pnr.log
	echo "[3/6] frames";       fasm2frames --db-root $(PRJXRAY_DB)/kintex7 --part $(FPGA_PART) $(CHELLO)/hello.fasm $(CHELLO)/hello.frames 2>/dev/null
	echo "[4/6] bit";          xc7frames2bit --part_file $(PRJXRAY_DB)/kintex7/$(FPGA_PART)/part.yaml --part_name $(FPGA_PART) --frm_file $(CHELLO)/hello.frames --output_file $(CHELLO)/hello.bit
	echo "[5/6] bin";          python3 $(CR)/scripts/bit2bin.py $(CHELLO)/hello.bit $(CHELLO)/hello.bin > /dev/null
	echo "[6/6] idcode";       test "$$(bittool get_device_id $(CHELLO)/hello.bin)" = "0x3651093"
	echo "hello world ok: $(CHELLO)/hello.bin (idcode 0x3651093)"
	EOF

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
	@$(CONTAINER_ENGINE) rmi -f $(FPGA_IMAGE) $(YOSYS_IMAGE) $(NEXTPNR_IMAGE) \
	  $(PRJXRAY_IMAGE) $(BASE_IMAGE) 2>/dev/null || true
