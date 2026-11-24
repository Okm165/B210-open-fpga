// diag_rd.v - the atomic GPIF ladder.  One protocol-legal reader, three
// clock paths; each rung adds exactly one piece of the real design's clocking.
//
//   MODE=0  codec 40 MHz -> IBUFDS -> BUFG; IFCLK = ~clk through fabric
//   MODE=1  same clock;  IFCLK = ODDR(D1=0,D2=1) clocked from the BUFG
//           (adds the HCLK leaf -> IOI_OCLK path the real design uses)
//   MODE=2  b200_clk_gen MMCM (100 MHz) -> BUFG -> ODDR IFCLK, reader
//           held in reset until `locked` (adds the MMCM + lock gating)
//
//   DESIGN=diag_rd NAME=diag_rdB PARAMS="MODE=1" scripts/build_diag.sh
//
// Reader: FIFOADR = 0 (FX3 thread 0 = EP2 OUT, host->FPGA data; verified in
// b200_main.c), one single-word read every 8 PCLK cycles while the FX3's
// ready flag (CTL4) is high.  One word per 8 cycles keeps the flag latency
// (<= 3 cycles) out of the picture, so the FIFO is never read while empty.
// IFCLK is the inverted logic clock: the FX3 samples our strobes half a
// period after we launch them, which needs no I/O timing constraints.
//
// Observable: host bulk-OUT throughput on EP 0x02 (scripts/fx3_raw_load.py).
// 40 MHz / 8 * 4 B = 20 MB/s capacity, above the ~12 MB/s the host delivers.
`default_nettype none

module diag_rd #(parameter MODE = 0) (
   input  wire codec_main_clk_p, input wire codec_main_clk_n,
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8,
   input  wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   input  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS, output wire LED_CLK_G, output wire LED_RX1
);
   wire clk, rst;
   generate
      if (MODE == 2) begin : g_mmcm
         wire locked;
         b200_clk_gen gen (
            .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
            .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(clk), .CLK_OUT3_100_bus(),
            .reset(GPIF_CTL9), .locked(locked));
         assign rst = ~locked;
      end else begin : g_direct
         wire clk_ref;
         IBUFDS ibufds (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk_ref));
         BUFG   bufg   (.I(clk_ref), .O(clk));
         assign rst = 1'b0;
      end
      if (MODE == 0) begin : g_fabric_ifclk
         assign IFCLK = ~clk;
      end else begin : g_oddr_ifclk
         ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
         oddr (.Q(IFCLK), .C(clk), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0));
      end
   endgenerate

   reg [2:0] cnt = 3'd0;
   reg       rdy1 = 1'b0, rdy2 = 1'b0;
   reg       rd_n = 1'b1;
   always @(posedge clk) begin
      cnt  <= cnt + 3'd1;
      rdy1 <= GPIF_CTL4;
      rdy2 <= rdy1;
      rd_n <= rst | ~(rdy2 & (cnt == 3'd0));
   end

   assign GPIF_CTL0  = 1'b0;   // SLCS   active
   assign GPIF_CTL1  = 1'b1;   // SLWR   idle
   assign GPIF_CTL2  = rd_n;   // SLOE   with the read
   assign GPIF_CTL3  = rd_n;   // SLRD
   assign GPIF_CTL7  = 1'b1;   // PKTEND idle
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0]  -> thread 0

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;
endmodule
