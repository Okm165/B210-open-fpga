// SPDX-License-Identifier: GPL-3.0-or-later
//
// regs - the register map (docs/PROTOCOL.md 6), on the register bus of
// command: reg_we / reg_re are one-cycle strobes with reg_addr; a read's value
// is on reg_rdata in the next cycle (0 for an address not listed).
//
//   0x000 id          r   0x42323130 "B210"
//   0x001 version     r   protocol version [31:16], build number [15:0]
//   0x002 build       r   first 32 bits of the source commit
//   0x003 scratch     rw  free, for bus tests
//   0x004 status      r   [0] clocks locked, [1] sample clock running
//   0x005 sample_rate r   sample strobes in the last 1 ms of the bus clock,
//                         i.e. the sample rate in kS/s (a time set makes the
//                         next window wrong; it is right again 1 ms later)
//   0x010 time_lo     r   time now [31:0]; reading it latches time_hi
//   0x011 time_hi     r   time [63:32] as of the last time_lo read
//   0x012 time_set_lo rw  \ the time to set
//   0x013 time_set_hi rw  /
//   0x014 time_ctrl   w   1: set the time now     r: [0] a set is pending
//   0x020 rx_ctrl     rw  w: [0] start, [1] stop (strobes); [3] timed start,
//                         [7:4] format (1 sc16, 2 sc12), [9:8] channels
//                         r: [9:8], [7:4] and [3] as written, [0] = a stream
//                         runs. An invalid format (not 1 or 2) or channel
//                         mask 0 makes start do nothing.
//   0x021 rx_count    rw  sample times in the stream, 0 = until stopped
//   0x022 rx_at_lo    rw  \ start time (with rx_ctrl[3])
//   0x023 rx_at_hi    rw  /
//   0x024 rx_spp      rw  sample times per packet: values above 8191 are
//                         saturated to 8191, and rx_framer clamps them to
//                         16 .. the full packet of the running format
//   0x030 radio       rw  [0] AD9361 RESETB: 0 holds the AD9361 in reset
//                         (after power-up and after a reset), 1 releases it
//   0x080 + k - 1     r   event counter of code k (PROTOCOL.md 5): 1
//                         OVERFLOW, 2 UNDERFLOW, 3 LATE, 4 SEQ_ERROR,
//                         5 BURST_ACK, 6 BAD_PACKET
//   0x086 rx_cdc_lost r   sample times lost crossing to the bus clock (a
//                         design error if ever nonzero); it is also part of
//                         event 1 (OVERFLOW), which is rx_framer's overflows
//                         + rx_cdc_lost
//   0x087 cmd_dropped r   command packets dropped as malformed
//   0x088 rx_used     r   words (4 bytes) now in the rx ring, 0 .. 131072
//                         (2^17 words = 512 KiB; 131072 = full)
//   0x089 rx_hwm      rw  most words ever in the rx ring; write any value to
//                         clear it before a run
//   0x08A tx_used     r   words (4 bytes) now in the tx ring, 0 .. 65536
//                         (2^16 words = 256 KiB; 65536 = full)
//   0x08B tx_hwm      rw  as rx_hwm, for the tx ring
//   0x0F0 rx_source   rw  0 radio, 1 pattern f(t), 2 tx loopback
//   0x0F1 strobe_div  rw  step 1 only: a sample strobe every strobe_div + 1
//                         cycles of the 61.54 MHz test clock (1200/19.5)
`default_nettype none

module regs #(
  parameter [15:0] BUILD_NUMBER = 0,
  parameter [31:0] BUILD_COMMIT = 0
) (
  input  wire         clk, rst,
  input  wire         reg_we, reg_re,
  input  wire [15:0]  reg_addr,
  input  wire [31:0]  reg_wdata,
  output reg  [31:0]  reg_rdata = 0,
  // status
  input  wire         locked, sample_running,
  // time
  input  wire [63:0]  now,
  output reg  [63:0]  time_set = 0,
  output reg          time_req = 0,      // toggles: set the time
  input  wire         time_ack,          // equals time_req when done
  // rx stream
  output reg          rx_start = 0,
  output reg          rx_stop = 0,
  output reg          rx_timed = 0,      // start at rx_at, else at once
  output reg  [3:0]   rx_format = 1,
  output reg  [1:0]   rx_channels = 1,
  output reg  [31:0]  rx_count = 0,
  output reg  [63:0]  rx_at = 0,
  output reg  [12:0]  rx_spp = 4096,
  input  wire         rx_running,
  // counters
  input  wire [191:0] counts,            // event code k in bits 32 k - 1 : 32 (k - 1)
  input  wire [31:0]  rx_cdc_lost, cmd_dropped,
  // live statistics
  input  wire [17:0]  rx_used,           // words in the rx ring (AW = 17: 0 .. 2^17)
  input  wire [16:0]  tx_used,           // words in the tx ring (AW = 16: 0 .. 2^16)
  input  wire [16:0]  sample_ksps,       // strobes in the last 1 ms
  // radio
  output reg          resetb = 0,        // AD9361 RESETB pin
  // step-1 sample source
  output reg  [1:0]   rx_source = 0,
  output reg  [15:0]  strobe_div = 0
);
  localparam [15:0] PROTOCOL_VERSION = 1;
  reg [31:0] scratch = 0, time_hi = 0;
  reg [17:0] rx_hwm = 0;
  reg [16:0] tx_hwm = 0;

  always @(posedge clk) begin
    rx_start <= 0; rx_stop <= 0;
    reg_rdata <= 0;
    if (rst) begin
      // every writable register starts at its safe value: no stream, no
      // time set, radio in reset
      rx_timed <= 0; rx_format <= 1; rx_channels <= 1; rx_count <= 0; rx_at <= 0;
      rx_spp <= 4096; rx_source <= 0; strobe_div <= 0; resetb <= 0; time_set <= 0;
      time_req <= 0; rx_hwm <= 0; tx_hwm <= 0;
    end else begin
      if (rx_used > rx_hwm) rx_hwm <= rx_used;
      if (tx_used > tx_hwm) tx_hwm <= tx_used;
      if (reg_we) case (reg_addr)
        16'h003: scratch <= reg_wdata;
        16'h012: time_set[31:0] <= reg_wdata;
        16'h013: time_set[63:32] <= reg_wdata;
        16'h014: if (reg_wdata[0] && time_req == time_ack) time_req <= !time_req;
        16'h020: begin
          rx_start <= reg_wdata[0]; rx_stop <= reg_wdata[1]; rx_timed <= reg_wdata[3];
          rx_format <= reg_wdata[7:4]; rx_channels <= reg_wdata[9:8];
        end
        16'h021: rx_count <= reg_wdata;
        16'h022: rx_at[31:0] <= reg_wdata;
        16'h023: rx_at[63:32] <= reg_wdata;
        // saturate, never wrap: 8192 would otherwise read as 0
        16'h024: rx_spp <= |reg_wdata[31:13] ? 13'h1FFF : reg_wdata[12:0];
        16'h030: resetb <= reg_wdata[0];
        16'h089: rx_hwm <= 0;
        16'h08B: tx_hwm <= 0;
        16'h0F0: rx_source <= reg_wdata[1:0];
        16'h0F1: strobe_div <= reg_wdata[15:0];
        default: ;
      endcase
      if (reg_re) case (reg_addr)
        16'h000: reg_rdata <= 32'h4232_3130;
        16'h001: reg_rdata <= {PROTOCOL_VERSION, BUILD_NUMBER};
        16'h002: reg_rdata <= BUILD_COMMIT;
        16'h003: reg_rdata <= scratch;
        16'h004: reg_rdata <= {30'd0, sample_running, locked};
        16'h005: reg_rdata <= {15'd0, sample_ksps};
        16'h010: begin reg_rdata <= now[31:0]; time_hi <= now[63:32]; end
        16'h011: reg_rdata <= time_hi;
        16'h012: reg_rdata <= time_set[31:0];
        16'h013: reg_rdata <= time_set[63:32];
        16'h014: reg_rdata <= {31'd0, time_req != time_ack};
        16'h020: reg_rdata <= {22'd0, rx_channels, rx_format, rx_timed, 2'd0, rx_running};
        16'h021: reg_rdata <= rx_count;
        16'h022: reg_rdata <= rx_at[31:0];
        16'h023: reg_rdata <= rx_at[63:32];
        16'h024: reg_rdata <= {19'd0, rx_spp};
        16'h030: reg_rdata <= {31'd0, resetb};
        16'h080, 16'h081, 16'h082, 16'h083, 16'h084, 16'h085:
                 reg_rdata <= counts[32 * (reg_addr - 16'h080) +: 32];
        16'h086: reg_rdata <= rx_cdc_lost;
        16'h087: reg_rdata <= cmd_dropped;
        16'h088: reg_rdata <= {14'd0, rx_used};
        16'h089: reg_rdata <= {14'd0, rx_hwm};
        16'h08A: reg_rdata <= {15'd0, tx_used};
        16'h08B: reg_rdata <= {15'd0, tx_hwm};
        16'h0F0: reg_rdata <= {30'd0, rx_source};
        16'h0F1: reg_rdata <= {16'd0, strobe_div};
        default: ;
      endcase
    end
  end
endmodule

`default_nettype wire
