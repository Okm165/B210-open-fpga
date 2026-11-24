// diag_echo.v - the FX3 bus on its own.
//
// The bus interface of the full design and nothing behind it: the MMCM bus
// clock, the forwarded IFCLK, gpif2_slave_fifo32 with its I/O registers and
// clock-crossing FIFOs.  Every packet the host sends on the data endpoint
// (EP2 OUT) comes back on EP6 IN, and every packet on the control endpoint
// (EP4 OUT) on EP8 IN, so both directions of the bus are checked bit for bit
// by `scripts/fx3_raw_load.py <image> --echo N`.
//
// The pad timing of this design is the pad timing of the full design: the
// boundary registers sit in the I/O blocks and the clocks come from the same
// buffers.  scripts/bus_window.py moves the lag of the forwarded clock
// (IFCLK_STEPS of b200_clk_gen.v) in the routed bitstream and so measures
// the range of lags the bus works at.
//
//   DESIGN=diag_echo scripts/build.sh
//   scripts/bus_window.py build/fpga/pnr/diag_echo.fasm
`default_nettype none

module diag_echo (
   input  wire codec_main_clk_p, input wire codec_main_clk_n,
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8,
   input  wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   inout  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS, output wire LED_CLK_G, output wire LED_RX1
);
   wire bus_clk, ifclk, locked;
   b200_clk_gen gen (
      .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
      .bus_clk(bus_clk), .ifclk(ifclk), .idelay_refclk(),
      .reset(GPIF_CTL9), .locked(locked));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   oddr_ifclk (.Q(IFCLK), .C(ifclk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

   // as b200.v: reset released 65536 clocks after the MMCM locks
   reg [15:0] ready_count = 16'd0;
   reg        ready = 1'b0;
   wire       clocks_reset = GPIF_CTL9 | !locked;
   always @(posedge bus_clk or posedge clocks_reset)
      if (clocks_reset) begin
         ready_count <= 16'd0;
         ready       <= 1'b0;
      end else if (!ready) begin
         ready_count <= ready_count + 16'd1;
         ready       <= (ready_count == 16'hffff);
      end
   wire rst;
   reset_sync rst_sync (.clk(bus_clk), .reset_in(!ready), .reset_out(rst));

   wire [63:0] data_tdata, ctrl_tdata;
   wire        data_tlast, data_tvalid, data_tready;
   wire        ctrl_tlast, ctrl_tvalid, ctrl_tready;
   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(14), .DATA_TX_FIFO_SIZE(14)) slave_fifo32 (
      .gpif_clk(bus_clk), .gpif_rst(rst), .gpif_enb(1'b1),
      .gpif_ctl({GPIF_CTL8, GPIF_CTL6, GPIF_CTL5, GPIF_CTL4}), .fifoadr({GPIF_CTL11, GPIF_CTL12}),
      .slwr(GPIF_CTL1), .sloe(GPIF_CTL2), .slcs(GPIF_CTL0), .slrd(GPIF_CTL3), .pktend(GPIF_CTL7),
      .gpif_d(GPIF_D),
      .fifo_clk(bus_clk), .fifo_rst(rst),
      .tx_tdata(data_tdata), .tx_tlast(data_tlast), .tx_tvalid(data_tvalid), .tx_tready(data_tready),
      .rx_tdata(data_tdata), .rx_tlast(data_tlast), .rx_tvalid(data_tvalid), .rx_tready(data_tready),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(ctrl_tdata), .resp_tlast(ctrl_tlast), .resp_tvalid(ctrl_tvalid), .resp_tready(ctrl_tready),
      .debug());

   assign LED_STATUS = ready;
   assign LED_CLK_G  = locked;
   assign LED_RX1    = 1'b0;
endmodule
