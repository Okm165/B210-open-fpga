// tb_e2e_rx.v - one signal, composed at the ADC pins and interpreted at the
// USB words, with the bench in the place of UHD.
//
//   AD9361 pin model -> b200_io -> b200_core (radio 0: DDC, stream control,
//   framer, wire-format converter, error mux, CDC FIFO, packet gate; receive
//   mux; extra buffer) -> gpif2_slave_fifo32 -> FX3 model -> "host"
//
// b200_core and gpif2_slave_fifo32 are the modules b200.v instantiates, with
// the parameters b200.v gives them, so the buffering is the board's.  The
// bench talks to the radio the way UHD does: every register is written with a
// control packet (answered by a response packet, which the bench waits for,
// on the FX3 control thread), streaming is started with the continuous
// stream command and ended with the stop command.  Control packets enter at
// b200_core's control stream; their way through the FX3 interface is
// tb_ctrl_fifo's subject.
//
// The DDC is programmed as UHD programs it for a sample rate equal to the
// master clock rate (decimation 1, no halfband, scale 39767), so one sample
// leaves the DDC per radio clock and its value is known: 16 * 0.99925 times
// the ADC word of L clocks earlier (0.99925 = the CORDIC's 1.64676 against
// the 1.648 in the scale word), turned by the DDC's LO when that is set (the
// LO starts at zero phase with every stream and a tone at f leaves at
// f + LO).
//
// What the host checks, on every word it receives:
//   words      none carries an X or Z bit; the FPGA never writes while the
//              FX3 flags say "full"
//   packets    header type, stream ID and length field; the transfer has
//              exactly the words the length field announces (plus the one pad
//              word the interface adds to transfers of a multiple of 1024
//              bytes); sequence numbers count up by one, none missing
//   time       each packet's time stamp is the previous packet's plus its
//              number of samples: the stream has no hole and no overlap
//   length     every packet carries the samples per packet that were asked
//              for, except the last one of the stream (end-of-burst flag set)
//   samples    EVERY payload sample, I and Q separately, is the stimulus
//              sample that was on the pins at (its time stamp + C) scaled by
//              the stock gain, within TOL codes, for one constant C found
//              once (bounded search) and then held for the rest of the run;
//              C must be the design's known pins-to-framer latency, LAT.
//              A swapped I/Q pair, a repeated, lost, reordered or made-up
//              sample fails here.  Exempt: the first FLUSH samples after each
//              stream start, which are what the DDC pipeline held while it
//              was stopped (stock: the CORDIC and CIC are enabled by `run`).
//   count      after the stop command and the drain, the host has received
//              exactly as many samples as the DDC produced while streaming
//   rate       unless the link is stalled on purpose: the words per bus clock,
//              measured over a whole number of packets, are what the sample
//              rate needs (within 0.5 %; for sc16 that is at least 0.60, or
//              245 MB/s at 100 MHz), and the backlog when the stop command
//              is sent is no more than the packets in flight
//   no error   no error packet in the stream (see the overrun case below)
//
// Cases (see the justfile for the flags):
//   base, fs, fslo, two, noisy   tone at bin 410/4096 at two levels, with a
//              DDC LO of fs/8, with a second tone 54 dB down, with noise
//   stall, stall30   the FX3 stops taking data for a while (flags low);
//              the FIFOs absorb the backlog, nothing is lost
//   oversize   the largest packet UHD asks for by default: 4080 samples,
//              which is the sc8 wire format with 8176-byte frames; honoured
//              as written, at full rate, nothing lost.  Run with the noise
//              stimulus: at 8 bits a plain tone looks the same ten samples
//              later, noise does not.
//   overrun    a stall longer than the buffering.  Stock behaviour, checked
//              step by step: the samples keep their order up to the overflow,
//              the packet in progress is closed short, ONE error packet with
//              code 8 (overrun) follows the data in the receive stream, and
//              streaming stops - no further word, state machine idle.  The
//              bench then does what UHD's b200 overflow handler does for a
//              continuous stream: it issues the stream command again, and
//              the stream must come back with full-length packets, at full
//              rate, time stamps and samples in place.
//
// Negative control (plusarg; the justfile runs it and requires FAIL):
// +NEG_IQSWAP puts Q in the first half of each pin period and I in the second.
//
// Offline (with +define+E2E_DUMP) every GPIF word is written to e2e_words.txt
// for spectral analysis.
`timescale 1ns/1ps

module tb_e2e_rx;

   // ---- configuration ------------------------------------------------------
   localparam integer NSAMP    = 4096;
   localparam integer KBIN     = 410;
`ifndef AMP
   localparam integer AMP = 1000;         // of 2047 full scale (12-bit ADC)
`else
   localparam integer AMP = `AMP;
`endif
`ifndef PHINC
   localparam [31:0] PHINC = 32'h0;       // DDC LO phase increment (2^32 = fs)
`else
   localparam [31:0] PHINC = `PHINC;
`endif
`ifndef E2E_MAXLEN
   localparam integer MAXLEN   = 66;      // samples per packet, as written to the framer
`else
   localparam integer MAXLEN   = `E2E_MAXLEN;
`endif
`ifndef E2E_RUNCLK
   localparam integer RUNCLK   = 50000;   // bus clocks of streaming before the stop command
`else
   localparam integer RUNCLK   = `E2E_RUNCLK;
`endif
`ifdef E2E_SC8
   localparam integer SC8 = 1;            // wire format sc8 (SR_RX_FMT = 3)
`else
   localparam integer SC8 = 0;            // wire format sc16 (SR_RX_FMT = 0)
`endif
`ifdef STALL
   localparam integer STALLED      = 1;
   localparam integer STALL_START  = `STALL_START;   // bus clocks after the stream command
   localparam integer STALL_CLKS   = `STALL_CLKS;
   localparam integer STALL_PERIOD = `STALL_PERIOD;
`else
   localparam integer STALLED      = 0;
   localparam integer STALL_START  = 0;
   localparam integer STALL_CLKS   = 0;
   localparam integer STALL_PERIOD = 1;
`endif
`ifdef E2E_OVERRUN
   localparam integer OVERRUN  = 1;
`else
   localparam integer OVERRUN  = 0;
`endif
`ifdef E2E_REPAID
   localparam integer REPAID   = 1;       // the stall must be repaid by the stop command
`else
   localparam integer REPAID   = 0;
`endif

   // register map, as UHD's b200 driver uses it (byte address / 4)
   localparam [7:0]  SR_RX_CTRL = 8'd96;  // +0 command, +1 time hi, +2 time lo (latches)
   localparam [7:0]  SR_RX_FRMR = 8'd100; // +0 samples per packet, +1 stream ID
   localparam [7:0]  SR_RX_FMT  = 8'd136; // 0 sc16, 3 sc8
   localparam [7:0]  SR_RX_DSP  = 8'd144; // +0 LO, +1 scale, +2 decimation, +3 mux
   localparam [31:0] CTRL_SID   = 32'h0000_0010;   // B200_CTRL0_MSG_SID
   localparam [31:0] RESP_SID   = 32'h0010_0000;   // the same, source and destination swapped
   localparam [31:0] RX_SID     = 32'h0000_00A0;   // B200_RX_DATA0_SID
   localparam [31:0] CMD_START  = 32'hE000_0001;   // now | chain | reload, 1 line: continuous
   localparam [31:0] CMD_STOP   = 32'h9000_0000;   // now | stop
   localparam [31:0] ERR_OVERRUN = 32'h8;

   // what the DDC makes of the stimulus
   localparam real    G_RX   = 0.99925;   // CORDIC 1.64676 / the 1.648 in UHD's scale word
   localparam real    TOL16  = 3.0;       // codes of the 16-bit sample (measured: 1.2)
   localparam real    TOL8   = 0.75;      // codes of the 8-bit sample (rounding: 0.5)
   localparam integer FLUSH  = 64;        // samples after a stream start that are pipeline history
   localparam integer LOCKN  = 24;        // samples used to find C
   localparam integer LMAX   = 160;       // radio clocks, pins -> framer: search range
   // What the search must find.  A sample's time stamp is the radio time at
   // which the framer took it, and that is this many clocks after the sample
   // was on the pins (3 in b200_io, the rest in the DDC, which tb_ddc_golden
   // holds to the Ettus original clock for clock).  A change of this number
   // moves every time stamp against the antenna and must be a decision.
   localparam integer LAT    = 42;
   localparam integer PEAK   = 16 * AMP * 0.99925 + 0.5;

   reg rx_clk  = 0;  always #8.138 rx_clk  = ~rx_clk;   // 61.44 MHz DATA_CLK
   reg bus_clk = 0;  always #5.0   bus_clk = ~bus_clk;  // 100 MHz bus and GPIF clock
   reg refclk  = 0;  always #2.5   refclk  = ~refclk;   // 200 MHz IDELAYCTRL reference

   reg neg_iqswap = 0;
   initial neg_iqswap = $test$plusargs("NEG_IQSWAP");

   // ---- ADC pins ---------------------------------------------------------
   // Data transitions 1 ns AFTER each DATA_CLK edge, I in the first half of
   // the period, Q in the second (UG-570 DDR).  hist_* keeps what was sent.
   localparam integer HIST = 1 << 20;
   reg signed [11:0] hist_i [0:HIST-1];
   reg signed [11:0] hist_q [0:HIST-1];
   reg rx_frame = 0;
   reg [11:0] rx_data = 0;
   integer n = 0;
   real arg;
   integer ci, cq;

   always @(posedge rx_clk) begin #1 rx_data <= neg_iqswap ? cq[11:0] : ci[11:0]; end   // I(n)
   always @(negedge rx_clk) begin
      #1 rx_data <= neg_iqswap ? ci[11:0] : cq[11:0];                                   // Q(n)
      hist_i[n] = ci; hist_q[n] = cq;
      n <= n + 1;
   end
`ifdef NOISY
   // Realistic composite: a -6 dBFS tone plus band-limited noise at -24 dBc,
   // each component clipped to the ADC's own 12-bit rails exactly as the
   // converter does.  This is the operating point where a gain-staging error
   // would show up as clipping long before a pure tone does.
   reg [31:0] nlfsr = 32'h1357_9BDF;
   integer ni, nq;
   always @(posedge rx_clk) nlfsr <= {nlfsr[30:0], nlfsr[31] ^ nlfsr[21] ^ nlfsr[1] ^ nlfsr[0]};
   always @(*) begin
      ni = $rtoi(1024.0*$cos(2.0*3.14159265358979*410*n/NSAMP))
                 + $signed({1'b0, nlfsr[8:1]}) - 128;
      nq = $rtoi(1024.0*$sin(2.0*3.14159265358979*410*n/NSAMP))
                 + $signed({1'b0, nlfsr[16:9]}) - 128;
      ci = (ni >  2047) ?  2047 : (ni < -2048) ? -2048 : ni;
      cq = (nq >  2047) ?  2047 : (nq < -2048) ? -2048 : nq;
   end
`else
`ifdef TWOTONE
   // Strong blocker + weak tone at the smallest level a 12-bit ADC can carry
   // (2 counts, ~ -54 dBc).  The weak tone is what a low-SNR measurement would
   // lose: it must survive the whole path unchanged.
   always @(*) begin
      ci = $rtoi(1000.0*$cos(2.0*3.14159265358979*410*n/NSAMP)
                + 2.0*$cos(2.0*3.14159265358979*1300*n/NSAMP));
      cq = $rtoi(1000.0*$sin(2.0*3.14159265358979*410*n/NSAMP)
                + 2.0*$sin(2.0*3.14159265358979*1300*n/NSAMP));
   end
`else
   always @(*) begin
      arg = 2.0*3.14159265358979*KBIN*n/NSAMP;
      ci  = $rtoi(AMP*$cos(arg));
      cq  = $rtoi(AMP*$sin(arg));
   end
`endif
`endif

   // ---- the board, as b200.v wires it ---------------------------------------
   reg reset_global = 1, clocks_ready = 0;
   wire radio_clk, idelay_rdy;
   wire gpif_rst, bus_rst, radio_rst;
   reset_sync gpif_sync  (.clk(bus_clk),   .reset_in(!clocks_ready), .reset_out(gpif_rst));
   reset_sync bus_sync   (.clk(bus_clk),   .reset_in(!clocks_ready), .reset_out(bus_rst));
   reset_sync radio_sync (.clk(radio_clk), .reset_in(!clocks_ready | !idelay_rdy), .reset_out(radio_rst));

   wire [31:0] rx_data0, rx_data1, tx_data0, tx_data1;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   b200_io io (
      .areset(reset_global),
      .idelay_refclk(refclk), .idelay_rst(!clocks_ready), .idelay_rdy(idelay_rdy),
      .mimo(1'b0),
      .radio_clk(radio_clk), .radio_rst(),
      .rx_i0(rx_data0[31:20]), .rx_q0(rx_data0[15:4]),
      .rx_i1(rx_data1[31:20]), .rx_q1(rx_data1[15:4]),
      .rx_stb(),
      .tx_i0(tx_data0[31:20]), .tx_q0(tx_data0[15:4]),
      .tx_i1(tx_data1[31:20]), .tx_q1(tx_data1[15:4]),
      .tx_stb(),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));
   assign {rx_data0[19:16], rx_data0[3:0], rx_data1[19:16], rx_data1[3:0]} = 16'h0;

   wire [63:0] rx_tdata, tx_tdata, resp_tdata;
   wire rx_tlast, rx_tvalid, rx_tready;
   wire tx_tlast, tx_tvalid, tx_tready;
   wire resp_tlast, resp_tvalid, resp_tready;
   reg  [63:0] ctrl_tdata = 64'h0;
   reg  ctrl_tlast = 0, ctrl_tvalid = 0;
   wire ctrl_tready;

   wire [3:0] led_events;                 // radio 0: {tx alarm, rx alarm, tx sample, rx sample}
   b200_core #(.EXTRA_BUFF_SIZE(12), .BUS_CLK_HZ(100000000)) core (
      .bus_clk(bus_clk), .bus_rst(bus_rst),
      .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx0(rx_data0), .rx1(rx_data1), .tx0(tx_data0), .tx1(tx_data1),
      .fe0_gpio_out(), .fe1_gpio_out(),
      .fp_gpio_in(10'h0), .fp_gpio_out(), .fp_gpio_ddr(),
      .pps_int(1'b0), .pps_ext(1'b0),
      .rxd(1'b1), .txd(),
      .sen(), .sclk(), .mosi(), .miso(1'b0),
      .rb_misc(32'h0), .misc_outs(),
      .lock_signals(2'b00), .radio0_events(led_events), .radio1_events(), .pps());

   // ---- GPIF + FX3 model --------------------------------------------------
   wire [31:0] gpif_d;
   wire sloe, slrd, slwr, slcs, pktend;
   wire [1:0] fifoadr;
   reg [3:0] gpif_ctl = 4'b0000;
   reg fx3_drive = 0;
   assign gpif_d = fx3_drive ? 32'h0 : 32'bz;

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(14), .DATA_TX_FIFO_SIZE(14)) gpif (
      .gpif_clk(bus_clk), .gpif_rst(gpif_rst), .gpif_enb(1'b1),
      .gpif_d(gpif_d), .gpif_ctl(gpif_ctl), .fifoadr(fifoadr),
      .slwr(slwr), .sloe(sloe), .slcs(slcs), .slrd(slrd), .pktend(pktend),
      .fifo_clk(bus_clk), .fifo_rst(bus_rst),
      .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
      .ctrl_tdata(), .ctrl_tlast(), .ctrl_tvalid(), .ctrl_tready(1'b1),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .debug());

   // FX3: flags follow the thread the FPGA addresses.  The host has nothing
   // to send (read threads: not ready).  The write threads have room, except
   // that during a stall the data thread's buffers are full: the watermark
   // flag drops first and the ready flag six clocks later, as a filling DMA
   // buffer announces itself.
   localparam [1:0] ADDR_DATA_RX = 2'b01, ADDR_CTRL_RX = 2'b11;
   integer sclk = -1;                    // bus clocks since the first stream command
   reg     stall_now = 0;
   reg [5:0] stall_sr = 6'b0;
   wire    fx3_full = stall_now & stall_sr[5];
   integer full_clks = 0;
   always @(posedge bus_clk) begin
      if (sclk >= 0) sclk <= sclk + 1;
      stall_now <= (STALLED != 0) && (sclk >= STALL_START) &&
                   (((sclk - STALL_START) % STALL_PERIOD) < STALL_CLKS);
      stall_sr  <= {stall_sr[4:0], stall_now};
      full_clks <= fx3_full ? full_clks + 1 : 0;
      case (fifoadr)
        ADDR_DATA_RX: gpif_ctl <= {2'b00, ~stall_now, ~fx3_full};
        ADDR_CTRL_RX: gpif_ctl <= 4'b0011;
        default:      gpif_ctl <= 4'b0000;
      endcase
   end
   always @(negedge bus_clk) fx3_drive <= (sloe === 1'b0) || (slrd === 1'b0);

   // ---- what the radio did (reference points inside the design) -------------
   // The number of samples the DDC handed to the framer while streaming, the
   // offset between the stimulus index and the radio's time, and the state of
   // the stream control machine.
   integer strobes = 0, full_events = 0, cref = 0;
   reg full_d = 0;
   // What the radio tells the LEDs: one pulse per received sample and one per
   // error packet.  A shimmer that counts something else, or an alarm that
   // fires twice or not at all, is found here.
   integer led_samples = 0, led_rx_alarms = 0, led_tx = 0;
   always @(posedge radio_clk) if (!radio_rst) begin
      if (led_events[0] === 1'b1) led_samples   = led_samples + 1;
      if (led_events[2] === 1'b1) led_rx_alarms = led_rx_alarms + 1;
      if (led_events[1] === 1'b1 || led_events[3] === 1'b1) led_tx = led_tx + 1;
   end
   wire [3:0] ibs_state = core.radio_0.ibs_state;
   always @(posedge radio_clk) begin
      cref = n - core.radio_0.vita_time;
      if (!radio_rst) begin
         if (core.radio_0.run_rx === 1'b1 && core.radio_0.strobe_rx === 1'b1) strobes = strobes + 1;
         full_d <= core.radio_0.full;
         if (core.radio_0.full === 1'b1 && !full_d) full_events = full_events + 1;
      end
   end

   // ---- the host ------------------------------------------------------------
   integer fails = 0;
   // control
   integer ctrl_seq = 0, acks = 0, bad_acks = 0, ctrl_timeouts = 0;
   // words and packets
   reg [31:0] dw [0:8191];               // words of the data transfer in progress
   reg [31:0] cw [0:15];                 // words of the response transfer in progress
   integer dn = 0, cn = 0;
   integer words = 0, x_words = 0, wr_while_full = 0, bad_strobe = 0;
   integer packets = 0, bad_hdr = 0, bad_xfer = 0, seq_errors = 0, time_errors = 0;
   integer len_errors = 0, eob_packets = 0, after_eob = 0, err_packets = 0, bad_err = 0;
   integer short_pending = 0;            // a short packet without EOB was the last one seen
   reg [11:0] expect_seq = 12'd0;
   reg [63:0] next_time = 64'd0;
   integer streams = 0, new_stream = 1;  // next data packet starts a stream
   integer stream_samples = 0, total_samples = 0;
   integer bclk = 0;
   // rate window: from the end of one data packet to the end of the last one
   // before the stop command, so it holds a whole number of packets
   integer measuring = 0, win_clk0 = -1, win_words0 = 0, win_clk1 = 0, win_words1 = 0;
   reg overrun_seen = 0;
   // samples
   integer locked = 0, lock_fail = 0, lkn = 0, cfix = 0, c0fix = 0, lat = 0;
   reg [63:0] lk_t [0:LOCKN-1];
   integer    lk_k [0:LOCKN-1], lk_i [0:LOCKN-1], lk_q [0:LOCKN-1];
   integer checked = 0, mismatches = 0, flushed = 0, shown = 0;
   real    max_err = 0.0;
   integer rail_hits = 0, max_i = 0, max_q = 0;
`ifdef E2E_DUMP
   integer fd;
   initial fd = $fopen("e2e_words.txt", "w");
`endif

   // The error of one received sample against the stimulus: sample at radio
   // time t (k samples into its stream) against the pin sample t + c, turned
   // by the DDC's LO.  The LO starts from zero phase with each stream and
   // advances by PHINC per clock; the sample passed the CORDIC -c0 clocks
   // before it reached the framer.
   function real sample_err(input [63:0] t, input integer k, input integer c, input integer c0,
                            input integer gi, input integer gq);
      integer ix;
      real xi, xq, a, ei, eq, di, dq;
      begin
         ix = t[31:0] + c;
         if (ix < 0 || ix >= HIST) sample_err = 1.0e9;
         else begin
            xi = hist_i[ix]; xq = hist_q[ix];
            // the DDC multiplies by exp(+j phase): a tone at f leaves at f + LO
            a  = 2.0 * 3.14159265358979 * (PHINC / 4294967296.0) * (k + c0);
            ei = 16.0 * G_RX * (xi * $cos(a) - xq * $sin(a));
            eq = 16.0 * G_RX * (xi * $sin(a) + xq * $cos(a));
            if (SC8 != 0) begin ei = ei / 256.0; eq = eq / 256.0; end
            di = gi - ei; if (di < 0) di = -di;
            dq = gq - eq; if (dq < 0) dq = -dq;
            sample_err = (di > dq) ? di : dq;
         end
      end
   endfunction

   task find_c;
      integer l, c0, j, ok, c0min;
      begin
         c0min = (PHINC == 32'd0) ? 0 : -LMAX;
         for (l = 0; l <= LMAX && !locked; l = l + 1)
            for (c0 = 0; c0 >= c0min && !locked; c0 = c0 - 1) begin
               ok = 1;
               for (j = 0; j < LOCKN && ok; j = j + 1)
                  if (sample_err(lk_t[j], lk_k[j], cref - l, c0, lk_i[j], lk_q[j]) >
                      ((SC8 != 0) ? TOL8 : TOL16)) ok = 0;
               if (ok) begin locked = 1; cfix = cref - l; c0fix = c0; lat = l; end
            end
         if (!locked) lock_fail = 1;
      end
   endtask

   task host_sample(input [63:0] t, input integer k, input integer gi, input integer gq);
      real e;
      integer ai, aq;
      begin
         ai = (gi < 0) ? -gi : gi;  aq = (gq < 0) ? -gq : gq;
         if (ai > max_i) max_i = ai;
         if (aq > max_q) max_q = aq;
         if (SC8 != 0) begin
            if (gi == 127 || gi == -128 || gq == 127 || gq == -128) rail_hits = rail_hits + 1;
         end else begin
            if (gi == 32767 || gi == -32768 || gq == 32767 || gq == -32768) rail_hits = rail_hits + 1;
         end
         if (k < FLUSH) flushed = flushed + 1;
         else if (!locked && !lock_fail) begin
            lk_t[lkn] = t; lk_k[lkn] = k; lk_i[lkn] = gi; lk_q[lkn] = gq;
            lkn = lkn + 1;
            if (lkn == LOCKN) begin
               find_c;
               if (locked) checked = checked + LOCKN;
            end
         end else if (locked) begin
            checked = checked + 1;
            e = sample_err(t, k, cfix, c0fix, gi, gq);
            if (e > max_err && e < 1.0e8) max_err = e;
            if (e > ((SC8 != 0) ? TOL8 : TOL16)) begin
               mismatches = mismatches + 1;
               if (shown < 6) begin
                  shown = shown + 1;
                  $display("E2E:   sample at time %0d (pin sample %0d) is I=%0d Q=%0d: off by %.1f codes",
                           t, t[31:0] + cfix, gi, gq, e);
               end
            end
         end
      end
   endtask

   task host_data_packet;
      reg [63:0] hdr, tm;
      integer i, bytes, nsamps, we, bps, gi, gq, isx;
      begin
         isx = 0;
         for (i = 0; i < dn; i = i + 1) if (^dw[i] === 1'bx) isx = isx + 1;
         x_words = x_words + isx;
         hdr = {dw[0], dw[1]};  tm = {dw[2], dw[3]};
         bytes = hdr[47:32];
         we = 2 * ((bytes + 7) / 8);
         if (isx != 0 || dn < 4) begin
            bad_hdr = bad_hdr + 1;
            if (shown < 6) begin
               shown = shown + 1;
               $display("E2E:   transfer of %0d words with %0d undefined, header %h", dn, isx, hdr);
            end
         end else if (hdr[63] === 1'b1) begin
            // not a data packet: the stream control's error report
            err_packets = err_packets + 1;
            // Its sequence number is the framer's count of packets handed on
            // when the overflow happened; the packets still in the framer's
            // FIFO (at most a FIFO full of them) left after that.  UHD does
            // not check the sequence number of a packet that is not data.
            if (hdr[63:60] !== 4'hA || bytes != 24 || dn != 6 || hdr[31:0] !== RX_SID ||
                ((expect_seq - hdr[59:48]) & 12'hFFF) > 4096 / (MAXLEN + 4) + 2 ||
                dw[4] !== ERR_OVERRUN || dw[5] !== 32'h0 ||
                tm < next_time || OVERRUN == 0 || overrun_seen) begin
               bad_err = bad_err + 1;
               $display("E2E:   unexpected error packet: header %h time %0d payload %h %h (%0d words)",
                        hdr, tm, dw[4], dw[5], dn);
            end else begin
               overrun_seen = 1;
               $display("E2E: overrun error packet (code 8) at radio time %0d, after %0d packets, %0d samples; last data sample was at %0d",
                        tm, packets, total_samples, next_time - 1);
            end
            short_pending = 0;
         end else begin
            bps    = (SC8 != 0) ? 2 : 4;
            nsamps = (bytes - 16) / bps;
            if (hdr[63:61] !== 3'b001 || hdr[31:0] !== RX_SID || bytes < 16 + bps ||
                (bytes - 16) % bps != 0) begin
               bad_hdr = bad_hdr + 1;
               if (shown < 6) begin
                  shown = shown + 1;
                  $display("E2E:   bad data header %h", hdr);
               end
               nsamps = 0;
            end
            // the transfer is the packet, plus one pad word when it is a
            // multiple of 256 words (the interface's FX3 corner case)
            if (dn != we + ((we % 256 == 0) ? 1 : 0)) begin
               bad_xfer = bad_xfer + 1;
               if (shown < 6) begin
                  shown = shown + 1;
                  $display("E2E:   transfer of %0d words for a packet of %0d bytes", dn, bytes);
               end
               nsamps = 0;
            end
            if (hdr[59:48] !== expect_seq) seq_errors = seq_errors + 1;
            expect_seq = hdr[59:48] + 12'd1;
            if (eob_packets != 0) after_eob = after_eob + 1;
            if (short_pending) len_errors = len_errors + 1;    // a short packet was not the last
            if (new_stream) begin
               streams = streams + 1;
               if (streams > 1 && tm < next_time) time_errors = time_errors + 1;
               stream_samples = 0; new_stream = 0;
            end else if (tm !== next_time) begin
               time_errors = time_errors + 1;
               if (shown < 6) begin
                  shown = shown + 1;
                  $display("E2E:   packet %0d time %0d, expected %0d", packets, tm, next_time);
               end
            end
            next_time = tm + nsamps;
            if (hdr[60]) eob_packets = eob_packets + 1;
            else if (nsamps != MAXLEN) short_pending = 1;
            if (nsamps > MAXLEN) len_errors = len_errors + 1;
            for (i = 0; i < nsamps; i = i + 1) begin
               if (SC8 != 0) begin
                  gi = (i % 2 == 0) ? $signed(dw[4 + i/2][31:24]) : $signed(dw[4 + i/2][15:8]);
                  gq = (i % 2 == 0) ? $signed(dw[4 + i/2][23:16]) : $signed(dw[4 + i/2][7:0]);
               end else begin
                  gi = $signed(dw[4 + i][31:16]);
                  gq = $signed(dw[4 + i][15:0]);
               end
               host_sample(tm + i, stream_samples + i, gi, gq);
            end
            stream_samples = stream_samples + nsamps;
            total_samples  = total_samples + nsamps;
            packets = packets + 1;
            if (measuring) begin
               if (win_clk0 < 0) begin win_clk0 = bclk; win_words0 = words; end
               win_clk1 = bclk; win_words1 = words;
            end
         end
      end
   endtask

   task host_response;
      reg [63:0] hdr;
      begin
         hdr = {cw[0], cw[1]};
         if (cn != 6 || hdr !== {4'hA, ctrl_seq[11:0], 16'd24, RESP_SID}) begin
            bad_acks = bad_acks + 1;
            $display("E2E:   bad control response: %0d words, header %h", cn, hdr);
         end else acks = acks + 1;
      end
   endtask

   always @(posedge bus_clk) begin
      bclk = bclk + 1;
      if (!gpif_rst) begin
         if (slwr === 1'b0) begin
            if (fifoadr == ADDR_DATA_RX) begin
               words = words + 1;
               if (full_clks > 4) wr_while_full = wr_while_full + 1;
               if (dn < 8192) begin dw[dn] = gpif_d; dn = dn + 1; end
`ifdef E2E_DUMP
               $fwrite(fd, "w %08x\n", gpif_d);
`endif
            end else if (fifoadr == ADDR_CTRL_RX) begin
               if (cn < 16) begin cw[cn] = gpif_d; cn = cn + 1; end
            end else bad_strobe = bad_strobe + 1;
         end else if (slwr !== 1'b1) bad_strobe = bad_strobe + 1;
         if (pktend === 1'b0) begin
            if (fifoadr == ADDR_DATA_RX) begin
`ifdef E2E_DUMP
               $fwrite(fd, "e\n");
`endif
               host_data_packet;
               dn = 0;
            end else if (fifoadr == ADDR_CTRL_RX) begin
               host_response;
               cn = 0;
            end
         end else if (pktend !== 1'b1) bad_strobe = bad_strobe + 1;
      end
   end

   // one register write, as UHD's radio_ctrl_core_3000 does it: a control
   // packet, then wait for the response packet
   task poke(input [7:0] addr, input [31:0] data);
      integer t;
      begin
         ctrl_seq = ctrl_seq + 1;
         @(posedge bus_clk);
         ctrl_tdata <= {4'h8, ctrl_seq[11:0], 16'd16, CTRL_SID}; ctrl_tlast <= 1'b0; ctrl_tvalid <= 1'b1;
         @(posedge bus_clk); while (!ctrl_tready) @(posedge bus_clk);
         ctrl_tdata <= {24'h0, addr, data}; ctrl_tlast <= 1'b1;
         @(posedge bus_clk); while (!ctrl_tready) @(posedge bus_clk);
         ctrl_tvalid <= 1'b0; ctrl_tlast <= 1'b0;
         t = 0;
         while (acks + bad_acks < ctrl_seq && t < 20000) begin @(posedge bus_clk); t = t + 1; end
         if (acks + bad_acks < ctrl_seq) begin
            ctrl_timeouts = ctrl_timeouts + 1;
            $display("E2E:   no response to the write of register %0d", addr);
            acks = ctrl_seq - bad_acks;     // do not wait for it again
         end
      end
   endtask

   task stream_cmd(input [31:0] cmd);
      begin
         poke(SR_RX_CTRL + 8'd0, cmd);
         poke(SR_RX_CTRL + 8'd1, 32'h0);
         poke(SR_RX_CTRL + 8'd2, 32'h0);     // latches the command
      end
   endtask

   // ---- run ---------------------------------------------------------------
   integer t, idle, last_words, backlog, silent_words;
   integer strobes_at_overrun, samples_at_overrun, pkt_words;
   real    rate, full_rate;

   initial begin
      repeat (20) @(posedge bus_clk);
      reset_global <= 0;
      repeat (20) @(posedge bus_clk);
      clocks_ready <= 1;
      t = 0;
      while ((radio_rst !== 1'b0 || bus_rst !== 1'b0 || gpif_rst !== 1'b0) && t < 5000) begin
         @(posedge bus_clk); t = t + 1;
      end
      if (radio_rst !== 1'b0 || idelay_rdy !== 1'b1) begin
         $display("E2E: FAIL - the radio did not leave reset");
         fails = fails + 1;
      end
      // the capture registers and the DDC's input register hold real samples
      // before the first stream starts
      repeat (200) @(posedge radio_clk);

      poke(SR_RX_FMT, (SC8 != 0) ? 32'd3 : 32'd0);  // wire format
      poke(SR_RX_DSP + 8'd0, PHINC);                // DDC: LO phase increment
      poke(SR_RX_DSP + 8'd1, 32'd39767);            // DDC: the scale UHD writes at CIC rate 1
      poke(SR_RX_DSP + 8'd2, 32'h001);              // DDC: decimation 1, no halfband
      poke(SR_RX_DSP + 8'd3, 32'h0);                // DDC: no swap, no inversion
      poke(SR_RX_FRMR + 8'd0, MAXLEN);              // framer: samples per packet
      poke(SR_RX_FRMR + 8'd1, RX_SID);              // framer: stream ID
      stream_cmd(CMD_START);
      sclk = 0;
      measuring = (OVERRUN == 0);

      if (OVERRUN != 0) begin
         // ---- the stall outlasts the buffers: stock overrun sequence ----
         t = 0;
         while (!overrun_seen && t < STALL_START + STALL_CLKS + 200000) begin
            @(posedge bus_clk); t = t + 1;
         end
         if (!overrun_seen) begin
            $display("E2E: FAIL - no overrun error packet after a %0d-clock stall", STALL_CLKS);
            fails = fails + 1;
         end
         strobes_at_overrun = strobes; samples_at_overrun = total_samples;
         // streaming has stopped: nothing more arrives, the machine is idle
         silent_words = words;
         repeat (10000) @(posedge bus_clk);
         silent_words = words - silent_words;
         $display("E2E: after the error packet: %0d words in 10000 clocks, stream control state %0d, %0d samples produced / %0d received, framer-full episodes %0d",
                  silent_words, ibs_state, strobes_at_overrun, samples_at_overrun, full_events);
         if (silent_words != 0 || ibs_state !== 4'd0 || strobes != strobes_at_overrun) begin
            $display("E2E: FAIL - streaming did not stop after the overrun");
            fails = fails + 1;
         end
         if (samples_at_overrun != strobes_at_overrun) begin
            $display("E2E: FAIL - samples accepted before the overrun were not all delivered");
            fails = fails + 1;
         end
         // UHD's overflow handler: the stream command again
         new_stream = 1;
         stream_cmd(CMD_START);
         measuring = 1;
      end
      repeat (RUNCLK) @(posedge bus_clk);

      // ---- stop, as UHD does, and let everything arrive ----
      measuring = 0;
      backlog = strobes - total_samples;
      stream_cmd(CMD_STOP);
      // The end-of-burst packet is the last thing to arrive; 2000 quiet
      // clocks after it show that nothing follows.  Without it, give up when
      // the bus has been quiet for longer than any packet takes to build.
      idle = 0; last_words = words; t = 0;
      while (!(eob_packets != 0 && idle >= 2000) && idle < 30000 && t < 600000) begin
         @(posedge bus_clk); t = t + 1;
         if (words != last_words || dn != 0) idle = 0; else idle = idle + 1;
         last_words = words;
      end
`ifdef E2E_DUMP
      $fclose(fd);
`endif

      // ---- report ----
      rate = (win_clk1 > win_clk0 && win_clk0 >= 0) ?
             (win_words1 - win_words0) * 1.0 / (win_clk1 - win_clk0) : 0.0;
      // one sample per 16.276 ns radio clock, MAXLEN samples in pkt_words
      // GPIF words, 10 ns bus clock
      pkt_words = 2 * ((16 + ((SC8 != 0) ? 2 : 4) * MAXLEN + 7) / 8);
      if (pkt_words % 256 == 0) pkt_words = pkt_words + 1;
      full_rate = (10.0 / 16.276) * pkt_words / MAXLEN;
      $display("E2E: %0d control writes, %0d answered; %0d GPIF words, %0d packets, %0d stream(s), %0d samples received, %0d produced",
               ctrl_seq, acks - ctrl_timeouts, words, packets, streams, total_samples, strobes);
      $display("E2E: %.4f words/clk = %.1f MB/s while streaming (in the overrun case: after the restart), the sample rate needs %.4f; backlog at the stop command %0d samples",
               rate, rate * 400.0, full_rate, backlog);
      $display("E2E: samples: %0d checked against the stimulus (pins -> framer %0d clocks, largest error %.2f codes), %0d wrong, %0d pipeline-history samples exempt",
               checked, lat, max_err, mismatches, flushed);
      $display("E2E: peak |I|=%0d |Q|=%0d (stock gain gives %0d), rail hits %0d",
               max_i, max_q, (SC8 != 0) ? PEAK / 256 : PEAK, rail_hits);
      // NOTE: this counts overflow EPISODES (rising edges of `full`), not
      // samples.
      $display("E2E: framer-full episodes (NOT a sample count) = %0d, error packets = %0d",
               full_events, err_packets);

      // ---- verdict ----
      if (ctrl_timeouts != 0 || bad_acks != 0) begin
         $display("E2E: FAIL - control writes not answered"); fails = fails + 1;
      end
      if (x_words != 0 || bad_strobe != 0) begin
         $display("E2E: FAIL - %0d undefined words, %0d undefined strobes on the GPIF bus", x_words, bad_strobe);
         fails = fails + 1;
      end
      if (wr_while_full != 0) begin
         $display("E2E: FAIL - %0d words written while the FX3 was full", wr_while_full); fails = fails + 1;
      end
      if (bad_hdr != 0 || bad_xfer != 0 || dn != 0) begin
         $display("E2E: FAIL - packetisation broken (%0d bad headers, %0d bad transfers, %0d words left over)",
                  bad_hdr, bad_xfer, dn);
         fails = fails + 1;
      end
      if (seq_errors != 0) begin
         $display("E2E: FAIL - %0d sequence number errors (packets lost or repeated)", seq_errors);
         fails = fails + 1;
      end
      if (time_errors != 0) begin
         $display("E2E: FAIL - %0d time stamp errors (samples lost or repeated between packets)", time_errors);
         fails = fails + 1;
      end
      if (len_errors != 0 || eob_packets != 1 || after_eob != 0 || short_pending != 0) begin
         $display("E2E: FAIL - packet lengths: %0d wrong, %0d end-of-burst packets, %0d packets after it",
                  len_errors, eob_packets, after_eob);
         fails = fails + 1;
      end
      if (!locked || mismatches != 0 || checked + flushed != total_samples || checked < 1000) begin
         $display("E2E: FAIL - the samples received are not the samples on the pins");
         fails = fails + 1;
      end else if (lat != LAT) begin
         $display("E2E: FAIL - time stamps are %0d clocks behind the pins, not %0d", lat, LAT);
         fails = fails + 1;
      end
      if (total_samples != strobes) begin
         $display("E2E: FAIL - %0d samples produced, %0d received", strobes, total_samples);
         fails = fails + 1;
      end
      if (rail_hits > 0) begin
         $display("E2E: FAIL - output reached the rail (clipping)"); fails = fails + 1;
      end
      if (led_samples != strobes || led_rx_alarms != err_packets || led_tx != 0) begin
         $display("E2E: FAIL - LED events: %0d samples for %0d produced, %0d alarms for %0d error packets, %0d transmit events with no transmission",
                  led_samples, strobes, led_rx_alarms, err_packets, led_tx);
         fails = fails + 1;
      end
      if (bad_err != 0 || err_packets != OVERRUN || streams != 1 + OVERRUN) begin
         $display("E2E: FAIL - %0d error packets (%0d not as expected), %0d streams", err_packets, bad_err, streams);
         fails = fails + 1;
      end
      if (OVERRUN == 0 && full_events != 0) begin
         $display("E2E: FAIL - the framer ran full"); fails = fails + 1;
      end
      if (STALLED == 0 || OVERRUN != 0 || REPAID != 0) begin
         // the host keeps up: what is not yet delivered is in flight
         if (backlog > 3 * MAXLEN + 512) begin
            $display("E2E: FAIL - the link is behind by %0d samples", backlog); fails = fails + 1;
         end
      end
      if ((STALLED == 0 || OVERRUN != 0) &&
          (rate < 0.995 * full_rate || (SC8 == 0 && rate < 0.60))) begin
         $display("E2E: FAIL - the stream is not carried at the sample rate"); fails = fails + 1;
      end
`ifndef TWOTONE
`ifndef NOISY
      // With the LO at zero the tone walks every phase, so the crest is hit
      // exactly; with a running LO the samples sit on a coarser phase grid.
      if (SC8 == 0 && PHINC == 32'd0 &&
          (max_i < PEAK - 3 || max_i > PEAK + 3 || max_q < PEAK - 3 || max_q > PEAK + 3)) begin
         $display("E2E: FAIL - gain is not 16 x 0.99925 at zero LO"); fails = fails + 1;
      end
`endif
`endif
      if (fails == 0) begin
         if (OVERRUN != 0)
            $display("E2E: PASS - stock overrun sequence (short packet, one error packet code 8, stop), then a new stream command restores a full-rate stream; every sample received is the sample on the pins");
         else
            $display("E2E: PASS - every sample from the ADC pins received once, in order, at stock gain; %0d-sample packets, time stamps and sequence numbers continuous, %0d samples produced = %0d received",
                     MAXLEN, strobes, total_samples);
      end else
         $display("E2E: FAIL - %0d checks failed", fails);
      $finish;
   end

endmodule
