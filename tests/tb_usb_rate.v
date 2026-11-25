`timescale 1ns/1ps
// USB-side throughput with an FX3 behavioural model: the FX3 slave-FIFO
// interface (gpif2_slave_fifo32, sized as in b200.v) must carry a 61.44 MSPS
// sc16 stream, 245.76 MB/s, with nothing withheld, lost or altered.
//
// The FX3 multiplexes FLAGA/FLAGB by the thread address the FPGA presents, so
// the model must too:
//   DATA_RX (2'b01) / CTRL_RX (2'b11): ready + watermark high  -> FPGA may write
//   DATA_TX (2'b00) / CTRL_TX (2'b10): ready low              -> idle host
//
// The sample source is a credit accumulator: one 64-bit beat per 1/0.3072
// clocks (61.44 MSPS at 100 MHz), and a beat, once offered, is HELD until
// accepted (an ADC never withdraws a sample).  A converter cannot wait: if
// the interface holds the source off until SRC_BACKLOG beats are owed, the
// beat is counted as dropped.  Beats are numbered through the whole run, so
// every word of the stream differs from its neighbours.
//
// Verdict (one line, `USB-RATE: PASS` or `USB-RATE: FAIL`), over 1 ms of bus
// time at the nominal rate:
//   * no beat dropped at the source, and the accepted rate is the offered one,
//   * every 32-bit word on the GPIF bus is the next word of the stream the
//     source sent (high half of a beat first), defined, none missing, none
//     repeated,
//   * every packet ends with one PKTEND after exactly 2 * PKT_BEATS words,
//   * the words on the bus account for the beats accepted (the difference is
//     what the FIFOs hold: less than three packets),
// and, with the source offering more than the link can take (0.5 beats per
// clock, what the 64 -> 32 bit converter accepts at most), the rate of words
// on the bus is at least CEIL_MIN times the nominal one.
module tb_usb_rate;
   localparam integer PKT_BEATS   = 33;      // 66 samples per VITA packet
   localparam integer SRC_BACKLOG = 6;       // beats the source may be held off
   localparam integer RUN_CLKS    = 100000;  // 1 ms of bus time per phase
   localparam real    NOMINAL     = 0.3072;  // beats per clock: 61.44 MSPS
   localparam real    CEIL_MIN    = 1.02;    // required headroom over NOMINAL

   reg clk = 0; always #5 clk = ~clk;    // 100 MHz bus = GPIF clock
   reg rst = 1;

   wire [31:0] gpif_d;
   wire sloe, slrd, slwr, slcs, pktend;
   wire [1:0] fifoadr;
   reg  [3:0] gpif_ctl;                 // declared before use by the instance
   reg        fx3_drive = 0;
   assign gpif_d = fx3_drive ? 32'h0 : 32'bz;

   reg  [63:0] rx_tdata = 0; reg rx_tlast = 0, rx_tvalid = 0; wire rx_tready;
   wire [63:0] tx_tdata; wire tx_tlast, tx_tvalid, tx_tready;
   wire [63:0] ctrl_tdata; wire ctrl_tlast, ctrl_tvalid, ctrl_tready;
   wire [63:0] resp_tdata; wire resp_tlast, resp_tvalid, resp_tready;
   assign resp_tdata = 64'h0; assign resp_tlast = 1'b0; assign resp_tvalid = 1'b0;
   assign tx_tready = 1'b1; assign ctrl_tready = 1'b1;

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(14), .DATA_TX_FIFO_SIZE(14))   // as b200.v
     dut (.gpif_clk(clk), .gpif_rst(rst), .gpif_enb(1'b1),
          .gpif_d(gpif_d), .gpif_ctl(gpif_ctl), .fifoadr(fifoadr),
          .slwr(slwr), .sloe(sloe), .slcs(slcs), .slrd(slrd), .pktend(pktend),
          .fifo_clk(clk), .fifo_rst(rst),
          .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
          .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
          .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
          .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
          .debug());

   // Negative controls (the justfile runs the first and requires FAIL):
   //   +NEG_SLOW   the FX3 refuses data one clock in eight (a link below rate)
   reg neg_slow = 0;
   initial neg_slow = $test$plusargs("NEG_SLOW");

   // ---------------- FX3 model -------------------------------------------
   integer fx3_cyc = 0;
   always @(posedge clk) if (!rst) begin
      fx3_cyc <= fx3_cyc + 1;
      case (fifoadr)
        2'b01: begin gpif_ctl[0] <= 1'b1;                                        // data write
                     gpif_ctl[1] <= !(neg_slow && fx3_cyc % 8 == 0); end
        2'b11: begin gpif_ctl[0] <= 1'b1; gpif_ctl[1] <= 1'b1; end               // ctrl write
        default: begin gpif_ctl[0] <= 1'b0; gpif_ctl[1] <= 1'b0; end             // read threads
      endcase
   end
   // FX3 drives the bus during FPGA read cycles (never expected here)
   always @(negedge clk) fx3_drive <= (sloe === 1'b0) || (slrd === 1'b0);

   // ---------------- ADC-side source -------------------------------------
   // 10000 credits = one beat.
   integer cred = 0, inc = 3072, beat = 0, pos = 0, dropped = 0;
   always @(posedge clk) if (!rst) begin
      if (cred < SRC_BACKLOG * 10000) cred = cred + inc;
      else dropped = dropped + 1;               // held off too long: a sample is lost
      if (rx_tvalid && rx_tready) begin         // the beat on offer was taken
         cred      = cred - 10000;
         beat      = beat + 1;
         pos       = (pos == PKT_BEATS-1) ? 0 : pos + 1;
         rx_tvalid <= 1'b0;
      end
      if ((!rx_tvalid || rx_tready) && cred >= 10000) begin   // offer the next
         rx_tvalid <= 1'b1;
         rx_tdata  <= {32'hB0000000 + beat, 32'hA0000000 + beat};
         rx_tlast  <= (pos == PKT_BEATS-1);
      end
   end

   // ---------------- measurement -----------------------------------------
   // run totals (never cleared): the content and conservation checks
   integer t_beats = 0, t_words = 0, pkt_words = 0;
   integer bad_words = 0, x_words = 0, bad_pkts = 0, shown = 0;
   reg [31:0] expect_word;
   // window counters (cleared at the start of each phase)
   integer cyc = 0, beats = 0, words = 0, pktends = 0, stalls = 0;
   always @(posedge clk) if (!rst) begin
      cyc = cyc + 1;
      if (rx_tvalid && rx_tready) begin beats = beats + 1; t_beats = t_beats + 1; end
      if (rx_tvalid && !rx_tready) stalls = stalls + 1;
      if (slwr === 1'b0) begin
         // word t_words of the stream: high half of beat t_words/2, then low half
         expect_word = ((t_words % 2 == 0) ? 32'hB0000000 : 32'hA0000000) + t_words / 2;
         if (^gpif_d === 1'bx) x_words = x_words + 1;
         else if (gpif_d !== expect_word) bad_words = bad_words + 1;
         if ((^gpif_d === 1'bx || gpif_d !== expect_word) && shown < 4) begin
            shown = shown + 1;
            $display("USB:  word %0d on the bus is %h, expected %h", t_words, gpif_d, expect_word);
         end
         words = words + 1; t_words = t_words + 1; pkt_words = pkt_words + 1;
      end
      if (pktend === 1'b0) begin
         pktends = pktends + 1;
         if (pkt_words != 2 * PKT_BEATS) bad_pkts = bad_pkts + 1;
         pkt_words = 0;
      end
   end

   integer fails = 0, held;
   real    rate_nom, rate_ceil;
   initial begin
      repeat (20) @(posedge clk);
      rst <= 0;
      repeat (500) @(posedge clk);
      @(negedge clk);                              // between two counting edges
      cyc = 0; beats = 0; words = 0; pktends = 0; stalls = 0;
      repeat (RUN_CLKS) @(negedge clk);            // 1 ms of bus time
      rate_nom = beats * 1.0 / cyc;
      held     = 2 * t_beats - t_words;
      $display("USB:  %0d clocks at the nominal rate (%.4f beats/clk offered)", cyc, NOMINAL);
      $display("USB:  beats accepted %0d (%.4f/clk), %0d dropped at the source, %0d clocks held off",
               beats, rate_nom, dropped, stalls);
      $display("USB:  32-bit words written %0d (%.4f/clk) = %.2f MB/s in %0d packets",
               words, words*1.0/cyc, words*1.0/cyc*400.0, pktends);
      $display("USB:  stream on the bus: %0d words wrong, %0d undefined, %0d packets not %0d words; FIFOs hold %0d words",
               bad_words, x_words, bad_pkts, 2*PKT_BEATS, held);
      if (dropped != 0) begin
         fails = fails + 1; $display("USB:  FAIL - the source was held off until samples were lost");
      end
      if (beats < NOMINAL * RUN_CLKS - 2 || words < 2 * (NOMINAL * RUN_CLKS) - 6 * PKT_BEATS) begin
         fails = fails + 1; $display("USB:  FAIL - throughput below 61.44 MSPS");
      end
      if (bad_words != 0 || x_words != 0) begin
         fails = fails + 1; $display("USB:  FAIL - the words on the bus are not the stream that was sent");
      end
      if (bad_pkts != 0 || pktends < beats / PKT_BEATS - 3) begin
         fails = fails + 1; $display("USB:  FAIL - packet boundaries (PKTEND) wrong");
      end
      if (held < 0 || held > 6 * PKT_BEATS) begin
         fails = fails + 1; $display("USB:  FAIL - words on the bus do not account for the beats accepted");
      end
      // ceiling: offer 0.5 beats/clk (400 MB/s); the bus cannot keep up, the
      // FIFOs fill, and the word rate on the bus is the link's own limit
      inc = 5000;
      repeat (500) @(negedge clk);
      cyc = 0; beats = 0; words = 0; pktends = 0; stalls = 0;
      repeat (RUN_CLKS) @(negedge clk);
      rate_ceil = words * 0.5 / cyc;               // beats per clock on the bus
      $display("USB ceiling: %.4f words/clk on the bus = %.2f MB/s (%.1f %% above nominal, need %.1f %%)",
               words*1.0/cyc, words*1.0/cyc*400.0, (rate_ceil / NOMINAL - 1.0) * 100.0,
               (CEIL_MIN - 1.0) * 100.0);
      if (rate_ceil < NOMINAL * CEIL_MIN) begin
         fails = fails + 1; $display("USB:  FAIL - no headroom above 61.44 MSPS");
      end
      if (bad_words != 0 || x_words != 0 || bad_pkts != 0) begin
         fails = fails + 1; $display("USB:  FAIL - stream corrupted at the ceiling");
      end
      if (fails == 0)
         $display("USB-RATE: PASS - %.2f MB/s carried with nothing dropped, every word in place; ceiling %.2f MB/s",
                  rate_nom * 800.0, rate_ceil * 800.0);
      else
         $display("USB-RATE: FAIL - %0d checks failed", fails);
      $finish;
   end
endmodule
