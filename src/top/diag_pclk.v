// diag_pclk.v - THE most atomic test: drive IFCLK (PCLK to the FX3)
// straight from the differential input clock through fabric, no MMCM,
// no BUFG, no global clock spine, no lock dependency.  Also strobe the
// GPIF data bus with an incrementing word (always driven).
`default_nettype none
module diag_pclk (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8, input wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   inout  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS, output wire LED_CLK_G, output wire LED_RX1
);
   wire clk_ibuf;
   IBUFDS ib (.I(codec_main_clk_p), .O(clk_ibuf), .IB(codec_main_clk_n));

   // divide by 4 in fabric so the IOB ODDR sees a clean ~10-40 MHz
   reg [1:0] div = 2'b00;
   always @(posedge clk_ibuf) div <= div + 2'b01;

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   ODDR_IFCLK (.Q(IFCLK), .C(clk_ibuf), .CE(1'b1),
               .D1(div[1]), .D2(~div[1]), .R(1'b0), .S(1'b0));

   // strobe master on the FD bus (always driven)
   reg [31:0] cnt = 32'd0;
   always @(posedge clk_ibuf) cnt <= cnt + 32'd1;
   assign GPIF_CTL0 = 1'b0;            // SLCS active
   assign GPIF_CTL1 = (cnt[1:0]==2'b00); // SLWR strobe
   assign GPIF_CTL2 = 1'b1;            // SLOE
   assign GPIF_CTL3 = 1'b1;            // SLRD
   assign GPIF_CTL7 = 1'b1;            // PKTEND
   assign GPIF_CTL11 = 1'b1;           // FIFOADR[1]
   assign GPIF_CTL12 = 1'b1;           // FIFOADR[0]
   assign GPIF_D = {cnt[15:0], ~cnt[15:0]};

   assign LED_STATUS = 1'b1;
   reg [23:0] blink = 24'd0;
   always @(posedge clk_ibuf) blink <= blink + 24'd1;
   assign LED_CLK_G = blink[23];
   assign LED_RX1 = 1'b0;
endmodule
