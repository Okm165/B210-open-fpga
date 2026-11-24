// tb_io_handover.v - received samples across the capture-clock -> radio_clk
// boundary of b200_io, with the clock skew the tools do not constrain.
//
// An AD9361 model drives known sequences on the DDR bus in 1R1T and in 2R2T
// framing: sample n carries I0 = n, Q0 = n ^ AAA, I1 = n + 1000,
// Q1 = (n + 1000) ^ 555.  A model of the radio core samples the b200_io
// outputs with radio_clk delayed by SKEW and every data bit delayed by its
// own amount between 0.4 and 2.5 ns, as a routed design does.  For SKEW from
// 0.4 to 7.6 ns (the design's limit is half a 61.44 MHz period, 8.1 ns, plus
// the shortest path), both phases of the /2 divider and both modes, every
// word the radio sees must
//   * be fully defined (no X or Z bit),
//   * be a whole sample (I and Q of one instant), the two channels being
//     the two halves of one pair,
//   * follow the previous word by exactly one sample, and
//   * be the sample the converter put on the pins LAG periods earlier, LAG
//     being one constant per case within LAG_MIN..LAG_MAX: the word is
//     compared with the stimulus counter itself, not only with its own
//     fields, so a constant, stale or made-up word cannot pass.
//
// Control: the same radio model fed from the register that changes on the
// capture clock's rising edge (the direct crossing) must show torn or
// out-of-order words for some skew.
`timescale 1ns/1ps

module handover_case #(
   parameter real    SKEW  = 1.0,
   parameter integer MIMO  = 0,
   parameter integer PHASE = 0,     // release of the divider reset, in half periods
   parameter integer DIRECT = 0     // 1: tap the rising-edge register (control)
) (output reg [31:0] words,    // words the radio sampled
   output reg [31:0] torn,     // not a whole sample / pair, or out of order
   output reg [31:0] xwords,   // with an X or Z bit
   output reg [31:0] stale,    // not the sample sent LAG periods earlier
   output integer    lag0);    // LAG of this case

   // Sample periods (1R1T) or pairs (2R2T) from the pins to the radio's
   // register.  The design measures 1 or 2, depending on mode, divider phase
   // and skew; one more is allowed.
   localparam integer LAG_MIN = 1;
   localparam integer LAG_MAX = 3;

   localparam real HALF = 8.138;    // 61.44 MHz
   reg rx_clk = 0;
   always #(HALF) rx_clk = ~rx_clk;

   // AD9361 model: I on the falling edge, Q on the next rising edge; in 2R2T
   // the frame is high for channel 0 and low for channel 1.
   reg [11:0] n = 0;
   reg        ch = 0;
   reg [11:0] rx_data = 0;
   reg        rx_frame = 0;
   wire [11:0] i0 = n,              q0 = n ^ 12'hAAA;
   wire [11:0] i1 = n + 12'd1000,   q1 = (n + 12'd1000) ^ 12'h555;
   always @(posedge rx_clk) begin   // launch I, sampled at the falling edge
      #1.0;
      if (MIMO) begin
         rx_frame <= ~ch;
         rx_data  <= ch ? i1 : i0;
      end else begin
         rx_frame <= 1'b1;
         rx_data  <= i0;
      end
   end
   always @(negedge rx_clk) begin   // launch Q, sampled at the rising edge
      #1.0;
      rx_data <= MIMO ? (ch ? q1 : q0) : q0;
      if (!MIMO) rx_frame <= 1'b0;
   end
   always @(posedge rx_clk) begin   // next sample
      #0.5;
      if (MIMO) begin
         if (ch) n <= n + 12'd1;
         ch <= ~ch;
      end else n <= n + 12'd1;
   end

   reg areset = 1;
   initial #(40.0 + PHASE * HALF) areset = 0;

   wire radio_clk;
   wire [11:0] o_i0, o_q0, o_i1, o_q1;
   b200_io #(.RX_IDELAY_TAPS(0)) dut (
      .areset(areset), .idelay_refclk(1'b0), .idelay_rst(1'b0), .mimo(MIMO != 0),
      .radio_clk(radio_clk), .radio_rst(),
      .rx_i0(o_i0), .rx_q0(o_q0), .rx_i1(o_i1), .rx_q1(o_q1), .rx_stb(),
      .tx_i0(12'd0), .tx_q0(12'd0), .tx_i1(12'd0), .tx_q1(12'd0), .tx_stb(),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(), .tx_frame(), .tx_data());

   // the radio core: skewed clock, per-bit routing delay
   wire [47:0] src = DIRECT ? dut.pair : {o_i0, o_q0, o_i1, o_q1};
   wire [47:0] at_radio;
   genvar b;
   generate
      for (b = 0; b < 48; b = b + 1) begin : route
         assign #(0.4 + 2.1 * ((b * 37) % 48) / 47.0) at_radio[b] = src[b];
      end
   endgenerate
   wire #(SKEW) radio_clk_d = radio_clk;

   // the stimulus counter as it stands at the (undelayed) radio_clk edge: it
   // changes 0.5 ns after the capture clock, never at this edge
   reg [11:0] n_edge = 0;
   always @(posedge radio_clk) n_edge = n;

   reg [47:0] got;
   reg [11:0] prev;
   reg        have_prev = 0;
   integer    settle = 0, lag;
   initial begin words = 0; torn = 0; xwords = 0; stale = 0; lag0 = -1; end
   always @(posedge radio_clk_d) begin
      got = at_radio;
      settle = settle + 1;
      if (settle > 64) begin
         words = words + 1;
         if (^got === 1'bx) begin                                                  // undefined
            xwords = xwords + 1;
            have_prev = 0;
         end else begin
            if (got[35:24] !== (got[47:36] ^ 12'hAAA)) torn = torn + 1;           // torn ch0
            else if (MIMO && got[23:12] !== (got[47:36] + 12'd1000)) torn = torn + 1;   // pairing
            else if (MIMO && got[11:0] !== (got[23:12] ^ 12'h555)) torn = torn + 1;     // torn ch1
            else if (!MIMO && got[23:0] !== got[47:24]) torn = torn + 1;
            else if (have_prev && got[47:36] !== prev + 12'd1) torn = torn + 1;   // order
            // absolute: this is the sample sent `lag` periods ago, always the same lag
            lag = (n_edge - got[47:36]) & 4095;
            if (lag0 < 0) lag0 = lag;
            if (lag != lag0 || lag < LAG_MIN || lag > LAG_MAX) stale = stale + 1;
            prev = got[47:36];
            have_prev = 1;
         end
      end
   end
endmodule

module tb_io_handover;
   localparam integer NS = 19;      // SKEW = 0.4 .. 7.6 ns
   localparam integer NC = NS * 4;
   wire [31:0] w  [0:NC-1], t  [0:NC-1], x  [0:NC-1], st  [0:NC-1], lg  [0:NC-1];
   wire [31:0] wd [0:NC-1], td [0:NC-1], xd [0:NC-1], std [0:NC-1], lgd [0:NC-1];
   genvar s, m, ph;
   generate
      for (s = 0; s < NS; s = s + 1) begin : skew
         for (m = 0; m < 2; m = m + 1) begin : mode
            for (ph = 0; ph < 2; ph = ph + 1) begin : phase
               handover_case #(.SKEW(0.4 * (s + 1)), .MIMO(m), .PHASE(ph * 2), .DIRECT(0))
                  c (.words(w[s*4 + m*2 + ph]), .torn(t[s*4 + m*2 + ph]),
                     .xwords(x[s*4 + m*2 + ph]), .stale(st[s*4 + m*2 + ph]),
                     .lag0(lg[s*4 + m*2 + ph]));
               handover_case #(.SKEW(0.4 * (s + 1)), .MIMO(m), .PHASE(ph * 2), .DIRECT(1))
                  d (.words(wd[s*4 + m*2 + ph]), .torn(td[s*4 + m*2 + ph]),
                     .xwords(xd[s*4 + m*2 + ph]), .stale(std[s*4 + m*2 + ph]),
                     .lag0(lgd[s*4 + m*2 + ph]));
            end
         end
      end
   endgenerate

   integer k, bad, starved, ctl_bad, ctl_x, total, lag_min, lag_max;
   initial begin
      #70000;
      bad = 0; starved = 0; ctl_bad = 0; ctl_x = 0; total = 0;
      lag_min = 1 << 30; lag_max = -1;
      for (k = 0; k < NC; k = k + 1) begin
         total = total + w[k];
         if (t[k] != 0 || x[k] != 0 || st[k] != 0) begin
            bad = bad + 1;
            $display("  FAIL skew %0.1f ns mode %0d phase %0d: %0d torn, %0d undefined, %0d stale (lag %0d) in %0d words",
                     0.4 * (k/4 + 1), (k/2) % 2, k % 2, t[k], x[k], st[k], $signed(lg[k]), w[k]);
         end
         if ($signed(lg[k]) < lag_min) lag_min = $signed(lg[k]);
         if ($signed(lg[k]) > lag_max) lag_max = $signed(lg[k]);
         if (w[k] < 1000) starved = starved + 1;
         // the control must fail the way a bad crossing fails: defined words
         // that are torn or out of order
         if (td[k] != 0) ctl_bad = ctl_bad + 1;
         if (xd[k] != 0 || wd[k] < 1000) ctl_x = ctl_x + 1;
      end
      $display("hand-over: %0d cases, %0d words checked against the stimulus, lag %0d..%0d periods, %0d cases with errors, %0d starved",
               NC, total, lag_min, lag_max, bad, starved);
      $display("control (direct crossing): %0d of %0d cases with torn or out-of-order words, %0d undefined or starved",
               ctl_bad, NC, ctl_x);
      if (bad == 0 && starved == 0 && ctl_bad > 0 && ctl_x == 0)
         $display("PASS: samples cross to radio_clk whole, paired, in order and unaltered for every skew and divider phase");
      else
         $display("FAIL: hand-over");
      $finish;
   end
endmodule
