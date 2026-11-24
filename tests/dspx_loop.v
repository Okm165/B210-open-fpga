// dspx_loop - the transmit and the receive DSP of this repository back to
// back, for scripts/dsp_exact.py.
//
// With the AD9361 in digital loopback the 12-bit samples the FPGA puts on the
// transmit data port come back on the receive data port.  The host knows what
// it transmitted (one block of samples, repeated without a gap), so what it
// receives can be compared with what the RTL computes, bit for bit.  This
// bench is the RTL half:
//
//   host block -> duc_chain -> DAC slice -> pins ->(delay)-> pins -> ddc_chain
//
// wired the way radio_legacy.v and b200.v wire it, and programmed with the
// register values scripts/dsp_exact.py passes in (it derives them from the
// UHD sources and documents each one).
//
// Between the chains and the pins, in radio_legacy.v:
//   transmit  dac_slice (round half even, saturate) takes the 24-bit DUC
//             output to the 12-bit pin word; +DAC=1 takes tx_fe[23:12]
//             instead, which is what the upstream Ettus file does
//             (tx <= tx_fe[23:8], of which the pins carry the top 12 bits)
//   receive   {rx[31:16], 8'd0}: the 12-bit pin word with zeros below
// b200_io.v moves the 12-bit words and computes nothing.
//
// The loopback inside the AD9361 is a delay of unknown length.  Only its
// length modulo the rate change matters here (it sets which transmit clock
// the receive decimator's grid falls on); +DELAY=<clocks> sets it, and the
// script tries each value.
//
// Output, one line per receive sample, written to +OUT=<file>:
//
//     <index of the host sample at the DUC input on that clock> <sample> <i_clip> <q_clip>
//
// as in dspx_rx.v: `sample` is what the chain sends to the host, i_clip and
// q_clip what entered its output rounder.  +PINS=<file> also writes the
// transmit pin words, one line per clock: <host sample index> <i> <q>.
//
// Plusargs: +TXHEX=<file> +TXLEN=<n> the block, one {I,Q} word per line;
// +TFREQ +TSCALE +TRATE (SR_TX_DSP + 0..2), +FREQ +SCALE +RATE +MUX
// (SR_RX_DSP + 0..3), hex; +TOTAL=<rate change>; +NOUT=<receive samples to
// write>; +DELAY, +DAC, +OUT, +PINS.
`timescale 1ns/1ps

module dspx_loop;

   localparam [7:0] TXBASE = 8'd184;        // SR_TX_DSP in radio_legacy.v
   localparam [7:0] RXBASE = 8'd144;        // SR_RX_DSP

   reg clk = 1'b0;
   always #5 clk = ~clk;

   reg         rst = 1'b1;
   reg         run_tx = 1'b0, run_rx = 1'b0;
   reg         set_stb = 1'b0;
   reg  [7:0]  set_addr = 8'd0;
   reg  [31:0] set_data = 32'd0;

   // ------------------------------------------------------------- transmit ---
   reg  [31:0] block [0:1048575];
   integer     txlen;
   integer     n_tx = 0;                    // host sample at the DUC input
   wire        strobe_tx;
   wire [23:0] tx_fe_i, tx_fe_q;

   always @(posedge clk)
     if (strobe_tx) n_tx <= (n_tx + 1 == txlen) ? 0 : n_tx + 1;

   duc_chain #(.BASE(TXBASE), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) duc
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_fe_i), .tx_fe_q(tx_fe_q),
      .sample(block[n_tx]), .run(run_tx), .strobe(strobe_tx), .debug());

   // radio_legacy.v: the DAC slice and the register in front of the pins
   integer     dac_truncate;
   wire [11:0] round_i, round_q;
   dac_slice dac_slice_i (.in(tx_fe_i), .out(round_i));
   dac_slice dac_slice_q (.in(tx_fe_q), .out(round_q));
   wire [11:0] code_i = (dac_truncate != 0) ? tx_fe_i[23:12] : round_i;
   wire [11:0] code_q = (dac_truncate != 0) ? tx_fe_q[23:12] : round_q;

   reg  [31:0] tx = 32'd0;
   always @(posedge clk)
     tx <= run_tx ? {code_i, 4'b0000, code_q, 4'b0000} : 32'd0;

   // b200.v: the pins carry tx[31:20] and tx[15:4]
   wire [11:0] tx_pin_i = tx[31:20];
   wire [11:0] tx_pin_q = tx[15:4];

   // ----------------------------------------------- the AD9361, looped back ---
   integer     delay;
   reg  [23:0] line [0:255];
   integer     d;
   always @(posedge clk) begin
      line[0] <= {tx_pin_i, tx_pin_q};
      for (d = 1; d < 256; d = d + 1) line[d] <= line[d-1];
   end
   wire [23:0] back = (delay == 0) ? {tx_pin_i, tx_pin_q} : line[delay-1];

   // b200.v: rx_data = {i, 4'b0, q, 4'b0};  radio_legacy.v: rx_fe = rx
   wire [31:0] rx_fe = {back[23:12], 4'b0000, back[11:0], 4'b0000};

   // -------------------------------------------------------------- receive ---
   wire [31:0] sample;
   wire        strobe;

   ddc_chain #(.BASE(RXBASE), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) ddc
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i({rx_fe[31:16], 8'd0}), .rx_fe_q({rx_fe[15:0], 8'd0}),
      .sample(sample), .run(run_rx), .strobe(strobe), .debug());

   task poke(input [7:0] addr, input [31:0] data);
      begin
         @(negedge clk);
         set_addr = addr; set_data = data; set_stb = 1'b1;
         @(negedge clk);
         set_stb = 1'b0;
      end
   endtask

   // --------------------------------------------------------------- output ---
   reg [32:0] qi [0:7], qq [0:7];
   reg [2:0]  wp = 3'd0, rp = 3'd0;
   integer    fd, fp = 0, nout, written = 0, pins_left = 0;

   always @(posedge clk) begin
      if (ddc.strobe_clip) begin
         qi[wp] <= ddc.i_clip;
         qq[wp] <= ddc.q_clip;
         wp <= wp + 3'd1;
      end
      if (strobe) begin
         if (written < nout)
           $fwrite(fd, "%0d %h %h %h\n", n_tx, sample, qi[rp], qq[rp]);
         written = written + 1;
         rp <= rp + 3'd1;
      end
      if (pins_left > 0) begin
         $fwrite(fp, "%0d %h %h\n", n_tx, tx_pin_i, tx_pin_q);
         pins_left = pins_left - 1;
      end
   end

   // ------------------------------------------------------------- stimulus ---
   reg [31:0]     t_freq, t_scale, t_rate, r_freq, r_scale, r_rate, r_mux;
   integer        total;
   reg [8*400:1]  outname, hexname, pinname;

   initial begin
      if (!$value$plusargs("TXHEX=%s", hexname) || !$value$plusargs("TXLEN=%d", txlen) ||
          !$value$plusargs("TFREQ=%h", t_freq) || !$value$plusargs("TSCALE=%h", t_scale) ||
          !$value$plusargs("TRATE=%h", t_rate) ||
          !$value$plusargs("FREQ=%h", r_freq) || !$value$plusargs("SCALE=%h", r_scale) ||
          !$value$plusargs("RATE=%h", r_rate) || !$value$plusargs("MUX=%h", r_mux) ||
          !$value$plusargs("TOTAL=%d", total) ||
          !$value$plusargs("NOUT=%d", nout) || !$value$plusargs("OUT=%s", outname)) begin
         $display("dspx_loop: +TXHEX +TXLEN +TFREQ +TSCALE +TRATE +FREQ +SCALE +RATE +MUX +TOTAL +NOUT +OUT are required");
         $finish;
      end
      if (!$value$plusargs("DELAY=%d", delay)) delay = 0;
      if (!$value$plusargs("DAC=%d", dac_truncate)) dac_truncate = 0;
      $readmemh(hexname, block, 0, txlen - 1);
      fd = $fopen(outname, "w");

      repeat (12) @(negedge clk);
      rst = 1'b0;
      poke(TXBASE + 8'd0, t_freq);
      poke(TXBASE + 8'd1, t_scale);
      poke(TXBASE + 8'd2, t_rate);
      poke(RXBASE + 8'd0, r_freq);
      poke(RXBASE + 8'd1, r_scale);
      poke(RXBASE + 8'd2, r_rate);
      poke(RXBASE + 8'd3, r_mux);
      repeat (16) @(negedge clk);
      // the transmitter starts first (0.2 s on the board) and is long past its
      // start-up when the receiver starts (0.3 s)
      run_tx = 1'b1;
      repeat (600 * total + 512) @(negedge clk);
      run_rx = 1'b1;
      if ($value$plusargs("PINS=%s", pinname)) begin
         fp = $fopen(pinname, "w");
         pins_left = txlen * total;
      end
      wait (written >= nout);
      @(negedge clk);
      $fclose(fd);
      if (fp != 0) $fclose(fp);
      $finish;
   end

endmodule
