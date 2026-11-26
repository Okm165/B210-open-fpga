// SPDX-License-Identifier: GPL-3.0-or-later
//
// command - executes command packets and answers each with one result packet
// (docs/PROTOCOL.md section 4).
//
// Command packet: 4 header words, then 2 words per operation:
//   a = opcode[31:24] arg[23:16] addr[15:0],   b = data
// Result packet: the same header with type 3 (result) and the command's
// length and sequence, then 2 words per operation:
//   a = opcode[31:24] status[23:16] addr[15:0], b = data
// Operations:
//   1 WRITE  register addr := data                         -> 0
//   2 READ                                                 -> register addr
//   3 SPI    one 24-bit frame data[23:0] to device arg (0 AD9361, 1
//            ADF4001) through spi_master                   -> the 8 bits read
//   4 WAIT   data microseconds                             -> 0
//   5 POLL   repeat the previous READ or SPI (the last one executed, in
//            this packet or an earlier one) until (value[15:0] &
//            data[31:16]) == data[15:0], for at most arg milliseconds (0:
//            one try)                                      -> the last value
// Status: 0 ok, 1 timeout (POLL), 3 unknown opcode (also SPI to a device
// other than 0 or 1) - then every later operation of the packet is skipped
// and answered with status 3 too.
//
// Malformed input never stalls the host:
//   - wrong version or type, or a length that is not 16 + 8 n bytes with
//     n <= 126: no answer, the packet is dropped, `cmd_dropped` counts it;
//   - a packet that ends before its length says (FIFO `last`): the missing
//     operations are answered with status 3; words beyond the length are
//     dropped. Either way the result has exactly n operations.
//
// Register bus: reg_we / reg_re are one-cycle strobes with reg_addr (and
// reg_wdata); regs puts the value on reg_rdata in the next cycle.
//
// SPI port (spi_master): spi_start is a one-cycle strobe with spi_dev and
// spi_word (the registers POLL repeats, set in the same cycle); spi_done
// pulses when the frame is over, with spi_rdata valid and held from then
// on. An SPI operation takes the frame's 50 half periods plus a few cycles.
//
// Time: CLK_MHZ cycles per microsecond (CLK_MHZ <= 127). WAIT and POLL count
// microseconds with a prescaler restarted at the operation's start: no
// multiplier on the 100 MHz path. A WAIT of b us occupies exactly
// b * CLK_MHZ cycles (and 2 for b = 0): its load and exit cycles are taken
// out of the first microsecond (the prescaler starts at 2). POLL's limit,
// arg ms = arg * 1000 us = arg * 1024 - arg * 16 - arg * 8 us.
`default_nettype none

module command #(
  parameter CLK_MHZ = 100
) (
  input  wire        clk, rst,
  // command packets (packet_fifo read side)
  input  wire        r_avail,
  input  wire [31:0] r_data,
  input  wire        r_last,
  output reg         r_take,
  // result packets (packet_fifo write side, MAX = 256 words)
  input  wire        w_room,
  output reg         w_valid, w_last,
  output reg  [31:0] w_data,
  // register bus
  output reg         reg_we, reg_re,
  output reg  [15:0] reg_addr,
  output reg  [31:0] reg_wdata,
  input  wire [31:0] reg_rdata,
  // SPI master
  output reg         spi_start = 0,
  output wire        spi_dev,
  output wire [23:0] spi_word,
  input  wire        spi_done,
  input  wire [7:0]  spi_rdata,
  output reg  [31:0] cmd_dropped = 0 // command packets dropped as malformed
);
  `include "protocol.vh"
  localparam OP_WRITE = 8'd1, OP_READ = 8'd2, OP_SPI = 8'd3, OP_WAIT = 8'd4, OP_POLL = 8'd5;
  localparam ST_OK = 8'd0, ST_TIMEOUT = 8'd1, ST_UNKNOWN = 8'd3;

  // states
  localparam IDLE = 0, HEAD = 1, ANSWER_HEAD = 2, OPA = 3, OPB = 4, EXEC = 5,
             RESULT_A = 6, RESULT_B = 7, DRAIN = 8;
  reg [3:0]  state = IDLE;
  reg [1:0]  hw = 0;             // header word being read
  reg [31:0] h0 = 0, h1 = 0;     // header words 0 and 1
  reg [6:0]  ops = 0, k = 0;     // operations announced, done
  reg        ended = 0;          // the command packet's last word was taken
  reg        skip = 0;           // an unknown opcode was seen
  reg [31:0] a = 0, b = 0;       // current operation
  reg [7:0]  status = 0;
  reg [31:0] value = 0;          // result data
  // the previous READ or SPI, which POLL repeats
  reg        poll_spi = 0;       // 0 READ of poll_addr, 1 SPI of poll_word to poll_dev
  reg [15:0] poll_addr = 0;
  reg        poll_dev = 0;
  reg [23:0] poll_word = 0;
  assign spi_dev = poll_dev, spi_word = poll_word;
  reg [31:0] us = 0;             // microseconds left (WAIT, POLL)
  reg [6:0]  pre = 0;            // cycles into the current microsecond
  wire       tick = pre == CLK_MHZ - 1;
  reg [1:0]  phase = 0;          // within EXEC

  wire [15:0] length = h0[15:0];
  wire        good   = h0[31:28] == VERSION && h0[19:16] == T_COMMAND &&
                       length >= 16 && length <= 1024 && length[2:0] == 0;
  wire [7:0]  opcode = a[31:24];
  wire        known  = opcode == OP_WRITE || opcode == OP_READ || (opcode == OP_SPI && a[23:17] == 0) ||
                       opcode == OP_WAIT || opcode == OP_POLL;
  wire [15:0] polled = poll_spi ? {8'd0, spi_rdata} : reg_rdata[15:0];   // what POLL compares

  always @(posedge clk) begin
    r_take <= 0; w_valid <= 0; w_last <= 0; reg_we <= 0; reg_re <= 0; spi_start <= 0;
    if (rst) begin
      // POLL repeats a READ of address 0 after a reset (PROTOCOL.md 4): a
      // POLL must never repeat an SPI frame a reset cut, which would send
      // the cut write to the device whole
      state <= IDLE; poll_spi <= 0; poll_addr <= 0;
    end else case (state)
      IDLE: if (r_avail && !r_take) begin hw <= 0; ended <= 0; state <= HEAD; end
      // read 4 header words; a packet shorter than that is dropped
      HEAD: if (!r_take) begin
        r_take <= 1;
        if (hw == 0) h0 <= r_data;
        if (hw == 1) h1 <= r_data;
        hw <= hw + 1;
        if (r_last) begin ended <= 1; if (hw != 3) begin cmd_dropped <= cmd_dropped + 1; state <= IDLE; end end
        if (hw == 3) state <= ANSWER_HEAD;
      end
      ANSWER_HEAD: if (!good) begin
        cmd_dropped <= cmd_dropped + 1; state <= ended ? IDLE : DRAIN;
      end else if (hw != 0 || w_room) begin
        // header of the result, one word per cycle; w_room reserved room
        // for the whole result packet before its first word
        w_valid <= 1;
        case (hw)
          0: w_data <= {VERSION, 8'd0, T_RESULT, length};
          1: w_data <= {16'd0, h1[15:0]};
          default: w_data <= 0;
        endcase
        ops <= (length - 16) >> 3; k <= 0; skip <= 0;
        w_last <= hw == 3 && length == 16;
        hw <= hw + 1;
        if (hw == 3) state <= length == 16 ? (ended ? IDLE : DRAIN) : OPA;
      end
      // the next operation: 2 words, or status 3 if the packet ended early
      OPA: if (ended) begin
        a <= 0; b <= 0; status <= ST_UNKNOWN; value <= 0; state <= RESULT_A;
      end else if (!r_take) begin
        r_take <= 1; a <= r_data;
        if (r_last) ended <= 1;
        state <= OPB;
      end
      OPB: if (ended) begin
        status <= ST_UNKNOWN; value <= 0; state <= RESULT_A;
      end else if (!r_take) begin
        r_take <= 1; b <= r_data;
        if (r_last) ended <= 1;
        phase <= 0; state <= EXEC;
      end
      EXEC: begin
        status <= ST_OK; value <= 0;
        if (skip || !known) begin
          skip <= 1; status <= ST_UNKNOWN; state <= RESULT_A;
        end else case (opcode)
          OP_WRITE: begin
            reg_we <= 1; reg_addr <= a[15:0]; reg_wdata <= b; state <= RESULT_A;
          end
          OP_READ: case (phase)   // strobe, wait, take the value
            0: begin reg_re <= 1; reg_addr <= a[15:0]; poll_spi <= 0; poll_addr <= a[15:0]; phase <= 1; end
            1: phase <= 2;
            default: begin value <= reg_rdata; state <= RESULT_A; end
          endcase
          OP_SPI: case (phase)    // start the frame, take the byte when it is over
            0: begin
              spi_start <= 1; poll_spi <= 1; poll_dev <= a[16]; poll_word <= b[23:0]; phase <= 1;
            end
            default: if (spi_done) begin value <= {24'd0, spi_rdata}; state <= RESULT_A; end
          endcase
          OP_WAIT: case (phase)   // b * CLK_MHZ cycles in all
            0: begin us <= b; pre <= 2; phase <= 1; end
            default: if (us == 0) state <= RESULT_A;
                     else begin pre <= tick ? 7'd0 : pre + 1; if (tick) us <= us - 1; end
          endcase
          default: begin          // POLL: read or SPI, compare; again until a match or the time is up
            if (phase != 0) begin pre <= tick ? 7'd0 : pre + 1; if (tick && us != 0) us <= us - 1; end
            case (phase)
              0: begin us <= {a[23:16], 10'd0} - {a[23:16], 4'd0} - {a[23:16], 3'd0}; pre <= 0; phase <= 1; end
              1: begin
                if (poll_spi) spi_start <= 1;
                else begin reg_re <= 1; reg_addr <= poll_addr; end
                phase <= 2;
              end
              2: if (!poll_spi || spi_done) phase <= 3;   // the register's value comes next cycle
              default: begin
                value <= poll_spi ? {24'd0, spi_rdata} : reg_rdata;
                if ((polled & b[31:16]) == b[15:0]) state <= RESULT_A;
                else if (us == 0) begin status <= ST_TIMEOUT; state <= RESULT_A; end
                else phase <= 1;
              end
            endcase
          end
        endcase
      end
      RESULT_A: begin
        w_valid <= 1; w_data <= {a[31:24], status, a[15:0]}; state <= RESULT_B;
      end
      RESULT_B: begin
        w_valid <= 1; w_data <= value; k <= k + 1;
        w_last <= k + 1 == ops;
        if (k + 1 == ops) state <= ended ? IDLE : DRAIN;
        else state <= OPA;
      end
      DRAIN: if (!r_take) begin           // words beyond the length
        r_take <= 1;
        if (r_last) state <= IDLE;
      end
      default: state <= IDLE;
    endcase
  end
endmodule

`default_nettype wire
