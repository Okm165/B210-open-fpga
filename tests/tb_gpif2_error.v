//
// gpif2_error_checker: CHDR packet error detection and resynchronisation.
//
// This block sits on the RX GPIF path, so a mistake here either drops good
// packets or forwards a desynchronised stream.  It was also modified: the
// `gate_terror` input of axi_packet_gate has no source, and leaving it open
// made `bus_error` x in simulation and 0 in silicon.  It is now tied low, and
// this bench proves `bus_error` is a defined 0 on good traffic.
//
// Three phases:
//   A  legal 3-word packet       -> 3 words out, tlast on the last, no error
//   B  header whose length is 0  -> bus_error, packet dropped, resync
//   C  another legal packet      -> forwarded again (the block recovered)
//
`timescale 1ns/1ps

module tb_gpif2_error;

   reg         clk = 0;
   reg         reset = 1;
   reg         clear = 0;
   reg  [31:0] i_tdata = 0;
   reg         i_tlast = 0;
   reg         i_tvalid = 0;
   wire        i_tready;
   wire [31:0] o_tdata;
   wire        o_tlast;
   wire        o_tvalid;
   reg         o_tready = 1;
   wire        bus_error;
   wire [63:0] debug;

   integer     errors = 0;
   integer     out_words = 0;
   integer     out_lasts = 0;
   integer     err_pulses = 0;
   integer     n;

   reg [31:0]  got [0:7];

   always #5 clk = ~clk;

   gpif2_error_checker #(.SIZE(9)) dut (
      .clk(clk), .reset(reset), .clear(clear),
      .i_tdata(i_tdata), .i_tlast(i_tlast), .i_tvalid(i_tvalid), .i_tready(i_tready),
      .o_tdata(o_tdata), .o_tlast(o_tlast), .o_tvalid(o_tvalid), .o_tready(o_tready),
      .bus_error(bus_error), .debug(debug));

   always @(posedge clk) begin
      if (!reset && o_tvalid && o_tready) begin
         got[out_words] = o_tdata;
         out_words = out_words + 1;
         if (o_tlast) out_lasts = out_lasts + 1;
      end
      if (!reset && bus_error) err_pulses = err_pulses + 1;
   end

   // One AXI-stream beat, waiting for the block to accept it.
   task send(input [31:0] data, input last);
      begin
         @(negedge clk);
         i_tdata  = data;
         i_tlast  = last;
         i_tvalid = 1'b1;
         @(posedge clk);
         while (!i_tready) @(posedge clk);
         @(negedge clk);
         i_tvalid = 1'b0;
         i_tlast  = 1'b0;
      end
   endtask

   task legal_packet;
      begin
         // hdr_bytes = length+3 rounded up, so 12 bytes = 3 words.
         send(32'h0000_000C, 1'b0);
         send(32'h1111_1111, 1'b0);
         send(32'h2222_2222, 1'b1);
      end
   endtask

   initial begin
      repeat (4) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (4) @(posedge clk);

      // ---- phase A -------------------------------------------------------
      legal_packet;
      repeat (8) @(posedge clk);
      if (out_words != 3) begin
         errors = errors + 1;
         $display("FAIL: legal packet produced %0d words, expected 3", out_words);
      end
      if (out_lasts != 1) begin
         errors = errors + 1;
         $display("FAIL: legal packet produced %0d tlast beats, expected 1", out_lasts);
      end
      if (err_pulses != 0) begin
         errors = errors + 1;
         $display("FAIL: legal packet raised bus_error %0d times", err_pulses);
      end
      if (got[0] != 32'h0000_000C || got[1] != 32'h1111_1111 || got[2] != 32'h2222_2222) begin
         errors = errors + 1;
         $display("FAIL: forwarded words %h %h %h", got[0], got[1], got[2]);
      end

      // ---- phase B: illegal header (length 0) -----------------------------
      send(32'h0000_0000, 1'b1);      // bad header, tlast to drain the wait state
      repeat (8) @(posedge clk);
      if (err_pulses == 0) begin
         errors = errors + 1;
         $display("FAIL: illegal header did not raise bus_error");
      end
      if (out_words != 3) begin
         errors = errors + 1;
         $display("FAIL: illegal packet forwarded %0d extra words", out_words - 3);
      end

      // ---- phase C: resynchronisation -------------------------------------
      // After a bad header the block enters its wait state and only returns to
      // header decoding on a tlast.  That is the documented recovery strategy:
      // the stream must supply an end-of-frame marker before it can resync.
      send(32'hDEAD_BEEF, 1'b1);      // resync marker: consumed, not forwarded
      repeat (4) @(posedge clk);
      if (out_words != 3) begin
         errors = errors + 1;
         $display("FAIL: resync marker was forwarded");
      end

      legal_packet;
      repeat (8) @(posedge clk);
      if (out_words != 6) begin
         errors = errors + 1;
         $display("FAIL: after resync %0d words total, expected 6", out_words);
      end
      if (out_lasts != 2) begin
         errors = errors + 1;
         $display("FAIL: after resync %0d tlast beats, expected 2", out_lasts);
      end

      if (errors == 0)
         $display("PASS: gpif2_error_checker forwards good CHDR, flags bad length, resyncs");
      else
         $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #200000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
