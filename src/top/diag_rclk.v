// diag_rclk.v - SIMPLEST POSSIBLE GPIF speaker.
//
// Purpose: answer "is the FPGA fabric alive and is the FPGA->FX3 GPIF path
// conducting?" with ZERO dependencies beyond one clock wire:
//
//   codec_main_clk (40 MHz, always present at power-up)
//        -> IBUFDS -> BUFG -> rclk                      (no MMCM!)
//        -> ODDR      -> IFCLK                          (PCLK to the FX3)
//        -> counter   -> GPIF_D  (free-running pattern)
//        -> pulse     -> GPIF_CTL1 (SLWR, thread 3)
//
// No MMCM, no control processor, no DSP, no resets, no handshakes.  If the
// FX3 accepts a single word, its DMA counters/log must show it.  If it
// shows nothing, the physical FPGA->FX3 path (or the 40 MHz input clock)
// is the fault - not our design's clocking or logic.
//
// Thread 3 = CTRL_RESP (firmware CyU3PGpifSocketConfigure(3,
// CY_U3P_PIB_SOCKET_3,...)), i.e. the socket that answers control reads.

`default_nettype none

module diag_rclk (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   input  wire GPIF_CTL4, input  wire GPIF_CTL5,
   input  wire GPIF_CTL6, input  wire GPIF_CTL8,
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

   // ---- the one clock: raw 40 MHz codec main clock, no MMCM ----
   wire clk_in, rclk;
   IBUFDS ibufds (.O(clk_in), .I(codec_main_clk_p), .IB(codec_main_clk_n));
   BUFG   bufg   (.I(clk_in), .O(rclk));

   // PCLK for the FX3
   ODDR #(
      .DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
   ) ODDR_IFCLK (
      .Q(IFCLK), .C(rclk), .CE(1'b1),
      .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
   );

   // ---- free-running write master into thread 3 ----
   reg [31:0] cnt = 32'd0;
   reg [31:0] dat = 32'd0;
   reg        slwr_r = 1'b1;

   always @(posedge rclk) begin
      cnt <= cnt + 32'd1;
      case (cnt[2:0])
        3'd0: begin dat    <= {cnt[15:0], ~cnt[15:0]}; slwr_r <= 1'b1; end
        3'd1: begin dat    <= {cnt[15:0], ~cnt[15:0]}; slwr_r <= 1'b1; end
        3'd2: begin dat    <= dat;                      slwr_r <= 1'b0; end  // write
        3'd3: begin dat    <= dat;                      slwr_r <= 1'b1; end
        default: begin dat  <= dat;                     slwr_r <= 1'b1; end
      endcase
   end

   assign GPIF_D     = dat;
   assign GPIF_CTL0  = 1'b0;      // SLCS active
   assign GPIF_CTL1  = slwr_r;    // SLWR
   assign GPIF_CTL2  = 1'b1;      // SLOE idle
   assign GPIF_CTL3  = 1'b1;      // SLRD idle
   assign GPIF_CTL7  = 1'b1;      // PKTEND idle
   assign GPIF_CTL11 = 1'b1;      // fifoadr[1:0] = 3
   assign GPIF_CTL12 = 1'b1;

   assign LED_STATUS = 1'b1;      // FPGA configured
   reg [23:0] blink = 24'd0;
   always @(posedge rclk) blink <= blink + 24'd1;
   assign LED_CLK_G  = blink[23]; // ~2.4 Hz if rclk alive
   assign LED_RX1    = cnt[25];   // ~0.6 Hz if the counter runs

endmodule
`default_nettype wire
