// tb_rx_framer.v — VITA framing: samples in, packets out.
//
// Exercises new_rx_framer (the block that turns the DDC sample stream into
// CHDR/VITA packets for the FX3).  Nothing tested this path before; it was
// only ever elaborated.
//
// The packet the design emits for 8 samples is six 64-bit words:
//
//   word 0  header : {3'b001, eob, seq[11:0], len[13:0], 2'b0, sid[31:0]}
//   word 1  time   : the vita_time latched at the start of the packet
//   word 2..5 body : two 32-bit samples per word, tlast on the last word
//
// `len` is emitted as `len[13:0] << 2` in the 16-bit size field.  For this
// packet that is 48, i.e. the packet size in bytes (12 32-bit words).  The
// test records that value explicitly so a change in the convention breaks the
// test instead of the host.
`timescale 1ns/1ps

module tb_rx_framer;

   localparam integer NSAMP = 8;

   reg                clk = 0;
   reg                reset = 1;
   reg                clear = 0;
   reg                run = 0;
   reg                strobe = 0;
   reg                eob = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [63:0]        vita_time = 64'h1122334455667788;
   reg  [31:0]        sample = 0;

   wire               full;
   wire [11:0]        seqnum;
   wire [31:0]        sid;
   wire [63:0]        o_tdata;
   wire               o_tlast, o_tvalid;
   reg                o_tready = 1;
   wire [31:0]        debug;

   integer            errors = 0;
   integer            n, got = 0;
   reg [63:0]         words [0:15];
   reg                lasts [0:15];

   always #5 clk = ~clk;

   new_rx_framer #(.BASE(0), .SAMPLE_FIFO_SIZE(10)) dut (
      .clk(clk), .reset(reset), .clear(clear),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time), .strobe(strobe), .sample(sample),
      .run(run), .eob(eob), .full(full), .seqnum(seqnum), .sid(sid),
      .o_tdata(o_tdata), .o_tlast(o_tlast), .o_tvalid(o_tvalid),
      .o_tready(o_tready), .debug(debug)
   );

   task check(input cond, input [8*64-1:0] what);
      begin
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", what);
         end
      end
   endtask

   task set_reg(input [7:0] addr, input [31:0] data);
      begin
         @(posedge clk);
         set_stb  <= 1'b1;
         set_addr <= addr;
         set_data <= data;
         @(posedge clk);
         set_stb  <= 1'b0;
      end
   endtask

   always @(posedge clk)
     if (o_tvalid && o_tready) begin
        words[got] = o_tdata;
        lasts[got] = o_tlast;
        got = got + 1;
     end

   initial begin
      repeat (6) @(posedge clk);
      reset <= 1'b0;
      repeat (4) @(posedge clk);

      set_reg(8'd0, NSAMP);          // maxlen, in samples
      set_reg(8'd1, 32'h00000042);   // stream id
      run <= 1'b1;
      repeat (4) @(posedge clk);

      // Eight samples, eob on the last one.
      for (n = 0; n < NSAMP; n = n + 1) begin
         @(negedge clk);
         strobe <= 1'b1;
         sample <= 32'h1000 + n;
         eob    <= (n == NSAMP - 1);
         @(posedge clk);
         @(negedge clk);
         strobe <= 1'b0;
         eob    <= 1'b0;
      end

      repeat (200) @(posedge clk);

      $display("  captured %0d word(s), seqnum=%0d", got, seqnum);
      for (n = 0; n < got; n = n + 1)
        $display("  word %0d: %h tlast=%b", n, words[n], lasts[n]);

      check(got == 6,                     "six words: header, time, four body words");
      check(words[0][63:61] === 3'b001,   "header type is 001 (data)");
      check(words[0][60] === 1'b1,        "EOB is set on the last packet");
      check(words[0][59:48] === 12'd0,    "sequence number starts at zero");
      check(words[0][47:32] === 16'd48,   "length field is the packet size in bytes");
      check(words[0][31:0] === 32'h42,    "stream id matches the setting");
      check(words[1] === 64'h1122334455667788, "time word carries vita_time");
      check(words[2] === {32'h1000, 32'h1001}, "body word 0 packs samples 0 and 1");
      check(words[3] === {32'h1002, 32'h1003}, "body word 1 packs samples 2 and 3");
      check(words[4] === {32'h1004, 32'h1005}, "body word 2 packs samples 4 and 5");
      check(words[5] === {32'h1006, 32'h1007}, "body word 3 packs samples 6 and 7");
      check(lasts[5] === 1'b1,            "tlast on the last body word only");
      check(lasts[0] === 1'b0 && lasts[1] === 1'b0 && lasts[2] === 1'b0,
            "no tlast on header, time or first body word");
      check(seqnum === 12'd1,             "sequence number increments once per packet");

      if (errors == 0) $display("PASS: rx framer builds a six-word packet (14 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #200000;
      $display("FAIL: timeout after %0d words", got);
      $finish;
   end

endmodule
