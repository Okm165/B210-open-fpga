// tb_tx_pairing.v - the TX packet's sample pairing: every host sample must
// reach the DUC exactly once, in order, including an odd-length packet.
//
// Information flow under test:
//
//   host 64-bit word (high half = earlier sample, low half = later sample)
//     -> new_tx_deframer  (strips header/time, forwards body words)
//     -> new_tx_control   (presents sample0 then sample1 on `sample`,
//                          gated by `run`, advancing on `strobe`)
//     -> DUC              (consumes `sample` on `strobe` while `run`)
//
// The failure classes this catches, all silent at the pins:
//   * a sample duplicated or dropped at a packet boundary,
//   * I/Q swapped (the high half is I, the low half is Q),
//   * the odd-length final word emitting its PAD instead of its sample,
//   * a burst of two packets losing the seam between them.
//
// A sample is tagged {counter[15:0], ~counter[15:0]} so both halves are
// self-checking: I must be the counter, Q must be its complement.
`timescale 1ns/1ps

module tb_tx_pairing;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1, clear = 0;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;

   // deframer input (host side)
   reg  [63:0] i_tdata = 0;
   reg         i_tlast = 0, i_tvalid = 0;
   wire        i_tready;

   // deframer -> control
   wire [175:0] sample_tdata;
   wire         sample_tvalid, sample_tready;
   wire [31:0]  sample;
   wire         run;
   wire         strobe;
   wire         ack_or_error, packet_consumed;
   wire [11:0]  seqnum;
   wire [63:0]  error_code;
   wire [31:0]  sid;

   // deframer
   new_tx_deframer deframer (
      .clk(clk), .reset(rst), .clear(clear),
      .i_tdata(i_tdata), .i_tlast(i_tlast), .i_tvalid(i_tvalid), .i_tready(i_tready),
      .sample_tdata(sample_tdata), .sample_tvalid(sample_tvalid),
      .sample_tready(sample_tready), .debug());

   // control
   new_tx_control #(.BASE(8'd0)) control (
      .clk(clk), .reset(rst), .clear(clear),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(64'd0),
      .ack_or_error(ack_or_error), .packet_consumed(packet_consumed),
      .seqnum(seqnum), .error_code(error_code), .sid(sid),
      .sample_tdata(sample_tdata), .sample_tvalid(sample_tvalid), .sample_tready(sample_tready),
      .sample(sample), .run(run), .strobe(strobe),
      .debug());

   // ---- rate strobe: the DUC would produce this; here once every 8 clocks,
   //      slow enough that the FIFO is always ahead of the consumer -------
   reg [2:0] sp = 0;
   always @(posedge clk) sp <= sp + 3'd1;
   assign strobe = (sp == 3'd0);

   // ---- host driver ----------------------------------------------------
   reg [63:0] hdr;
   integer n, j;
   integer host_n = 0;      // global sample index across packets in a burst

   function [31:0] tag(input integer v);
      tag = {v[15:0], ~v[15:0]};
   endfunction

   task send(input [63:0] d, input last);
      begin
         @(negedge clk);
         i_tdata = d; i_tlast = last; i_tvalid = 1'b1;
         @(posedge clk);
         while (!i_tready) @(posedge clk);
      end
   endtask

   task send_packet(input integer nsamp, input eob, input [11:0] seq);
      integer w, nwords;
      reg [31:0] hi, lo;
      begin
         // Header layout (matches new_rx_framer):
         //   [63:61] type, [60] eob, [59:48] seqnum, [47:34] len[13:0],
         //   [33:32] zero, [31:0] sid.
         // The deframer's `odd` is bit 34, i.e. len[0] - the parity of the
         // sample count.  Driving a truthful length therefore sets it.
         hdr = 64'd0;
         hdr[63:61] = 3'b000;        // no trailer, no time
         hdr[60]    = eob;
         hdr[59:48] = seq;
         hdr[47:34] = nsamp[13:0];
         hdr[31:0]  = 32'hC0FF_EE00;
         send(hdr, 1'b0);

         nwords = (nsamp + 1) / 2;
         for (w = 0; w < nwords; w = w + 1) begin
            hi = tag(host_n);
            host_n = host_n + 1;
            if ((2*w + 1) < nsamp) begin
               lo = tag(host_n);
               host_n = host_n + 1;
            end else
               lo = 32'hDEAD_BEEF;         // pad in the odd final word
            send({hi, lo}, (w == nwords - 1));
         end
         @(negedge clk); i_tvalid = 1'b0; i_tlast = 1'b0;
      end
   endtask

   // ---- checker: record every sample the DUC would consume ------------
   integer expect_n = 0, errors = 0, nseen = 0;

   always @(posedge clk) begin
      if (!rst && run && strobe) begin
         if (sample[31:16] !== expect_n[15:0]) begin
            errors = errors + 1;
            if (errors < 6)
               $display("TX-PAIR: FAIL I at sample %0d: %0d, expected %0d",
                        nseen, $signed(sample[31:16]), expect_n);
         end
         if (sample[15:0] !== ~expect_n[15:0]) begin
            errors = errors + 1;
            if (errors < 6)
               $display("TX-PAIR: FAIL Q at sample %0d: %0h, expected %0h",
                        nseen, sample[15:0], ~expect_n[15:0]);
         end
         expect_n = expect_n + 1;
         nseen = nseen + 1;
      end
   end

   task do_reset;
      begin
         @(negedge clk); rst = 1;
         repeat (4) @(negedge clk);
         @(negedge clk); rst = 0;
         repeat (4) @(negedge clk);
         @(negedge clk); set_stb = 1; set_addr = 8'd0; set_data = 32'd0;
         @(negedge clk); set_stb = 0;
         repeat (4) @(negedge clk);
         expect_n = 0; nseen = 0; host_n = 0;
      end
   endtask

   integer case_start;

   initial begin
      repeat (8) @(posedge clk);
      rst = 0;

      // ---- case 1: one even packet, 8 samples, eob ---------------------
      do_reset;
      send_packet(8, 1'b1, 12'd0);
      repeat (60) @(posedge clk);
      $display("TX-PAIR: even packet 8 samples -> %0d consumed", nseen);
      if (nseen != 8) begin
         errors = errors + 1;
         $display("TX-PAIR: FAIL - even packet delivered %0d of 8", nseen);
      end

      // ---- case 2: one odd packet, 7 samples, eob ----------------------
      do_reset;
      send_packet(7, 1'b1, 12'd0);
      repeat (60) @(posedge clk);
      $display("TX-PAIR: odd packet 7 samples -> %0d consumed", nseen);
      if (nseen != 7) begin
         errors = errors + 1;
         $display("TX-PAIR: FAIL - odd packet delivered %0d of 7 (pad leaked or sample lost)", nseen);
      end

      // ---- case 3: burst of even 6 then odd 5, eob on the last ---------
      do_reset;
      send_packet(6, 1'b0, 12'd0);
      send_packet(5, 1'b1, 12'd1);
      repeat (120) @(posedge clk);
      $display("TX-PAIR: burst 6+5 samples -> %0d consumed", nseen);
      if (nseen != 11) begin
         errors = errors + 1;
         $display("TX-PAIR: FAIL - burst delivered %0d of 11 (seam lost or pad leaked)", nseen);
      end

      if (errors == 0)
         $display("TX-PAIR: PASS - every host sample reaches the DUC once, in order, across even, odd and burst packets");
      else
         $display("TX-PAIR: FAIL - %0d mismatches", errors);
      $finish;
   end

endmodule
