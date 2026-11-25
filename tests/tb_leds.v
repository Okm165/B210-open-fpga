//
// tb_leds.v - the LED module says what its header says.
//
// Each scenario drives UHD's LED word and the radio's events as the design
// would and checks the colour of every LED over a window: which of the two
// halves were ever lit, and whether the lit one went dark in between (the
// shimmer).  Ticks are shortened (TICK = 6, SHIMMER = 8) so that a second of
// board time is a few thousand clocks; the logic is the same.
//
//   +NEG_RED   the bench expects a transmitting port to be red instead of
//              amber: it has to fail, or the colour checks check nothing.
//
`timescale 1ns/1ps
module tb_leds;
   reg bus_clk = 0, radio_clk = 0, radio_on = 0;
   always #5 bus_clk = ~bus_clk;
   always #8.138 if (radio_on) radio_clk = ~radio_clk;

   reg  [1:0] clocks_ok = 2'b00;
   reg        ctrl_stb = 0, pps = 0;
   reg  [5:0] atr = 0;
   reg  [7:0] events = 0;
   wire [1:0] trx_g, trx_r, rx2_g, rx2_r;
   wire       clk_g, clk_r, usr_g, usr_r, status;

   b200_leds #(.SHIMMER(8), .TICK(6)) dut (
      .bus_clk(bus_clk), .clocks_ok(clocks_ok), .ctrl_stb(ctrl_stb),
      .radio_clk(radio_clk), .pps(pps), .atr(atr), .events(events),
      .trx_g(trx_g), .trx_r(trx_r), .rx2_g(rx2_g), .rx2_r(rx2_r),
      .clk_g(clk_g), .clk_r(clk_r), .usr_g(usr_g), .usr_r(usr_r), .status(status));

   // every LED half: was it ever on, ever off, and how often did it change
   wire [12:0] led = {status, usr_r, usr_g, clk_r, clk_g, rx2_r, rx2_g, trx_r, trx_g};
   localparam TRX_G0 = 0, TRX_G1 = 1, TRX_R0 = 2, TRX_R1 = 3, RX2_G0 = 4, RX2_G1 = 5, RX2_R0 = 6, RX2_R1 = 7,
              CLK_G = 8, CLK_R = 9, USR_G = 10, USR_R = 11, STATUS = 12;
   reg [12:0] was_on, was_off, last;
   integer    changes [0:12];
   integer    k;
   always @(posedge bus_clk) begin
      was_on  <= was_on | led;
      was_off <= was_off | ~led;
      for (k = 0; k < 13; k = k + 1) if (led[k] !== last[k]) changes[k] = changes[k] + 1;
      last <= led;
   end
   task watch(input integer clocks);
      begin
         @(posedge bus_clk); was_on = 0; was_off = 0; last = led;
         for (k = 0; k < 13; k = k + 1) changes[k] = 0;
         repeat (clocks) @(posedge bus_clk);
      end
   endtask

   integer errors = 0;
   // what one LED half did during the last watch(): "off", "on" (never dark),
   // "blinks" (lit and dark in turn)
   task expect_led(input integer half, input [8*6-1:0] want, input [8*40-1:0] what);
      reg [8*6-1:0] got;
      begin
         got = !was_on[half] ? "off" : !was_off[half] ? "on" : "blinks";
         if (led[half] === 1'bx || got != want) begin
            errors = errors + 1;
            $display("  %0s: is %0s, expected %0s", what, got, want);
         end
      end
   endtask

   // the radio: samples flowing in the directions given, per front end
   reg [1:0] rx_flow = 0, tx_flow = 0;
   reg [7:0] alarm = 0;
   always @(posedge radio_clk) events <= {1'b0, 1'b0, tx_flow[1], rx_flow[1], 1'b0, 1'b0, tx_flow[0], rx_flow[0]}
                                         | alarm;
   task pulse_alarm(input integer bit_);
      begin
         @(posedge radio_clk); alarm[bit_] = 1; @(posedge radio_clk); alarm[bit_] = 0;
         repeat (8) @(posedge bus_clk);     // across the synchroniser and into the LED registers
      end
   endtask

   localparam SECOND = 128 * 64;      // 2^(TICK+7) bus clocks
   reg neg_red;
   initial begin
      neg_red = $test$plusargs("NEG_RED");

      // 1. the FPGA's clocks are not locked: CLK red, nothing else but the heartbeat
      watch(2 * SECOND);
      expect_led(CLK_R, "on", "no lock: CLK red");
      expect_led(CLK_G, "off", "no lock: CLK green");
      expect_led(STATUS, "blinks", "heartbeat");
      expect_led(USR_R, "off", "no lock: USR red");

      // 2. locked, AD9361 not initialised: CLK dark
      clocks_ok = 2'b11;
      watch(SECOND);  watch(SECOND);
      expect_led(CLK_R, "off", "locked, no radio clock: CLK red");
      expect_led(CLK_G, "off", "locked, no radio clock: CLK green");

      // 3. radio clock running, a PPS: CLK green with a blink
      radio_on = 1;
      watch(SECOND);
      fork
         begin #(SECOND * 4) pps = 1; #(SECOND * 2) pps = 0; end
         watch(SECOND);
      join
      expect_led(CLK_G, "blinks", "radio clock and PPS: CLK green");
      expect_led(CLK_R, "off", "radio clock and PPS: CLK red");
      watch(SECOND);                                 // no PPS edge in here
      expect_led(CLK_G, "on", "radio clock, no PPS edge: CLK green");

      // 4. idle: every RF LED dark
      expect_led(TRX_G0, "off", "idle: TX/RX 0 green");  expect_led(TRX_R0, "off", "idle: TX/RX 0 red");
      expect_led(RX2_G0, "off", "idle: RX2 0 green");    expect_led(RX2_R0, "off", "idle: RX2 0 red");
      expect_led(TRX_G1, "off", "idle: TX/RX 1 green");  expect_led(RX2_G1, "off", "idle: RX2 1 green");

      // 5. front end 0 receives through RX2: its RX2 LED shimmers green, nothing else lit
      atr = 6'b000_100;  rx_flow = 2'b01;
      watch(SECOND);  watch(SECOND);
      expect_led(RX2_G0, "blinks", "RX on RX2: RX2 0 green");
      expect_led(RX2_R0, "off", "RX on RX2: RX2 0 red");
      expect_led(TRX_G0, "off", "RX on RX2: TX/RX 0 green");
      expect_led(TRX_R0, "off", "RX on RX2: TX/RX 0 red");
      expect_led(RX2_G1, "off", "RX on RX2: RX2 1 green");
      expect_led(USR_R, "off", "RX on RX2: USR red");

      // 6. full duplex on front end 1 (UHD: TX on TX/RX, RX on RX2): amber and green
      atr = 6'b101_000;  rx_flow = 2'b10;  tx_flow = 2'b10;
      watch(SECOND);  watch(SECOND);
      expect_led(TRX_G1, "blinks", "full duplex: TX/RX 1 green half");
      expect_led(TRX_R1, neg_red ? "off" : "blinks", "full duplex: TX/RX 1 red half (amber)");
      expect_led(RX2_G1, "blinks", "full duplex: RX2 1 green");
      expect_led(RX2_R1, "off", "full duplex: RX2 1 red");
      expect_led(RX2_G0, "off", "full duplex: RX2 0 green");

      // 7. receiving through TX/RX on front end 0: green only
      atr = 6'b000_010;  rx_flow = 2'b01;  tx_flow = 2'b00;
      watch(SECOND);  watch(SECOND);
      expect_led(TRX_G0, "blinks", "RX on TX/RX: TX/RX 0 green");
      expect_led(TRX_R0, "off", "RX on TX/RX: TX/RX 0 red");

      // 8. an overflow on front end 0: its RX2 LED red, not green, and USR red
      atr = 6'b000_100;
      watch(SECOND);
      pulse_alarm(2);
      watch(8 * 64);                                    // 8 ticks into the 20-tick alarm
      expect_led(RX2_R0, "on", "overflow: RX2 0 red");
      expect_led(RX2_G0, "off", "overflow: RX2 0 green");
      expect_led(RX2_R1, "off", "overflow: RX2 1 red");
      expect_led(TRX_R0, "off", "overflow: TX/RX 0 red");
      expect_led(USR_R, "on", "overflow: USR red");
      watch(40 * 64);  watch(8 * 64);                   // the port alarm is over, the summary is not
      expect_led(RX2_R0, "off", "after the alarm: RX2 0 red");
      expect_led(USR_R, "on", "within 2 s of the alarm: USR red");
      watch(2 * SECOND);  watch(8 * 64);
      expect_led(USR_R, "off", "2 s after the alarm: USR red");

      // 9. an underflow on front end 1 while transmitting: TX/RX 1 red only
      atr = 6'b001_000;  tx_flow = 2'b10;  rx_flow = 2'b00;
      watch(SECOND);
      pulse_alarm(7);
      watch(8 * 64);
      expect_led(TRX_R1, "on", "underflow: TX/RX 1 red");
      expect_led(TRX_G1, "off", "underflow: TX/RX 1 green");
      expect_led(TRX_R0, "off", "underflow: TX/RX 0 red");

      // 10. control packets from the host: USR green flashes, and goes dark again
      atr = 0;  tx_flow = 0;
      watch(3 * SECOND);
      expect_led(USR_G, "off", "no host traffic: USR green");
      @(posedge bus_clk) ctrl_stb = 1;  @(posedge bus_clk) ctrl_stb = 0;
      watch(64);
      expect_led(USR_G, "on", "control packet: USR green");
      watch(8 * 64);  watch(64);
      expect_led(USR_G, "off", "after the control packet: USR green");

      // 11. the radio clock stops: CLK goes dark, not red
      radio_on = 0;
      watch(SECOND);  watch(SECOND);
      expect_led(CLK_G, "off", "radio clock gone: CLK green");
      expect_led(CLK_R, "off", "radio clock gone: CLK red");

      if (errors == 0) $display("LEDS: PASS - every LED shows what the module's header says, in 11 situations");
      else             $display("LEDS: FAIL - %0d LED states differ", errors);
      $finish;
   end
endmodule
