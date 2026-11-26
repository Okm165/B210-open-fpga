// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_ad9361_io - ad9361_io against the AD9361 data-port model
// (ad9361_port_model.v) at 61.44 MHz, both directions at once, with the
// sample side driven as sample_domain drives it (dac changes at strobes).
//
// Phases: 1R1T, a change to 2R2T, 2R2T with RX_FRAME held low for a while
// and back, 2R2T with RX_FRAME held high at the design's pin for a while
// and back (the frame never starts again: the strobe must keep every other
// period, then lock to the frame when it toggles), a change to 1R1T. The model and the design change mode a
// random few periods apart, in a random order; checks pause while they
// disagree and settle. In every checked stretch:
//   rx  every strobe's adc is the model's next sample time, exactly
//       ({0, 0, Q0, I0} in 1R1T); the first is found among the last 64
//       sent, then each must follow the previous with nothing lost
//   tx  every sample time the model decodes from P1 and TX_FRAME (frame
//       pattern checked) is the next dac value, exactly (channel 0 only in
//       1R1T, whatever channel 1 of dac holds)
//   stb every period in 1R1T, every other period in 2R2T, also while
//       RX_FRAME is absent
// and the latency is exact: rx, adc and stb change 1.5 periods after the
// falling edge that launches a sample time's last word (1 period after the
// rising edge that captures it); tx, a sample time's first word (I0) leaves
// on FB_CLK's rising edge 2 periods after the edge where dac changes to it. Each stretch must check >= 4096 consecutive sample times in
// both directions: the values are bijective in the sample time mod 4096,
// so every 12-bit code passes in every field of the mode, both ways.
// DLY: the model's rx launch delay (ns, ad9361_port_model.v); the eye in
// this model is 0 .. 5.07 ns: the word plus its 1.5 ns of tDDRX plus the
// 1.56 ns input delay must settle within T/2 = 8.14 ns (and DLY >= 0).
// FAULT 1: rx I and Q swapped on the bus (must be caught).
// FAULT 2: RX_FRAME one period late, marking channel 1 (must be caught).
// FAULT 3: TX_FRAME reaches the AD9361 one period late (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_ad9361_io;
  parameter SEED = 1, FAULT = 0;
  parameter real DLY = 1.35;
  localparam real T = 16.276;
  localparam integer NEED = 4096;

  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  reg ref200 = 0;
  always #2.5 ref200 = ~ref200;
  reg ref_rst = 1, run = 0, check = 0, quiet = 0, two_m = 0, two_d = 0;
  reg high = 0;                        // RX_FRAME held high at the design's pin
  wire        data_clk, rx_frame, fb_clk, tx_frame, delay_ready, dclk, stb;
  wire [11:0] rx_d, tx_d;
  wire [47:0] adc;
  reg  [47:0] dac = 0;
  reg         tx_frame_m = 0;          // TX_FRAME as the AD9361 sees it

  ad9361_port_model #(.T(T), .DLY(DLY), .FAULT(FAULT == 1 || FAULT == 2 ? FAULT : 0)) m (
    .two(two_m), .run(run), .check(check), .quiet(quiet), .data_clk(data_clk), .rx_frame(rx_frame), .rx_d(rx_d),
    .fb_clk(fb_clk), .tx_frame(tx_frame_m), .tx_d(tx_d));
  always @(tx_frame) tx_frame_m <= #(FAULT == 3 ? T : 0.0) tx_frame;
  wire rx_frame_d = high ? 1'b1 : rx_frame;
  ad9361_io dut (.data_clk(data_clk), .rx_frame(rx_frame_d), .rx_d(rx_d), .fb_clk(fb_clk), .tx_frame(tx_frame),
    .tx_d(tx_d), .ref200(ref200), .ref_rst(ref_rst), .delay_ready(delay_ready), .dclk(dclk), .two_async(two_d),
    .stb(stb), .adc(adc), .dac(dac));

  function [47:0] rx_exp(input integer k, input two);
    rx_exp = {two ? {m.rxval(k, 3), m.rxval(k, 2)} : 24'd0, m.rxval(k, 1), m.rxval(k, 0)};
  endfunction
  function [47:0] txval(input integer k);
    txval = {12'd2741 * k[11:0] + 12'd99, 12'd1543 * k[11:0] + 12'd7, 12'd3001 * k[11:0] + 12'd555, 12'd877 * k[11:0] + 12'd4000};
  endfunction
  function [47:0] tx_exp(input integer k, input two);
    tx_exp = two ? txval(k) : {24'd0, txval(k) & 48'hFFFFFF};
  endfunction

  // -- the sample side: dac changes at strobes ------------------------------------------------
  integer kt = 0;
  realtime t_dac [0:65535];
  always @(posedge dclk) if (stb) begin dac <= txval(kt); t_dac[kt % 65536] = $realtime; kt <= kt + 1; end
  task latency(input [8*2-1:0] dir, input real got, input real want);
    if (got < want - 0.01 || got > want + 0.01) begin
      errors = errors + 1; if (errors < 10) $display("%0t %0s latency %0f ns, expected %0f", $time, dir, got, want);
    end
  endtask

  // -- rx: every strobe; stb pattern ---------------------------------------------------------------
  reg     rx_lock = 0, stb_p = 0;
  integer rx_next = 0, rx_run = 0, rx_lag = 0, i;
  always @(posedge dclk) if (check) begin
    if (two_m ? stb == stb_p : !stb) begin
      errors = errors + 1; if (errors < 10) $display("%0t stb %b after %b in %0s", $time, stb, stb_p, two_m ? "2R2T" : "1R1T");
    end
    if (stb && !quiet && !high) begin
      if (!rx_lock) begin
        for (i = m.k - 64; i <= m.k; i = i + 1) if (!rx_lock && i >= 0 && adc === rx_exp(i, two_m)) begin
          rx_lock = 1; rx_next = i; rx_lag = m.k - i;
        end
        if (!rx_lock) begin errors = errors + 1; if (errors < 10) $display("%0t rx %h: no recent sample time", $time, adc); end
      end
      if (rx_lock) begin
        if (adc !== rx_exp(rx_next, two_m) || m.k - rx_next != rx_lag) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t rx %h, expected %h (sample time %0d, lag %0d, was %0d)", $time, adc,
                                    rx_exp(rx_next, two_m), rx_next, m.k - rx_next, rx_lag);
        end else rx_run = rx_run + 1;
        // read at the edge after adc changed: 1.5 + 1 periods after the launch
        latency("rx", $realtime - m.rxt[rx_next % 65536], 2.5 * T);
        rx_next = rx_next + 1;
      end
    end
  end
  always @(posedge dclk) stb_p <= stb;

  // -- tx: every sample time the model decodes -------------------------------------------------------
  reg     tx_lock = 0;
  integer tx_seen = 0, tx_next = 0, tx_run = 0, tx_lag = 0;
  reg [47:0] got;
  always @(posedge dclk) begin
    if (!check) tx_seen = m.ntx;
    while (check && tx_seen < m.ntx) begin
      got = m.txs[tx_seen % 65536]; tx_seen = tx_seen + 1;
      if (!tx_lock) begin
        for (i = kt - 64; i <= kt; i = i + 1) if (!tx_lock && i >= 0 && got === tx_exp(i, two_m)) begin
          tx_lock = 1; tx_next = i; tx_lag = kt - i;
        end
        if (!tx_lock) begin errors = errors + 1; if (errors < 10) $display("%0t tx %h: no recent dac value", $time, got); end
      end
      if (tx_lock) begin
        if (got !== tx_exp(tx_next, two_m) || kt - tx_next != tx_lag) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t tx %h, expected %h (sample time %0d, lag %0d, was %0d)", $time, got,
                                    tx_exp(tx_next, two_m), tx_next, kt - tx_next, tx_lag);
        end else tx_run = tx_run + 1;
        latency("tx", m.txt[(tx_seen - 1) % 65536] - 4.0 - t_dac[tx_next % 65536], 2.0 * T);
        tx_next = tx_next + 1;
      end
    end
  end

  // -- run --------------------------------------------------------------------------------------------
  task periods(input integer n); repeat (n) @(posedge dclk); endtask
  // check a stretch: both directions >= NEED consecutive sample times
  task stretch(input [8*24-1:0] what);
    begin
      rx_lock = 0; tx_lock = 0; rx_run = 0; tx_run = 0;
      check = 1;
      while ((rx_run < NEED || tx_run < NEED) && errors < 10) periods(1);
      check = 0;
      $display("%0t %0s: %0d rx and %0d tx sample times exact, lag rx %0d tx %0d sample times", $time, what,
               rx_run, tx_run, rx_lag, tx_lag);
    end
  endtask
  // change the mode in the model and the design a few periods apart
  task change(input to);
    begin
      periods(rnd(7));
      if (rnd(2)) begin two_m = to; periods(rnd(5)); two_d = to; end
      else        begin two_d = to; periods(rnd(5)); two_m = to; end
      periods(16);
    end
  endtask
  initial begin
    #100 ref_rst = 0;
    run = 1;
    periods(40 + rnd(3));
    if (!delay_ready) begin errors = errors + 1; $display("delays not ready"); end
    stretch("1R1T");
    change(1);
    stretch("2R2T");
    // RX_FRAME absent: the strobe keeps every other period; then it locks again
    quiet = 1; check = 1; periods(301 + rnd(2)); check = 0; quiet = 0; periods(8);
    stretch("2R2T after no frame");
    // RX_FRAME held high: no frame starts; the strobe keeps every other period, then locks again
    high = 1; check = 1; periods(301 + rnd(2)); check = 0; high = 0; periods(8);
    stretch("2R2T after frame high");
    change(0);
    stretch("1R1T again");
    if (m.tx_errors != 0) begin errors = errors + 1; $display("tx frame or timing: %0d errors", m.tx_errors); end
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
  initial begin #5_000_000; $display("timeout"); $display("RESULT: FAIL"); $finish; end
endmodule

`default_nettype wire
