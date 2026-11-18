`timescale 1ns/1ps
// USB-side throughput with an FX3 behavioural model.
//
// The FX3 multiplexes FLAGA/FLAGB by the thread address the FPGA presents, so
// the model must too:
//   DATA_RX (2'b01) / CTRL_RX (2'b11): ready + watermark high  -> FPGA may write
//   DATA_TX (2'b00) / CTRL_TX (2'b10): ready low              -> idle host
// Watermark also delimits read packets, so for read threads it pulses low.
//
// The sample source is a credit accumulator: one 64-bit beat per 1/0.3072
// clocks (61.44 MSPS at 100 MHz), and a beat, once offered, is HELD until
// accepted (an ADC never withdraws a sample).
module tb_usb_rate;
   localparam PKT_BEATS = 33;   // 66 samples, matching the RX framer      // 66 samples per VITA packet

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

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(13), .DATA_TX_FIFO_SIZE(13))
     dut (.gpif_clk(clk), .gpif_rst(rst), .gpif_enb(1'b1),
          .gpif_d(gpif_d), .gpif_ctl(gpif_ctl), .fifoadr(fifoadr),
          .slwr(slwr), .sloe(sloe), .slcs(slcs), .slrd(slrd), .pktend(pktend),
          .fifo_clk(clk), .fifo_rst(rst),
          .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
          .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
          .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
          .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
          .debug());

   // ---------------- FX3 model -------------------------------------------
   integer rcnt = 0;
   always @(posedge clk) if (!rst) begin
      case (fifoadr)
        2'b01: begin gpif_ctl[0] <= 1'b1; gpif_ctl[1] <= 1'b1; rcnt <= 0; end  // data write
        2'b11: begin gpif_ctl[0] <= 1'b1; gpif_ctl[1] <= 1'b1; rcnt <= 0; end  // ctrl write
        default: begin                                                          // read threads
           gpif_ctl[0] <= 1'b0; gpif_ctl[1] <= 1'b0; rcnt <= 0;
        end
      endcase
   end
   // FX3 drives the bus during FPGA read cycles (never expected here)
   always @(negedge clk) fx3_drive <= (sloe === 1'b0) || (slrd === 1'b0);

   // ---------------- ADC-side source -------------------------------------
   integer cred = 0, beat = 0, inc = 307;   // credits per clock (307 = 61.44 MSPS)
   reg pending = 0;
   always @(posedge clk) if (!rst) begin
      if (cred < 6000) cred <= cred + inc;
      if (!pending && cred >= 1000) begin
         pending   <= 1'b1;
         rx_tvalid <= 1'b1;
         rx_tdata  <= {32'hB0000000 + beat, 32'hA0000000 + beat};
         rx_tlast  <= (beat == PKT_BEATS-1);
      end else if (pending && rx_tready) begin
         pending   <= 1'b0;
         rx_tvalid <= 1'b0;
         cred      <= cred - 1000 + inc;   // this cycle's credit is not lost
         beat      <= (beat == PKT_BEATS-1) ? 0 : beat + 1;
      end
   end

   // ---------------- measurement -----------------------------------------
   integer cyc = 0, beats = 0, words = 0, pktends = 0, stalls = 0, xfers = 0;
   always @(posedge clk) if (!rst) begin
      cyc <= cyc + 1;
      if (rx_tvalid && rx_tready) beats <= beats + 1;
      if (rx_tvalid && !rx_tready) stalls <= stalls + 1;
      if (slwr === 1'b0) words <= words + 1;
      if (pktend === 1'b0) pktends <= pktends + 1;
      if (dut.wr_fifo_xfer) xfers <= xfers + 1;
   end

   initial begin
      repeat (20) @(posedge clk);
      rst <= 0;
      repeat (500) @(posedge clk);
      inc = 307;                                   // 61.44 MSPS
      cyc = 0; beats = 0; words = 0; pktends = 0; stalls = 0; xfers = 0;
      repeat (100000) @(posedge clk);              // 1 ms of bus time
      $display("USB:  %0d clocks", cyc);
      $display("USB:  beats offered/accepted %0d (%.3f/clk)  demand %.1f MB/s",
               beats, beats*1.0/cyc, beats*2.0/cyc*400.0);
      $display("USB:  32-bit words written %0d (%.3f/clk)  delivered %.1f MB/s, %0d packets",
               words, words*1.0/cyc, words*1.0/cyc*400.0, pktends);
      $display("USB:  words per beat = %.3f (2.000 = nothing lost)  local fifo transfers %0d",
               words*1.0/beats, xfers);
      $display("USB:  input stalls %0d of %0d offered cycles", stalls, beats+stalls);
      // ceiling: offer 0.5 beats/clk (400 MB/s), the converter's structural max
      inc = 500;
      repeat (500) @(posedge clk);
      cyc = 0; beats = 0; words = 0; pktends = 0; stalls = 0; xfers = 0;
      repeat (100000) @(posedge clk);
      $display("USB ceiling: accepted %.3f beats/clk, delivered %.1f MB/s, words/beat %.3f",
               beats*1.0/cyc, words*1.0/cyc*400.0, words*1.0/beats);
      $finish;
   end
endmodule
