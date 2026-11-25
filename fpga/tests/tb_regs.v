// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_regs - the register map against a reference model.
//
// Random writes and reads over every listed address and others. Checked:
// read/write registers return what was written (masked to their width);
// read-only registers ignore writes and show their source; unlisted
// addresses read 0; rx_spp saturates at 8191 instead of wrapping (a write
// of 8192 must read 8191, not 0); the ring high-water registers follow
// their used input and are cleared by a write; the ring statistics are
// full width (rx 0 .. 2^17, tx 0 .. 2^16 words: values above 8191 and, for
// rx, above 65535 read back exactly); 0x005 reports the sample
// rate input; start / stop strobe for exactly one cycle, only on a
// write with their bit set; a time set toggles time_req only when none is
// pending; reading time_lo then time_hi gives one coherent 64-bit time
// while `now` runs across a 2^32 carry every few cycles; status 0x004
// shows locked, sample_running, delay_ready and sample_ready in bits
// 0 .. 3 as they change; the radio register's RESETB [0] and 2R2T [1] and the bands
// register's five bits reach their outputs exactly and start at 0 after
// a reset; 0x0F1 (step 1's strobe_div) is gone: reads 0, writes ignored.
// Every address is read right after power-up, before any write, and again
// after a reset in the middle of the run with every rw register written:
// each must show its documented reset value (scratch keeps its own).
// FAULT 1: time_hi taken at the time_hi read, not latched (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_regs;
  parameter SEED = 1, N = 20000, FAULT = 0;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED, seed2 = SEED + 1000;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  reg         we = 0, re = 0;
  reg  [15:0] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  // now: a carry from bit 31 to bit 32 every 64 cycles
  reg  [63:0] now = 64'h0000_0005_FFFF_FFC0;
  always @(posedge clk) now <= now + 1;
  reg         ack = 0;
  wire [63:0] time_set, rx_at;
  wire        time_req, rx_start, rx_stop, rx_timed;
  wire [3:0]  rx_format;
  wire [1:0]  rx_channels, rx_source;
  wire        resetb, two;
  wire [4:0]  bands;
  reg         running = 0, delay_ready = 0, ready = 0, wander = 0;
  reg  [2:0]  st_p = 0;                     // {ready, delay_ready, running} at the last edge
  wire [31:0] rx_count;
  wire [12:0] rx_spp;
  reg  [191:0] ev;
  reg  [17:0] rx_used = 0, rx_hwm = 0;      // rx ring: 2^17 words
  reg  [16:0] tx_used = 0, tx_hwm = 0;      // tx ring: 2^16 words
  reg  [16:0] sample_ksps = 17'd61540;
  initial ev = {32'h66, 32'h55, 32'h44, 32'h33, 32'h22, 32'h11};
  regs #(.BUILD_NUMBER(16'h1234), .BUILD_COMMIT(32'hC0FFEE01)) dut (.clk(clk), .rst(rst),
    .reg_we(we), .reg_re(re), .reg_addr(addr), .reg_wdata(wdata), .reg_rdata(rdata),
    .locked(1'b1), .sample_running(running), .delay_ready(delay_ready), .sample_ready(ready), .now(now), .time_set(time_set), .time_req(time_req), .time_ack(ack),
    .rx_start(rx_start), .rx_stop(rx_stop), .rx_timed(rx_timed), .rx_format(rx_format), .rx_channels(rx_channels),
    .rx_count(rx_count), .rx_at(rx_at), .rx_spp(rx_spp), .rx_running(1'b1),
    .counts(ev), .rx_cdc_lost(32'h77), .cmd_dropped(32'h88),
    .rx_used(rx_used), .tx_used(tx_used), .sample_ksps(sample_ksps),
    .resetb(resetb), .two(two), .bands(bands), .rx_source(rx_source));

  // the time set is acknowledged a random while later
  // (the acknowledging side follows a reset of the requester: a time set
  // pending across a reset is dropped)
  always @(posedge clk) if (rst) ack <= 0; else if (time_req != ack && rnd(20) == 0) ack <= time_req;

  // -- reference model ----------------------------------------------------------------
  reg [31:0] m [0:255];      // written values of the rw registers, by address
  reg [31:0] mask [0:255];   // 0: not a rw register
  integer i;
  // the documented reset values (regs.v header, PROTOCOL.md 6); scratch
  // and time_hi have none and keep their value
  task reset_model;
    begin
      for (i = 0; i < 256; i = i + 1) if (i != 8'h03) m[i] = 0;
      m[8'h24] = 4096; m[8'h20] = {22'd0, 2'd1, 4'd1, 4'd0};
    end
  endtask
  initial begin
    for (i = 0; i < 256; i = i + 1) begin m[i] = 0; mask[i] = 0; end
    mask[8'h03] = 32'hFFFF_FFFF; mask[8'h12] = 32'hFFFF_FFFF; mask[8'h13] = 32'hFFFF_FFFF;
    mask[8'h21] = 32'hFFFF_FFFF; mask[8'h22] = 32'hFFFF_FFFF; mask[8'h23] = 32'hFFFF_FFFF;
    mask[8'h24] = 32'h1FFF; mask[8'h30] = 32'h3; mask[8'h31] = 32'h1F; mask[8'hF0] = 32'h3;
    m[8'h24] = 4096; m[8'h20] = {22'd0, 2'd1, 4'd1, 4'd0};
  end
  function [31:0] expect(input [15:0] a, input [63:0] t, input [31:0] hi);
    case (a)
      16'h000: expect = 32'h4232_3130;
      16'h001: expect = 32'h0001_1234;
      16'h002: expect = 32'hC0FFEE01;
      16'h004: expect = {28'd0, st_p, 1'b1};
      16'h005: expect = sample_ksps;
      16'h010: expect = t[31:0];
      16'h011: expect = hi;
      16'h014: expect = time_req != ack;
      16'h020: expect = m[8'h20] | 1;            // [0] reads "running"
      16'h080, 16'h081, 16'h082, 16'h083, 16'h084, 16'h085: expect = ev[32 * (a - 16'h080) +: 32];
      16'h086: expect = 32'h77;
      16'h087: expect = 32'h88;
      16'h088: expect = rx_used;
      16'h089: expect = rx_hwm;
      16'h08A: expect = tx_used;
      16'h08B: expect = tx_hwm;
      default: expect = a < 256 ? m[a] & mask[a] : 0;
    endcase
  endfunction

  // -- the two high-water registers: follow their used input, cleared by a write ---------------
  always @(posedge clk) if (rst) begin rx_hwm <= 0; tx_hwm <= 0; end else begin
    if (rx_used > rx_hwm) rx_hwm <= rx_used;
    if (tx_used > tx_hwm) tx_hwm <= tx_used;
    if (we && addr == 16'h089) rx_hwm <= 0;
    if (we && addr == 16'h08B) tx_hwm <= 0;
  end

  // -- status inputs change now and then; the radio outputs follow their registers ------------
  // (the model's m changes at the negedge after a write's edge, so at an
  // edge the outputs, before they update, match it)
  always @(posedge clk) begin
    st_p <= {ready, delay_ready, running};
    // their own random sequence: the accesses stay those of the seed
    if (wander && ($random(seed2) & 63) == 0) running <= !running;
    if (wander && ($random(seed2) & 127) == 0) delay_ready <= !delay_ready;
    if (wander && ($random(seed2) & 63) == 0) ready <= !ready;
  end
  always @(posedge clk) if (!rst && {bands, two, resetb} !== {m[8'h31][4:0], m[8'h30][1:0]}) begin
    errors = errors + 1;
    if (errors < 10) $display("%0t bands %b 2R2T %b RESETB %b, expected %b %b", $time, bands, two, resetb,
                              m[8'h31][4:0], m[8'h30][1:0]);
  end

  // -- strobes: exactly one cycle, only for a write with the bit --------------------------------
  // a write at edge e strobes in the cycle after e: checked at edge e + 1
  reg want_start = 0, want_stop = 0, due_start = 0, due_stop = 0;
  always @(posedge clk) begin
    if (rx_start !== due_start || rx_stop !== due_stop) begin
      errors = errors + 1; $display("%0t start %b stop %b, expected %b %b", $time, rx_start, rx_stop, due_start, due_stop);
    end
    due_start = want_start; due_stop = want_stop;
    want_start = 0; want_stop = 0;
  end

  // -- run ------------------------------------------------------------------------------
  reg [15:0] a;
  reg [31:0] d, e, hi;
  reg [63:0] t_lo;
  reg        req0, ack0;
  integer n, kind;
  task wr(input [15:0] aa, input [31:0] dd);
    begin @(negedge clk); we = 1; addr = aa; wdata = dd; @(negedge clk); we = 0; end
  endtask
  task rd(input [15:0] aa, input [31:0] want);
    begin
      @(negedge clk); re = 1; addr = aa;
      @(negedge clk); re = 0;
      if (rdata !== want) begin errors = errors + 1; $display("directed read %h: %h, expected %h", aa, rdata, want); end
    end
  endtask

  // read every address 0x000 .. 0x0FF and a few above against the model
  // (after a reset: the reset values), no write in between
  task sweep(input [8*24-1:0] what);
    integer j, bad;
    begin
      bad = 0;
      for (j = 0; j < 256 + 4; j = j + 1) begin
        a = j < 256 ? j : j == 256 ? 16'h0100 : j == 257 ? 16'h0F10 : j == 258 ? 16'h8030 : 16'hFFFF;
        @(negedge clk); re = 1; addr = a; t_lo = now;
        @(negedge clk); re = 0;
        if (a == 16'h010) hi = t_lo[63:32];
        e = expect(a, t_lo, hi);
        if (rdata !== e) begin
          bad = bad + 1; errors = errors + 1;
          if (bad < 5) $display("%0t %0s: read %h: %h, expected %h", $time, what, a, rdata, e);
        end
      end
      $display("%0t %0s: every register read", $time, what);
    end
  endtask

  initial begin
    repeat (3) @(posedge clk); rst = 0;
    hi = 0;
    sweep("after power-up");
    // after reset: AD9361 in reset, 1R1T, band selects 0
    if (resetb !== 0 || two !== 0 || bands !== 0) begin errors = errors + 1; $display("radio outputs after reset"); end
    rd(16'h030, 0); rd(16'h031, 0);
    wr(16'h030, 32'hFFFF_FFFE); m[8'h30] = 2; rd(16'h030, 2);
    wr(16'h031, 32'hFFFF_FFF5); m[8'h31] = 5'h15; rd(16'h031, 5'h15);
    // step 1's strobe_div is gone
    wr(16'h0F1, 32'h0000_1234); rd(16'h0F1, 0);
    // the status bits follow their inputs
    @(negedge clk); running = 1; delay_ready = 0; ready = 0; rd(16'h004, 3);
    @(negedge clk); running = 0; delay_ready = 1; ready = 0; rd(16'h004, 5);
    @(negedge clk); running = 0; delay_ready = 0; ready = 1; rd(16'h004, 9);
    // rx_spp saturates: 8192 must not read back as 0
    wr(16'h024, 32'h0000_2000); rd(16'h024, 32'h1FFF);
    wr(16'h024, 32'hFFFF_FFFF); rd(16'h024, 32'h1FFF);
    wr(16'h024, 32'h0000_1000); rd(16'h024, 32'h1000);
    m[8'h24] = 32'h1000;
    // the high-water marks follow their used input and a write clears them
    rx_used = 18'd900; tx_used = 17'd200; repeat (3) @(posedge clk);
    rd(16'h088, 900); rd(16'h089, 900); rd(16'h08A, 200); rd(16'h08B, 200);
    // full width: above 8191 (13 bits) and, for rx, above 65535 (16 bits);
    // a full ring reads its depth, 2^17 / 2^16 words
    rx_used = 18'd100000; tx_used = 17'd40000; repeat (3) @(posedge clk);
    rd(16'h088, 100000); rd(16'h089, 100000); rd(16'h08A, 40000); rd(16'h08B, 40000);
    rx_used = 18'd131072; tx_used = 17'd65536; repeat (3) @(posedge clk);
    rd(16'h088, 131072); rd(16'h089, 131072); rd(16'h08A, 65536); rd(16'h08B, 65536);
    // a clear while the ring still holds words is undone at once (the mark
    // tracks its used input), so empty the rings first: that is the state a
    // host clears them in, before a run
    rx_used = 18'd0; tx_used = 17'd0; repeat (2) @(posedge clk);
    wr(16'h089, 32'h0); wr(16'h08B, 32'hFFFF_FFFF);
    rd(16'h089, 0); rd(16'h08B, 0);
    rx_used = 18'd5; tx_used = 17'd3; repeat (3) @(posedge clk);
    rd(16'h089, 5); rd(16'h08B, 3);
    // the sample rate is reported as written by the top
    sample_ksps = 17'd30770; rd(16'h005, 30770);
    sample_ksps = 17'd61540;
    wander = 1;
    for (n = 0; n < N; n = n + 1) begin
      kind = rnd(4);
      a = rnd(3) == 0 ? rnd(65536) : rnd(4) == 0 ? 16'h080 + rnd(8) : rnd(256);
      if (rnd(3) == 0) a = rnd(2) ? 16'h010 : 16'h011;
      if (kind == 0 && a != 16'h014 && a != 16'h020) begin           // write
        d = $random(seed);
        @(negedge clk); we = 1; addr = a; wdata = d;
        @(negedge clk); we = 0;
        if (a == 16'h024) m[a] = |d[31:13] ? 32'h1FFF : d[12:0];
        else if (a < 256 && mask[a] != 0) m[a] = d & mask[a];
      end else if (kind == 1) begin                                   // rx_ctrl or time_ctrl
        d = $random(seed);
        @(negedge clk); we = 1; addr = rnd(2) ? 16'h020 : 16'h014; wdata = d; req0 = time_req; ack0 = ack;
        if (addr == 16'h020) begin
          want_start = d[0]; want_stop = d[1];
          m[8'h20] = {22'd0, d[9:8], d[7:4], d[3], 3'd0};
        end
        @(negedge clk); we = 0;
        // time_req toggles exactly when bit 0 is written with no set pending
        // (ack0: ack before the write's edge; ack only moves at edges)
        if (addr == 16'h014 && time_req !== ((d[0] && req0 == ack0) ? !req0 : req0)) begin
          errors = errors + 1; $display("%0t time_req %b after writing %b, was %b, ack %b", $time, time_req, d[0], req0, ack0);
        end
      end else begin                                                  // read
        @(negedge clk); re = 1; addr = a; t_lo = now;
        @(negedge clk); re = 0;
        if (a == 16'h010) hi = t_lo[63:32];
        e = expect(a, t_lo, FAULT == 1 ? now[63:32] : hi);
        if (rdata !== e && !(a == 16'h014)) begin
          errors = errors + 1; if (errors < 10) $display("%0t read %h: %h, expected %h", $time, a, rdata, e);
        end
        if (FAULT == 1 && a == 16'h011) hi = now[63:32];
      end
    end
    $display("%0d accesses", N);
    // a reset in the middle of a run, every rw register written first:
    // all return to their reset values (scratch keeps its value)
    wander = 0;
    for (i = 0; i < 256; i = i + 1) if (mask[i] != 0 && i != 8'h20) begin
      d = $random(seed) | 1; wr(i, d); m[i] = i == 8'h24 ? (|d[31:13] ? 32'h1FFF : d[12:0]) : d & mask[i];
    end
    wr(16'h020, 32'h0000_0328); m[8'h20] = {22'd0, 2'd3, 4'd2, 1'b1, 3'd0};      // timed, sc12, 2 channels
    rx_used = 0; tx_used = 0; repeat (3) @(posedge clk);
    @(negedge clk); rst = 1; reset_model;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;
    if (resetb !== 0 || two !== 0 || bands !== 0 || rx_source !== 0 || rx_format !== 1 || rx_channels !== 1 ||
        rx_timed !== 0 || rx_spp !== 4096 || rx_count !== 0 || rx_at !== 0 || time_set !== 0 || time_req !== 0) begin
      errors = errors + 1; $display("outputs after a reset in the run");
    end
    sweep("after a reset in the run");
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
