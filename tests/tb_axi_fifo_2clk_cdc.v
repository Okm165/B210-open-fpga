//
// tb_axi_fifo_2clk_cdc.v - the clock-domain crossing every sample and control
// stream in the design goes through, exercised at the rates it actually runs.
//
// radio_legacy crosses both directions between the radio domain (61.44 MHz,
// from the codec data clock) and the bus domain (100 MHz) using
// axi_fifo_2clk:
//
//   radio -> bus   tx/rx sample FIFOs, SIZE = RADIO_FIFO_SIZE (13)
//   bus   -> radio ctrl/resp FIFOs,     SIZE = 0 (floored to 5 entries)
//
// This bench runs both directions at once, with the real clock periods, real
// FIFO sizes, random valid/ready gaps, and checks that every word arrives
// exactly once, in order, with its payload intact.  Both sides honour the
// handshake (a write only counts when tvalid && tready), so this is what the
// design's own producers and consumers do.
//
// The point is not the FIFO's algorithm (it is a textbook Gray-pointer async
// FIFO); it is that the *behavioral model in src/rtl/fifo/axi_fifo_2clk_sim.v
// is the netlist*, so any divergence between its simulation semantics and a
// real dual-clock FIFO is a hardware risk that only simulation can expose.
//
`timescale 1ns/1ps

module tb_axi_fifo_2clk_cdc;

   localparam NW = 512;

   // ---------------------------------------------------------------- clocks
   reg slow_clk = 0;   // 61.44 MHz  (period 16.276 ns)
   reg fast_clk = 0;   // 100 MHz    (period 10 ns)

   // Periods and phase are overridable so the same integrity check can be run
   // at clock ratios and alignments other than the nominal 61.44/100 pair:
   // Gray-pointer correctness must not depend on the two clocks' relationship.
   // Defaults are initialised at declaration (before time 0), so the first
   // half period is well defined even when a plusarg overrides them.
   real tslow = 8.138;      // half period, ns
   real tfast = 5.000;
   real tphase = 0.0;

   initial begin
      if (!$value$plusargs("TSLOW=%f", tslow)) tslow = tslow;
      if (!$value$plusargs("TFAST=%f", tfast)) tfast = tfast;
      if (!$value$plusargs("TPHASE=%f", tphase)) tphase = tphase;
      $display("CDC: half periods slow %.3f ns (%.2f MHz), fast %.3f ns (%.2f MHz), phase %.2f ns",
               tslow, 500.0/tslow, tfast, 500.0/tfast, tphase);
   end

   always begin #tslow slow_clk = ~slow_clk; end
   initial begin
      #tphase;
      forever begin #tfast fast_clk = ~fast_clk; end
   end

   // ------------------------------------------------- direction A: radio->bus
   reg         rst_a = 1;
   reg  [64:0] a_wdata = 0;
   reg         a_wvalid = 0;
   wire        a_wready;
   wire [64:0] a_rdata;
   wire        a_rvalid;
   reg         a_rready = 1'b1;

   // ------------------------------------------------- direction B: bus->radio
   reg         rst_b = 1;
   reg  [64:0] b_wdata = 0;
   reg         b_wvalid = 0;
   wire        b_wready;
   wire [64:0] b_rdata;
   wire        b_rvalid;
   reg         b_rready = 1'b1;

   axi_fifo_2clk #(.WIDTH(65), .SIZE(13)) dut_a (
      .reset   (rst_a),
      .i_aclk  (slow_clk),   // write: 61.44 MHz
      .i_tdata (a_wdata),
      .i_tvalid(a_wvalid),
      .i_tready(a_wready),
      .o_aclk  (fast_clk),   // read:  100 MHz
      .o_tdata (a_rdata),
      .o_tvalid(a_rvalid),
      .o_tready(a_rready));

   axi_fifo_2clk #(.WIDTH(65), .SIZE(5)) dut_b (
      .reset   (rst_b),
      .i_aclk  (fast_clk),   // write: 100 MHz
      .i_tdata (b_wdata),
      .i_tvalid(b_wvalid),
      .i_tready(b_wready),
      .o_aclk  (slow_clk),   // read:  61.44 MHz
      .o_tdata (b_rdata),
      .o_tvalid(b_rvalid),
      .o_tready(b_rready));

   // ------------------------------------------------------------- bookkeeping
   integer a_wr = 0, a_rd = 0, a_bad = 0;
   integer b_wr = 0, b_rd = 0, b_bad = 0;
   integer seed_a = 32'h1234_5678;
   integer seed_b = 32'h8765_4321;
   integer seed_ra = 32'h0BAD_F00D;
   integer seed_rb = 32'hF00D_0BAD;

   // payload: index in both halves so a swapped/stale/duplicated word is
   // unmistakable, and a one-bit error is visible too
   function [64:0] payload(input integer idx);
      payload = {1'b0, idx[31:0], ~idx[31:0]};
   endfunction

   // ----------------------------------------------------- writers (negedge)
   // Driving at the negedge puts the values half a period before the sampling
   // posedge; i_tready only changes on that posedge, so the value read at the
   // negedge is exactly what the posedge will sample.
   initial begin : writer_a
      repeat (6) @(posedge slow_clk);
      rst_a = 0;
      repeat (6) @(posedge slow_clk);
      while (a_wr < NW) begin
         @(negedge slow_clk);
         a_wdata  = payload(a_wr);
         a_wvalid = (($random(seed_a) & 7) != 0);      // ~87 % duty
         if (a_wvalid && a_wready)
            a_wr = a_wr + 1;
      end
      @(negedge slow_clk);
      a_wvalid = 1'b0;
   end

   initial begin : writer_b
      repeat (6) @(posedge fast_clk);
      rst_b = 0;
      repeat (6) @(posedge fast_clk);
      while (b_wr < NW) begin
         @(negedge fast_clk);
         b_wdata  = payload(b_wr);
         b_wvalid = (($random(seed_b) & 7) != 0);
         if (b_wvalid && b_wready)
            b_wr = b_wr + 1;
      end
      @(negedge fast_clk);
      b_wvalid = 1'b0;
   end

   // ------------------------------------------------------ readers (posedge)
   always @(posedge fast_clk) begin
      if (!rst_a && a_rvalid && a_rready) begin
         if (a_rdata !== payload(a_rd)) begin
            a_bad = a_bad + 1;
            if (a_bad <= 3)
               $display("  A: word %0d read back %h, expected %h", a_rd, a_rdata, payload(a_rd));
         end
         a_rd = a_rd + 1;
      end
   end

   always @(posedge slow_clk) begin
      if (!rst_b && b_rvalid && b_rready) begin
         if (b_rdata !== payload(b_rd)) begin
            b_bad = b_bad + 1;
            if (b_bad <= 3)
               $display("  B: word %0d read back %h, expected %h", b_rd, b_rdata, payload(b_rd));
         end
         b_rd = b_rd + 1;
      end
   end

   // ------------------------------------------------------ reader backpressure
   initial begin : ready_a
      forever begin
         @(negedge fast_clk);
         a_rready = (($random(seed_ra) & 3) != 0);      // ~75 % ready
      end
   end

   initial begin : ready_b
      forever begin
         @(negedge slow_clk);
         b_rready = (($random(seed_rb) & 3) != 0);
      end
   end

   // --------------------------------------------------------------- verdict
   initial begin : watchdog
      #2000000;
      $display("FAIL: timeout (a %0d/%0d, b %0d/%0d)", a_rd, a_wr, b_rd, b_wr);
      $finish;
   end

   integer stall = 0;

   initial begin : check
      // wait for both streams to drain completely
      while ((a_rd < NW || b_rd < NW) && stall < 200000) begin
         @(posedge slow_clk);
         stall = stall + 1;
      end
      #100;
      $display("A radio->bus : wrote %0d, read %0d, corrupt %0d", a_wr, a_rd, a_bad);
      $display("B bus->radio : wrote %0d, read %0d, corrupt %0d", b_wr, b_rd, b_bad);
      if (a_wr == NW && a_rd == NW && a_bad == 0 &&
          b_wr == NW && b_rd == NW && b_bad == 0)
         $display("PASS: axi_fifo_2clk delivers %0d/%0d words in order in both directions", NW, NW);
      else
         $display("FAIL: axi_fifo_2clk lost or corrupted data");
      $finish;
   end

endmodule

//
// tb_axi_fifo_2clk_rate - sustained throughput, both directions.
//
// The integrity bench above proves no word is lost or reordered when the
// clocks have unrelated phases.  This one asks the complementary question:
// does the crossing itself cap the sample rate below the slowest clock?
//
// Both FIFOs are driven flat out (tvalid and tready held high) and the words
// delivered are counted over an exact window of 1024 radio-clock cycles:
//
//   A  radio->bus   write 61.44 MHz, read 100 MHz  -> expect 1024 (write-bound)
//   B  bus->radio   write 100 MHz, read 61.44 MHz  -> expect 1024 (read-bound)
//
// Equivalently: 1024 words in 1024 * 16.276 ns = 16.66 us = 61.44 Mword/s,
// exactly one word per radio clock and no structural stall.
//
module tb_axi_fifo_2clk_rate;

   reg  wr_slow = 0, wr_fast = 0, rd_slow = 0, rd_fast = 0;
   reg  rst_a = 1, rst_b = 1;

   wire        a_wready, a_rvalid;
   wire [31:0] a_rdata;
   wire        b_wready, b_rvalid;
   wire [31:0] b_rdata;

   integer a_accepted = 0, a_reads = 0;
   integer b_accepted = 0, b_reads = 0;

   always #8.138 wr_slow = ~wr_slow;    // 61.44 MHz
   always #5.000 wr_fast = ~wr_fast;    // 100 MHz
   always #8.138 rd_slow = ~rd_slow;
   always #5.000 rd_fast = ~rd_fast;

   // A: radio -> bus
   axi_fifo_2clk #(.WIDTH(32), .SIZE(13)) dut_a (
      .reset(rst_a), .i_aclk(wr_slow), .i_tdata(32'hA5A5_0000 | a_accepted[15:0]),
      .i_tvalid(1'b1), .i_tready(a_wready), .o_aclk(rd_fast),
      .o_tdata(a_rdata), .o_tvalid(a_rvalid), .o_tready(1'b1));

   // B: bus -> radio (the control path's direction)
   axi_fifo_2clk #(.WIDTH(32), .SIZE(5)) dut_b (
      .reset(rst_b), .i_aclk(wr_fast), .i_tdata(32'h5A5A_0000 | b_accepted[15:0]),
      .i_tvalid(1'b1), .i_tready(b_wready), .o_aclk(rd_slow),
      .o_tdata(b_rdata), .o_tvalid(b_rvalid), .o_tready(1'b1));

   always @(posedge wr_slow) if (!rst_a && a_wready) a_accepted = a_accepted + 1;
   always @(posedge rd_fast) if (!rst_a && a_rvalid) a_reads    = a_reads + 1;
   always @(posedge wr_fast) if (!rst_b && b_wready) b_accepted = b_accepted + 1;
   always @(posedge rd_slow) if (!rst_b && b_rvalid) b_reads    = b_reads + 1;

   integer c;
   initial begin
      repeat (8) @(posedge wr_slow);
      rst_a = 0;
      rst_b = 0;
      repeat (8) @(posedge wr_slow);
      // start of the measurement window: exactly 1024 radio-clock cycles
      a_accepted = 0; a_reads = 0; b_accepted = 0; b_reads = 0;
      for (c = 0; c < 1024; c = c + 1) @(posedge wr_slow);
      #1;
      $display("A radio->bus: %0d accepted, %0d read   in 1024 radio clocks (%.1f Mword/s)",
               a_accepted, a_reads, a_reads / 16.276);
      $display("B bus->radio: %0d accepted, %0d read   in 1024 radio clocks (%.1f Mword/s)",
               b_accepted, b_reads, b_reads / 16.276);
      if (a_reads >= 1023 && b_reads >= 1023)
         $display("PASS: sustained throughput is one word per radio clock in both directions (no CDC stall)");
      else
         $display("FAIL: sustained throughput below one word per radio clock");
      $finish;
   end

endmodule

//
// tb_axi_fifo_2clk_capacity - how many words the FIFO takes, and in what order
// they come back.
//
// The memory holds 2^SIZE words: full is "the write pointer reaches the read
// pointer" (the pair of FIFOSIZE-bit pointers cannot tell full from empty, so
// a flag says which).  The two-entry output register stage holds two more, so
// a reader that never accepts lets 2^SIZE + 2 words in.  That capacity is the
// vendor core's, and the flag rewrite must not change it; the count is exact
// and every word must drain in order.
//
module tb_axi_fifo_2clk_capacity;

   localparam N5  = 32 + 2;     // 2^5  + the output stage
   localparam N13 = 8192 + 2;   // 2^13 + the output stage

   reg clk = 0;
   always #5.000 clk = ~clk;

   reg rst = 1;

   reg  wvalid5 = 0, wvalid13 = 0;
   wire ready5, ready13;
   wire [31:0] rdata5, rdata13;
   wire valid5, valid13;
   reg  rready5 = 0, rready13 = 0;

   integer taken5 = 0, taken13 = 0;

   axi_fifo_2clk #(.WIDTH(32), .SIZE(5)) dut5 (
      .reset(rst), .i_aclk(clk), .i_tdata(taken5 + 1), .i_tvalid(wvalid5), .i_tready(ready5),
      .o_aclk(clk), .o_tdata(rdata5), .o_tvalid(valid5), .o_tready(rready5));

   axi_fifo_2clk #(.WIDTH(32), .SIZE(13)) dut13 (
      .reset(rst), .i_aclk(clk), .i_tdata(taken13 + 1), .i_tvalid(wvalid13), .i_tready(ready13),
      .o_aclk(clk), .o_tdata(rdata13), .o_tvalid(valid13), .o_tready(rready13));

   // a write happens exactly when the producer hands a word over
   always @(posedge clk) begin
      if (!rst) begin
         if (wvalid5  && ready5)  taken5  <= taken5  + 1;
         if (wvalid13 && ready13) taken13 <= taken13 + 1;
      end
   end

   integer rd5 = 0, rd13 = 0, errors = 0, i;

   always @(posedge clk) begin
      if (!rst) begin
         if (valid5 && rready5) begin
            if (rdata5 !== rd5 + 1) begin
               errors = errors + 1;
               if (errors <= 3) $display("  SIZE 5: word %0d reads %0d, expected %0d", rd5, rdata5, rd5 + 1);
            end
            rd5 <= rd5 + 1;
         end
         if (valid13 && rready13) begin
            if (rdata13 !== rd13 + 1) begin
               errors = errors + 1;
               if (errors <= 3) $display("  SIZE 13: word %0d reads %0d, expected %0d", rd13, rdata13, rd13 + 1);
            end
            rd13 <= rd13 + 1;
         end
      end
   end

   reg [8*64-1:0] why = 0;

   initial begin : watchdog
      #5000000;
      $display("FAIL: timeout (taken %0d/%0d, read %0d/%0d)", taken5, taken13, rd5, rd13);
      $finish;
   end

   initial begin : run
      repeat (4) @(posedge clk);
      rst = 0;
      repeat (4) @(posedge clk);
      wvalid5  = 1;
      wvalid13 = 1;
      // the readers never accept: the FIFOs must fill, then stop
      repeat (40000) @(posedge clk);
      wvalid5  = 0;
      wvalid13 = 0;
      repeat (4) @(posedge clk);

      $display("capacity: SIZE 5 takes %0d words (expected %0d), SIZE 13 takes %0d (expected %0d)",
               taken5, N5, taken13, N13);
      if (taken5  != N5)  begin errors = errors + 1; why = "SIZE 5 capacity";  end
      if (taken13 != N13) begin errors = errors + 1; why = "SIZE 13 capacity"; end
      if (ready5 || ready13) begin
         errors = errors + 1;
         why = "full FIFO still reports ready";
      end

      // drain both and check order; each drains exactly what it took
      rready5  = 1;
      rready13 = 1;
      repeat (N13 + 100) @(posedge clk);
      rready5  = 0;
      rready13 = 0;
      repeat (4) @(posedge clk);

      if (rd5  != N5)  begin errors = errors + 1; why = "SIZE 5 did not drain";  end
      if (rd13 != N13) begin errors = errors + 1; why = "SIZE 13 did not drain"; end

      // and it must accept words again afterwards
      wvalid5 = 1;
      repeat (8) @(posedge clk);
      if (taken5 <= N5) begin errors = errors + 1; why = "SIZE 5 stalled after a drain"; end
      wvalid5 = 0;

      if (errors == 0)
         $display("PASS: axi_fifo_2clk capacity is 2^SIZE + 2 words and every word drains in order");
      else
         $display("FAIL: axi_fifo_2clk capacity or ordering changed (%0s)", why);
      $finish;
   end

endmodule
