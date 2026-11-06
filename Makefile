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

SYNTH_JSON := $(FPGA_DIR)/synth/$(TOP).json
FASM       := $(FPGA_DIR)/pnr/$(TOP).fasm
FRAMES     := $(FPGA_DIR)/pnr/$(TOP).frames
BIT        := $(FPGA_DIR)/bitstream/$(TOP).bit
BIN        := $(FPGA_DIR)/bitstream/$(TOP).bin
UHD_BIN    := $(FPGA_DIR)/bitstream/usrp_b210_fpga.bin

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

.PHONY: help doctor verify test sim tools tools-base tools-yosys tools-nextpnr tools-prjxray \
        shell build synth pnr bitstream analyze timing clean image-clean

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
	  '  make test       Run the self-checking host tests' \
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

pnr: tools
	@$(CONTAINER_RUN) $(CONTAINER_ENV) \
	  -e FPGA_ALLOW_TIMING_FAIL=$(FPGA_ALLOW_TIMING_FAIL) \
	  $(FPGA_IMAGE) bash -s <<-'EOF'
	set -euo pipefail
	mkdir -p $(CFPGA)/pnr $(CFPGA)/logs $(CFPGA)/reports
	test -s $(CSYNTH_JSON) || { echo "ERROR: missing netlist; run make synth"; exit 1; }
	test -s $(CHIPDB) || { echo "ERROR: missing chip database: $(CHIPDB)"; exit 1; }
	test -s $(CXDC) || { echo "ERROR: missing constraints: $(CXDC)"; exit 1; }
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
	grep -E 'Max frequency|Critical path|slack|Device utilisation' \
	  $(CFPGA)/logs/pnr.log > $(CFPGA)/reports/pnr-timing.txt || true
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
	@cd $(ROOT) && git diff --exit-code HEAD -- src scripts tests container third_party Makefile README.md .gitignore .gitattributes .dockerignore LICENSE
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
	@mkdir -p $(SIM_DIR)
	@rm -f $(SIM_DIR)/tb_gray_roundtrip.log $(SIM_DIR)/tb_hbdec_impulse.log
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_gray_roundtrip \
	  -o tb_gray_roundtrip.vvp $(TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_gray_roundtrip.log tb_gray_roundtrip.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_gray_roundtrip.log || \
	  { echo "ERROR: Gray-code test failed; see $(SIM_DIR)/tb_gray_roundtrip.log"; exit 1; }
	cd $(SIM_DIR) && $(IVERILOG) -g2005 -s tb_hbdec_impulse \
	  -o tb_hbdec_impulse.vvp $(HB_TEST_SRCS)
	cd $(SIM_DIR) && $(VVP) -l tb_hbdec_impulse.log tb_hbdec_impulse.vvp
	@grep -q '^PASS:' $(SIM_DIR)/tb_hbdec_impulse.log || \
	  { echo "ERROR: halfband test failed; see $(SIM_DIR)/tb_hbdec_impulse.log"; exit 1; }
	@python3 $(ROOT)/tests/test_bit2bin.py

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
