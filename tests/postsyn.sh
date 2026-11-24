#!/bin/bash
# postsyn.sh - the yosys half of the post-synthesis benches.  Runs inside the
# toolchain container, from the repository root (/work); `make test` calls it.
#
#   postsyn.sh netlists <outdir>   synthesize the benches' devices under test
#   postsyn.sh design   <outdir>   check the complete design after DSP mapping
#
# The board runs the netlist yosys makes, not the RTL, and yosys can get a
# signed product wrong where every RTL simulation is right (see
# tests/yosys_dsp_signext.v).  So the RTL benches are repeated on netlists
# made with the flags of scripts/build.sh, from the source list the build
# uses, and the complete design is checked for the fault's fingerprint.
#
# netlists: each top below is synthesized on its own, its module renamed
# <top>_syn, and written as plain Verilog over the cells of yosys' own
# simulation library (copied to <outdir>/cells_sim.v):
#
#   ddc_chain, duc_chain   BASE as radio_legacy.v sets it  (tb_ddc_golden, tb_duc_golden)
#   hbdec1, hbdec2                                         (tb_hbdec)
#   signext_plain/_rst/_en the reproducer                  (tb_yosys_dsp_signext)
#
# design: the build's synthesis of the complete design is run as far as the
# DSP mapping, with yosys' `check` immediately before and after it.  A
# register bit that yosys leaves reading a net without a driver shows there,
# before later passes turn it into a constant; tests/check_dsp_packing.py
# compares the two reports.  The reproducer gets the same treatment, so the
# check is known to see the fault with the yosys at hand.
set -eu -o pipefail

mode=$1
out=$2
mkdir -p "$out"

srcs=$(grep '^src/' scripts/sources.txt | tr '\n' ' ')
flags="-flatten -abc9 -family xc7"          # scripts/build.sh

# synth <top> <log> <yosys commands before synthesis> <files...>
synth() {
  local top=$1 log=$2 pre=${3:-select -clear}
  shift 3
  yosys -p "read_verilog -I src/rtl/control $*" -p "$pre" \
        -p "synth_xilinx $flags -top $top" \
        -p "rename -top ${top}_syn" \
        -p "write_verilog -noattr $out/${top}_syn.v" > "$out/$log" 2>&1 \
    || { tail -5 "$out/$log"; echo "postsyn: synthesis of $top failed"; exit 1; }
}

# check_dsp <top> <prefix> <files...>: `check` before and after the DSP mapping
check_dsp() {
  local top=$1 pre=$2
  shift 2
  yosys -p "read_verilog -I src/rtl/control $*" \
        -p "synth_xilinx $flags -top $top -run begin:map_dsp" \
        -p "opt_clean" -p "tee -o $out/${pre}_before.txt check" \
        -p "synth_xilinx $flags -top $top -run map_dsp:coarse" \
        -p "opt_clean" -p "tee -o $out/${pre}_after.txt check" > "$out/${pre}.log" 2>&1 \
    || { tail -5 "$out/${pre}.log"; echo "postsyn: DSP-mapping check of $top failed"; exit 1; }
}

case "$mode" in
  netlists)
    cp /opt/fpga/share/yosys/xilinx/cells_sim.v "$out/"
    pids=()
    synth ddc_chain ddc_chain_synth.log "chparam -set BASE 144 ddc_chain" $srcs & pids+=($!)
    synth duc_chain duc_chain_synth.log "chparam -set BASE 184 duc_chain" $srcs & pids+=($!)
    synth hbdec1 hbdec1_synth.log "" $srcs & pids+=($!)
    synth hbdec2 hbdec2_synth.log "" $srcs & pids+=($!)
    for top in signext_plain signext_rst signext_en; do
      synth $top ${top}_synth.log "" tests/yosys_dsp_signext.v & pids+=($!)
      check_dsp $top check_$top tests/yosys_dsp_signext.v & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done
    ;;
  design)
    check_dsp b200 check_b200 $srcs
    ;;
  *)
    echo "usage: postsyn.sh netlists|design <outdir>"; exit 2
    ;;
esac
