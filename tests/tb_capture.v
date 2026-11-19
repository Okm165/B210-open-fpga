// tb_capture.v - dump every intermediate stage of the whole-radio loop for
// offline analysis (scripts/plot-loop.py draws the PNGs).
//
// Not a pass/fail bench: it is the instrument.  It drives a wideband COMPLEX
// multitone (14 tones, 7 positive and 7 negative bins, fixed pseudo-random
// phases, all inside +-0.15 fs) through two channels at once, through the real
// DUC/DDC chains and an explicit air model, and writes one text file per
// observed node:
//
//   <tag>_host.txt     host 16-bit complex word (one line per host sample)
//   <tag>_tx_hb.txt    DUC interpolator output, pre-mixer (18-bit, DAC rate)
//   <tag>_tx_mix.txt   DUC mixer output, pre-scale (18-bit, DAC rate)
//   <tag>_tx_pins.txt  TX pin word (24-bit, DAC rate) = what the DAC sees
//   <tag>_air.txt      air model output (= RX input, 24-bit)
//   <tag>_rx_mix.txt   DDC mixer output, 24-bit (post ->8, pre 0.5 scale)
//   <tag>_rx_host.txt  host 16-bit complex word out of the RX quantiser
//
// Modes:
//   (default)      forward:  host -> TX0/TX1 -> pins -> [air] -> RX0/RX1 -> host
//   -DREVERSE      reverse:  antenna -> [air] -> RX0/RX1 -> TX0/TX1 -> pins
//   -DX2           transmit interpolation x2 (the MIMO rate); forward only,
//                  because the reverse path needs the RX at the full clock.
//
// The two channels carry disjoint tone sets, so any tone of channel 1 that
// appears in a channel 0 node is crosstalk, and it is measurable to the dither
// floor by construction.
`timescale 1ns/1ps

module tb_capture;

   localparam integer L    = 1024;   // period of the stimulus, host samples
   localparam integer NT   = 7;      // tone pairs per channel
   localparam integer NCYC = 2;      // periods captured

`ifdef X2
   localparam integer CLKS = L * NCYC * 2;   // DAC clocks in the window
`else
   localparam integer CLKS = L * NCYC;
`endif

   // bin pairs: disjoint between the two channels, |k| <= 150 (0.146 fs)
   integer kidx0 [0:NT-1];
   integer kidx1 [0:NT-1];
   initial begin
`ifdef MATCH
      kidx0[0]=8;   kidx0[1]=24;  kidx0[2]=47;  kidx0[3]=83;
      kidx0[4]=115; kidx0[5]=138; kidx0[6]=150;
      kidx1[0]=8;   kidx1[1]=24;  kidx1[2]=47;  kidx1[3]=83;
      kidx1[4]=115; kidx1[5]=138; kidx1[6]=150;
`else
      kidx0[0]=8;   kidx0[1]=24;  kidx0[2]=47;  kidx0[3]=83;
      kidx0[4]=115; kidx0[5]=138; kidx0[6]=150;
      kidx1[0]=13;  kidx1[1]=31;  kidx1[2]=59;  kidx1[3]=97;
      kidx1[4]=124; kidx1[5]=143; kidx1[6]=149;
`endif
   end

`ifdef AMPDEF
   localparam real AMP = `AMPDEF;    // level sweep: -DAMPDEF=16000.0
`else
   localparam real AMP = 7000.0;    // per channel tone-set amplitude, host units
`endif
   localparam real PI  = 3.14159265358979323846;

   real s0i [0:L-1], s0q [0:L-1], s1i [0:L-1], s1q [0:L-1];
   integer n, k;
   real ph, acc;
   initial begin
      for (n = 0; n < L; n = n + 1) begin
         s0i[n] = 0.0; s0q[n] = 0.0; s1i[n] = 0.0; s1q[n] = 0.0;
         for (k = 0; k < NT; k = k + 1) begin
            // deterministic pseudo-random phase per (channel, tone, sign)
            ph = 2.0*PI*(((k*37 + 11) % 181)/181.0);
            acc = 2.0*PI*kidx0[k]*n/L + ph;
            s0i[n] = s0i[n] + (AMP/NT)*$cos(acc);
            s0q[n] = s0q[n] + (AMP/NT)*$sin(acc);
            acc = 2.0*PI*(-kidx0[k])*n/L + ph + PI/3.0;
            s0i[n] = s0i[n] + (AMP/NT)*$cos(acc);
            s0q[n] = s0q[n] + (AMP/NT)*$sin(acc);
`ifdef MATCH
            ph = 2.0*PI*(((k*37 + 11) % 181)/181.0);
`else
            ph = 2.0*PI*(((k*53 + 97) % 227)/227.0);
`endif
            acc = 2.0*PI*kidx1[k]*n/L + ph;
            s1i[n] = s1i[n] + (AMP/NT)*$cos(acc);
            s1q[n] = s1q[n] + (AMP/NT)*$sin(acc);
`ifdef MATCH
            acc = 2.0*PI*(-kidx1[k])*n/L + ph + PI/3.0;
`else
            acc = 2.0*PI*(-kidx1[k])*n/L + ph + 2.0*PI/5.0;
`endif
            s1i[n] = s1i[n] + (AMP/NT)*$cos(acc);
            s1q[n] = s1q[n] + (AMP/NT)*$sin(acc);
         end
      end
   end

   // ---- converter model -------------------------------------------------
   // The AD9361 is a 12-bit part.  On the transmit side the FPGA hands it a
   // 12-bit word (dac_slice rounds the 24-bit datapath word to 12 bits); on
   // the receive side it returns 12 bits, which the datapath sees as a 24-bit
   // word with the low 12 bits zero.  With -DCONV the loop runs through those
   // two quantisers, which is what hardware does and simulation otherwise
   // flatters.
   function signed [23:0] q12(input signed [23:0] x);
      reg signed [23:0] a, m;
      begin
         a = (x < 0) ? -x : x;
         m = (a + 24'sd2048) >>> 12;
         if (m > 24'sd2047) m = 24'sd2047;
         q12 = (x < 0) ? -(m <<< 12) : (m <<< 12);
      end
   endfunction

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;
   reg run = 0;          // held low through the register writes in -DALIGN

   // ---- chains -----------------------------------------------------------
   reg        t0_stb=0; reg [7:0] t0_addr=0; reg [31:0] t0_data=0;
   reg        t1_stb=0; reg [7:0] t1_addr=0; reg [31:0] t1_data=0;
   reg        r0_stb=0; reg [7:0] r0_addr=0; reg [31:0] r0_data=0;
   reg        r1_stb=0; reg [7:0] r1_addr=0; reg [31:0] r1_data=0;
   wire [31:0] rx0_sample, rx1_sample;
   wire        rx0_strobe, rx1_strobe;
   wire [23:0] tx0_i, tx0_q, tx1_i, tx1_q;
   wire        tx0_strobe, tx1_strobe;
   wire [31:0] tx0_debug, tx1_debug;

`ifdef REVERSE
   reg [31:0] tx0_sample, tx1_sample;   // driven from the RX word below
`else
   reg [31:0] tx0_sample=0, tx1_sample=0;
`endif

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx0 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t0_stb), .set_addr(t0_addr), .set_data(t0_data),
      .tx_fe_i(tx0_i), .tx_fe_q(tx0_q),
      .sample(tx0_sample), .run(run), .strobe(tx0_strobe), .debug(tx0_debug));

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx1 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t1_stb), .set_addr(t1_addr), .set_data(t1_data),
      .tx_fe_i(tx1_i), .tx_fe_q(tx1_q),
      .sample(tx1_sample), .run(run), .strobe(tx1_strobe), .debug(tx1_debug));

   // ---- air model: delay 3, two-path multipath -18 dB, -30 dB coupling ----
   localparam integer D = 3;
`ifdef MATCH
   integer beta_den = 8, alpha_den = 1000000;   // no coupling: channels independent
`else
   integer beta_den = 8, alpha_den = 32;
`endif
   reg signed [23:0] d0i [0:D-1], d0q [0:D-1], d1i [0:D-1], d1q [0:D-1];
   integer di;
`ifdef REVERSE
   wire signed [23:0] src0_i, src0_q, src1_i, src1_q;
`endif

`ifdef REVERSE
   wire signed [23:0] ant0_i = src0_i, ant0_q = src0_q;
   wire signed [23:0] ant1_i = src1_i, ant1_q = src1_q;
`else
   wire signed [23:0] ant0_i = $signed(tx0_i), ant0_q = $signed(tx0_q);
   wire signed [23:0] ant1_i = $signed(tx1_i), ant1_q = $signed(tx1_q);
`endif

`ifdef CONV
   // What the converter sees on each side.  dac0/1 is the channel model's input
   // (the TX output when transmitting, the antenna source when looping back);
   // pind0/1 is always the quantised *transmitter* output, i.e. the word the
   // DAC actually receives.
   wire signed [23:0] dac0_i = q12(ant0_i), dac0_q = q12(ant0_q);
   wire signed [23:0] dac1_i = q12(ant1_i), dac1_q = q12(ant1_q);
   wire signed [23:0] pind0_i = q12(tx0_i), pind0_q = q12(tx0_q);
   wire signed [23:0] pind1_i = q12(tx1_i), pind1_q = q12(tx1_q);
`else
   wire signed [23:0] dac0_i = ant0_i, dac0_q = ant0_q;
   wire signed [23:0] dac1_i = ant1_i, dac1_q = ant1_q;
   wire signed [23:0] pind0_i = tx0_i, pind0_q = tx0_q;
   wire signed [23:0] pind1_i = tx1_i, pind1_q = tx1_q;
`endif

   always @(posedge clk) begin
      for (di = D-1; di > 0; di = di - 1) begin
         d0i[di] <= d0i[di-1]; d0q[di] <= d0q[di-1];
         d1i[di] <= d1i[di-1]; d1q[di] <= d1q[di-1];
      end
      d0i[0] <= dac0_i; d0q[0] <= dac0_q;
      d1i[0] <= dac1_i; d1q[0] <= dac1_q;
   end

   // The channel's sum is clamped to the converter's range instead of wrapping:
   // a real ADC saturates, and a wrapping model would fake a catastrophic
   // distortion that the hardware cannot produce.
   function signed [23:0] sat24(input signed [25:0] x);
      begin
         sat24 = (x > 26'sd8388607)  ? 24'sd8388607 :
                 (x < -26'sd8388608) ? -24'sd8388608 : x[23:0];
      end
   endfunction

   wire signed [25:0] sum0_i = dac0_i - (d0i[D-1] / beta_den) + (dac1_i / alpha_den);
   wire signed [25:0] sum0_q = dac0_q - (d0q[D-1] / beta_den) + (dac1_q / alpha_den);
   wire signed [25:0] sum1_i = dac1_i - (d1i[D-1] / beta_den) + (dac0_i / alpha_den);
   wire signed [25:0] sum1_q = dac1_q - (d1q[D-1] / beta_den) + (dac0_q / alpha_den);

   wire signed [23:0] air0_i = sat24(sum0_i), air0_q = sat24(sum0_q);
   wire signed [23:0] air1_i = sat24(sum1_i), air1_q = sat24(sum1_q);

`ifdef CONV
   wire signed [23:0] adc0_i = q12(air0_i), adc0_q = q12(air0_q);
   wire signed [23:0] adc1_i = q12(air1_i), adc1_q = q12(air1_q);
`else
   wire signed [23:0] adc0_i = air0_i, adc0_q = air0_q;
   wire signed [23:0] adc1_i = air1_i, adc1_q = air1_q;
`endif

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx0 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r0_stb), .set_addr(r0_addr), .set_data(r0_data),
      .rx_fe_i(adc0_i), .rx_fe_q(adc0_q),
      .sample(rx0_sample), .run(run), .strobe(rx0_strobe), .debug());

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx1 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r1_stb), .set_addr(r1_addr), .set_data(r1_data),
      .rx_fe_i(adc1_i), .rx_fe_q(adc1_q),
      .sample(rx1_sample), .run(run), .strobe(rx1_strobe), .debug());

`ifdef REVERSE
   always @(posedge clk) begin
      if (rx0_strobe) begin tx0_sample <= rx0_sample; tx1_sample <= rx1_sample; end
   end
`endif

   // ---- register writes ---------------------------------------------------
   task twr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch==0) begin t0_stb=1; t0_addr=a; t0_data=d; end
         else       begin t1_stb=1; t1_addr=a; t1_data=d; end
         @(negedge clk); t0_stb=0; t1_stb=0;
      end
   endtask
   task rwr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch==0) begin r0_stb=1; r0_addr=a; r0_data=d; end
         else       begin r1_stb=1; r1_addr=a; r1_data=d; end
         @(negedge clk); r0_stb=0; r1_stb=0;
      end
   endtask

   // ---- stimulus ----------------------------------------------------------
   integer p0 = 0, p1 = 0;
   integer si0, sq0, si1, sq1;

`ifdef REVERSE
   // antenna source: 24-bit, one sample per clock
   assign src0_i = $rtoi(s0i[p0]*256.0);
   assign src0_q = $rtoi(s0q[p0]*256.0);
   assign src1_i = $rtoi(s1i[p1]*256.0);
   assign src1_q = $rtoi(s1q[p1]*256.0);
   always @(posedge clk) begin
      p0 <= (p0 == L-1) ? 0 : p0 + 1;
      p1 <= (p1 == L-1) ? 0 : p1 + 1;
   end
`else
   // host source: 16-bit, one sample per DUC input strobe
   always @(posedge clk) begin
      if (tx0.strobe_hb1) begin
         si0 = $rtoi(s0i[p0]); sq0 = $rtoi(s0q[p0]);
         si1 = $rtoi(s1i[p1]); sq1 = $rtoi(s1q[p1]);
         // A multitone sums to up to 2x its per-component amplitude, so the
         // generator must saturate at the 16-bit rail like a host would; a
         // truncated word would wrap and fake a catastrophic distortion.
         if (si0 >  32767) si0 =  32767;
         if (si0 < -32768) si0 = -32768;
         if (sq0 >  32767) sq0 =  32767;
         if (sq0 < -32768) sq0 = -32768;
         if (si1 >  32767) si1 =  32767;
         if (si1 < -32768) si1 = -32768;
         if (sq1 >  32767) sq1 =  32767;
         if (sq1 < -32768) sq1 = -32768;
         tx0_sample <= { si0[15:0], sq0[15:0] };
         tx1_sample <= { si1[15:0], sq1[15:0] };
         p0 <= (p0 == L-1) ? 0 : p0 + 1;
         p1 <= (p1 == L-1) ? 0 : p1 + 1;
      end
   end
`endif

   // ---- dump --------------------------------------------------------------
   integer fd_host, fd_hb, fd_mix, fd_pins, fd_air, fd_rxmix, fd_rxhost;
   reg dump_en = 0;
   integer dn = 0;

   initial begin
`ifdef REVERSE
   `ifdef X2
      $fatal(1, "REVERSE and X2 are mutually exclusive: the reverse path needs the RX at the full clock");
   `endif
      fd_host   = $fopen("cap_rev_host.txt",   "w");
      fd_hb     = $fopen("cap_rev_tx_hb.txt",  "w");
      fd_mix    = $fopen("cap_rev_tx_mix.txt", "w");
      fd_pins   = $fopen("cap_rev_tx_pins.txt","w");
      fd_air    = $fopen("cap_rev_air.txt",    "w");
      fd_rxmix  = $fopen("cap_rev_rx_mix.txt", "w");
      fd_rxhost = $fopen("cap_rev_rx_host.txt","w");
`else
   `ifdef MATCH
      fd_host   = $fopen("cap_match_host.txt",   "w");
      fd_hb     = $fopen("cap_match_tx_hb.txt",  "w");
      fd_mix    = $fopen("cap_match_tx_mix.txt", "w");
      fd_pins   = $fopen("cap_match_tx_pins.txt","w");
      fd_air    = $fopen("cap_match_air.txt",    "w");
      fd_rxmix  = $fopen("cap_match_rx_mix.txt", "w");
      fd_rxhost = $fopen("cap_match_rx_host.txt","w");
   `elsif CONV
      fd_host   = $fopen("cap_conv_host.txt",   "w");
      fd_hb     = $fopen("cap_conv_tx_hb.txt",  "w");
      fd_mix    = $fopen("cap_conv_tx_mix.txt", "w");
      fd_pins   = $fopen("cap_conv_tx_pins.txt","w");
      fd_air    = $fopen("cap_conv_air.txt",    "w");
      fd_rxmix  = $fopen("cap_conv_rx_mix.txt", "w");
      fd_rxhost = $fopen("cap_conv_rx_host.txt","w");
   `elsif X2
      fd_host   = $fopen("cap_fwd_x2_host.txt",   "w");
      fd_hb     = $fopen("cap_fwd_x2_tx_hb.txt",  "w");
      fd_mix    = $fopen("cap_fwd_x2_tx_mix.txt", "w");
      fd_pins   = $fopen("cap_fwd_x2_tx_pins.txt","w");
      fd_air    = $fopen("cap_fwd_x2_air.txt",    "w");
      fd_rxmix  = $fopen("cap_fwd_x2_rx_mix.txt", "w");
      fd_rxhost = $fopen("cap_fwd_x2_rx_host.txt","w");
   `else
      fd_host   = $fopen("cap_fwd_x1_host.txt",   "w");
      fd_hb     = $fopen("cap_fwd_x1_tx_hb.txt",  "w");
      fd_mix    = $fopen("cap_fwd_x1_tx_mix.txt", "w");
      fd_pins   = $fopen("cap_fwd_x1_tx_pins.txt","w");
      fd_air    = $fopen("cap_fwd_x1_air.txt",    "w");
      fd_rxmix  = $fopen("cap_fwd_x1_rx_mix.txt", "w");
      fd_rxhost = $fopen("cap_fwd_x1_rx_host.txt","w");
   `endif
`endif
   end

   always @(posedge clk) begin
      if (dump_en) begin
`ifdef REVERSE
`ifdef CONV
         $fwrite(fd_air,    "%0d %0d\n", $signed(adc0_i),  $signed(adc0_q));
`else
         $fwrite(fd_air,    "%0d %0d\n", $signed(air0_i),  $signed(air0_q));
`endif
         $fwrite(fd_rxmix,  "%0d %0d\n", $signed(rx0.pipe_i), $signed(rx0.pipe_q));
         $fwrite(fd_rxhost, "%0d %0d\n", $signed(rx0_sample[31:16]), $signed(rx0_sample[15:0]));
         $fwrite(fd_hb,     "%0d %0d\n", $signed(tx0.i_interp), $signed(tx0.q_interp));
         $fwrite(fd_mix,    "%0d %0d\n", $signed(tx0.da_r), $signed(tx0.db_r));
         $fwrite(fd_pins,   "%0d %0d\n", $signed(pind0_i), $signed(pind0_q));
`else
`ifdef CONV
         $fwrite(fd_air,    "%0d %0d\n", $signed(adc0_i),  $signed(adc0_q));
`else
         $fwrite(fd_air,    "%0d %0d\n", $signed(air0_i),  $signed(air0_q));
`endif
         $fwrite(fd_rxmix,  "%0d %0d\n", $signed(rx0.pipe_i), $signed(rx0.pipe_q));
         $fwrite(fd_rxhost, "%0d %0d\n", $signed(rx0_sample[31:16]), $signed(rx0_sample[15:0]));
         $fwrite(fd_hb,     "%0d %0d\n", $signed(tx0.i_interp), $signed(tx0.q_interp));
         $fwrite(fd_mix,    "%0d %0d\n", $signed(tx0.da_r), $signed(tx0.db_r));
         $fwrite(fd_pins,   "%0d %0d\n", $signed(pind0_i), $signed(pind0_q));
         if (tx0.strobe_hb1)
           $fwrite(fd_host, "%0d %0d\n", $signed(tx0_sample[31:16]), $signed(tx0_sample[15:0]));
`endif
      end
   end

   // Channel 1 gets the same end nodes as channel 0 - its host word in, its
   // interpolator, its pin word and its receive host word - so both channels
   // are graded identically at the ends, not one measured and one assumed.
   integer fd_dac, fd_adc;

   integer fd_pins1, fd_rxhost1, fd_host1, fd_hb1, fd_air1;
   initial begin
`ifdef REVERSE
      fd_pins1   = $fopen("cap_rev_tx_pins1.txt", "w");
      fd_rxhost1 = $fopen("cap_rev_rx_host1.txt","w");
      fd_host1   = $fopen("cap_rev_host1.txt",   "w");
      fd_hb1     = $fopen("cap_rev_hb1.txt",     "w");
      fd_air1    = $fopen("cap_rev_air1.txt",    "w");
      fd_dac     = $fopen("cap_rev_dac.txt", "w");
      fd_adc     = $fopen("cap_rev_adc.txt", "w");
`else
   `ifdef MATCH
      fd_pins1   = $fopen("cap_match_tx_pins1.txt", "w");
      fd_rxhost1 = $fopen("cap_match_rx_host1.txt","w");
      fd_host1   = $fopen("cap_match_host1.txt",   "w");
      fd_hb1     = $fopen("cap_match_hb1.txt",     "w");
      fd_air1    = $fopen("cap_match_air1.txt",    "w");
      fd_dac     = $fopen("cap_match_dac.txt", "w");
      fd_adc     = $fopen("cap_match_adc.txt", "w");
   `elsif CONV
      fd_pins1   = $fopen("cap_conv_tx_pins1.txt", "w");
      fd_rxhost1 = $fopen("cap_conv_rx_host1.txt","w");
      fd_host1   = $fopen("cap_conv_host1.txt",   "w");
      fd_hb1     = $fopen("cap_conv_hb1.txt",     "w");
      fd_air1    = $fopen("cap_conv_air1.txt",    "w");
      fd_dac     = $fopen("cap_conv_dac.txt", "w");
      fd_adc     = $fopen("cap_conv_adc.txt", "w");
   `elsif X2
      fd_pins1   = $fopen("cap_fwd_x2_tx_pins1.txt", "w");
      fd_rxhost1 = $fopen("cap_fwd_x2_rx_host1.txt","w");
      fd_host1   = $fopen("cap_fwd_x2_host1.txt",   "w");
      fd_hb1     = $fopen("cap_fwd_x2_hb1.txt",     "w");
      fd_air1    = $fopen("cap_fwd_x2_air1.txt",    "w");
      fd_dac     = $fopen("cap_fwd_x2_dac.txt", "w");
      fd_adc     = $fopen("cap_fwd_x2_adc.txt", "w");
   `else
      fd_pins1   = $fopen("cap_fwd_x1_tx_pins1.txt", "w");
      fd_rxhost1 = $fopen("cap_fwd_x1_rx_host1.txt","w");
      fd_host1   = $fopen("cap_fwd_x1_host1.txt",   "w");
      fd_hb1     = $fopen("cap_fwd_x1_hb1.txt",     "w");
      fd_air1    = $fopen("cap_fwd_x1_air1.txt",    "w");
      fd_dac     = $fopen("cap_fwd_x1_dac.txt", "w");
      fd_adc     = $fopen("cap_fwd_x1_adc.txt", "w");
   `endif
`endif
   end
   always @(posedge clk) begin
      if (dump_en) begin
         $fwrite(fd_pins1,   "%0d %0d\n", $signed(pind1_i), $signed(pind1_q));
         $fwrite(fd_hb1,     "%0d %0d\n", $signed(tx1.i_interp), $signed(tx1.q_interp));
         if (tx1.strobe_hb1)
           $fwrite(fd_host1, "%0d %0d\n", $signed(tx1_sample[31:16]), $signed(tx1_sample[15:0]));
         $fwrite(fd_rxhost1, "%0d %0d\n", $signed(rx1_sample[31:16]), $signed(rx1_sample[15:0]));
`ifdef CONV
         $fwrite(fd_air1,    "%0d %0d\n", $signed(adc1_i), $signed(adc1_q));
`else
         $fwrite(fd_air1,    "%0d %0d\n", $signed(air1_i), $signed(air1_q));
`endif
         $fwrite(fd_dac,     "%0d %0d\n", dac0_i, dac0_q);
         $fwrite(fd_adc,     "%0d %0d\n", adc0_i, adc0_q);
      end
   end

   initial begin
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      repeat (4) @(negedge clk);

`ifdef ALIGN
      // Both oscillators start from phase 0 at the same clock: write the
      // frequencies with run low, then release.  Without this the second
      // channel's write lands two clocks later and its NCO is 90 deg ahead.
      run = 1;   // the accumulator only resets while run is low at reset time
      @(negedge clk); run = 0;
`endif
`ifdef UNALIGNED
      // A naive driver: the datapath is already running while the two
      // channels' registers are written one after the other.
      run = 1;
`endif
      // NCO at fs/8 on both sides: the composite RX->TX rotation is exactly 1.
`ifdef X2
      // BASE+2 = {enable_hb1, enable_hb2, interp_rate}: hb1 on, CIC rate 1 = x2
      twr(0,8'd0,32'h2000_0000); twr(0,8'd1,32'h00008000); twr(0,8'd2,32'h0000_0201);
      twr(1,8'd0,32'h2000_0000); twr(1,8'd1,32'h00008000); twr(1,8'd2,32'h0000_0201);
`else
      twr(0,8'd0,32'h2000_0000); twr(0,8'd1,32'h00008000); twr(0,8'd2,32'h0000_0001);
      twr(1,8'd0,32'h2000_0000); twr(1,8'd1,32'h00008000); twr(1,8'd2,32'h0000_0001);
`endif
      rwr(0,8'd0,32'h2000_0000); rwr(0,8'd3,0);
      rwr(1,8'd0,32'h2000_0000); rwr(1,8'd3,0);
`ifndef ALIGN
   `ifndef UNALIGNED
      run = 1;            // gated start: both accumulators released together
   `endif
`endif
`ifdef ALIGN
      @(negedge clk); run = 1;
`endif
      repeat (400) @(posedge clk);

      $display("CFG: sr2=0x%03x hb1=%0d hb2=%0d rate=%0d strobe_hb1=%0d", tx0.sr_2.out, tx0.enable_hb1, tx0.enable_hb2, tx0.interp_rate, tx0.strobe_hb1);
      @(negedge clk); dump_en = 1;
      repeat (CLKS) @(posedge clk);
      @(negedge clk); dump_en = 0;
      repeat (4) @(posedge clk);
      $fclose(fd_host); $fclose(fd_hb); $fclose(fd_mix); $fclose(fd_pins);
      $fclose(fd_air); $fclose(fd_rxmix); $fclose(fd_rxhost);
      $fclose(fd_pins1); $fclose(fd_rxhost1);
      $fclose(fd_host1); $fclose(fd_hb1); $fclose(fd_air1);
      $fclose(fd_dac); $fclose(fd_adc);
      $display("CAPTURE: done (%0d clocks dumped)", CLKS);
      $finish;
   end

endmodule
