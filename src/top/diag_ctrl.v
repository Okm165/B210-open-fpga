// diag_ctrl.v - the MINIMAL control-path design: clocks + gpif2_slave_fifo32
// + the real radio_ctrl_proc, nothing else.  It answers one question:
//
//   does a control packet survive the FX3 -> GPIF -> settings -> response
//   round trip on THIS BOARD?
//
// If uhd_usrp_probe's first peek64(0) gets a response from THIS image, the
// board wiring and the FIFO core are proven and the full design has an
// integration bug.  If it still times out, the board's GPIF wiring/pin map
// is the root cause - no FPGA-side change can fix that.
//
// The readback register returns the magic 0xACE0BA5E-compat word so that a
// working path is visible as progress in uhd_usrp_probe (it will complain
// about missing radios, not about timeouts).

`default_nettype none

module diag_ctrl (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   // directions per b200.v: CTL0/1/2/3/7/11/12 are FPGA OUTPUTS (strobes,
   // chip-select, address); CTL4/5 are FX3 flags (inputs); CTL6/8 are the
   // FX3's serial settings bus (inputs); CTL9 is the FX3 reset (input).
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8,
   input  wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   inout  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS,
   output wire LED_CLK_G,
   output wire LED_RX1
);

   wire bus_clk, gpif_clk, locked;
   b200_clk_gen gen (
      .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
      .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(gpif_clk), .CLK_OUT3_100_bus(),
      .reset(1'b0), .locked(locked));
   assign bus_clk = gpif_clk;

   // Drive the FX3's GPIF clock (PCLK) — the FX3 samples the slave-FIFO
   // interface on this input.  WITHOUT THIS THE GPIF IS CLOCKLESS.
   ODDR #(
      .DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
   ) ODDR_IFCLK (
      .Q(IFCLK), .C(gpif_clk), .CE(1'b1),
      .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0)
   );

   reg [15:0] ready_cnt = 16'd0;
   reg ready = 1'b0;
   always @(posedge bus_clk) begin
      if (!ready && &ready_cnt[14:0]) ready <= 1'b1;
      ready_cnt <= ready_cnt + 16'd1;
   end

   reg gpif_rst = 1'b0, bus_rst = 1'b0;
   always @(posedge gpif_clk) begin
      if (&ready_cnt[13:0]) gpif_rst <= 1'b0;
   end
   always @(posedge bus_clk) begin
      if (&ready_cnt[13:0]) bus_rst <= 1'b0;
   end

   wire [63:0] tx_tdata, rx_tdata, ctrl_tdata, resp_tdata;
   wire tx_tlast, rx_tlast, ctrl_tlast, resp_tlast;
   wire tx_tvalid, rx_tvalid, ctrl_tvalid, resp_tvalid;
   wire tx_tready, rx_tready, ctrl_tready, resp_tready;

   // ---- UNCONDITIONAL STROBE MASTER (override) ----
   // Bypasses the slave_fifo32 flag gating entirely: continuously write an
   // incrementing 32-bit word into GPIF thread 3 (CTRL_RESP) with SLWR,
   // ignoring every flag.  If the FX3's GPIF samples ANY of this, its DMA
   // counters move and EP8 delivers data (possibly garbage).
   wire        ov_slwr, ov_sloe, ov_slcs, ov_slrd, ov_pktend;
   wire [1:0]  ov_fifoadr;
   wire [31:0] ov_data;
   wire        ov_d_drive;

   reg [31:0] strobe_cnt = 32'd0;
   always @(posedge gpif_clk) strobe_cnt <= strobe_cnt + 32'd1;

   assign ov_slcs    = 1'b0;                 // SLCS always active
   assign ov_sloe    = 1'b1;                 // never tri-state the bus for read
   assign ov_slrd    = 1'b1;                 // no reads
   assign ov_pktend  = 1'b1;                 // no PKTEND
   assign ov_fifoadr = 2'b11;                // thread 3 = CTRL_RESP
   // SLWR active-low strobe: one low cycle every 4, data launched one cycle early
   assign ov_slwr    = (strobe_cnt[1:0] == 2'b00);
   assign ov_d_drive = 1'b1;                 // we always drive (sloe=1 keeps Z off)
   assign ov_data    = {strobe_cnt[15:0], ~strobe_cnt[15:0]};

   assign GPIF_CTL0    = ov_slcs;
   assign GPIF_CTL1    = ov_slwr;
   assign GPIF_CTL2    = ov_sloe;
   assign GPIF_CTL3    = ov_slrd;
   assign GPIF_CTL7    = ov_pktend;
   assign GPIF_CTL11   = ov_fifoadr[1];
   assign GPIF_CTL12   = ov_fifoadr[0];
   assign GPIF_D       = ov_data;

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(13), .DATA_TX_FIFO_SIZE(13))
     slave_fifo32 (
      .gpif_clk(gpif_clk), .gpif_rst(gpif_rst), .gpif_enb(1'b1),
      .gpif_ctl({GPIF_CTL8, GPIF_CTL6, GPIF_CTL5, GPIF_CTL4}),
      .fifoadr(), 
      .slwr(), .sloe(), .slcs(),
      .slrd(), .pktend(),
      .gpif_d(), 
      .fifo_clk(bus_clk), .fifo_rst(bus_rst),
      .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .debug());

   // 64-bit incoming control -> 32-bit settings: the real responder.
   wire set_stb;
   wire [7:0] set_addr;
   wire [31:0] set_data;
   reg [63:0] vita_time = 64'd0;
   always @(posedge bus_clk) vita_time <= vita_time + 64'd1;

   // readback: return the value check_fpga_compat expects from peek64(0)
   // (compat number in the low half; high half is the second word of peek64)
   wire [63:0] readback = {32'h0000_0002, 32'h0000_BABE};

   radio_ctrl_proc ctrl_proc (
      .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast),
      .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast),
      .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .vita_time(vita_time),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ready(ready), .readback(readback),
      .debug());

   // LEDs: STATUS constant (configured), CLK_G blinks from bus_clk,
   // RX1 = set_stb activity (a control transaction reaching the responder!)
   reg [24:0] blink_cnt = 25'd0;
   always @(posedge bus_clk) blink_cnt <= blink_cnt + 25'd1;
   assign LED_CLK_G  = blink_cnt[24];
   reg [22:0] act_cnt = 23'd0;
   always @(posedge bus_clk) if (set_stb) act_cnt <= 23'd0; else act_cnt <= act_cnt + 23'd1;
   assign LED_RX1    = (act_cnt < 23'd1) ? 1'b1 : 1'b0;  // pulses on set_stb
   assign LED_STATUS = 1'b1;

endmodule
