// tb_tx_timed.v - the timed-send path: a packet scheduled for a future
// vita_time must wait, fire exactly on that tick, and report an error if the
// time has already passed.
//
// This is the FPGA-side half of every timed command UHD issues.  time_compare
// is a plain equality/less-than on 64-bit ticks, so the whole behaviour is:
//
//   ST_IDLE:  if (~send_at | now) start;  else if (late) -> CODE_TIME_ERROR
//
// Important premise the bench has to respect: a timed packet is consumed once.
// Holding the same packet on the bus after its time has passed is itself a
// late packet, and the control correctly reports TIME_ERROR - so each case
// starts from reset, not from the tail of the previous one.
//
// Error codes are {32'dN, 20'd0, seqnum}: the code number is the HIGH word and
// the low word is only the sequence number.  ack_or_error is a one-clock pulse,
// so it is latched by a monitor rather than sampled.
`timescale 1ns/1ps

module tb_tx_timed;

   reg clk = 0; always #5 clk = ~clk;
   reg reset = 1, clear = 0;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;

   reg  [175:0] sample_tdata = 0;
   reg          sample_tvalid = 0;
   wire         sample_tready;
   wire [31:0]  sample;
   wire         run;
   reg          strobe = 0;
   wire         ack_or_error, packet_consumed;
   wire [11:0]  seqnum;
   wire [63:0]  error_code;
   wire [31:0]  sid;
   reg  [63:0]  vita_time = 0;

   new_tx_control #(.BASE(8'd0)) dut (
      .clk(clk), .reset(reset), .clear(clear),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time),
      .ack_or_error(ack_or_error), .packet_consumed(packet_consumed),
      .seqnum(seqnum), .error_code(error_code), .sid(sid),
      .sample_tdata(sample_tdata), .sample_tvalid(sample_tvalid), .sample_tready(sample_tready),
      .sample(sample), .run(run), .strobe(strobe),
      .debug());

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clk); set_stb = 0;
      end
   endtask

   task setpkt(input [63:0] t, input sched, input [11:0] seq);
      begin
         sample_tdata[31:0]    = 32'h1111_1111;
         sample_tdata[63:32]   = 32'h2222_2222;
         sample_tdata[127:64]  = t;            // send_time
         sample_tdata[159:128] = 32'h0;        // sid
         sample_tdata[171:160] = seq;
         sample_tdata[172]     = 1'b1;         // eop
         sample_tdata[173]     = 1'b1;         // eob
         sample_tdata[174]     = sched;        // send_at
         sample_tdata[175]     = 1'b1;         // odd
      end
   endtask

   integer k, errors = 0, fired_at = -1;

   // one-clock pulse latches: ack_or_error and the packet handshake
   reg ack_seen = 0;
   reg consumed = 0;
   always @(posedge clk) if (ack_or_error) ack_seen <= 1'b1;
   always @(posedge clk) if (packet_consumed) consumed <= 1'b1;

   task do_reset;
      begin
         @(negedge clk); reset = 1; sample_tvalid = 0;
         repeat (4) @(negedge clk);
         @(negedge clk); reset = 0;
         repeat (4) @(negedge clk);
         wr(8'd0, 32'h0);                      // policy: next burst
      end
   endtask

   initial begin
      repeat (8) @(posedge clk);

      // ---------------- case 1: scheduled for tick 40, must wait then fire --
      do_reset;
      ack_seen = 0;
      consumed  = 0;
      setpkt(64'd40, 1'b1, 12'd0);
      sample_tvalid = 1'b1;
      fired_at = -1;
      // Present the packet and drop it the instant the handshake completes:
      // a timed packet held past its tick is correctly rejected as late.
      begin : case1_loop
         for (k = 0; k < 60; k = k + 1) begin
            @(negedge clk);
            vita_time = vita_time + 1;         // ticks once per clock
            strobe = ~strobe;
            if (run && fired_at < 0) fired_at = k;
            if (consumed) begin
               sample_tvalid = 1'b0;
               disable case1_loop;
            end
         end
      end
      repeat (4) @(negedge clk);
      if (!consumed) begin
         errors = errors + 1;
         $display("TX-TIMED: FAIL - the scheduled packet was never consumed");
      end

      $display("TX-TIMED: scheduled 40, first run at tick %0d", fired_at);
      if (fired_at != 40) begin
         errors = errors + 1;
         $display("TX-TIMED: FAIL - expected to fire at exactly tick 40");
      end
      // it must have been accepted, not rejected with a time error
      if (error_code[63:32] == 32'd8) begin
         errors = errors + 1;
         $display("TX-TIMED: FAIL - a future-scheduled packet was rejected as late");
      end

      // ---------------- case 2: time already in the past -> TIME_ERROR (8) --
      do_reset;
      ack_seen = 0;
      setpkt(vita_time - 1, 1'b1, 12'd0);
      sample_tvalid = 1'b1;
      repeat (8) @(negedge clk);
      $display("TX-TIMED: past time -> error_code 0x%08x (expect 8), ack pulse %b",
               error_code[63:32], ack_seen);
      if (error_code[63:32] !== 32'd8) errors = errors + 1;
      if (ack_seen !== 1'b1) errors = errors + 1;
      if (run !== 1'b0) begin
         errors = errors + 1;
         $display("TX-TIMED: FAIL - a late packet started the DAC (run high)");
      end
      sample_tvalid = 1'b0;

      if (errors == 0)
         $display("TX-TIMED: PASS - scheduled packet waits and fires on its tick, past time reports TIME_ERROR and never starts the DAC");
      else
         $display("TX-TIMED: FAIL - %0d cases wrong", errors);
      $finish;
   end

endmodule
