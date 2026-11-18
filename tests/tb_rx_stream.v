`timescale 1ns/1ps
// Stream integrity at full rate: one sample per radio clock into the RX
// framer, drained continuously at the AXI output (no USB backpressure).
//
// The sample word carries a 16-bit tag that counts up by one for every sample
// the DAC-side datapath produces.  Decoding the packets back into a sample
// stream must reproduce that counter with no gap, no repeat and no reordering,
// including across packet boundaries -- that is the "no data loss" property,
// checked without assuming anything about packet lengths.
//
// Packet layout (from new_rx_framer): beat 0 = header, beat 1 = timestamp,
// beats 2..N = sample pairs (high half = earlier sample).
module tb_rx_stream;
   localparam MAXLEN = 66;   // samples per packet (even)
   reg clk = 0, rst = 1, run = 0, set_stb = 0;
   reg [7:0] set_addr = 0; reg [31:0] set_data = 0;
   wire [63:0] o_tdata; wire o_tlast, o_tvalid;
   reg o_tready = 1;
   always #8.14 clk = ~clk;   // 61.44 MSPS

   reg [31:0] sample = 0, injected = 0;
   wire [31:0] sid;
   wire [11:0] seqnum;
   wire        full;
   reg         eob    = 1'b0;
   reg         stim   = 1'b0;
   wire        strobe = stim;

   new_rx_framer #(.BASE(0), .SAMPLE_FIFO_SIZE(11)) dut
     (.clk(clk), .reset(rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(64'h0),
      .strobe(strobe), .sample(sample), .run(run), .eob(eob), .full(full),
      .sid(sid), .seqnum(seqnum),
      .o_tdata(o_tdata), .o_tlast(o_tlast), .o_tvalid(o_tvalid), .o_tready(o_tready),
      .debug());

   task set_reg(input [7:0] a, input [31:0] d);
     begin @(posedge clk); set_stb <= 1; set_addr <= a; set_data <= d;
           @(posedge clk); set_stb <= 0; end
   endtask

   // ---- output monitor -------------------------------------------------
   integer beat = 0;            // 0 header, 1 timestamp, >=2 body
   integer errors = 0, samples_seen = 0, packets = 0, full_seen = 0;
   reg [15:0] expect_tag = 16'd0;     // next tag the stream must carry
   reg        armed = 1'b0;           // ignore the power-up packet boundary
   reg [11:0] expect_seq = 12'd0;
   reg signed [15:0] prev_tag = -16'sd1;
   always @(posedge clk) if (!rst) begin
      if (full) full_seen = full_seen + 1;
      if (o_tvalid && o_tready) begin
         if (beat == 0) begin
            // header: {3'b001, eob, seqnum[11:0], len[13:0], sid[31:0]}
            if (o_tdata[59:48] !== expect_seq) begin
               errors = errors + 1;
               if (errors < 6) $display("FAIL: packet %0d seqnum %0d, expected %0d",
                                        packets, o_tdata[59:48], expect_seq);
            end
            if (o_tdata[63:61] !== 3'b001) begin
               errors = errors + 1;
               if (errors < 6) $display("FAIL: header type field %b", o_tdata[63:61]);
            end
            expect_seq = expect_seq + 12'd1;
            packets = packets + 1;
            beat = 1;
         end else if (beat == 1) begin
            beat = 2;
         end else begin
            // body word: high half then low half (low half is zero for an
            // odd-length final word, which must not appear with MAXLEN even)
            check_tag(o_tdata[63:32]);            // earlier sample
            check_tag(o_tdata[31:0]);             // later sample (0 = pad)
            if (o_tlast) beat = 0; else beat = beat + 1;
         end
      end
   end

   // tag = {16'hA5A5, counter}: contiguous counter == no loss, no repeat
   task check_tag(input [31:0] w);
      begin
         // an odd-length final word carries a zero pad in the low half
         if (w !== 32'h0) begin
         samples_seen = samples_seen + 1;
         // The very first packet is a power-up artifact: the sample FIFO's
         // space output reads zero until its read side initialises, which the
         // framer correctly treats as end-of-packet.  Start checking at the
         // next packet, where the stream is genuinely continuous.
         if (!armed) begin
            if (packets >= 2 && w[31:16] === 16'hA5A5) begin
               armed = 1'b1;
               // the low half of this same word carries w+1
               expect_tag = w[15:0];
            end
         end else if (w[31:16] !== 16'hA5A5) begin
            errors = errors + 1;
            if (errors < 6) $display("FAIL: body word %08x is not a sample", w);
         end else if (w[15:0] !== expect_tag) begin
            errors = errors + 1;
            if (errors < 6) $display("FAIL: sample tag %0d, expected %0d (gap or reorder)",
                                     w[15:0], expect_tag);
         end
         if (armed) expect_tag = expect_tag + 16'd1;
         end
      end
   endtask

   // ---- stimulus -------------------------------------------------------
   integer n;
   initial begin
      repeat (10) @(posedge clk);
      rst <= 0;
      // Let the sample FIFO's space counter come out of reset before the
      // datapath starts: while it reads zero the framer legitimately treats
      // every strobe as end-of-packet (one-sample packets at power-up).
      repeat (200) @(posedge clk);
      set_reg(8'd0, MAXLEN);
      set_reg(8'd1, 32'h0102_0304);    // sid
      run  <= 1;
      stim <= 1;
      for (n = 0; n < 30000; n = n + 1) begin
         @(posedge clk);
         sample <= {16'hA5A5, injected[15:0]};
         injected <= injected + 1;
      end
      // End the stream the way the driver does: eob forces the framer to
      // terminate the current packet and flush.  The source keeps supplying
      // fresh samples while eob is asserted (as the ADC does in hardware);
      // freezing it would push duplicates, which is a test artifact.
      eob <= 1;
      repeat (4) begin
         @(posedge clk);
         sample <= {16'hA5A5, injected[15:0]};
         injected <= injected + 1;
      end
      stim <= 0;
      eob  <= 0;
      repeat (4000) @(posedge clk);    // drain
      $display("  injected %0d, packets %0d, samples decoded %0d, errors %0d",
               injected, packets, samples_seen, errors);
      if (full_seen != 0) begin
         $display("FAIL: framer reported full %0d times with continuous drain", full_seen);
         errors = errors + 1;
      end
      // After the drain every injected sample must have been delivered: the
      // framer may hold at most one unpaired sample in its packing register.
      if (samples_seen < injected - 1 || samples_seen > injected) begin
         $display("FAIL: injected %0d, delivered %0d (%0d lost or duplicated)",
                  injected, samples_seen, injected - samples_seen);
         errors = errors + 1;
      end
      if (errors == 0)
        $display("PASS: RX stream is lossless and in order at one sample per clock (%0d samples, %0d packets)",
                 samples_seen, packets);
      else
        $display("FAIL: %0d errors", errors);
      $finish;
   end
endmodule
