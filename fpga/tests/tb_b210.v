// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_b210 - the whole step-1 design against the FX3 model; the bench is the
// host, speaking docs/PROTOCOL.md on the four threads.
//
//   1 identity: id, version; scratch written and read back
//   2 rx pattern, sc16 1 channel, a strobe every sample clock: 3 full
//     packets + a short one; every value f(t), times contiguous, the last
//     packet END_OF_BURST at exactly the count
//   3 rx pattern, sc12 2 channels, a strobe every other clock
//   4 timed loopback: time set; continuous rx; one tx packet of 300 samples
//     with START/END_OF_BURST at T = now + 20000; they must come back on rx
//     at exactly T .. T + 299 (zeros around); stop -> a header-only
//     END_OF_BURST packet; a BURST_ACK event of count 1 arrives
//   5 counters: overflow, underflow, late, sequence, bad, rx_lost all 0
// FAULT 1: one tx sample corrupted in the model's buffer (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_b210;
  parameter FAULT = 0;
  localparam DATA = 4096;

  reg ref = 0;
  always #12.5 ref = ~ref;                       // 40 MHz
  wire [31:0] d;
  wire ifclk, slcs, slwr, sloe, slrd, pktend, a1, a0, flaga, flagb;
  wire [7:0] leds;
  b210 dut (.codec_main_clk_p(ref), .codec_main_clk_n(!ref), .IFCLK(ifclk), .GPIF_D(d),
    .GPIF_CTL0(slcs), .GPIF_CTL1(slwr), .GPIF_CTL2(sloe), .GPIF_CTL3(slrd), .GPIF_CTL7(pktend),
    .GPIF_CTL11(a1), .GPIF_CTL12(a0), .GPIF_CTL4(flaga), .GPIF_CTL5(flagb), .GPIF_CTL9(1'b0),
    .codec_reset(), .cat_ce(), .cat_mosi(), .cat_sclk(), .pll_ce(), .pll_mosi(), .pll_sclk(), .ref_sel(),
    .tx_enable1(), .tx_enable2(), .SFDX1_RX(), .SFDX1_TX(), .SFDX2_RX(), .SFDX2_TX(),
    .SRX1_RX(), .SRX1_TX(), .SRX2_RX(), .SRX2_TX(),
    .LED_STATUS(leds[0]), .LED_CLK_G(leds[1]), .LED_CLK_R(leds[2]), .LED_USR_G(leds[3]), .LED_USR_R(leds[4]),
    .LED_RX1(leds[5]), .LED_TXRX1_RX(leds[6]), .LED_TXRX1_TX(leds[7]));
  // the FX3 samples on the forwarded IFCLK, as on the board
  // with the board's clock-to-output times: the FPGA captures FX3 outputs
  // one bus cycle later than without them, as on the board
  fx3_model #(.TCO_DATA(7.0), .TCO_FLAG(8.0)) fx3 (.clk(ifclk), .d(d), .slwr(slwr), .slrd(slrd), .sloe(sloe), .pktend(pktend), .a({a1, a0}),
    .fpga_drives(!dut.pads.bit_[0].pad_t), .flaga(flaga), .flagb(flagb));

  integer errors = 0;
  task fail(input [8*80-1:0] what); begin errors = errors + 1; $display("%0t FAIL: %0s", $time, what); end endtask
  function [11:0] f(input [63:0] t, input integer k);
    case (k) 0: f = t[11:0]; 1: f = ~t[11:0]; 2: f = t[11:0] * 7; default: f = t[11:0] * 13 + 5; endcase
  endfunction

  // -- commands: one operation per packet, the result returned -----------------------------
  integer cseq = 0, n, k;
  integer ev_sum [1:6];
  initial for (k = 1; k <= 6; k = k + 1) ev_sum[k] = 0;
  reg [31:0] res;
  task op(input [7:0] code, input [15:0] addr, input [31:0] data);
    reg got;
    begin
      fx3.send[2*DATA + 0] = {4'd1, 8'd0, 4'd2, 16'd24};
      fx3.send[2*DATA + 1] = cseq;
      fx3.send[2*DATA + 2] = 0; fx3.send[2*DATA + 3] = 0;
      fx3.send[2*DATA + 4] = {code, 8'd0, addr};
      fx3.send[2*DATA + 5] = data;
      fx3.host_send(2, 6);
      got = 0;
      while (!got) begin
        fx3.host_recv(3, n);
        if (fx3.recv[3*DATA][19:16] == 4'd4) take_events(n);
        else begin
          if (n != 6 || fx3.recv[3*DATA] !== {4'd1, 8'd0, 4'd3, 16'd24} || fx3.recv[3*DATA + 1] !== cseq ||
              fx3.recv[3*DATA + 4] !== {code, 8'd0, addr})
            fail("command result header");
          res = fx3.recv[3*DATA + 5];
          got = 1;
        end
      end
      cseq = cseq + 1;
    end
  endtask
  task take_events(input integer words);
    integer j;
    for (j = 4; j < words; j = j + 4) ev_sum[fx3.recv[3*DATA + j][7:0]] = ev_sum[fx3.recv[3*DATA + j][7:0]] + fx3.recv[3*DATA + j + 1];
  endtask
  task wr(input [15:0] a, input [31:0] v); op(8'd1, a, v); endtask
  task rd(input [15:0] a); op(8'd2, a, 0); endtask

  // -- rx packets: checked against the pattern or the loopback burst --------------------------
  reg [63:0] t, next_t, burst_t;
  integer    nt, B, vb, nv, kk, v, bit0, j, total, seq, fl, played;
  reg [15:0] raw;
  reg [11:0] got, expv;
  reg        eob, loop;
  reg [47:0] burst [0:299];
  task rx_packet;
    begin
      fx3.host_recv(1, n);
      fl = fx3.recv[DATA + 1][31:16];
      vb = fx3.recv[DATA][23:20] == 2 ? 12 : 16;
      nv = fx3.recv[DATA][25:24] == 3 ? 4 : 2;
      B = nv * vb / 8;
      nt = (fx3.recv[DATA][15:0] - 16) / B;
      t = {fx3.recv[DATA + 3], fx3.recv[DATA + 2]};
      if (fx3.recv[DATA][31:28] != 1 || fx3.recv[DATA][19:16] != 0 || fx3.recv[DATA + 1][15:0] != seq[15:0] || !fl[0])
        fail("rx header");
      if (seq > 0 && t != next_t) begin fail("rx time not contiguous"); $display("  %0d, expected %0d", t, next_t); end
      for (kk = 0; kk < nt; kk = kk + 1)
        for (v = 0; v < nv; v = v + 1) begin
          bit0 = 128 + (kk * nv + v) * vb;
          raw = 0;
          for (j = 0; j < vb; j = j + 1) raw[j] = fx3.recv[DATA + (bit0 + j) / 32][(bit0 + j) % 32];
          got = vb == 16 ? raw[15:4] : raw[11:0];
          if (!loop) expv = f(t + kk, nv == 4 ? v : v);
          else expv = (t + kk >= burst_t && t + kk < burst_t + 300) ? burst[t + kk - burst_t][12*v +: 12] : 12'd0;
          if (got !== expv) begin
            fail("rx value"); $display("  t %0d value %0d: %h, expected %h", t + kk, v, got, expv);
            kk = nt; v = nv;
          end
          if (loop && v == 0 && t + kk >= burst_t && t + kk < burst_t + 300) played = played + 1;
        end
      total = total + nt; seq = seq + 1; next_t = t + nt; eob = fl[2];
    end
  endtask

  // -- run ---------------------------------------------------------------------------------------
  integer i;
  initial begin
    wait (dut.locked); repeat (100) @(posedge dut.bus_clk);
    // 1
    rd(16'h000); if (res !== 32'h42323130) fail("id");
    rd(16'h001); if (res !== 32'h0001_0000) fail("version");
    wr(16'h003, 32'hA5A5_0F0F); rd(16'h003); if (res !== 32'hA5A5_0F0F) fail("scratch");
    rd(16'h004); if (res[1:0] !== 2'b11) fail("status: clocks and sample clock");
    $display("%0t 1 identity done", $time);
    // 2
    loop = 0;
    wr(16'h0F0, 1); wr(16'h0F1, 0); wr(16'h024, 4092); wr(16'h021, 3 * 4092 + 100);
    wr(16'h020, 32'h0000_0111);                    // start, sc16, channel 0
    seq = 0; total = 0; eob = 0;
    while (!eob) rx_packet;
    if (total != 3 * 4092 + 100 || seq != 4) begin fail("rx count"); $display("  %0d in %0d packets", total, seq); end
    $display("%0t 2 rx sc16 x1: %0d samples in %0d packets", $time, total, seq);
    // 3
    wr(16'h0F1, 1); wr(16'h024, 1000); wr(16'h021, 5000);
    wr(16'h020, 32'h0000_0321);                    // start, sc12, channels 0 and 1
    seq = 0; total = 0; eob = 0;
    while (!eob) rx_packet;
    if (total != 5000 || seq != 5) begin fail("rx count 2"); $display("  %0d in %0d packets", total, seq); end
    $display("%0t 3 rx sc12 x2: %0d samples in %0d packets", $time, total, seq);
    // 4
    wr(16'h0F0, 2); wr(16'h0F1, 0);
    wr(16'h012, 32'h1000_0000); wr(16'h013, 32'h0000_0007); wr(16'h014, 1);
    rd(16'h014); while (res[0]) rd(16'h014);
    rd(16'h010); t = res; rd(16'h011); t = {res, t[31:0]};
    if (t < 64'h0000_0007_1000_0000 || t > 64'h0000_0007_1001_0000) begin fail("time set"); $display("  %h", t); end
    burst_t = t + 20000;
    wr(16'h024, 512); wr(16'h021, 0); wr(16'h020, 32'h0000_0111);
    for (i = 0; i < 300; i = i + 1) begin burst[i] = {24'd0, $random} & 48'h0000_00FF_FFFF; if (burst[i] == 0) burst[i] = 1; end
    fx3.send[0] = {4'd1, 2'd0, 2'd1, 4'd1, 4'd1, 16'd16 + 16'd1200};
    fx3.send[1] = {12'd0, 1'b0, 1'b1, 1'b1, 1'b1, 16'd0};       // EOB SOB HAS_TIME, sequence 0
    fx3.send[2] = burst_t[31:0]; fx3.send[3] = burst_t[63:32];
    for (i = 0; i < 300; i = i + 1) fx3.send[4 + i] = {burst[i][23:12], 4'd0, burst[i][11:0], 4'd0};
    if (FAULT == 1) fx3.send[4 + 123] = fx3.send[4 + 123] ^ 32'h10;
    fx3.host_send(0, 304);
    seq = 0; total = 0; eob = 0; played = 0; loop = 1;
    while (next_t < burst_t + 5000 || seq == 0) rx_packet;
    wr(16'h020, 2);                                // stop
    while (!eob) rx_packet;
    if (played != 300) begin fail("burst samples"); $display("  %0d of 300 came back", played); end
    if (fx3.recv[DATA][15:0] != 16) fail("stop: header-only END_OF_BURST");
    $display("%0t 4 loopback: 300 samples back at exactly T, %0d rx samples in %0d packets", $time, total, seq);
    // 5: the BURST_ACK event, the trouble counters
    repeat (30000) @(posedge dut.bus_clk);
    rd(16'h003);                                   // any result, collects events sent meanwhile
    for (k = 1; k <= 6; k = k + 1) begin
      rd(16'h07F + k);
      if (res != (k == 5 ? 1 : 0)) begin fail("counter"); $display("  code %0d = %0d", k, res); end
      if (ev_sum[k] != (k == 5 ? 1 : 0)) begin fail("events"); $display("  code %0d events add to %0d", k, ev_sum[k]); end
    end
    rd(16'h086); if (res != 0) fail("rx_lost");
    rd(16'h087); if (res != 0) fail("cmd_dropped");
    if (fx3.errors != 0) fail("FX3 contract");
    $display("model errors %0d, bench errors %0d", fx3.errors, errors);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
  initial begin #20_000_000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
