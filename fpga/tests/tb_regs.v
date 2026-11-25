// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_regs - the register map against a reference model.
//
// Random writes and reads over every listed address and others. Checked:
// read/write registers return what was written (masked to their width);
// read-only registers ignore writes and show their source; unlisted
// addresses read 0; start / stop strobe for exactly one cycle, only on a
// write with their bit set; a time set toggles time_req only when none is
// pending; reading time_lo then time_hi gives one coherent 64-bit time
// while `now` runs across a 2^32 carry every few cycles.
// FAULT 1: time_hi taken at the time_hi read, not latched (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_regs;
  parameter SEED = 1, N = 20000, FAULT = 0;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  reg         we = 0, re = 0;
  reg  [15:0] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  // now: a carry from bit 31 to bit 32 every 64 cycles
  reg  [63:0] now = 64'h0000_0005_FFFF_FFC0;
  always @(posedge clk) now <= now + 1;
  reg         ack = 0;
  wire [63:0] time_set, rx_time;
  wire        time_req, rx_start, rx_stop, rx_at;
  wire [3:0]  rx_format;
  wire [1:0]  rx_channels, test;
  wire        resetb;
  wire [31:0] rx_count;
  wire [12:0] rx_spp;
  wire [15:0] test_div;
  reg  [191:0] ev;
  initial ev = {32'h66, 32'h55, 32'h44, 32'h33, 32'h22, 32'h11};
  regs #(.BUILD_NUMBER(16'h1234), .BUILD_COMMIT(32'hC0FFEE01)) dut (.clk(clk), .rst(rst),
    .reg_we(we), .reg_re(re), .reg_addr(addr), .reg_wdata(wdata), .reg_rdata(rdata),
    .locked(1'b1), .sample_running(1'b0), .now(now), .time_set(time_set), .time_req(time_req), .time_ack(ack),
    .rx_start(rx_start), .rx_stop(rx_stop), .rx_at(rx_at), .rx_format(rx_format), .rx_channels(rx_channels),
    .rx_count(rx_count), .rx_time(rx_time), .rx_spp(rx_spp), .rx_running(1'b1),
    .events(ev), .rx_lost(32'h77), .cmd_dropped(32'h88), .resetb(resetb), .test(test), .test_div(test_div));

  // the time set is acknowledged a random while later
  always @(posedge clk) if (time_req != ack && rnd(20) == 0) ack <= time_req;

  // -- reference model ----------------------------------------------------------------
  reg [31:0] m [0:255];      // written values of the rw registers, by address
  reg [31:0] mask [0:255];   // 0: not a rw register
  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) begin m[i] = 0; mask[i] = 0; end
    mask[8'h03] = 32'hFFFF_FFFF; mask[8'h12] = 32'hFFFF_FFFF; mask[8'h13] = 32'hFFFF_FFFF;
    mask[8'h21] = 32'hFFFF_FFFF; mask[8'h22] = 32'hFFFF_FFFF; mask[8'h23] = 32'hFFFF_FFFF;
    mask[8'h24] = 32'h1FFF; mask[8'h30] = 32'h1; mask[8'hF0] = 32'h3; mask[8'hF1] = 32'hFFFF;
    m[8'h24] = 4096; m[8'h20] = {22'd0, 2'd1, 4'd1, 4'd0};
  end
  function [31:0] expect(input [15:0] a, input [63:0] t, input [31:0] hi);
    case (a)
      16'h000: expect = 32'h4232_3130;
      16'h001: expect = 32'h0001_1234;
      16'h002: expect = 32'hC0FFEE01;
      16'h004: expect = 1;
      16'h010: expect = t[31:0];
      16'h011: expect = hi;
      16'h014: expect = time_req != ack;
      16'h020: expect = m[8'h20] | 1;            // [0] reads "running"
      16'h080, 16'h081, 16'h082, 16'h083, 16'h084, 16'h085: expect = ev[32 * (a - 16'h080) +: 32];
      16'h086: expect = 32'h77;
      16'h087: expect = 32'h88;
      default: expect = a < 256 ? m[a] & mask[a] : 0;
    endcase
  endfunction

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
  initial begin
    repeat (3) @(posedge clk); rst = 0;
    hi = 0;
    for (n = 0; n < N; n = n + 1) begin
      kind = rnd(4);
      a = rnd(3) == 0 ? rnd(65536) : rnd(4) == 0 ? 16'h080 + rnd(8) : rnd(256);
      if (rnd(3) == 0) a = rnd(2) ? 16'h010 : 16'h011;
      if (kind == 0 && a != 16'h014 && a != 16'h020) begin           // write
        d = $random(seed);
        @(negedge clk); we = 1; addr = a; wdata = d;
        @(negedge clk); we = 0;
        if (a < 256 && mask[a] != 0) m[a] = d & mask[a];
      end else if (kind == 1) begin                                   // rx_ctrl or time_ctrl
        d = $random(seed);
        @(negedge clk); we = 1; addr = rnd(2) ? 16'h020 : 16'h014; wdata = d; req0 = time_req; ack0 = ack;
        if (addr == 16'h020) begin
          want_start = d[0]; want_stop = d[1];
          m[8'h20] = {20'd0, 2'd0, d[9:8], d[7:4], d[3], 3'd0};
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
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
