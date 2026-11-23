// diag_ctrl2.v - bisect rung 1: diag_ctrl (gpif2 + responder) PLUS the
// b200_core control sub-path: axi_demux4 + timing fifos + radio_ctrl_proc
// + setting_reg readback mux + resp mux.  If this answers UHD on hardware,
// the demux/settings path is exonerated and the fault lies deeper (radio
// core / DSP / data path fabric).
`default_nettype none

module diag_ctrl8 (
   input  wire codec_main_clk_p, input wire codec_main_clk_n,
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
      .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(gpif_clk), .CLK_OUT3_100_bus(bus_clk),
      .reset(GPIF_CTL9), .locked(locked));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   ODDR_IFCLK (.Q(IFCLK), .C(gpif_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   // reset sync (short, like diag_ctrl)
   reg [15:0] ready_cnt = 16'd0;
   reg ready = 1'b0;
   always @(posedge bus_clk) begin
      if (!ready && &ready_cnt[14:0]) ready <= 1'b1;
      ready_cnt <= ready_cnt + 16'd1;
   end
   reg gpif_rst = 1'b1, bus_rst = 1'b1;
   always @(posedge gpif_clk) if (&ready_cnt[13:0]) gpif_rst <= 1'b0;
   always @(posedge bus_clk) if (&ready_cnt[13:0]) bus_rst  <= 1'b0;

   wire [63:0] tx_tdata, rx_tdata, ctrl_tdata, resp_tdata;
   wire tx_tlast, rx_tlast, ctrl_tlast, resp_tlast;
   wire tx_tvalid, rx_tvalid, ctrl_tvalid, resp_tvalid;
   wire tx_tready, rx_tready, ctrl_tready, resp_tready;

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(13), .DATA_TX_FIFO_SIZE(13))
     slave_fifo32 (
      .gpif_clk(gpif_clk), .gpif_rst(gpif_rst), .gpif_enb(1'b1),
      .gpif_ctl({GPIF_CTL8, GPIF_CTL6, GPIF_CTL5, GPIF_CTL4}), .fifoadr({GPIF_CTL11,GPIF_CTL12}),
      .slwr(GPIF_CTL1), .sloe(GPIF_CTL2), .slcs(GPIF_CTL0), .slrd(GPIF_CTL3), .pktend(GPIF_CTL7),
      .gpif_d(GPIF_D),
      .fifo_clk(bus_clk), .fifo_rst(bus_rst),
      .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .debug());

   // ---- b200_core control sub-path ----
   localparam R0_CTRL_SID = 8'h10, R1_CTRL_SID = 8'h20,
              U0_CTRL_SID = 8'h30, L0_CTRL_SID = 8'h40;
   localparam DEMUX_SID_MASK = 8'hf0;

   wire [63:0] r0_ctrl_tdata, r1_ctrl_tdata, u0_ctrl_tdata, l0_ctrl_tdata;
   wire r0_ctrl_tlast, r1_ctrl_tlast, u0_ctrl_tlast, l0_ctrl_tlast;
   wire r0_ctrl_tvalid, r1_ctrl_tvalid, u0_ctrl_tvalid, l0_ctrl_tvalid;
   wire r0_ctrl_tready, r1_ctrl_tready, u0_ctrl_tready, l0_ctrl_tready;

   wire [63:0] ctrl_hdr;
   wire [1:0] ctrl_dst =
       ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == R0_CTRL_SID)? 2'd0 : (
       ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == R1_CTRL_SID)? 2'd1 : (
       ((ctrl_hdr[7:0] & DEMUX_SID_MASK) == U0_CTRL_SID)? 2'd2 : 2'd3));
   axi_demux4 #(.ACTIVE_CHAN(4'b1111), .WIDTH(64), .BUFFER(1)) demux_for_ctrl
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .header(ctrl_hdr), .dest(ctrl_dst),
     .i_tdata(ctrl_tdata), .i_tlast(ctrl_tlast), .i_tvalid(ctrl_tvalid), .i_tready(ctrl_tready),
     .o0_tdata(r0_ctrl_tdata), .o0_tlast(r0_ctrl_tlast), .o0_tvalid(r0_ctrl_tvalid), .o0_tready(r0_ctrl_tready),
     .o1_tdata(r1_ctrl_tdata), .o1_tlast(r1_ctrl_tlast), .o1_tvalid(r1_ctrl_tvalid), .o1_tready(r1_ctrl_tready),
     .o2_tdata(u0_ctrl_tdata), .o2_tlast(u0_ctrl_tlast), .o2_tvalid(u0_ctrl_tvalid), .o2_tready(u0_ctrl_tready),
     .o3_tdata(l0_ctrl_tdata), .o3_tlast(l0_ctrl_tlast), .o3_tvalid(l0_ctrl_tvalid), .o3_tready(l0_ctrl_tready));

   // ---- R0 responder (radio slot, SID 0x10): the loopback test target ----
   wire [63:0] r0i_ctrl_tdata; wire r0i_ctrl_tlast, r0i_ctrl_tvalid, r0i_ctrl_tready;
   axi_fifo #(.WIDTH(65), .SIZE(5)) r0_timing_fifo
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .i_tdata({r0_ctrl_tlast, r0_ctrl_tdata}), .i_tvalid(r0_ctrl_tvalid), .i_tready(r0_ctrl_tready), .space(),
     .o_tdata({r0i_ctrl_tlast, r0i_ctrl_tdata}), .o_tvalid(r0i_ctrl_tvalid), .o_tready(r0i_ctrl_tready), .occupied());

   wire set_stb_r0;
   wire [7:0] set_addr_r0;
   wire [31:0] set_data_r0;
   wire [63:0] r0_resp_tdata; wire r0_resp_tlast, r0_resp_tvalid; wire r0_resp_tready;

   localparam SR_TEST     = 8'd21;
   localparam SR_READBACK = 8'd32;
   wire [31:0] test_readback;
   wire [2:0] r0_rb_addr;

   reg [63:0] rb_data_r0;
   radio_ctrl_proc radio_ctrl_proc_r0
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .ctrl_tdata(r0i_ctrl_tdata), .ctrl_tlast(r0i_ctrl_tlast),
     .ctrl_tvalid(r0i_ctrl_tvalid), .ctrl_tready(r0i_ctrl_tready),
     .resp_tdata(r0_resp_tdata), .resp_tlast(r0_resp_tlast),
     .resp_tvalid(r0_resp_tvalid), .resp_tready(r0_resp_tready),
     .vita_time(64'b0),
     .set_stb(set_stb_r0), .set_addr(set_addr_r0), .set_data(set_data_r0),
     .ready(ready), .readback(rb_data_r0), .debug());

   setting_reg #(.my_addr(SR_TEST), .awidth(8), .width(32)) sr_test
    (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb_r0), .addr(set_addr_r0), .in(set_data_r0),
     .out(test_readback), .changed());

   setting_reg #(.my_addr(SR_READBACK), .awidth(8), .width(3)) sr_rdback_r0
    (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb_r0), .addr(set_addr_r0), .in(set_data_r0),
     .out(r0_rb_addr), .changed());

   always @*
     case(r0_rb_addr)
       3'd0 : rb_data_r0 <= { 32'b0, test_readback };
       default : rb_data_r0 <= 64'd0;
     endcase

   // ---- L0 responder (misc/core slot) ----
   wire [63:0] l0i_ctrl_tdata; wire l0i_ctrl_tlast, l0i_ctrl_tvalid, l0i_ctrl_tready;
   axi_fifo #(.WIDTH(65), .SIZE(5)) radio_ctrl_proc_timing_fifo
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .i_tdata({l0_ctrl_tlast, l0_ctrl_tdata}), .i_tvalid(l0_ctrl_tvalid), .i_tready(l0_ctrl_tready), .space(),
     .o_tdata({l0i_ctrl_tlast, l0i_ctrl_tdata}), .o_tvalid(l0i_ctrl_tvalid), .o_tready(l0i_ctrl_tready), .occupied());

   wire set_stb;
   reg [63:0] rb_data;
   wire [7:0] set_addr;
   wire [31:0] set_data;
   wire [63:0] l0_resp_tdata; wire l0_resp_tlast, l0_resp_tvalid; wire l0_resp_tready;

   radio_ctrl_proc radio_ctrl_proc
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .ctrl_tdata(l0i_ctrl_tdata), .ctrl_tlast(l0i_ctrl_tlast),
     .ctrl_tvalid(l0i_ctrl_tvalid), .ctrl_tready(l0i_ctrl_tready),
     .resp_tdata(l0_resp_tdata), .resp_tlast(l0_resp_tlast),
     .resp_tvalid(l0_resp_tvalid), .resp_tready(l0_resp_tready),
     .vita_time(64'b0),
     .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
     .ready(ready), .readback(rb_data), .debug());

   // readback mux (subset of b200_core)
   wire [1:0] rb_addr;
   localparam COMPAT_MAJOR = 16'd16, COMPAT_MINOR = 16'd0;
   setting_reg #(.my_addr(8'h10/*SR_CORE_READBACK-ish*/), .awidth(8), .width(2), .at_reset(2'h0)) sr_rdback
    (.clk(bus_clk), .rst(bus_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
     .out(rb_addr), .changed());

   always @*
     case(rb_addr)
       2'd0 : rb_data <= { 32'hACE0BA5E, COMPAT_MAJOR, COMPAT_MINOR };
       2'd3 : rb_data <= 64'hDEAD_BEEF_CAFE_1234;
       default : rb_data <= 64'd0;
     endcase

   // resp mux (i0 = R0 radio, i3 = L0 misc; others idle)
   wire [63:0] r1_resp_tdata = 64'b0, u0_resp_tdata = 64'b0;
   wire r1_resp_tlast = 1'b0, u0_resp_tlast = 1'b0;
   wire r1_resp_tvalid = 1'b0, u0_resp_tvalid = 1'b0;
   wire r1_resp_tready, u0_resp_tready;

   axi_mux4 #(.WIDTH(64), .BUFFER(1)) mux_for_resp
    (.clk(bus_clk), .reset(bus_rst), .clear(1'b0),
     .i0_tdata(r0_resp_tdata), .i0_tlast(r0_resp_tlast), .i0_tvalid(r0_resp_tvalid), .i0_tready(r0_resp_tready),
     .i1_tdata(r1_resp_tdata), .i1_tlast(r1_resp_tlast), .i1_tvalid(r1_resp_tvalid), .i1_tready(r1_resp_tready),
     .i2_tdata(u0_resp_tdata), .i2_tlast(u0_resp_tlast), .i2_tvalid(u0_resp_tvalid), .i2_tready(u0_resp_tready),
     .i3_tdata(l0_resp_tdata), .i3_tlast(l0_resp_tlast), .i3_tvalid(l0_resp_tvalid), .i3_tready(l0_resp_tready),
     .o_tdata(resp_tdata), .o_tlast(resp_tlast), .o_tvalid(resp_tvalid), .o_tready(resp_tready));

   assign LED_STATUS = 1'b1;
   reg [24:0] blink_cnt = 25'd0;
   always @(posedge bus_clk) blink_cnt <= blink_cnt + 25'd1;
   assign LED_CLK_G = blink_cnt[24];
   assign LED_RX1   = set_stb;

endmodule
