#!/usr/bin/env bash
# build_diag_ctrl4.sh - build the minimal control-path diagnostic.
# Output: build/fpga/diag/usrp_diag_ctrl4_s3.bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR=/work
FPGA_PART=xc7k325tffg676-1
FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
CE=podman
$CE run --rm -i --userns=keep-id -v "$ROOT:$CR:z" -w "$CR" -e HOME="$CR/build" \
  -e FPGA_PART=$FPGA_PART -e FPGA_HOME=$FPGA_HOME ${FPGA_IMAGE:-b210-open-fpga:0.1.0} bash -s <<-'EOF'
set -euo pipefail
CR=/work; FPGA_PART=xc7k325tffg676-1; FPGA_HOME=/opt/fpga
PRJXRAY_DB=$FPGA_HOME/share/prjxray-db
OUT=$CR/build/fpga/diag4
SRCS="$CR/src/top/diag_ctrl4.v $CR/src/top/b200_clk_gen.v $CR/src/top/pps_switch.v $CR/src/top/edge_detect.v $CR/src/rtl/gpif2/gpif2_slave_fifo32.v $CR/src/rtl/gpif2/gpif2_to_fifo64.v $CR/src/rtl/gpif2/fifo64_to_gpif2.v $CR/src/rtl/gpif2/gpif2_error_checker.v $CR/src/rtl/fifo/axi_fifo32_to_fifo64.v $CR/src/rtl/fifo/axi_fifo64_to_fifo32.v $CR/src/rtl/fifo/axi_fifo.v $CR/src/rtl/fifo_200/axi_fifo_legacy.v $CR/src/rtl/fifo/axi_fifo_short.v $CR/src/rtl/fifo/axi_fifo_flop.v $CR/src/rtl/fifo/axi_fifo_flop2.v $CR/src/rtl/fifo/axi_fifo_bram.v $CR/src/rtl/fifo/axi_fifo_2clk_sim.v $CR/src/rtl/fifo/axi_demux4.v $CR/src/rtl/fifo/axi_mux4.v $CR/src/rtl/control/setting_reg.v $CR/src/rtl/control_200/radio_ctrl_proc.v $CR/src/rtl/control/synchronizer.v $CR/src/rtl/control/synchronizer_impl.v $CR/src/rtl/control/bin2gray.v $CR/src/rtl/control/gray2bin.v $CR/src/rtl/fifo/axi_packet_gate.v $CR/src/rtl/control/ram_2port.v $CR/src/rtl/timing/time_compare.v $CR/src/rtl/timing/timekeeper_legacy.v $CR/src/rtl/timing/pps_generator.v $CR/src/rtl/dsp/add2_and_clip.v $CR/src/rtl/dsp/add2_and_clip_reg.v $CR/src/rtl/dsp/cic_int_shifter.v $CR/src/rtl/dsp/cic_interp.v $CR/src/rtl/dsp/cic_strober.v $CR/src/rtl/dsp/clip.v $CR/src/rtl/dsp/clip_reg.v $CR/src/rtl/dsp/round.v $CR/src/rtl/dsp/sign_extend.v $CR/src/rtl/dsp/cic_comp.v $CR/src/rtl/dsp/ddc_chain.v $CR/src/rtl/dsp/dds_lut.v $CR/src/rtl/dsp/round_sd.v $CR/src/rtl/dsp/duc_chain.v $CR/src/rtl/dsp/hb47_poly.v $CR/src/rtl/dsp/dac_slice.v $CR/src/rtl/control/binary_encoder.v $CR/src/rtl/control/gpio_atr.v $CR/src/rtl/control/gpio_atr_io.v $CR/src/rtl/control/reset_sync.v $CR/src/rtl/control/serial_to_settings.v $CR/src/rtl/control/simple_spi_core.v $CR/src/rtl/control/user_settings.v $CR/src/rtl/vita_200/chdr_12sc_to_16sc.v $CR/src/rtl/vita_200/chdr_16sc_to_12sc.v $CR/src/rtl/vita_200/chdr_16sc_to_32f.v $CR/src/rtl/vita_200/chdr_16sc_to_8sc.v $CR/src/rtl/vita_200/chdr_16sc_to_xxxx_chain.v $CR/src/rtl/vita_200/chdr_32f_to_16sc.v $CR/src/rtl/vita_200/chdr_8sc_to_16sc.v $CR/src/rtl/vita_200/chdr_xxxx_to_16sc_chain.v $CR/src/rtl/vita_200/context_packet_gen.v $CR/src/rtl/vita_200/float_to_iq.v $CR/src/rtl/vita_200/iq_to_float.v $CR/src/rtl/vita_200/new_rx_control.v $CR/src/rtl/vita_200/new_rx_framer.v $CR/src/rtl/vita_200/new_tx_control.v $CR/src/rtl/vita_200/new_tx_deframer.v $CR/src/rtl/vita_200/trigger_context_pkt.v $CR/src/rtl/vita_200/tx_responder.v $CR/src/rtl/control_200/cvita_uart.v $CR/src/rtl/radio_200/radio_legacy.v $CR/src/rtl/wishbone/simple_uart.v $CR/src/rtl/wishbone/simple_uart_rx.v $CR/src/rtl/wishbone/simple_uart_tx.v"
mkdir -p $OUT/synth $OUT/pnr $OUT/bitstream $CR/build/fpga/logs
yosys -p "read_verilog -I $CR/src/rtl/control $CR/src/ip/xilinx_macros.v $SRCS; synth_xilinx -flatten -abc9 -family xc7 -top diag_ctrl4; write_json $OUT/synth/diag_ctrl4.json; stat" \
  > $CR/build/fpga/logs/diagc4-seed3-synth.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc4-seed3-synth.log; exit 1; }
echo "synth ok"
nextpnr-himbaechel --device $FPGA_PART \
  --chipdb $FPGA_HOME/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin \
  --json $OUT/synth/diag_ctrl4.json \
  -o xdc=$CR/src/constraints/diag_ctrl4.xdc -o fasm=$OUT/pnr/diag_ctrl4_s3.fasm \
  --seed 3 > $CR/build/fpga/logs/diagc4-seed3-pnr.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc4-seed3-pnr.log; exit 1; }
echo "pnr ok"
fasm2frames --db-root $PRJXRAY_DB/kintex7 --part $FPGA_PART \
  $OUT/pnr/diag_ctrl4_s3.fasm $OUT/pnr/diag_ctrl4_s3.frames \
  > $CR/build/fpga/logs/diagc-f2f.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-f2f.log; exit 1; }
xc7frames2bit --part_file $PRJXRAY_DB/kintex7/$FPGA_PART/part.yaml \
  --part_name $FPGA_PART --frm_file $OUT/pnr/diag_ctrl4_s3.frames \
  --output_file $OUT/bitstream/diag_ctrl4_s3.bit \
  > $CR/build/fpga/logs/diagc-bit.log 2>&1 \
  || { tail -40 $CR/build/fpga/logs/diagc-bit.log; exit 1; }
python3 $CR/scripts/bit2bin.py $OUT/bitstream/diag_ctrl4_s3.bit $OUT/usrp_diag_ctrl4_s3.bin \
  > $CR/build/fpga/logs/diagc-b2b.log 2>&1 \
  || { cat $CR/build/fpga/logs/diagc-b2b.log; exit 1; }
idcode=$(bittool get_device_id $OUT/usrp_diag_ctrl4_s3.bin)
echo "idcode: $idcode (expect 0x3651093)"
echo "diag ctrl image ok: $OUT/usrp_diag_ctrl4_s3.bin"
EOF
