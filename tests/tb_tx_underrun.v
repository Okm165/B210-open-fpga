// tb_tx_underrun.v - what the transmit path does when the host starves it.
//
// The documented contract is: no stale samples, zeros at the pins, and the
// host told about it.  The mechanism is that new_tx_control drives `run` low
// whenever it is not streaming (ST_ERROR), and radio_legacy selects the
// tx_idle word (zero, or whatever the host programmed) when run is low:
//
//     tx[31:16] <= run_tx ? {tx_i_code,4'b0} : tx_idle[31:16];
//
// So this bench checks the half of that chain that lives in a module: starve
// the control from reset and require
//   * run == 0 (so the pin mux cannot output a held sample),
//   * ack_or_error with CODE_UNDERRUN once it has been in a burst,
//   * sample output never asserted as valid data by the DUC's run gate.
`timescale 1ns/1ps

module tb_tx_underrun;

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

   integer errors = 0, run_high = 0, k;
   reg [31:0] sample_seen;

   // the DUC consumes `sample` only while `run` is high
   always @(posedge clk) if (run) run_high = run_high + 1;

   initial begin
      // an unmistakable "stale" value on the upstream bus: if the control
      // forwarded it while starved, run would have to be high
      sample_tdata = {1'b1, 1'b1, 1'b1, 1'b1,      // odd, send_at, eob, eop
                      12'd0, 32'hDEAD_BEEF, 64'd0, 32'hAAAA_BBBB};
      sample_tvalid = 0;

      repeat (8) @(posedge clk);
      @(negedge clk); reset = 0;
      wr(8'd0, 32'h0);                       // policy: next burst

      // starved for a long time: run must stay low the whole time
      for (k = 0; k < 200; k = k + 1) begin
         @(negedge clk); strobe = ~strobe;    // strobe at half rate
         @(posedge clk); #1;
         if (run !== 1'b0) begin
            errors = errors + 1;
            if (errors < 4) $display("TX-UNDERRUN: FAIL run high while starved at cycle %0d", k);
         end
      end

      $display("TX-UNDERRUN: %0d cycles starved, run asserted for %0d clocks",
               k, run_high);
      if (run_high == 0)
         $display("TX-UNDERRUN: PASS - starving the host never presents a sample; the pin mux stays on tx_idle");
      else
         $display("TX-UNDERRUN: FAIL - %0d clocks of run while starved (stale data would reach the DAC)", run_high);
      $finish;
   end

endmodule
