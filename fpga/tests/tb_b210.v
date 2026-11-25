// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_b210 - the whole step-2 design against the FX3 model and the AD9361
// data-port model (ad9361_port_model.v, 61.44 MHz DATA_CLK); the bench is
// the host, speaking docs/PROTOCOL.md on the four threads. The model's
// DATA_CLK runs only while RESETB is high and the bench lets it (as the
// AD9361 drives no DATA_CLK in reset).
//
//   0 no sample clock: the AD9361 in reset after power-up (pin and radio
//     register), the bus side answers: id, version, status = locked, not
//     running, delays ready, sample path in reset; an rx start ends at
//     once in a header-only START + END_OF_BURST packet. RESETB released,
//     DATA_CLK starts 3 us later: status bit 1 (clock running) comes first,
//     bit 3 (sample path out of reset) after it
//   1 identity: scratch written and read back; status all four bits
//   2 rx pattern, sc16 1 channel, 1R1T (a strobe every DATA_CLK cycle): 3
//     full packets + a short one; every value f(t), times contiguous, the
//     last packet END_OF_BURST at exactly the count
//   3 2R2T through the radio register (bit 1; a strobe every other cycle):
//     rx pattern sc12 2 channels until the host's stop write (which
//     rewrites rx_ctrl's configuration bits); then rx source 0 (the
//     radio), sc16 2 channels: every sample time is the model's, I0 Q0 I1
//     Q1 bit-exact, sample times consecutive, times contiguous; the
//     sample rate register reads 30720 kS/s
//   4 back to 1R1T; timed loopback: time set; continuous rx; one tx packet
//     of 300 samples with START/END_OF_BURST at T = now + 20000; they must
//     come back on rx at exactly T .. T + 299 (zeros around), and leave on
//     the AD9361's P1 pins exactly as sent, in order, zeros around (decoded
//     by the model); stop -> a header-only END_OF_BURST packet; a
//     BURST_ACK event of count 1 arrives
//   5 counters: overflow, underflow, late, sequence, bad, rx_cdc_lost all 0
//   7 rx source 0 in 1R1T, sc16: channel 0 the model's samples bit-exact
//     and consecutive; channel 1 (alone) zero; 61440 kS/s (two channels
//     at 61.44 MS/s would exceed the bus)
//   8 DATA_CLK stops during a continuous radio stream: the packet in
//     progress is completed with zero sample times, then the stream's
//     END_OF_BURST; status bit 1 and bit 3 fall, the bus side answers
//     throughout, the rate reads 0. DATA_CLK restarts: status follows; a
//     new radio stream is exact with the time restarted from 0; a pattern
//     stream is exact; the counters are as after step 5 (no loss, no
//     spurious event from the restart)
//   6 radio control: an AD9361 register written and read back over SPI
//     (opcode 3) and POLLed over SPI; an ADF4001 word latched; both
//     devices' timing checked (spi_model.v) at the design's SPI rates;
//     RESETB low again when the radio register is cleared, and with it
//     DATA_CLK stops and status bit 1 falls
//   9 one of each trouble counter, register and event code: two bursts
//     whose time has passed (LATE 2), a sequence jump inside a timed burst
//     (SEQ_ERROR 1, and its BURST_ACK), a version-2 packet (BAD_PACKET 1),
//     the rx crossing forced full for 5 strobes (rx_cdc_lost 5, and 5 in
//     OVERFLOW); band selects written and read back
//  10 ring depth: thread 1 left unread during a radio stream until the
//     first OVERFLOW: rx_hwm >= 2^17 - 4096 words; 16 full tx packets of
//     a burst timed 1.6 ms ahead: tx_hwm >= 2^16 - 4096; the burst plays
//     (BURST_ACK)
// Every step's counters are compared with the counts the bench caused.
// Every bus cycle: PA enables low, RF switches 1010_0101 (UHD's off
// state), ref_sel low, SLCS# low, AD9361 CTRL_IN 0001 / EN_AGC 1 / TXNRX 1
// / ENABLE 1 / SYNC_IN 0, band-select pins = register 0x031; LED CLK
// green = locked and sample clock running, USR green dark until the
// first result packet's last word and lit after it, both TX/RX LEDs
// together (and lit for the 300 samples of step 4's burst).
// The model's tx decoder (P1 timing and TX_FRAME pattern) checks every
// period while the mode is steady and the clock runs.
// FAULT 1: one tx sample corrupted in the model's buffer (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_b210;
  parameter FAULT = 0;
  localparam DATA = 4096;
  localparam real T = 16.276;                    // DATA_CLK: 61.44 MHz

  reg ref = 0;
  always #12.5 ref = ~ref;                       // 40 MHz
  wire [31:0] d;
  wire ifclk, slcs, slwr, sloe, slrd, pktend, a1, a0, flaga, flagb;
  wire [7:0] leds;
  wire resetb, cat_ce, cat_mosi, cat_sclk, cat_miso, pll_ce, pll_mosi, pll_sclk;
  wire data_clk, rx_frame, fb_clk, tx_frame;
  wire [11:0] rx_d, tx_d;
  reg  clk_on = 0, two_m = 0, check = 0;
  wire c_enable, c_txrx, c_en_agc, c_sync, ref_sel;
  wire [3:0] c_ctrl_in;
  wire [4:0] bsel;                               // {tx_bandsel_b, tx_bandsel_a, rx_bandsel_c, rx_bandsel_b, rx_bandsel_a}
  wire [1:0] pa;                                 // tx_enable1, tx_enable2
  wire [7:0] sw;                                 // SFDX1_RX SFDX1_TX SFDX2_RX SFDX2_TX SRX1_RX SRX1_TX SRX2_RX SRX2_TX
  pulldown (cat_miso);                           // SPI_DO released: the bench reads 0
  ad9361_spi_model ad (.ce(cat_ce), .sclk(cat_sclk), .mosi(cat_mosi), .miso(cat_miso));
  adf4001_model pll (.le(pll_ce), .clk(pll_sclk), .data(pll_mosi));
  ad9361_port_model #(.T(T)) m (.two(two_m), .run(clk_on && resetb === 1'b1), .check(check), .quiet(1'b0),
    .data_clk(data_clk), .rx_frame(rx_frame), .rx_d(rx_d), .fb_clk(fb_clk), .tx_frame(tx_frame), .tx_d(tx_d));
  b210 dut (.codec_main_clk_p(ref), .codec_main_clk_n(!ref), .IFCLK(ifclk), .GPIF_D(d),
    .GPIF_CTL0(slcs), .GPIF_CTL1(slwr), .GPIF_CTL2(sloe), .GPIF_CTL3(slrd), .GPIF_CTL7(pktend),
    .GPIF_CTL11(a1), .GPIF_CTL12(a0), .GPIF_CTL4(flaga), .GPIF_CTL5(flagb), .GPIF_CTL9(1'b0),
    .codec_reset(resetb), .cat_ce(cat_ce), .cat_mosi(cat_mosi), .cat_sclk(cat_sclk), .cat_miso(cat_miso),
    .pll_ce(pll_ce), .pll_mosi(pll_mosi), .pll_sclk(pll_sclk),
    .codec_enable(c_enable), .codec_txrx(c_txrx), .codec_en_agc(c_en_agc), .codec_sync(c_sync), .codec_ctrl_in(c_ctrl_in),
    .rx_bandsel_a(bsel[0]), .rx_bandsel_b(bsel[1]), .rx_bandsel_c(bsel[2]), .tx_bandsel_a(bsel[3]), .tx_bandsel_b(bsel[4]),
    .codec_data_clk_p(data_clk), .rx_frame_p(rx_frame), .rx_codec_d(rx_d),
    .codec_fb_clk_p(fb_clk), .tx_frame_p(tx_frame), .tx_codec_d(tx_d), .ref_sel(ref_sel),
    .tx_enable1(pa[1]), .tx_enable2(pa[0]), .SFDX1_RX(sw[7]), .SFDX1_TX(sw[6]), .SFDX2_RX(sw[5]), .SFDX2_TX(sw[4]),
    .SRX1_RX(sw[3]), .SRX1_TX(sw[2]), .SRX2_RX(sw[1]), .SRX2_TX(sw[0]),
    .LED_STATUS(leds[0]), .LED_CLK_G(leds[1]), .LED_CLK_R(leds[2]), .LED_USR_G(leds[3]), .LED_USR_R(leds[4]),
    .LED_RX1(leds[5]), .LED_TXRX1_RX(leds[6]), .LED_TXRX1_TX(leds[7]));
  // the FX3 samples on the forwarded IFCLK, as on the board
  // with the board's clock-to-output times: the FPGA captures FX3 outputs
  // one bus cycle later than without them, as on the board
  fx3_model #(.TCO_DATA(7.0), .TCO_FLAG(8.0)) fx3 (.clk(ifclk), .d(d), .slwr(slwr), .slrd(slrd), .sloe(sloe), .pktend(pktend), .a({a1, a0}),
    .fpga_drives(!dut.pads.bit_[0].pad_t), .flaga(flaga), .flagb(flagb));

  integer errors = 0;
  task fail(input [8*80-1:0] what); begin errors = errors + 1; $display("%0t FAIL: %0s", $time, what); end endtask

  // -- every bus cycle: pins that must stay at their constants, LEDs ------------------------------
  // PA enables off; RF switches in UHD's off state SFDXn_RX | SRXn_TX;
  // reference internal; SLCS# low (the FX3 model then sees every strobe);
  // AD9361 CTRL_IN 0001, EN_AGC 1, TXNRX 1, ENABLE 1, SYNC_IN 0; band
  // selects = register 0x031 bit by bit. CLK green = locked and sample
  // clock running; USR green dark until the first result packet's last
  // word, lit the cycle after it; the two TX/RX LEDs together.
  integer pin_errs = 0, txled = 0;
  reg     res_seen = 0, res_seen_p = 0;
  always @(posedge dut.bus_clk) begin
    if (pa !== 2'b00 || sw !== 8'b1010_0101 || ref_sel !== 1'b0 || slcs !== 1'b0 || c_ctrl_in !== 4'b0001 ||
        {c_en_agc, c_txrx, c_enable, c_sync} !== 4'b1110 || bsel !== dut.registers.bands ||
        leds[1] !== (dut.locked && dut.sample_running) || leds[6] !== leds[7] ||
        (!res_seen && leds[3] === 1'b1) || (res_seen_p && leds[3] !== 1'b1)) begin
      pin_errs = pin_errs + 1;
      if (pin_errs <= 5) $display("%0t FAIL: pins: PA %b switches %b ref %b SLCS# %b ctrl %b %b bands %b (register %b) LEDs %b",
                                  $time, pa, sw, ref_sel, slcs, c_ctrl_in, {c_en_agc, c_txrx, c_enable, c_sync}, bsel,
                                  dut.registers.bands, leds);
    end
    // (command.v's w_valid / w_last start undefined in simulation, and
    // with them the LED until the first result: dark = not 1)
    res_seen <= res_seen || (dut.res_w_valid === 1'b1 && dut.res_w_last === 1'b1);
    res_seen_p <= res_seen;
    if (leds[7]) txled = txled + 1;
  end
  function [11:0] f(input [63:0] t, input integer k);
    case (k) 0: f = t[11:0]; 1: f = ~t[11:0]; 2: f = t[11:0] * 7; default: f = t[11:0] * 13 + 5; endcase
  endfunction

  // -- commands: one operation per packet, the result returned -----------------------------
  integer cseq = 0, n, k;
  integer ev_sum [1:6];
  initial for (k = 1; k <= 6; k = k + 1) ev_sum[k] = 0;
  reg [31:0] res;
  task op(input [7:0] code, input [15:0] addr, input [31:0] data); op_arg(code, 8'd0, addr, data); endtask
  task op_arg(input [7:0] code, input [7:0] arg, input [15:0] addr, input [31:0] data);
    reg got;
    begin
      fx3.send[2*DATA + 0] = {4'd1, 8'd0, 4'd2, 16'd24};
      fx3.send[2*DATA + 1] = cseq;
      fx3.send[2*DATA + 2] = 0; fx3.send[2*DATA + 3] = 0;
      fx3.send[2*DATA + 4] = {code, arg, addr};
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
  // poll status until (status & mask) == want, at most `tries` reads
  task wait_status(input [3:0] mask, input [3:0] want, input integer tries, input [8*40-1:0] what);
    integer c;
    begin
      rd(16'h004); c = 1;
      while ((res[3:0] & mask) != want && c < tries) begin rd(16'h004); c = c + 1; end
      if ((res[3:0] & mask) != want) begin fail(what); $display("  status %b", res[3:0]); end
    end
  endtask
  task bus_wait(input integer cycles); repeat (cycles) @(posedge dut.bus_clk); endtask
  // the sample rate register is renewed every 1 ms (b210's ms counter):
  // wait for a window to start, then for it to end, so it lies wholly in
  // the present state (no time set, mode change or clock change in it)
  task full_window;
    begin
      @(posedge dut.bus_clk); while (dut.ms != 0) @(posedge dut.bus_clk);
      @(posedge dut.bus_clk); while (dut.ms != 0) @(posedge dut.bus_clk);
      bus_wait(5);
    end
  endtask

  // the expected counts of event codes 1 .. 6 and of rx_cdc_lost
  integer exp_c [1:6];
  integer exp_cdc = 0;
  initial for (k = 1; k <= 6; k = k + 1) exp_c[k] = 0;
  // -- rx packets: checked against the pattern, the loopback burst or the radio ----------------
  localparam PATTERN = 0, LOOP = 1, RADIO = 2, ZERO = 3;
  reg [63:0] t, next_t, burst_t;
  integer    nt, B, vb, nv, kk, v, bit0, j, total, seq, fl, played, mode;
  reg [15:0] raw;
  reg [11:0] got, expv;
  reg [11:0] val [0:3];
  reg        eob, two_exp, fill_ok, fill_seen, have_k;
  integer    kr, k_prev, fills;
  reg [3:0]  want_fmt;
  reg [1:0]  want_ch;
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
      if (fx3.recv[DATA][31:28] != 1 || fx3.recv[DATA][19:16] != 0 || fx3.recv[DATA + 1][15:0] != seq[15:0] || !fl[0]
          || fx3.recv[DATA][23:20] != want_fmt || fx3.recv[DATA][25:24] != want_ch || fl[3]) begin
        fail("rx header"); $display("  %h %h, format %0d channels %0d configured", fx3.recv[DATA], fx3.recv[DATA + 1], want_fmt, want_ch);
      end
      if (seq > 0 && t != next_t) begin fail("rx time not contiguous"); $display("  %0d, expected %0d", t, next_t); end
      for (kk = 0; kk < nt; kk = kk + 1) begin
        for (v = 0; v < nv; v = v + 1) begin
          bit0 = 128 + (kk * nv + v) * vb;
          raw = 0;
          for (j = 0; j < vb; j = j + 1) raw[j] = fx3.recv[DATA + (bit0 + j) / 32][(bit0 + j) % 32];
          val[v] = vb == 16 ? raw[15:4] : raw[11:0];
        end
        if (nv == 2) begin val[2] = 0; val[3] = 0; end
        if (mode == RADIO) radio_check;
        else if (mode == ZERO) begin
          if (val[0] !== 0 || val[1] !== 0) begin fail("rx value not zero"); $display("  t %0d", t + kk); kk = nt; end
        end
        else
          for (v = 0; v < nv; v = v + 1) begin
            got = val[v];
            if (mode == PATTERN) expv = f(t + kk, v);
            else expv = (t + kk >= burst_t && t + kk < burst_t + 300) ? burst[t + kk - burst_t][12*v +: 12] : 12'd0;
            if (got !== expv) begin
              fail("rx value"); $display("  t %0d value %0d: %h, expected %h", t + kk, v, got, expv);
              kk = nt; v = nv;
            end
            if (mode == LOOP && v == 0 && t + kk >= burst_t && t + kk < burst_t + 300) played = played + 1;
          end
      end
      total = total + nt; seq = seq + 1; next_t = t + nt; eob = fl[2];
    end
  endtask
  // one sample time from the radio (channel 0, or both): the model's sample time
  // kr follows from I0 (rxval(k, 0) = 1029 k + 17, and 2253 = 1 / 1029 mod
  // 4096); the other values must be the model's for the same kr, channel 1
  // zero in 1R1T (a 1-channel stream: channel 0 only), and kr the
  // previous sample time's + 1. With fill_ok,
  // zero sample times may end the stream (no sample time of the model is
  // zero in I0 and Q0), and then nothing else may follow.
  task radio_check;
    begin
      if (fill_ok && val[0] == 0 && val[1] == 0) begin
        fill_seen = 1; fills = fills + 1;
        if (val[2] != 0 || val[3] != 0) begin fail("radio: fill not zero"); kk = nt; end
      end else begin
        kr = (2253 * (val[0] - 17)) & 4095;
        if (fill_seen) begin fail("radio: a sample time after the fill"); kk = nt; end
        else if (val[1] !== m.rxval(kr, 1) || (nv == 4 && (val[2] !== (two_exp ? m.rxval(kr, 2) : 12'd0) ||
                 val[3] !== (two_exp ? m.rxval(kr, 3) : 12'd0)))) begin
          fail("radio: value"); kk = nt;
          $display("  t %0d: %h %h %h %h, model sample time %0d: %h %h %h %h", t + kk, val[0], val[1], val[2], val[3],
                   kr, m.rxval(kr, 0), m.rxval(kr, 1), two_exp ? m.rxval(kr, 2) : 12'd0, two_exp ? m.rxval(kr, 3) : 12'd0);
        end else if (have_k && kr != ((k_prev + 1) & 4095)) begin
          fail("radio: sample times not consecutive"); kk = nt;
          $display("  t %0d: sample time %0d after %0d", t + kk, kr, k_prev);
        end
        k_prev = kr; have_k = 1;
      end
    end
  endtask
  task stream_start(input integer md, input [3:0] fmt, input [1:0] ch, input integer spp, input integer count);
    begin
      mode = md; want_fmt = fmt; want_ch = ch;
      wr(16'h024, spp); wr(16'h021, count);
      wr(16'h020, {22'd0, ch, fmt, 4'b0001});
      seq = 0; total = 0; eob = 0; played = 0; have_k = 0; fill_seen = 0; fills = 0; fill_ok = 0;
    end
  endtask

  // a tx packet into fx3.send[0 ..]: sc16, channel 0, ns sample times
  // (nonzero), version ver (1 is valid), flags EOB SOB HAS_TIME, sent
  task tx_packet(input [3:0] ver, input eob, input sob, input timed, input [15:0] sq, input [63:0] at,
                 input integer ns);
    integer q;
    begin
      fx3.send[0] = {ver, 2'd0, 2'd1, 4'd1, 4'd1, 16'd16 + ns[15:0] * 16'd4};
      fx3.send[1] = {12'd0, 1'b0, eob, sob, timed, sq};
      fx3.send[2] = at[31:0]; fx3.send[3] = at[63:32];
      for (q = 0; q < ns; q = q + 1) fx3.send[4 + q] = {q[11:0] * 12'd3 + 12'd1, 4'd0, q[11:0] * 12'd5 + 12'd2, 4'd0};
      fx3.host_send(0, 4 + ns);
    end
  endtask
  // rx packets taken unchecked up to the stream's END_OF_BURST
  task drain;
    begin
      eob = 0;
      while (!eob) begin fx3.host_recv(1, n); eob = fx3.recv[DATA + 1][18]; end
    end
  endtask
  task now_time; begin rd(16'h010); t = res; rd(16'h011); t = {res, t[31:0]}; end endtask

  // -- run ---------------------------------------------------------------------------------------
  integer i, n0, nb, rate;
  initial begin
    wait (dut.locked); repeat (100) @(posedge dut.bus_clk);
    // 0
    if (resetb !== 1'b0) fail("AD9361 out of reset at power-up");
    rd(16'h030); if (res !== 0) fail("radio register after power-up");
    rd(16'h000); if (res !== 32'h42323130) fail("id");
    rd(16'h001); if (res !== 32'h0001_0000) fail("version");
    wait_status(4'hF, 4'b0101, 200, "status without a sample clock");
    rd(16'h005); if (res !== 0) fail("sample rate without a sample clock");
    wr(16'h0F0, 1);
    stream_start(PATTERN, 1, 1, 4092, 1000);
    rx_packet;
    if (fx3.recv[DATA][15:0] != 16 || fl[3:0] != 4'b0111) begin
      fail("start without a sample clock: one header-only START + END_OF_BURST"); $display("  %h %h", fx3.recv[DATA], fx3.recv[DATA + 1]);
    end
    rd(16'h020); if (res[0]) fail("stream still running without a sample clock");
    wr(16'h030, 1); if (resetb !== 1'b1) fail("RESETB not released");
    rd(16'h030); if (res !== 1) fail("radio register readback");
    #3000 clk_on = 1;                            // DATA_CLK starts after the FPGA's reset, late
    wait_status(4'b0010, 4'b0010, 50, "sample clock running");
    if (res[3]) fail("sample path out of reset as soon as the clock runs");
    wait_status(4'b1000, 4'b1000, 200, "sample path out of reset");
    check = 1;
    $display("%0t 0 no sample clock: bus answers, start ends at once; DATA_CLK late: status follows", $time);
    // 1
    wr(16'h003, 32'hA5A5_0F0F); rd(16'h003); if (res !== 32'hA5A5_0F0F) fail("scratch");
    rd(16'h004); if (res[3:0] !== 4'b1111) fail("status: locked, sample clock, delays, sample path");
    $display("%0t 1 identity done", $time);
    // 2
    stream_start(PATTERN, 1, 1, 4092, 3 * 4092 + 100);
    while (!eob) rx_packet;
    if (total != 3 * 4092 + 100 || seq != 4) begin fail("rx count"); $display("  %0d in %0d packets", total, seq); end
    $display("%0t 2 rx sc16 x1, 1R1T: %0d samples in %0d packets", $time, total, seq);
    // 3
    check = 0; wr(16'h030, 3); two_m = 1;
    rd(16'h030); if (res !== 3) fail("radio register: 2R2T");
    bus_wait(100); check = 1;
    // continuous, ended by the host's stop write, which also rewrites
    // rx_ctrl's format and channel bits: the stream must keep its own,
    // and channel 1's pattern is nonzero, so a change would show
    stream_start(PATTERN, 2, 3, 1000, 0);
    while (seq < 3) rx_packet;
    wr(16'h020, 2);                                // stop
    while (!eob) rx_packet;
    if (fx3.recv[DATA][15:0] != 16) fail("stop: header-only END_OF_BURST");
    $display("%0t 3 rx sc12 x2, 2R2T, until stopped: %0d samples in %0d packets", $time, total, seq);
    wr(16'h0F0, 0); two_exp = 1;
    stream_start(RADIO, 1, 3, 2046, 3 * 2046 + 50);
    while (!eob) rx_packet;
    if (total != 3 * 2046 + 50) begin fail("radio rx count"); $display("  %0d", total); end
    full_window; rd(16'h005); rate = res;
    if (rate < 30719 || rate > 30721) begin fail("sample rate 2R2T"); $display("  %0d kS/s", rate); end
    $display("%0t 3 rx radio sc16 x2, 2R2T: %0d sample times exact, %0d kS/s", $time, total, rate);
    // 4
    check = 0; wr(16'h030, 1); two_m = 0; bus_wait(100); check = 1;
    wr(16'h0F0, 2);
    wr(16'h012, 32'h1000_0000); wr(16'h013, 32'h0000_0007); wr(16'h014, 1);
    rd(16'h014); while (res[0]) rd(16'h014);
    rd(16'h010); t = res; rd(16'h011); t = {res, t[31:0]};
    if (t < 64'h0000_0007_1000_0000 || t > 64'h0000_0007_1001_0000) begin fail("time set"); $display("  %h", t); end
    burst_t = t + 20000;
    stream_start(LOOP, 1, 1, 512, 0);
    for (i = 0; i < 300; i = i + 1) begin burst[i] = {24'd0, $random} & 48'h0000_00FF_FFFF; if (burst[i] == 0) burst[i] = 1; end
    fx3.send[0] = {4'd1, 2'd0, 2'd1, 4'd1, 4'd1, 16'd16 + 16'd1200};
    fx3.send[1] = {12'd0, 1'b0, 1'b1, 1'b1, 1'b1, 16'd0};       // EOB SOB HAS_TIME, sequence 0
    fx3.send[2] = burst_t[31:0]; fx3.send[3] = burst_t[63:32];
    for (i = 0; i < 300; i = i + 1) fx3.send[4 + i] = {burst[i][23:12], 4'd0, burst[i][11:0], 4'd0};
    if (FAULT == 1) fx3.send[4 + 123] = fx3.send[4 + 123] ^ 32'h10;
    n0 = m.ntx; txled = 0;
    fx3.host_send(0, 304);
    while (next_t < burst_t + 5000 || seq == 0) rx_packet;
    wr(16'h020, 2);                                // stop
    while (!eob) rx_packet;
    if (played != 300) begin fail("burst samples"); $display("  %0d of 300 came back", played); end
    if (fx3.recv[DATA][15:0] != 16) fail("stop: header-only END_OF_BURST");
    // on the pins: the decoded sample times since the send, zeros, then
    // the burst in order, then zeros
    if (m.ntx - n0 > 65536) fail("tx: model buffer overrun");
    i = n0; while (i < m.ntx && m.txs[i % 65536] == 0) i = i + 1;
    for (nb = 0; nb < 300 && i + nb < m.ntx; nb = nb + 1)
      if (m.txs[(i + nb) % 65536] !== burst[nb]) begin
        fail("tx on the pins"); $display("  sample %0d: %h, expected %h", nb, m.txs[(i + nb) % 65536], burst[nb]); nb = 300;
      end
    if (i + 300 >= m.ntx) fail("tx on the pins: burst incomplete");
    for (nb = i + 300; nb < m.ntx; nb = nb + 1)
      if (m.txs[nb % 65536] !== 0) begin fail("tx on the pins: not zero after the burst"); nb = m.ntx; end
    // 300 samples = 4.88 us = 488 bus cycles of TX/RX amber
    if (txled < 480 || txled > 496) begin fail("TX/RX LED"); $display("  lit %0d bus cycles", txled); end
    exp_c[5] = 1;
    $display("%0t 4 loopback: 300 samples back at exactly T and on P1 as sent, %0d rx samples in %0d packets", $time, total, seq);
    // 5: the BURST_ACK event, the trouble counters
    bus_wait(30000);
    counters("5");
    // 7
    // (two channels at 61.44 MS/s exceed the bus: channel 0, then channel 1 alone)
    wr(16'h0F0, 0); two_exp = 0;
    stream_start(RADIO, 1, 1, 4092, 3 * 4092 + 50);
    while (!eob) rx_packet;
    if (total != 3 * 4092 + 50) begin fail("radio rx count"); $display("  %0d", total); end
    full_window; rd(16'h005); rate = res;
    if (rate < 61439 || rate > 61441) begin fail("sample rate 1R1T"); $display("  %0d kS/s", rate); end
    stream_start(ZERO, 1, 2, 1000, 2000);
    while (!eob) rx_packet;
    if (total != 2000) fail("channel 1 count");
    $display("%0t 7 rx radio sc16, 1R1T: %0d sample times exact, channel 1 zero, %0d kS/s", $time, 3 * 4092 + 50, rate);
    // 8
    stream_start(RADIO, 1, 1, 1000, 0);
    while (seq < 3) rx_packet;
    check = 0; clk_on = 0; fill_ok = 1;
    while (!eob) rx_packet;
    // (no zeros at all if the clock stopped just as a packet was complete)
    if (fx3.recv[DATA][15:0] != 16 || fills >= 1000) begin
      fail("clock stop: packet completed with zeros, then END_OF_BURST"); $display("  %0d zero sample times", fills);
    end
    wait_status(4'b1010, 4'b0000, 50, "clock stop: status");
    rd(16'h004); if (res[3:0] !== 4'b0101) begin fail("clock stopped: status"); $display("  %b", res[3:0]); end
    rd(16'h020); if (res[0]) fail("clock stopped: stream still running");
    full_window; rd(16'h005); if (res !== 0) begin fail("clock stopped: sample rate not 0"); $display("  %0d", res); end
    $display("%0t 8 DATA_CLK stopped: stream closed after %0d zero sample times, status and rate 0", $time, fills);
    clk_on = 1;
    wait_status(4'b1010, 4'b1010, 200, "clock restart: status");
    check = 1;
    stream_start(RADIO, 1, 1, 4092, 2 * 4092 + 7);
    while (!eob) rx_packet;
    if (total != 2 * 4092 + 7) begin fail("radio rx count after restart"); $display("  %0d", total); end
    if (next_t > 200000) begin fail("time not restarted from 0"); $display("  %0d", next_t); end
    wr(16'h0F0, 1);
    stream_start(PATTERN, 1, 1, 1000, 2500);
    while (!eob) rx_packet;
    if (total != 2500) fail("pattern count after restart");
    counters("8");
    $display("%0t 8 DATA_CLK restarted: radio and pattern streams exact", $time);
    // 9: one of each counter, register and event code
    rd(16'h031); if (res !== 0) fail("bands after power-up");
    wr(16'h031, 32'h0000_0016); rd(16'h031); if (res !== 32'h16) fail("bands readback");
    now_time;
    tx_packet(1, 1, 1, 1, 16'd0, 64'd5, 16);                          // LATE twice: their time has passed
    tx_packet(1, 1, 1, 1, 16'd1, 64'd6, 16);                          // (2 here, 1 SEQ_ERROR: a swap shows)
    exp_c[3] = exp_c[3] + 2;
    tx_packet(1, 0, 1, 1, 16'd10, t + 20000, 16);                     // a burst, the second packet's
    tx_packet(1, 1, 0, 0, 16'd12, 64'd0, 16);                         // sequence jumps: SEQ_ERROR, plays
    exp_c[4] = exp_c[4] + 1; exp_c[5] = exp_c[5] + 1;
    tx_packet(2, 1, 1, 0, 16'd0, 64'd0, 16);                          // version 2: BAD_PACKET
    exp_c[6] = exp_c[6] + 1;
    // the rx crossing full for 5 strobes (1R1T: every DATA_CLK cycle)
    @(negedge dut.dclk); force dut.rxs_full = 1'b1;
    repeat (5) @(negedge dut.dclk);
    release dut.rxs_full;
    exp_cdc = exp_cdc + 5; exp_c[1] = exp_c[1] + 5;
    bus_wait(80000);                               // the burst ends 0.33 ms after its send, then its event
    counters("9");
    $display("%0t 9 LATE x2, SEQ_ERROR, BAD_PACKET, 5 sample times lost in the crossing: registers and events", $time);
    // 10: the rings' depth. rx: stop reading until the framer overflows
    wr(16'h0F0, 0); wr(16'h089, 0);
    stream_start(RADIO, 1, 1, 4092, 0);
    rd(16'h080); while (res == exp_c[1]) begin bus_wait(20000); rd(16'h080); end
    rd(16'h089); nb = res;
    if (nb < 131072 - 4096 || nb > 131072) begin fail("rx_hwm at the first overflow"); $display("  %0d words", nb); end
    wr(16'h020, 2); drain;
    bus_wait(1000); rd(16'h080); exp_c[1] = res;
    // tx: a burst timed 1.6 ms ahead, 16 full packets: the ring fills
    wr(16'h08B, 0); now_time;
    for (i = 0; i < 16; i = i + 1) tx_packet(1, i == 15, i == 0, i == 0, i, t + 100000, 4092);
    bus_wait(20000);                               // the last packets reach the ring
    rd(16'h08B); n0 = res;
    if (n0 < 65536 - 4096 || n0 > 65536) begin fail("tx_hwm with the ring full"); $display("  %0d words", n0); end
    rd(16'h08A); while (res != 0) begin bus_wait(20000); rd(16'h08A); end
    exp_c[5] = exp_c[5] + 1;
    bus_wait(40000);
    counters("10");
    $display("%0t 10 rings: rx_hwm %0d at the first overflow, tx_hwm %0d with 16 packets queued", $time, nb, n0);
    // 6
    op(8'd3, 16'h0000, {8'd0, 1'b1, 5'd0, 10'h123, 8'h5A});               // AD9361 0x123 := 0x5A
    if (ad.r[10'h123] !== 8'h5A) fail("AD9361 SPI write");
    op(8'd3, 16'h0000, {8'd0, 1'b0, 5'd0, 10'h123, 8'h00}); if (res !== 32'h5A) fail("AD9361 SPI read");
    op_arg(8'd5, 8'd1, 16'h0000, {16'h00FF, 16'h005A}); if (res !== 32'h5A) fail("POLL over SPI");
    op_arg(8'd3, 8'd1, 16'h0000, 32'h00AB_CDE3);                          // ADF4001
    if (pll.n !== 1 || pll.log[0] !== 24'hABCDE3) fail("ADF4001 word");
    if (ad.errors != 0 || pll.errors != 0) fail("SPI timing or framing");
    check = 0;
    wr(16'h030, 0); if (resetb !== 1'b0) fail("RESETB not asserted again");
    wait_status(4'b1010, 4'b0000, 50, "RESETB low: sample clock and path down");
    $display("%0t 6 radio control: AD9361 write / read / POLL, ADF4001 word (%0d AD9361 frames); RESETB low stops the clock", $time, ad.frames);
    if (pin_errs != 0) fail("pins or LEDs");
    if (m.tx_errors != 0) begin fail("tx pins: timing or frame"); $display("  %0d", m.tx_errors); end
    if (fx3.errors != 0) fail("FX3 contract");
    $display("model errors %0d, bench errors %0d", fx3.errors, errors);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
  task counters(input [8*2-1:0] step);
    begin
      rd(16'h003);                                 // any result, collects events sent meanwhile
      for (k = 1; k <= 6; k = k + 1) begin
        rd(16'h07F + k);
        if (res != exp_c[k]) begin fail("counter"); $display("  code %0d = %0d, expected %0d", k, res, exp_c[k]); end
        if (ev_sum[k] != exp_c[k]) begin fail("events"); $display("  code %0d events add to %0d, expected %0d", k, ev_sum[k], exp_c[k]); end
      end
      rd(16'h086); if (res != exp_cdc) begin fail("rx_cdc_lost"); $display("  %0d, expected %0d", res, exp_cdc); end
      rd(16'h087); if (res != 0) fail("cmd_dropped");
      $display("%0t %0s counters done", $time, step);
    end
  endtask
  initial begin #30_000_000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
