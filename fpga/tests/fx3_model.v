// SPDX-License-Identifier: GPL-3.0-or-later
//
// fx3_model - the FX3 slave FIFO as the stock firmware sets it up: the
// referee every bus-master test runs against. It is strict: whatever the
// real FX3 leaves undefined or answers with a PIB error is an error here.
//
// Sources: Infineon AN65974 rev *P "Designing with the EZ-USB FX3 slave
// FIFO interface", sections 5, 7, 8, 9.3, 9.5; the firmware (b200_main.c):
// CyU3PGpifSocketConfigure(thread, socket, W, CyFalse, 1) with W = 5 on
// the threads the FPGA reads and W = 6 on those it writes; FLAGA = current
// thread DMA ready, FLAGB = current thread DMA watermark; two DMA buffers
// per thread.
//
// Time: edge k is the k-th rising clk edge. "X at edge k" is the value X
// held in the cycle before k, which is what a register clocked at k takes.
//
// Threads, t = {control, in}: 0 data OUT (host -> FPGA: the FPGA reads),
// 1 data IN (FPGA -> host: the FPGA writes), 2 control OUT, 3 control IN.
// Each has two DMA buffers that the GPIF side and the host side each use
// alternately, so buffers stay in order.
//
// The contract (every rule checked; a violation counts in `errors`):
//   read   SLRD# and SLOE# low at edge k: the next word of the thread's
//          buffer is taken; it is on D from edge k+1 to edge k+2 only, so
//          the FPGA's input register captures it at k+2 ("2 cycle latency
//          from SLRD# to data"). Elsewhere D carries X while the FX3 drives.
//   write  SLWR# low at edge k: D is stored. With PKTEND# low as well the
//          buffer is committed after this word (a short packet); a full
//          buffer commits by itself (PKTEND# with the word that fills it is
//          an error: it is not defined). PKTEND# without SLWR# commits the
//          buffer as it is (zero-length if empty).
//   PIB    a read with no word to read is an underrun, a write with no
//          space an overrun (AN 9.6).
//   ZLP    a short packet of a multiple of 1024 bytes is an error: USB
//          sends it as full-size packets and the firmware adds no
//          zero-length packet, so the host never sees it end.
//   bus    the FX3 drives D while SLOE# is low and for one cycle after
//          (tOEZ up to 8 ns); the FPGA must leave a full idle cycle between
//          its own drive and the FX3's, in both directions.
//   flags  driven right after edge k (so sampled by the FPGA at k+1):
//          thread  the one sampled on A at edge k-ADDR_LAT+1. ADDR_LAT = 2:
//                  "valid on the 3rd clock edge" after A changes (AN 8.2).
//          READY   OUT: the buffer has words left; IN: it has space. From
//                  the state after edge k-RD_LAT (OUT) or k-WR_LAT (IN):
//                  RD_LAT = 2, WR_LAT = 3 (AN Table 4: empty sampled on the
//                  3rd edge after the last read, full on the 4th after the
//                  last write).
//          WMARK   OUT: more than W-1 words left; IN: more than W-2 words
//                  of space. From the state after edge k-WM_LAT, WM_LAT = 1.
//                  This is AN 9.3 exactly: once WMARK is sampled low at
//                  edge E, W-1 words are still to arrive on D after E (the
//                  two strobed at E-1 and E included), and W-4 words may
//                  still be written after E.
//   switch once a buffer is consumed or committed the thread stays not
//          ready for SWITCH cycles (AN 7: the socket takes "up to a few
//          microseconds" to load the next DMA descriptor).
//
// Host side: host_send(t, n) commits an OUT buffer of n words from
// send[t*DATA + i]; host_recv(t, n) waits for the next IN buffer and copies
// it to recv[t*DATA + i]. Both block until a buffer is free / committed.
`timescale 1ns/1ps
`default_nettype none

module fx3_model #(
  parameter DATA = 4096, CTRL = 256,    // buffer sizes in 32-bit words: 16 KiB, 1 KiB
  parameter W_RD = 5, W_WR = 6,         // watermarks the firmware sets
  parameter ADDR_LAT = 2, RD_LAT = 2, WR_LAT = 3, WM_LAT = 1,
  parameter SWITCH = 100,               // cycles: 1 us at 100 MHz
  // clock to output, ns (AN65974 Table 3: tCO <= 7 for data, tCFLG <= 8 for
  // flags); 0 when the FPGA side runs on the same clock in simulation
  parameter real TCO_DATA = 0.0, TCO_FLAG = 0.0
) (
  input  wire        clk,
  inout  wire [31:0] d,
  input  wire        slwr, slrd, sloe, pktend,
  input  wire [1:0]  a,
  input  wire        fpga_drives,       // the FPGA's output enable on D (bench probe)
  output reg         flaga = 0, flagb = 0
);
  integer errors = 0;
  task fail(input [8*48-1:0] what, input integer t);
    begin errors = errors + 1; $display("%0t fx3_model: %0s (thread %0d)", $time, what, t); end
  endtask

  function integer size(input integer t); size = t[1] ? CTRL : DATA; endfunction
  function is_in(input integer t); is_in = t[0]; endfunction

  // -- buffers: index ((t * 2 + b) * DATA + word) --------------------------
  reg [31:0] mem [0:8*DATA-1];
  reg [31:0] send [0:4*DATA-1];
  reg [31:0] recv [0:4*DATA-1];
  reg        gpif_owns [0:7];  // OUT: holds unread words; IN: free for writing
  integer    words [0:7];      // words in the buffer
  integer    g [0:3], h [0:3]; // buffer the GPIF / host side uses next
  integer    pos [0:3];        // next word the GPIF side reads (OUT)
  integer    sw [0:3];         // cycles until the GPIF side may use its buffer
  integer    t, i;
  initial for (t = 0; t < 4; t = t + 1) begin
    g[t] = 0; h[t] = 0; pos[t] = 0; sw[t] = 0;
    for (i = 0; i < 2; i = i + 1) begin gpif_owns[2*t+i] = is_in(t); words[2*t+i] = 0; end
  end

  function integer cur(input integer t); cur = 2 * t + g[t]; endfunction
  // what READY and WMARK would say now
  function ready_now(input integer t);
    ready_now = sw[t] == 0 && gpif_owns[cur(t)] &&
                (is_in(t) ? words[cur(t)] < size(t) : pos[t] < words[cur(t)]);
  endfunction
  function wmark_now(input integer t);
    wmark_now = ready_now(t) && (is_in(t) ? size(t) - words[cur(t)] > W_WR - 2
                                          : words[cur(t)] - pos[t] > W_RD - 1);
  endfunction
  task release_buffer(input integer t);   // GPIF side done with its buffer
    begin gpif_owns[cur(t)] = 0; pos[t] = 0; g[t] = 1 - g[t]; sw[t] = SWITCH; end
  endtask

  // -- data bus ---------------------------------------------------------------
  reg [31:0] dq = 0;
  reg        tail = 0;                // the cycle after SLOE# rises: still driving
  wire       fx3_drives = !sloe || tail;
  assign d = fx3_drives ? dq : 32'bz;

  // -- one clock edge -----------------------------------------------------------
  reg  [7:0] ready_hist [0:3];         // bit j: READY from the state after edge k-j
  reg  [7:0] wmark_hist [0:3];
  reg  [1:0] a_hist [0:7];             // a_hist[j]: A sampled at edge k-j
  reg [31:0] word;
  reg        word_due = 0, fpga_drove = 0;
  integer    sel;
  initial begin
    for (t = 0; t < 4; t = t + 1) begin ready_hist[t] = 0; wmark_hist[t] = 0; end
    for (i = 0; i < 8; i = i + 1) a_hist[i] = 0;
  end

  always @(posedge clk) begin
    // bus ownership in the cycle that just ended
    if (fpga_drives && fx3_drives)   fail("FPGA and FX3 both drive D", a);
    if (fpga_drove && !sloe)         fail("SLOE# low right after the FPGA drove D", a);
    fpga_drove = fpga_drives;
    tail <= !sloe;
    // D: the word read at the previous edge, else X
    dq <= #(TCO_DATA) word_due ? word : 32'bx;
    word_due = 0;

    for (t = 0; t < 4; t = t + 1) if (sw[t] > 0) sw[t] = sw[t] - 1;
    t = a;
    if (!slrd && !slwr) fail("SLRD# and SLWR# together", t);
    if (!slrd) begin
      if (sloe)                fail("read with SLOE# high", t);
      else if (is_in(t))       fail("read on an IN thread", t);
      else if (!ready_now(t))  fail("read underrun", t);
      else begin
        word = mem[cur(t) * DATA + pos[t]];
        word_due = 1;
        pos[t] = pos[t] + 1;
        if (pos[t] == words[cur(t)]) release_buffer(t);
      end
    end
    if (!slwr) begin
      if (!sloe)               fail("write while the FX3 drives D", t);
      else if (!is_in(t))      fail("write on an OUT thread", t);
      else if (!ready_now(t))  fail("write overrun", t);
      else begin
        mem[cur(t) * DATA + words[cur(t)]] = d;
        if (^d === 1'bx)       fail("write of an undefined word", t);
        words[cur(t)] = words[cur(t)] + 1;
        if (words[cur(t)] == size(t)) begin
          if (!pktend)         fail("PKTEND# with the word that fills the buffer", t);
          release_buffer(t);
        end else if (!pktend) begin
          if (words[cur(t)] % 256 == 0) fail("short packet of a multiple of 1024 bytes", t);
          release_buffer(t);
        end
      end
    end else if (!pktend) begin
      if (!is_in(t) || !ready_now(t)) fail("PKTEND# on a thread with no buffer", t);
      else begin fail("zero-length packet", t); release_buffer(t); end
    end

    // flags for the next cycle
    for (i = 7; i > 0; i = i - 1) a_hist[i] = a_hist[i-1];
    a_hist[0] = a;
    for (t = 0; t < 4; t = t + 1) begin
      ready_hist[t] = {ready_hist[t][6:0], ready_now(t)};
      wmark_hist[t] = {wmark_hist[t][6:0], wmark_now(t)};
    end
    sel = a_hist[ADDR_LAT - 1];
    flaga <= #(TCO_FLAG) ready_hist[sel][is_in(sel) ? WR_LAT : RD_LAT];
    flagb <= #(TCO_FLAG) wmark_hist[sel][WM_LAT];
  end

  // -- host side (between edges) ---------------------------------------------
  task automatic host_send(input integer t, input integer n);
    integer b, k;
    begin
      if (is_in(t) || n < 1 || n > size(t)) fail("host_send: bad thread or length", t);
      if (n < size(t) && n % 256 == 0)       fail("host_send: short multiple of 1024 bytes", t);
      b = 2 * t + h[t];
      while (gpif_owns[b]) @(negedge clk);
      for (k = 0; k < n; k = k + 1) mem[b * DATA + k] = send[t * DATA + k];
      words[b] = n; gpif_owns[b] = 1; h[t] = 1 - h[t];
    end
  endtask

  task automatic host_recv(input integer t, output integer n);
    integer b, k;
    begin
      b = 2 * t + h[t];
      @(negedge clk);
      while (gpif_owns[b]) @(negedge clk);
      n = words[b];
      for (k = 0; k < n; k = k + 1) recv[t * DATA + k] = mem[b * DATA + k];
      words[b] = 0; gpif_owns[b] = 1; h[t] = 1 - h[t];
    end
  endtask
endmodule

`default_nettype wire
