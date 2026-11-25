//
// b200_leds - what the board's LEDs say.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Green is data flowing, amber is transmitting, red is an alarm and nothing
// else.  Every pin lights its LED when high (schematic V2.1, sheet 11).
//
//   RF port LEDs, two per channel (TX/RX and RX2), green and red in one case:
//     green, shimmering   receiving through this port
//     amber, shimmering   transmitting (TX/RX port)
//     red, 0.2 s          samples were lost: receive overflow or late command
//                         on the RX2 LED; transmit underflow, late or
//                         out-of-sequence packet on the TX/RX LED
//     dark                idle
//   Which port and which direction is UHD's antenna-switch state, the word the
//   stock image puts on these LEDs as it is.  The shimmer is that direction's
//   sample counter: dark for an eighth of every 4 M samples, so it runs at the
//   sample rate - 7 blinks a second at 30.72 MS/s, one every 4 s at 1 MS/s.
//
//   CLK     green   the AD9361 data clock is running; a blink at every PPS
//           dark    the AD9361 is not initialised yet
//           red     the FPGA's clocks are not locked or the receive input
//                   delays are not calibrated
//   USR     green   a flash for every control packet from the host
//           red     samples were lost on some channel within the last 2 s
//   STATUS  blue    a heartbeat from the bus clock
//
module b200_leds #(
   parameter SHIMMER = 22,    // dark for 2^(SHIMMER-3) of every 2^SHIMMER samples
   parameter TICK    = 20     // 2^TICK bus clocks are one tick: 10.5 ms at 100 MHz
) (
   input        bus_clk,      // runs from MMCM lock on; all LED timing is its
   input  [1:0] clocks_ok,    // {MMCM locked and settled, input delays calibrated}
   input        ctrl_stb,     // a control packet arrived from the host (bus_clk)
   input        radio_clk,    // the AD9361 data clock; may not run
   input        pps,          // the selected PPS (radio_clk)
   // Per front end [1:0], in radio_clk: UHD's LED word {RX2 receive, TX/RX
   // receive, TX/RX transmit} and the radio's events {transmit alarm, receive
   // alarm, sample transmitted, sample received}.
   input  [5:0] atr,          // {front end 1, front end 0}
   input  [7:0] events,
   output reg [1:0] trx_g = 0, trx_r = 0, rx2_g = 0, rx2_r = 0,
   output reg   clk_g = 0, clk_r = 1,     // red until the bus clock says otherwise
   output reg   usr_g = 0, usr_r = 0,
   output reg   status = 0
);
   // ---- radio_clk: count samples, turn pulses into levels that can cross ----
   reg  [1:0] rx_dark = 0, tx_dark = 0, rx_alarm_t = 0, tx_alarm_t = 0;
   reg  [4:0] alive_n = 0;
   always @(posedge radio_clk) alive_n <= alive_n + 1'b1;
   genvar c;
   generate for (c = 0; c < 2; c = c + 1) begin : front_end
      reg [SHIMMER-1:0] rx_n = 0, tx_n = 0;
      always @(posedge radio_clk) begin
         if (events[4*c + 0]) rx_n <= rx_n + 1'b1;
         if (events[4*c + 1]) tx_n <= tx_n + 1'b1;
         if (events[4*c + 2]) rx_alarm_t[c] <= ~rx_alarm_t[c];
         if (events[4*c + 3]) tx_alarm_t[c] <= ~tx_alarm_t[c];
      end
      always @(posedge radio_clk) begin
         rx_dark[c] <= rx_n[SHIMMER-1 -: 3] == 3'd0;
         tx_dark[c] <= tx_n[SHIMMER-1 -: 3] == 3'd0;
      end
   end endgenerate

   // ---- into bus_clk ------------------------------------------------------
   wire [5:0] atr_b;
   wire [1:0] rx_dark_b, tx_dark_b, rx_alarm_b, tx_alarm_b;
   wire [1:0] clocks_b;
   wire       pps_b, alive_b;
   wire       clocks_ok_b = &clocks_b;
   synchronizer #(.WIDTH(18)) to_bus (.clk(bus_clk), .rst(1'b0),
      .in ({atr,   rx_dark,   tx_dark,   rx_alarm_t, tx_alarm_t, pps,   alive_n[4], clocks_ok}),
      .out({atr_b, rx_dark_b, tx_dark_b, rx_alarm_b, tx_alarm_b, pps_b, alive_b,    clocks_b}));

   reg [TICK+6:0] t = 0;                   // 2^(TICK+7) bus clocks are 1.3 s
   wire       tick = &t[TICK-1:0];
   reg  [1:0] rx_alarm_q = 0, tx_alarm_q = 0;
   reg        pps_q = 0, alive_q = 0, alive_seen = 0, alive = 0;
   wire [1:0] rx_alarm = rx_alarm_b ^ rx_alarm_q, tx_alarm = tx_alarm_b ^ tx_alarm_q;
   always @(posedge bus_clk) begin
      t <= t + 1'b1;
      rx_alarm_q <= rx_alarm_b;
      tx_alarm_q <= tx_alarm_b;
      pps_q      <= pps_b;
      alive_q    <= alive_b;
      // the data clock is running when its divider moved within the last tick
      if (tick) begin alive <= alive_seen; alive_seen <= 1'b0; end
      if (alive_b ^ alive_q) alive_seen <= 1'b1;
   end

   wire [1:0] rx_lost, tx_lost;
   wire       pps_blink, any_lost, host;
   led_hold #(.TICKS(20))  hold_rx0 (.clk(bus_clk), .tick(tick), .trigger(rx_alarm[0]), .lit(rx_lost[0]));
   led_hold #(.TICKS(20))  hold_rx1 (.clk(bus_clk), .tick(tick), .trigger(rx_alarm[1]), .lit(rx_lost[1]));
   led_hold #(.TICKS(20))  hold_tx0 (.clk(bus_clk), .tick(tick), .trigger(tx_alarm[0]), .lit(tx_lost[0]));
   led_hold #(.TICKS(20))  hold_tx1 (.clk(bus_clk), .tick(tick), .trigger(tx_alarm[1]), .lit(tx_lost[1]));
   led_hold #(.TICKS(190)) hold_any (.clk(bus_clk), .tick(tick), .trigger(|{rx_alarm, tx_alarm}), .lit(any_lost));
   led_hold #(.TICKS(6))   hold_pps (.clk(bus_clk), .tick(tick), .trigger(pps_b & ~pps_q), .lit(pps_blink));
   led_hold #(.TICKS(3))   hold_usr (.clk(bus_clk), .tick(tick), .trigger(ctrl_stb), .lit(host));

   integer n;
   always @(posedge bus_clk) begin
      for (n = 0; n < 2; n = n + 1) begin
         // atr_b[3*n +: 3] = {RX2 receive, TX/RX receive, TX/RX transmit}
         trx_g[n] <= ~tx_lost[n] & ((atr_b[3*n + 1] & ~rx_dark_b[n]) | (atr_b[3*n] & ~tx_dark_b[n]));
         trx_r[n] <=  tx_lost[n] | (atr_b[3*n] & ~tx_dark_b[n]);
         rx2_g[n] <= ~rx_lost[n] & atr_b[3*n + 2] & ~rx_dark_b[n];
         rx2_r[n] <=  rx_lost[n];
      end
      clk_r  <= ~clocks_ok_b;
      clk_g  <=  clocks_ok_b & alive & ~pps_blink;
      usr_r  <=  any_lost;
      usr_g  <= ~any_lost & host;
      status <=  t[TICK+6 -: 3] == 3'd0;
   end
endmodule

// lit from a trigger until TICKS ticks have passed since the last one
module led_hold #(parameter TICKS = 1) (input clk, input tick, input trigger, output lit);
   reg [7:0] left = 0;
   assign lit = left != 0;
   always @(posedge clk)
      if (trigger)          left <= TICKS;
      else if (tick && lit) left <= left - 1'b1;
endmodule
