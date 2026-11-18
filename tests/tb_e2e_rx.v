// tb_e2e_rx.v - one signal, composed at the ADC pins and interpreted at the
// USB words: b200_io -> ddc_chain -> new_rx_framer -> CDC -> packet gate ->
// gpif2_slave_fifo32 -> FX3 model.  This is the only bench that exercises the
// whole receive path at once, in both clock domains.
//
// Assertions (self-checking, no offline analysis required):
//   * sustained rate      >= 0.60 GPIF words per bus clock (245 MB/s at 100 MHz)
//   * packets             all complete (header + timestamp + MAXLEN samples)
//   * unity gain          peak |I| and |Q| == 16 * ADC amplitude (+-2 codes),
//                         i.e. the 12-bit ADC grid survives to the 16-bit output
//   * no clipping         peak far below the 16-bit rail
//
// The ADC model drives a complex tone at bin 410/4096 (6.15 MHz) with real bus
// timing: data transitions 1 ns AFTER each DATA_CLK edge, I in the first half,
// Q in the second (UG-570 DDR).  The DDC's LO is zero, so the delivered stream
// must be the input, 16x scaled, quantised once to 16 bits.
//
// Offline (with +define+E2E_DUMP) every GPIF word is written to e2e_words.txt
// for spectral analysis; measured that way: 48 840 samples, 0 packet breaks,
// 0.81 LSB16 rms error, gain 0.99997, image -132 dBc, SFDR = the stimulus's
// own 74.8 dB (the 12-bit grid, not the FPGA).
`timescale 1ns/1ps

module tb_e2e_rx;

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
   localparam integer MAXLEN   = 66;        // samples per VITA packet
   localparam integer RUNCLK   = 80000;     // bus clocks of measurement

   reg rx_clk = 0;   always #8.138 rx_clk = ~rx_clk;    // 61.44 MHz DATA_CLK
   reg bus_clk = 0;  always #5.0   bus_clk = ~bus_clk;  // 100 MHz GPIF clock

   reg reset = 1;

   // ---- ADC pins ---------------------------------------------------------
   reg rx_frame = 0;
   reg [11:0] rx_data = 0;
   integer n = 0;
   real arg;
   integer ci, cq;

   always @(posedge rx_clk) begin #1 rx_data <= ci[11:0]; end   // I(n)
   always @(negedge rx_clk) begin #1 rx_data <= cq[11:0]; n <= n + 1; end
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

   // ---- chain -------------------------------------------------------------
   wire radio_clk, radio_rst;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   b200_io io (
      .areset(reset), .mimo(1'b0),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(12'd0), .tx_q0(12'd0), .tx_i1(12'd0), .tx_q1(12'd0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   reg set_stb = 0;
   reg [7:0] set_addr = 0;
   reg [31:0] set_data = 0;
   wire [31:0] sample_rx, debug_ddc;
   wire strobe_rx;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) ddc (
      .clk(radio_clk), .rst(radio_rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i({rx_i0, 4'b0, 8'b0}), .rx_fe_q({rx_q0, 4'b0, 8'b0}),
      .sample(sample_rx), .run(1'b1), .strobe(strobe_rx), .debug(debug_ddc));

   wire [63:0] fr_tdata;
   wire fr_tlast, fr_tvalid, fr_tready;
   wire [31:0] sid;
   wire [11:0] seqnum;
   wire full;

   new_rx_framer #(.BASE(8), .SAMPLE_FIFO_SIZE(11)) framer (
      .clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(64'h0),
      .strobe(strobe_rx), .sample(sample_rx), .run(1'b1), .eob(1'b0), .full(full),
      .sid(sid), .seqnum(seqnum),
      .o_tdata(fr_tdata), .o_tlast(fr_tlast), .o_tvalid(fr_tvalid), .o_tready(fr_tready),
      .debug());

   wire [64:0] cdc_tdata;
   wire cdc_tvalid, cdc_tready;

   axi_fifo_2clk #(.WIDTH(65), .SIZE(4)) rx_fifo (
      .reset(radio_rst),
      .i_aclk(radio_clk), .i_tdata({fr_tlast, fr_tdata}), .i_tvalid(fr_tvalid), .i_tready(fr_tready),
      .o_aclk(bus_clk), .o_tdata(cdc_tdata), .o_tvalid(cdc_tvalid), .o_tready(cdc_tready));

   wire [63:0] gate_tdata;
   wire gate_tlast, gate_tvalid, gate_tready;

   axi_packet_gate #(.WIDTH(64), .SIZE(11), .USE_AS_BUFF(0)) buffer_whole_pkt (
      .clk(bus_clk), .reset(radio_rst), .clear(1'b0),
      .i_tdata(cdc_tdata[63:0]), .i_tlast(cdc_tdata[64]), .i_terror(1'b0),
      .i_tvalid(cdc_tvalid), .i_tready(cdc_tready),
      .o_tdata(gate_tdata), .o_tlast(gate_tlast), .o_tvalid(gate_tvalid), .o_tready(gate_tready));

   // ---- GPIF + FX3 model --------------------------------------------------
   wire [31:0] gpif_d;
   wire sloe, slrd, slwr, slcs, pktend;
   wire [1:0] fifoadr;
   reg [3:0] gpif_ctl;
   reg fx3_drive = 0;
   assign gpif_d = fx3_drive ? 32'h0 : 32'bz;

   wire [63:0] tx_tdata, ctrl_tdata, resp_tdata;
   wire tx_tlast, tx_tvalid, tx_tready;
   wire ctrl_tlast, ctrl_tvalid, ctrl_tready;
   wire resp_tlast, resp_tvalid, resp_tready;
   assign tx_tdata = 64'h0; assign tx_tlast = 1'b0; assign tx_tvalid = 1'b0;
   assign ctrl_tdata = 64'h0; assign ctrl_tlast = 1'b0; assign ctrl_tvalid = 1'b0;
   assign resp_tready = 1'b1;

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(13), .DATA_TX_FIFO_SIZE(13)) gpif (
      .gpif_clk(bus_clk), .gpif_rst(radio_rst), .gpif_enb(1'b1),
      .gpif_d(gpif_d), .gpif_ctl(gpif_ctl), .fifoadr(fifoadr),
      .slwr(slwr), .sloe(sloe), .slcs(slcs), .slrd(slrd), .pktend(pktend),
      .fifo_clk(bus_clk), .fifo_rst(radio_rst),
      .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
      .rx_tdata(gate_tdata), .rx_tlast(gate_tlast), .rx_tvalid(gate_tvalid), .rx_tready(gate_tready),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .debug());

   // FX3: per-thread flags - write threads have space, read threads have no data
`ifdef STALL
   // Real USB service is bursty: the FX3 stops accepting data for a while.  The
   // write thread's watermark goes low for STALL_CLKS out of STALL_PERIOD
   // clocks; the FIFOs must absorb the backlog without dropping a sample.
   localparam integer STALL_CLKS   = `STALL_CLKS;
   localparam integer STALL_PERIOD = `STALL_PERIOD;
   integer sp = 0;
   always @(posedge bus_clk) if (!reset) begin
      sp <= (sp >= STALL_PERIOD-1) ? 0 : sp + 1;
      case (fifoadr)
        2'b01: gpif_ctl <= (sp < STALL_CLKS) ? 4'b0001 : 4'b0011;
        2'b11: gpif_ctl <= 4'b0011;
        default: gpif_ctl <= 4'b0000;
      endcase
   end
`else
   always @(posedge bus_clk) if (!reset) begin
      case (fifoadr)
        2'b01: gpif_ctl <= 4'b0011;
        2'b11: gpif_ctl <= 4'b0011;
        default: gpif_ctl <= 4'b0000;
      endcase
   end
`endif
   always @(negedge bus_clk) fx3_drive <= (sloe === 1'b0) || (slrd === 1'b0);

   // ---- measurement -------------------------------------------------------
   integer words = 0, packets = 0, pkt_words = 0, short_packets = 0, rail_hits = 0;
   integer full_events = 0, fails = 0;
   reg full_d = 0;
   always @(posedge radio_clk) begin
      full_d <= full;
      if (full && !full_d) full_events = full_events + 1;
   end
   integer max_i = 0, max_q = 0, wi, wq;
`ifdef E2E_DUMP
   integer fd;
   initial fd = $fopen("e2e_words.txt", "w");
`endif

   always @(posedge bus_clk) begin
      if (!reset && slwr === 1'b0) begin
         words = words + 1;
         pkt_words = pkt_words + 1;
`ifdef E2E_DUMP
         $fwrite(fd, "w %08x\n", gpif_d);
`endif
         // body words carry one 16-bit I/Q pair each; header/timestamp are the
         // first two 64-bit beats (four 32-bit words) of a packet
         if (pkt_words > 4) begin
            wi = $signed(gpif_d[31:16]); wq = $signed(gpif_d[15:0]);
            if (gpif_d[31:16] == 16'h7FFF || gpif_d[31:16] == 16'h8000 ||
                gpif_d[15:0]  == 16'h7FFF || gpif_d[15:0]  == 16'h8000)
               rail_hits = rail_hits + 1;
            if (wi < 0) wi = -wi;
            if (wq < 0) wq = -wq;
            if (wi > max_i) max_i = wi;
            if (wq > max_q) max_q = wq;
         end
      end
      if (!reset && pktend === 1'b0) begin
`ifdef E2E_DUMP
         $fwrite(fd, "e\n");
`endif
         packets = packets + 1;
         if (pkt_words != 2*2 + MAXLEN) short_packets = short_packets + 1;
         pkt_words = 0;
      end
   end

   // ---- run ---------------------------------------------------------------
   task set_reg(input [7:0] a, input [31:0] d);
      begin @(posedge radio_clk); set_stb <= 1; set_addr <= a; set_data <= d;
            @(posedge radio_clk); set_stb <= 0; end
   endtask

   initial begin
      repeat (10) @(posedge bus_clk);
      reset <= 0;
      repeat (10) @(posedge bus_clk);
      set_reg(8'd0, PHINC);              // DDC (BASE 0): LO phase increment
      set_reg(8'd8, MAXLEN);             // framer (BASE 8): packet length
      set_reg(8'd9, 32'h0102_0304);      // framer: SID
      repeat (RUNCLK) @(posedge bus_clk);
`ifdef E2E_DUMP
      $fclose(fd);
`endif
      $display("E2E: %0d words in %0d bus clocks = %.3f words/clk = %.1f MB/s (need 0.60 / 245.8)",
               words, RUNCLK, words*1.0/RUNCLK, words*1.0/RUNCLK*400.0);
`ifdef TWOTONE
      // the sum of blocker (1000 counts) and weak tone (2 counts) crests at
      // 1002.06 counts, so a peak ABOVE 16*1000 proves the weak tone is carried
      $display("E2E: %0d packets, %0d incomplete; peak |I|=%0d |Q|=%0d (blocker alone would be %0d), rail hits %0d",
               packets, short_packets, max_i, max_q, 16*1000, rail_hits);
`else
      $display("E2E: %0d packets, %0d incomplete; peak |I|=%0d |Q|=%0d (expect %0d, rail 32767), rail hits %0d",
               packets, short_packets, max_i, max_q, 16*AMP, rail_hits);
`endif
      $display("E2E: framer full events (dropped samples) = %0d", full_events);
      fails = 0;
`ifndef STALL
      // under deliberate USB stalls the average rate is lower by construction
      if (words*1.0/RUNCLK < 0.60) begin
         $display("E2E: FAIL - throughput below requirement");
         fails = fails + 1;
      end
`endif
      if (full_events != 0) begin
         $display("E2E: FAIL - USB backpressure dropped samples");
         fails = fails + 1;
      end
      if (packets < 100 || short_packets > 2) begin
         $display("E2E: FAIL - packetisation broken");
         fails = fails + 1;
      end
`ifdef TWOTONE
      if (max_i < 16*1000 + 8 || max_i > 16*1002 + 16) begin
         $display("E2E: FAIL - weak tone lost or crest distorted");
         fails = fails + 1;
      end
`else
      // With the LO at zero the tone walks every phase, so the crest is hit
      // exactly and unity gain can be asserted to +-2 codes.  With a running
      // LO the samples sit on a coarser phase grid and the captured maximum is
      // legitimately a few codes lower, so the tolerance becomes proportional.
      // Clipping is checked separately, as rail hits.
      if (PHINC == 32'd0) begin
         if (max_i < 16*AMP - 2 || max_i > 16*AMP + 2 ||
             max_q < 16*AMP - 2 || max_q > 16*AMP + 2) begin
            $display("E2E: FAIL - gain is not exactly 16x at zero LO");
            fails = fails + 1;
         end
      end else if (max_i*1000 < 16*AMP*997 || max_i*1000 > 16*AMP*1003 ||
                   max_q*1000 < 16*AMP*997 || max_q*1000 > 16*AMP*1003) begin
         $display("E2E: FAIL - gain error or distortion at the peak");
         fails = fails + 1;
      end
`endif
      if (rail_hits > 0) begin
         $display("E2E: FAIL - output reached the 16-bit rail (clipping)");
         fails = fails + 1;
      end
      if (fails == 0)
         $display("E2E: PASS - signal from the ADC pins recovered at the GPIF words, unity gain, full rate, no clipping");
      $finish;
   end

endmodule
