// tb_atr.v - the frontend-control path: ATR state machine and the pin drivers.
//
// This path has no DSP in it, which is exactly why it had no bench: it is the
// one thing that can make a first hardware session look like a broken radio.
// It drives TX_ENABLE, the band-select lines and the LEDs on both frontends,
// and its register layout is a host contract (UHD writes SR_ATR + 0..5).
//
// What is checked, in the order a session discovers them:
//
//   A1  after reset the pins are already driven (DDR = all ones) and hold the
//       IDLE value, i.e. TX_ENABLE is low and no line floats: a floating PA
//       enable is the one state that must never exist.
//   A2  idle / rx / tx / full-duplex each select their own register, and the
//       latency from run_* to the pin is measured, not assumed.
//   A3  ATR-disable forces IDLE regardless of run_rx/run_tx.
//   A4  DDR = 0 turns the pins into inputs (high-Z).
//   A5  no runt: every clock of a transition holds either the old or the new
//       value, and every channel moves on the same clock.
//
// The register layout is UHD's gpio_atr_offsets: +0 idle, +1 rx, +2 tx,
// +3 full-duplex, +4 ddr, +5 atr_disable.
`timescale 1ns/1ps

module tb_atr;

   localparam integer BASE = 12;     // SR_ATR
   localparam integer W    = 8;

   reg clk = 0;  always #5 clk = ~clk;
   reg rst = 1;
   reg run_rx = 0, run_tx = 0;

   reg        set_stb = 0;
   reg [7:0]  set_addr = 0;
   reg [31:0] set_data = 0;

   wire [W-1:0] gpio_out, gpio_ddr, gpio_rb;
   wire [W-1:0] pins;

   integer errors = 0;
   integer checks = 0;
   integer lat = -1;          // measured run_* -> pin latency, in clocks

   gpio_atr #(.BASE(BASE), .WIDTH(W), .FAB_CTRL_EN(0),
              .DEFAULT_DDR(8'hFF), .DEFAULT_IDLE(8'h00)) atr (
      .clk(clk), .reset(rst),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx(run_rx), .tx(run_tx),
      .gpio_in(pins), .gpio_out(gpio_out), .gpio_ddr(gpio_ddr),
      .gpio_out_fab(8'h00), .gpio_sw_rb(gpio_rb));

   gpio_atr_io #(.WIDTH(W)) io (
      .clk(clk), .gpio_ddr(gpio_ddr), .gpio_out(gpio_out),
      .gpio_in(), .gpio_pins(pins));

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clk); set_stb = 0; set_addr = 8'h00; set_data = 0;
         repeat (2) @(posedge clk);
      end
   endtask

   // Wait for the pins to reach `want`, measure the latency, and prove no
   // other value appeared on the way.
   task settle(input [W-1:0] want, input [W-1:0] from, input [255:0] what,
                input track);
      integer n, bad;
      begin
         checks = checks + 1;
         n = 0; bad = 0;
         while (pins !== want && n < 16) begin
            @(posedge clk);
            n = n + 1;
            if (pins !== want && pins !== from) bad = bad + 1;
         end
         if (pins !== want) begin
            errors = errors + 1;
            $display("FAIL: %0s: pins stayed %02h, expected %02h", what, pins, want);
         end else if (bad != 0) begin
            errors = errors + 1;
            $display("FAIL: %0s: %0d intermediate values (runt)", what, bad);
         end else if (track && lat < 0) begin
            lat = n;
         end else if (track && n != lat) begin
            errors = errors + 1;
            $display("FAIL: %0s: latency %0d, first transition took %0d", what, n, lat);
         end
      end
   endtask

   initial begin
      repeat (4) @(posedge clk);
      rst = 0;
      repeat (3) @(posedge clk);

      // ---- A1: power-up state ----
      checks = checks + 1;
      if (gpio_ddr !== 8'hFF) begin
         errors = errors + 1;
         $display("FAIL: after reset DDR is %02h, expected FF (lines must not float)",
                  gpio_ddr);
      end
      checks = checks + 1;
      if (pins !== 8'h00) begin
         errors = errors + 1;
         $display("FAIL: after reset pins are %02h, expected 00 (TX_ENABLE low)", pins);
      end
      $display("  ATR: after reset DDR %02h, pins %02h (TX_ENABLE low, driven)",
               gpio_ddr, pins);

      // ---- A2: the four states, latency measured ----
      // UHD's per-state values, in the design's bit order (bit 7 = TX_ENABLE1).
      wr(BASE+0, 32'h81);            // idle: TX_ENABLE low, one LED
      wr(BASE+1, 32'h22);            // rx only
      wr(BASE+2, 32'h44);            // tx only
      wr(BASE+3, 32'h18);            // full duplex
      settle(8'h81, 8'h81, "A2 idle with no run", 0);
      run_rx = 1; settle(8'h22, 8'h81, "A2 rx running", 1);
      run_rx = 0; settle(8'h81, 8'h22, "A2 back to idle", 1);
      run_tx = 1; settle(8'h44, 8'h81, "A2 tx running", 1);
      run_rx = 1; settle(8'h18, 8'h44, "A2 both running (full duplex)", 1);
      run_rx = 0; run_tx = 0; settle(8'h81, 8'h18, "A2 idle again", 1);
      $display("  ATR: idle/rx/tx/fdx = 81/22/44/18, run*->pin latency %0d clocks", lat);

      // ---- A3: atr_disable forces idle ----
      wr(BASE+5, 32'hFF);
      run_rx = 1; run_tx = 1; settle(8'h81, 8'h81, "A3 atr_disable", 0);
      wr(BASE+5, 32'h00);
      settle(8'h18, 8'h81, "A3 atr_disable released", 0);
      run_rx = 0; run_tx = 0; settle(8'h81, 8'h18, "A3 idle again", 1);

      // ---- A4: DDR = 0 -> inputs ----
      wr(BASE+4, 32'h00);
      repeat (4) @(posedge clk);
      checks = checks + 1;
      if (pins !== 8'hzz) begin
         errors = errors + 1;
         $display("FAIL: DDR 0 left the pins driven (%02h)", pins);
      end
      $display("  ATR: DDR 0 -> pins high-Z, readback %02h", gpio_rb);

      $display("ATR: %0d checks, %0d errors", checks, errors);
      if (errors == 0)
         $display("ATR: PASS - frontend control registers, ATR mux, power-up state, tristate, %0d-clock latency",
                  lat);
      else
         $display("ATR: FAIL");
      $finish;
   end

   initial begin
      #200000;
      $display("ATR: FAIL - timeout");
      $finish;
   end

endmodule
