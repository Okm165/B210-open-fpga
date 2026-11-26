// SPDX-License-Identifier: GPL-3.0-or-later
//
// ad9361_port_model - the AD9361's CMOS dual-port full-duplex DDR sample
// port as the FPGA's pins see it (UG-570 Figures 74, 75, registers 0x010
// = 0xC8, 0x011 = 0x00, 0x012 = 0x02: RX_FRAME in pulse mode). Time in ns.
//
// DATA_CLK: period T, from the model. rx: sample time k carries
// rxval(k, f) for f = 0 I0, 1 Q0, 2 I1, 3 Q1 (bijective in k mod 4096 for
// every f: 4096 consecutive sample times carry every 12-bit code in every
// field). Each word leaves on a DATA_CLK edge: undefined from DLY to DLY +
// 1.5 ns after it (tDDRX 0 .. 1.5 ns, the AD9361's data delay and the
// board's clock lag folded into DLY), then valid; RX_FRAME likewise (tDDDV
// 1.0 ns).
//   1R1T  per period: I0 (rising), Q0 (falling); RX_FRAME high, low
//   2R2T  per 2 periods: I0, Q0 with RX_FRAME high; I1, Q1 with it low
// rxt[k mod 65536]: when sample time k's last word left (its falling edge).
// `two` is taken at the start of a frame (the first rising edge after it
// changes in 1R1T, a channel-0 period in 2R2T). quiet: RX_FRAME stays low.
// tx: P1 and TX_FRAME sampled TX_AT ns after each FB_CLK edge, checked
// stable 1 ns before (tSTX) and up to the sample (tHTX = 0); the word with
// FB_CLK high is I, with it low Q. Decoded by the frame:
//   1R1T  every period must be frame (1, 0): sample {0, 0, Q, I}
//   2R2T  periods alternate frame (1, 1) channel 0, (0, 0) channel 1:
//         sample {Q1, I1, Q0, I0} after channel 1
// Decoded sample times go to txs[0 .. ntx-1] (mod 65536), with txt[] the
// time its first word (I0) was sampled; anything else counts in
// tx_errors (while `check` is high).
// FAULT 1: rx I and Q swapped on the bus. FAULT 2: rx frame one period
// late (in 2R2T it then marks channel 1).
`timescale 1ns/1ps
`default_nettype none

module ad9361_port_model #(
  parameter real T = 16.276,          // DATA_CLK period: 61.44 MHz
  parameter real DLY = 1.35,          // rx launch delay after each edge (see above)
  parameter real TX_AT = 4.0,         // tx sample point after each FB_CLK edge
  parameter FAULT = 0
) (
  input  wire        two, run, check, quiet,
  output reg         data_clk = 0,
  output reg         rx_frame = 0,
  output reg  [11:0] rx_d = 0,
  input  wire        fb_clk, tx_frame,
  input  wire [11:0] tx_d
);
  function [11:0] rxval(input integer k, input integer f);
    case (f)
      0: rxval = 1029 * k + 17;
      1: rxval = 2053 * k + 1000;
      2: rxval = 3077 * k + 2222;
      default: rxval = 517 * k + 3333;
    endcase
  endfunction

  // -- DATA_CLK and rx ---------------------------------------------------------------
  always begin #(T / 2); data_clk = run && !data_clk; end
  integer    k = 0;                   // the sample time being sent
  reg        m2 = 0;                  // the mode of the current frame
  reg        second = 0;              // 2R2T: in channel 1's period
  reg        f_late = 0;              // FAULT 2: the previous period's frame
  reg        ends = 0;                // this period ends a sample time
  realtime   rxt [0:65535];
  reg [11:0] wi, wq;
  reg        wf;
  task launch(input [11:0] w, input f);
    begin
      rx_d <= #(DLY) 12'bx;        rx_d <= #(DLY + 1.5) w;
      rx_frame <= #(DLY) 1'bx;     rx_frame <= #(DLY + 1.0) f;
    end
  endtask
  always @(posedge data_clk) begin
    if (!second) m2 = two;            // a frame starts
    if (!m2) begin
      wi = rxval(k, 0); wq = rxval(k, 1); wf = 1; k = k + 1; second = 0; ends = 1;
    end else if (!second) begin
      wi = rxval(k, 0); wq = rxval(k, 1); wf = 1; second = 1; ends = 0;
    end else begin
      wi = rxval(k, 2); wq = rxval(k, 3); wf = 0; k = k + 1; second = 0; ends = 1;
    end
    if (FAULT == 1) begin wi = wi ^ wq; wq = wi ^ wq; wi = wi ^ wq; end
    if (FAULT == 2) begin f_late <= wf; wf = f_late; end
    if (quiet) wf = 0;
    launch(wi, wf);
  end
  always @(negedge data_clk) begin
    launch(wq, m2 ? wf : 1'b0);
    if (ends) rxt[(k - 1) % 65536] = $realtime;
  end

  // -- tx ----------------------------------------------------------------------------------
  reg [47:0] txs [0:65535];
  realtime   txt [0:65535], t_hi = 0, t_hi0 = 0;
  integer    ntx = 0, tx_errors = 0;
  realtime   t_chg = 0;
  always @(tx_d or tx_frame) t_chg = $realtime;
  reg [11:0] hi_w, lo_w;
  reg        hi_f, lo_f, have0 = 0;
  reg [23:0] c0;
  task tx_err(input [8*40-1:0] what);
    if (check) begin
      tx_errors = tx_errors + 1;
      if (tx_errors <= 5) $display("%0t ad9361 tx: %0s", $time, what);
    end
  endtask
  always @(posedge fb_clk) begin
    #(TX_AT);
    if ($realtime - t_chg < 1.0) tx_err("P1 setup (tSTX)");
    hi_w = tx_d; hi_f = tx_frame; t_hi = $realtime;
  end
  always @(negedge fb_clk) begin
    #(TX_AT);
    if ($realtime - t_chg < 1.0) tx_err("P1 setup (tSTX)");
    lo_w = tx_d; lo_f = tx_frame;
    if (^{hi_w, lo_w, hi_f, lo_f} === 1'bx) tx_err("P1 undefined");
    else if (!two) begin
      if ({hi_f, lo_f} != 2'b10) tx_err("1R1T frame not high, low");
      else begin txs[ntx % 65536] = {24'd0, lo_w, hi_w}; txt[ntx % 65536] = t_hi; ntx = ntx + 1; end
      have0 = 0;
    end else if ({hi_f, lo_f} == 2'b11) begin
      if (have0) tx_err("2R2T channel 0 twice");
      c0 = {lo_w, hi_w}; have0 = 1; t_hi0 = t_hi;
    end else if ({hi_f, lo_f} == 2'b00) begin
      if (!have0) tx_err("2R2T channel 1 without channel 0");
      else begin txs[ntx % 65536] = {lo_w, hi_w, c0}; txt[ntx % 65536] = t_hi0; ntx = ntx + 1; end
      have0 = 0;
    end else begin
      tx_err("2R2T frame half high"); have0 = 0;
    end
  end
endmodule

`default_nettype wire
