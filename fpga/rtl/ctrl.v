// SPDX-License-Identifier: GPL-3.0-or-later
//
// ctrl - executes command packets and answers each with one result packet
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
//   4 WAIT   data microseconds                             -> 0
//   5 POLL   repeat the previous READ until (value[15:0] & data[31:16]) ==
//            data[15:0], for at most arg milliseconds (0: one try)
//                                                          -> the last value
// Status: 0 ok, 1 timeout (POLL), 3 unknown opcode - then every later
// operation of the packet is skipped and answered with status 3 too.
//
// Malformed input never stalls the host:
//   - wrong version or type, or a length that is not 16 + 8 n bytes with
//     n <= 126: no answer, the packet is dropped, `dropped` counts it;
//   - a packet that ends before its length says (FIFO `last`): the missing
//     operations are answered with status 3; words beyond the length are
//     dropped. Either way the result has exactly n operations.
//
// Register bus: reg_we / reg_re are one-cycle strobes with reg_addr (and
// reg_wdata); the addressed block puts the value on reg_rdata in the next
// cycle (every block drives 0 when not addressed, the top ORs them).
//
// Time: CLK_MHZ cycles per microsecond; WAIT and POLL count cycles of clk.
`default_nettype none

module ctrl #(
  parameter CLK_MHZ = 100
) (
  input  wire        clk, rst,
  // command packets (packet_fifo read side)
  input  wire        c_avail,
  input  wire [31:0] c_data,
  input  wire        c_last,
  output reg         c_take,
  // result packets (packet_fifo write side, MAX = 256 words)
  input  wire        r_room,
  output reg         r_valid, r_last,
  output reg  [31:0] r_data,
  // register bus
  output reg         reg_we, reg_re,
  output reg  [15:0] reg_addr,
  output reg  [31:0] reg_wdata,
  input  wire [31:0] reg_rdata,
  output reg  [31:0] dropped = 0     // command packets dropped as malformed
);
  localparam VERSION = 4'd1, T_COMMAND = 4'd2, T_RESULT = 4'd3;
  localparam OP_WRITE = 8'd1, OP_READ = 8'd2, OP_WAIT = 8'd4, OP_POLL = 8'd5;
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
  reg [15:0] poll_addr = 0;      // the previous READ's address
  reg [39:0] timer = 0;          // cycles left (WAIT, POLL): 2^40 cycles = 3 h at 100 MHz
  reg [1:0]  phase = 0;          // within EXEC

  wire [15:0] length = h0[15:0];
  wire        good   = h0[31:28] == VERSION && h0[19:16] == T_COMMAND &&
                       length >= 16 && length <= 1024 && length[2:0] == 0;
  wire [7:0]  opcode = a[31:24];

  always @(posedge clk) begin
    c_take <= 0; r_valid <= 0; r_last <= 0; reg_we <= 0; reg_re <= 0;
    if (rst) begin
      state <= IDLE;
    end else case (state)
      IDLE: if (c_avail && !c_take) begin hw <= 0; ended <= 0; state <= HEAD; end
      // read 4 header words; a packet shorter than that is dropped
      HEAD: if (!c_take) begin
        c_take <= 1;
        if (hw == 0) h0 <= c_data;
        if (hw == 1) h1 <= c_data;
        hw <= hw + 1;
        if (c_last) begin ended <= 1; if (hw != 3) begin dropped <= dropped + 1; state <= IDLE; end end
        if (hw == 3) state <= ANSWER_HEAD;
      end
      ANSWER_HEAD: if (!good) begin
        dropped <= dropped + 1; state <= ended ? IDLE : DRAIN;
      end else if (hw != 0 || r_room) begin
        // header of the result, one word per cycle; r_room reserved room
        // for the whole result packet before its first word
        r_valid <= 1;
        case (hw)
          0: r_data <= {VERSION, 8'd0, T_RESULT, length};
          1: r_data <= {16'd0, h1[15:0]};
          default: r_data <= 0;
        endcase
        ops <= (length - 16) >> 3; k <= 0; skip <= 0;
        r_last <= hw == 3 && length == 16;
        hw <= hw + 1;
        if (hw == 3) state <= length == 16 ? (ended ? IDLE : DRAIN) : OPA;
      end
      // the next operation: 2 words, or status 3 if the packet ended early
      OPA: if (ended) begin
        a <= 0; b <= 0; status <= ST_UNKNOWN; value <= 0; state <= RESULT_A;
      end else if (!c_take) begin
        c_take <= 1; a <= c_data;
        if (c_last) ended <= 1;
        state <= OPB;
      end
      OPB: if (ended) begin
        status <= ST_UNKNOWN; value <= 0; state <= RESULT_A;
      end else if (!c_take) begin
        c_take <= 1; b <= c_data;
        if (c_last) ended <= 1;
        phase <= 0; state <= EXEC;
      end
      EXEC: begin
        status <= ST_OK; value <= 0;
        if (skip || !(opcode == OP_WRITE || opcode == OP_READ || opcode == OP_WAIT || opcode == OP_POLL)) begin
          skip <= 1; status <= ST_UNKNOWN; state <= RESULT_A;
        end else case (opcode)
          OP_WRITE: begin
            reg_we <= 1; reg_addr <= a[15:0]; reg_wdata <= b; state <= RESULT_A;
          end
          OP_READ: case (phase)   // strobe, wait, take the value
            0: begin reg_re <= 1; reg_addr <= a[15:0]; poll_addr <= a[15:0]; phase <= 1; end
            1: phase <= 2;
            default: begin value <= reg_rdata; state <= RESULT_A; end
          endcase
          OP_WAIT: case (phase)   // b * CLK_MHZ cycles in all
            0: begin timer <= b * CLK_MHZ; phase <= 1; end
            default: if (timer > 2) timer <= timer - 1; else state <= RESULT_A;
          endcase
          default: begin          // POLL: read, compare; again until a match or the time is up
            if (phase != 0 && timer != 0) timer <= timer - 1;
            case (phase)
              0: begin timer <= a[23:16] * 1000 * CLK_MHZ; phase <= 1; end
              1: begin reg_re <= 1; reg_addr <= poll_addr; phase <= 2; end
              2: phase <= 3;
              default: begin
                value <= reg_rdata;
                if ((reg_rdata[15:0] & b[31:16]) == b[15:0]) state <= RESULT_A;
                else if (timer == 0) begin status <= ST_TIMEOUT; state <= RESULT_A; end
                else phase <= 1;
              end
            endcase
          end
        endcase
      end
      RESULT_A: begin
        r_valid <= 1; r_data <= {a[31:24], status, a[15:0]}; state <= RESULT_B;
      end
      RESULT_B: begin
        r_valid <= 1; r_data <= value; k <= k + 1;
        r_last <= k + 1 == ops;
        if (k + 1 == ops) state <= ended ? IDLE : DRAIN;
        else state <= OPA;
      end
      DRAIN: if (!c_take) begin           // words beyond the length
        c_take <= 1;
        if (c_last) state <= IDLE;
      end
      default: state <= IDLE;
    endcase
  end
endmodule

`default_nettype wire
