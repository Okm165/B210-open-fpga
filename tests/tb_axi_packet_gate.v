//
// axi_packet_gate: buffering, backpressure and the error-drop path.
//
// This gate sits between the GPIF stream and the CHDR framer, so its contract
// decides whether a frame can be corrupted in transit:
//
//   * a packet is held in the buffer until it is complete, so a slow consumer
//     cannot tear a frame in half;
//   * with o_tready low nothing leaves, and when it rises the packet appears
//     contiguously with o_tvalid never dropping mid-frame;
//   * a packet whose last word carries i_terror is dropped, not forwarded.
//
// gpif2_error_checker ties i_terror low (there is no error source upstream),
// so this is the only bench that exercises the drop path at all.
//
`timescale 1ns/1ps

module tb_axi_packet_gate;

   localparam WIDTH = 32;
   localparam SIZE  = 4;      // 16 lines of buffer

   reg          clk = 0;
   reg          reset = 1;
   reg          clear = 0;
   reg  [WIDTH-1:0] i_tdata = 0;
   reg          i_tlast = 0;
   reg          i_terror = 0;
   reg          i_tvalid = 0;
   wire         i_tready;
   wire [WIDTH-1:0] o_tdata;
   wire         o_tlast;
   wire         o_tvalid;
   reg          o_tready = 0;

   integer      errors = 0;
   integer      words_out = 0;
   integer      lasts_out = 0;
   integer      valid_drops = 0;
   reg          seen_valid = 0;

   always #5 clk = ~clk;

   axi_packet_gate #(.WIDTH(WIDTH), .SIZE(SIZE), .USE_AS_BUFF(1'b0)) dut (
      .clk(clk), .reset(reset), .clear(clear),
      .i_tdata(i_tdata), .i_tlast(i_tlast), .i_terror(i_terror),
      .i_tvalid(i_tvalid), .i_tready(i_tready),
      .o_tdata(o_tdata), .o_tlast(o_tlast), .o_tvalid(o_tvalid), .o_tready(o_tready));

   always @(posedge clk) begin
      if (!reset && o_tvalid && o_tready) begin
         words_out = words_out + 1;
         if (o_tlast) lasts_out = lasts_out + 1;
      end
      // o_tvalid must not be withdrawn in the middle of a packet.
      if (!reset) begin
         if (o_tvalid) seen_valid = 1;
         else if (seen_valid && !o_tlast) valid_drops = valid_drops + 1;
      end
   end

   task send(input [WIDTH-1:0] data, input last, input terror);
      begin
         @(negedge clk);
         i_tdata  = data;
         i_tlast  = last;
         i_terror = terror;
         i_tvalid = 1'b1;
         @(posedge clk);
         while (!i_tready) @(posedge clk);
         @(negedge clk);
         i_tvalid = 1'b0;
         i_tlast  = 1'b0;
         i_terror = 1'b0;
      end
   endtask

   initial begin
      repeat (4) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (4) @(posedge clk);

      // ---- phase A: buffer a packet while the consumer is stalled ----------
      o_tready = 1'b0;
      send(32'hAAAA_0001, 1'b0, 1'b0);
      send(32'hAAAA_0002, 1'b0, 1'b0);
      send(32'hAAAA_0003, 1'b1, 1'b0);
      repeat (8) @(posedge clk);
      if (words_out != 0) begin
         errors = errors + 1;
         $display("FAIL: %0d words left the gate with o_tready low", words_out);
      end

      // Release the consumer: the whole packet must come out, in order.
      o_tready = 1'b1;
      repeat (12) @(posedge clk);
      if (words_out != 3) begin
         errors = errors + 1;
         $display("FAIL: buffered packet produced %0d words, expected 3", words_out);
      end
      if (lasts_out != 1) begin
         errors = errors + 1;
         $display("FAIL: buffered packet produced %0d tlast beats, expected 1", lasts_out);
      end

      // ---- phase B: a packet with terror on its last word is dropped ------
      words_out = 0; lasts_out = 0;
      send(32'hBBBB_0001, 1'b0, 1'b0);
      send(32'hBBBB_0002, 1'b1, 1'b1);      // error flag on the final word
      repeat (12) @(posedge clk);
      if (words_out != 0) begin
         errors = errors + 1;
         $display("FAIL: errored packet forwarded %0d words", words_out);
      end

      // ---- phase C: the gate still works after a drop ---------------------
      send(32'hCCCC_0001, 1'b0, 1'b0);
      send(32'hCCCC_0002, 1'b1, 1'b0);
      repeat (12) @(posedge clk);
      if (words_out != 2) begin
         errors = errors + 1;
         $display("FAIL: after a drop %0d words forwarded, expected 2", words_out);
      end
      if (lasts_out != 1) begin
         errors = errors + 1;
         $display("FAIL: after a drop %0d tlast beats, expected 1", lasts_out);
      end

      if (valid_drops != 0) begin
         errors = errors + 1;
         $display("FAIL: o_tvalid dropped mid-packet %0d times", valid_drops);
      end

      if (errors == 0)
         $display("PASS: axi_packet_gate buffers, holds tvalid, drops errored packets");
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
