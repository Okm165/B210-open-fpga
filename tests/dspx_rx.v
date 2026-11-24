// dspx_rx - the receive DSP of this repository on the AD9361 pseudo-random
// test sequence, for scripts/dsp_exact.py.
//
// The AD9361 can replace its converter samples by a 16-bit PN sequence
// (BIST).  What the FPGA then receives on its data port is known exactly,
// sample for sample, so what the receive chain sends to the host can be
// compared with what the RTL computes, bit for bit.  This bench is the RTL
// half: ddc_chain, fed the way radio_legacy.v and b200.v feed it, programmed
// with the register values scripts/dsp_exact.py passes in (it derives them
// from the UHD sources and documents each one).
//
// The sequence (analogdevicesinc/hdl, axi_ad9361_rx_pnmon.v, pn0): one 16-bit
// word W per sample period,
//
//     I[11:0] = W[15:4]       Q[11:0] = bit-reversed W[11:0]
//     W' = { W[14:0], (^W[15:4]) ^ (^W[2:1]) }          period 65535
//
// From the pins to the chain nothing computes: b200.v places the two 12-bit
// codes in rx_data[31:20] and [15:4] with zeros below, radio_legacy.v hands
// the chain {rx[31:16], 8'd0} and {rx[15:0], 8'd0}.
//
// Output, one line per output sample, written to +OUT=<file>:
//
//     <W at the pins on the clock of the strobe> <sample> <i_clip> <q_clip>
//
// `sample` is the 32-bit word the chain sends to the host.  i_clip / q_clip
// are the 33-bit values that entered the chain's last stage, the round_sd
// output rounder, for that sample.  That rounder is a first-order error
// feedback: its output depends on an error state which is not cleared when
// streaming starts and which, on a board, carries the history of everything
// received since reset.  Everything before it has finite memory.  So the
// script takes one period of i_clip / q_clip from here, and applies the
// rounder itself with the state the capture implies; the `sample` column
// (the same rounder, here in RTL, from reset) is what it checks its model of
// the rounder against.
//
// Plusargs: +FREQ +SCALE +RATE +MUX (hex register values: SR_RX_DSP + 0..3),
// +NOUT=<output samples to write>, +W0=<PN word on the pins at the start>,
// +PHASE=<clocks to hold back the start of streaming>, +OUT=<file>.
`timescale 1ns/1ps

module dspx_rx;

   localparam [7:0] BASE = 8'd144;          // SR_RX_DSP in radio_legacy.v

   reg clk = 1'b0;
   always #5 clk = ~clk;

   reg         rst = 1'b1;
   reg         run = 1'b0;
   reg         set_stb = 1'b0;
   reg  [7:0]  set_addr = 8'd0;
   reg  [31:0] set_data = 32'd0;

   // ---------------------------------------------- the AD9361 at the pins ---
   reg  [15:0] w = 16'hFFFF;
   always @(posedge clk)
     w <= {w[14:0], (^w[15:4]) ^ (^w[2:1])};

   wire [11:0] pin_i = w[15:4];
   wire [11:0] pin_q = {w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]};

   // b200.v: rx_data = {i, 4'b0, q, 4'b0};  radio_legacy.v: rx_fe = rx
   wire [31:0] rx_fe = {pin_i, 4'b0000, pin_q, 4'b0000};

   // ------------------------------------------------------------ the chain ---
   wire [31:0] sample;
   wire        strobe;

   ddc_chain #(.BASE(BASE), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i({rx_fe[31:16], 8'd0}), .rx_fe_q({rx_fe[15:0], 8'd0}),
      .sample(sample), .run(run), .strobe(strobe), .debug());

   task poke(input [7:0] addr, input [31:0] data);
      begin
         @(negedge clk);
         set_addr = addr; set_data = data; set_stb = 1'b1;
         @(negedge clk);
         set_stb = 1'b0;
      end
   endtask

   // --------------------------------------------------------------- output ---
   // The rounder's input for a sample is on i_clip / q_clip while strobe_clip
   // is high; the sample itself leaves two clocks later.  Keep them in order.
   reg [32:0] qi [0:7], qq [0:7];
   reg [2:0]  wp = 3'd0, rp = 3'd0;
   integer    fd, nout, written = 0;

   always @(posedge clk) begin
      if (dut.strobe_clip) begin
         qi[wp] <= dut.i_clip;
         qq[wp] <= dut.q_clip;
         wp <= wp + 3'd1;
      end
      if (strobe) begin
         if (written < nout)
           $fwrite(fd, "%h %h %h %h\n", w, sample, qi[rp], qq[rp]);
         written = written + 1;
         rp <= rp + 3'd1;
      end
   end

   // ------------------------------------------------------------- stimulus ---
   reg [31:0]     r_freq, r_scale, r_rate, r_mux;
   reg [15:0]     w0;
   integer        phase;
   reg [8*400:1]  outname;

   initial begin
      if (!$value$plusargs("FREQ=%h", r_freq) || !$value$plusargs("SCALE=%h", r_scale) ||
          !$value$plusargs("RATE=%h", r_rate) || !$value$plusargs("MUX=%h", r_mux) ||
          !$value$plusargs("NOUT=%d", nout) || !$value$plusargs("OUT=%s", outname)) begin
         $display("dspx_rx: +FREQ +SCALE +RATE +MUX +NOUT +OUT are required");
         $finish;
      end
      if (!$value$plusargs("PHASE=%d", phase)) phase = 0;
      if ($value$plusargs("W0=%h", w0)) w = w0;
      fd = $fopen(outname, "w");

      repeat (12) @(negedge clk);
      rst = 1'b0;
      poke(BASE + 8'd0, r_freq);
      poke(BASE + 8'd1, r_scale);
      poke(BASE + 8'd2, r_rate);
      poke(BASE + 8'd3, r_mux);
      // the chain is idle here, as it is on the board between the register
      // writes and the stream command; long enough for the CORDIC to hold
      // real samples
      repeat (64 + phase) @(negedge clk);
      run = 1'b1;
      wait (written >= nout);
      @(negedge clk);
      $fclose(fd);
      $finish;
   end

endmodule
