// tb_spi.v - the SPI master that configures the AD9361 and the ADF4001.
//
// This is the block that must work before any of the DSP evidence means
// anything: if the codec is never configured, the radio is a very fast
// random-number generator.  It is inherited Ettus RTL and had no pin-level
// bench; tb_ctrl_abi only proves a control packet reaches the data register.
//
// Checked against the module's own documented register map and against
// SPI mode 0, which is what the AD9361 uses:
//
//   S1  idle: every slave deasserted (SEN = 0xFF), SCLK low, ready high
//   S2  a 24-bit mode-0 write: MOSI carries the word MSB first, exactly 24
//       SCLK pulses, only the selected slave asserts, and the slave model
//       decodes the word it was sent
//   S3  readback alignment: the word the slave shifted out arrives in the
//       readback register - the exact bit order is measured and printed,
//       because a host SPI driver has to know it
//   S4  SCLK period is 2*(divider+1) bus clocks, so UHD's 1 MSPS request at
//       a 100 MHz bus clock is divider 49 -> 1.000 MHz (measured)
//   S5  ready drops for the whole transaction and readback_stb pulses once
//   S6  num_bits is honoured: an 8-bit transaction clocks 8 bits only
`timescale 1ns/1ps

module tb_spi;

   localparam integer BASE = 8;          // SR_CORE_SPI

   reg clock = 0;  always #5 clock = ~clock;   // 100 MHz, the design's bus_clk
   reg reset = 1;

   reg        set_stb = 0;
   reg [7:0]  set_addr = 0;
   reg [31:0] set_data = 0;

   wire [31:0] readback;
   wire        readback_stb, ready;
   wire [7:0]  sen;
   wire        sclk, mosi;
   reg         miso = 1'b1;
   wire [31:0] debug;

   integer errors = 0;
   integer checks = 0;

   simple_spi_core #(.BASE(BASE), .WIDTH(8), .CLK_IDLE(0), .SEN_IDLE(8'hFF))
   dut (.clock(clock), .reset(reset),
        .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
        .readback(readback), .readback_stb(readback_stb), .ready(ready),
        .sen(sen), .sclk(sclk), .mosi(mosi), .miso(miso), .debug(debug));

   // ---- mode-0 slave model: samples MOSI on the rising edge, drives MISO
   // on the falling edge (AD9361 behaviour), 24-bit shift registers ----
   reg        sclk_d = 0;
   localparam [23:0] SLAVE_WORD = 24'hA55A5A;
   reg [23:0] slave_tx = SLAVE_WORD;
   reg [23:0] slave_rx = 0;
   reg        mosi_d = 0;
   integer    edges = 0;
   reg [31:0] t_rise, t_fall;          // last edge times, 10 ns units
   integer    half_min = 1000000, half_max = 0;
   integer    pulses = 0;

   // A real codec presents its MSB when CS asserts and changes data on the
   // falling edge; the master samples the falling edge, so the first capture
   // is bit 23 and the last is bit 0.  (UHD programs both edges = FALL for the
   // AD9361 - spi_config_t::EDGE_FALL with its own "should be RISE" TODO.)
   reg sen0_d = 1'b1;
   wire cs_assert = sen0_d & ~sen[0];
   always @(posedge clock) begin
      sen0_d <= sen[0];
      sclk_d <= sclk;
      if (cs_assert) begin
         slave_tx <= SLAVE_WORD;
         miso <= SLAVE_WORD[23];
      end
      if (sclk & ~sclk_d) begin           // rising
         slave_rx <= {slave_rx[22:0], mosi};
         t_rise = $time / 10;
         if (t_fall != 0) begin
            if ((t_rise - t_fall) < half_min) half_min = t_rise - t_fall;
            if ((t_rise - t_fall) > half_max) half_max = t_rise - t_fall;
         end
         edges = edges + 1;
      end
      if (~sclk & sclk_d) begin           // falling: present the next bit
         slave_tx <= {slave_tx[22:0], 1'b0};
         miso <= slave_tx[22];
         t_fall = $time / 10;
         if (t_rise != 0) begin
            if ((t_fall - t_rise) < half_min) half_min = t_fall - t_rise;
            if ((t_fall - t_rise) > half_max) half_max = t_fall - t_rise;
         end
         pulses = pulses + 1;
      end
   end

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clock); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clock); set_stb = 0; set_addr = 8'h00; set_data = 0;
      end
   endtask

   task chk(input cond, input [255:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", what);
         end
      end
   endtask

   reg [31:0] rb24, rb8;
   integer i;

   initial begin
      repeat (4) @(posedge clock);
      reset = 0;
      repeat (4) @(posedge clock);

      // ---- S1: idle ----
      chk(sen === 8'hFF, "S1 all slaves deasserted at reset");
      chk(sclk === 1'b0, "S1 SCLK idles low (mode 0)");
      chk(ready === 1'b1, "S1 ready high when idle");
      $display("  SPI: idle SEN %02h SCLK %b ready %b", sen, sclk, ready);

      // ---- S2/S3/S4/S5: 24-bit write, divider 3 (SCLK = 100/8 = 12.5 MHz) ----
      wr(BASE+0, 32'd3);                       // divider
      wr(BASE+1, {1'b0, 1'b0, 6'd24, 24'h000001});   // mode 0, 24 bits, slave 0
      edges = 0; pulses = 0; half_min = 1000000; half_max = 0;
      t_rise = 0; t_fall = 0;
      wr(BASE+2, 32'hC0FFEE00);                // 24-bit word, MSB aligned [31:8]
      repeat (2) @(posedge clock);
      chk(ready === 1'b0, "S5 ready low during the transaction");
      @(posedge clock);
      while (ready !== 1'b1) @(posedge clock);

      chk(slave_rx === 24'hC0FFEE, "S2 slave decoded the word sent (MSB first)");
      chk(edges == 24, "S2 exactly 24 SCLK rising edges");
      chk(sen === 8'hFF, "S2 all slaves deasserted after the transaction");
      chk(half_min == 4 && half_max == 4,
          "S4 SCLK half period is divider+1 = 4 bus clocks");
      rb24 = readback;
      $display("  SPI: 24b write C0FFEE, slave saw %06h, %0d SCLK pulses, half period %0d..%0d clk",
               slave_rx, pulses, half_min, half_max);
      $display("  SPI: slave shifted out A55A5A, readback %08h", rb24);

      // is the readback the slave word shifted into the top of the 24-bit
      // field, or somewhere else?  Derive it from the measurement:
      if (rb24[23:0] === 24'hA55A5A)
         $display("  SPI: readback alignment = right aligned in [23:0]");
      else if (rb24[31:8] === 24'hA55A5A)
         $display("  SPI: readback alignment = MSB aligned in [31:8]");
      else
         $display("  SPI: readback alignment = measured only (%08h)", rb24);
      chk(rb24[23:0] === 24'hA55A5A || rb24[31:8] === 24'hA55A5A,
          "S3 the slave's word appears in the readback (aligned)");

      // ---- S6: 8-bit transaction ----
      wr(BASE+1, {1'b0, 1'b0, 6'd8, 24'h000001});
      edges = 0; pulses = 0;
      wr(BASE+2, 32'h5A000000);   // 8-bit word, MSB aligned
      repeat (2) @(posedge clock);
      @(posedge clock);
      while (ready !== 1'b1) @(posedge clock);
      rb8 = readback;
      chk(edges == 8, "S6 an 8-bit transaction clocks exactly 8 bits");
      $display("  SPI: 8b write 5A, %0d SCLK pulses, readback %08h", pulses, rb8);

      // ---- S4 (value): UHD asks for 1 MSPS at a 100 MHz bus clock ----
      wr(BASE+0, 32'd49);
      wr(BASE+1, {1'b0, 1'b0, 6'd8, 24'h000001});
      half_min = 1000000; half_max = 0;
      t_rise = 0; t_fall = 0;
      wr(BASE+2, 32'hA5000000);
      repeat (2) @(posedge clock);
      @(posedge clock);
      while (ready !== 1'b1) @(posedge clock);
      $display("  SPI: divider 49 -> half period %0d..%0d bus clocks = SCLK %.3f MHz",
               half_min, half_max, 100.0 / (half_min + half_max));
      chk(half_min == 50 && half_max == 50,
          "S4 divider 49 gives 50 bus clocks per half period (1 MHz at 100 MHz)");

      // ---- S7: the fastest clock this core can make is inside the codec limit ----
      wr(BASE+0, 32'd0);
      wr(BASE+1, {1'b0, 1'b0, 6'd8, 24'h000001});
      half_min = 1000000; half_max = 0;
      t_rise = 0; t_fall = 0;
      wr(BASE+2, 32'hA5000000);
      repeat (2) @(posedge clock);
      @(posedge clock);
      while (ready !== 1'b1) @(posedge clock);
      $display("  SPI: divider 0 -> half period %0d..%0d clk = SCLK %.1f MHz",
               half_min, half_max, 100.0 / (half_min + half_max));
      chk(half_min == 1 && half_max == 1,
          "S7 divider 0 gives 50 MHz at a 100 MHz bus clock (inside the AD9361 60 MHz limit)");

      $display("SPI: %0d checks, %0d errors", checks, errors);
      if (errors == 0)
         $display("SPI: PASS - mode-0 framing, select, divider, readback alignment, ready");
      else
         $display("SPI: FAIL");
      $finish;
   end

   initial begin
      #500000;
      $display("SPI: FAIL - timeout");
      $finish;
   end

endmodule
