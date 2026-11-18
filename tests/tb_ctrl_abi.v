// Self-checking bench for the control-packet ABI (radio_ctrl_proc).
//
// Verifies, on the real RTL:
//   1. an untimed setting write reaches the settings bus with the right
//      address and data, and produces the documented 3-word response;
//   2. a timestamp in the past executes immediately;
//   3. a timestamp in the future holds the command until time catches up.
//
// Expected response header layout (chapter 14):
//   { 4'hA, seq[11:0], 16'd24, sid[15:0], sid[31:16] }
//
`timescale 1ns/1ps

module tb_ctrl_abi;

   reg         clk = 0;
   reg         reset = 1;
   reg         clear = 0;

   reg  [63:0] ctrl_tdata = 0;
   reg         ctrl_tlast = 0;
   reg         ctrl_tvalid = 0;
   wire        ctrl_tready;

   wire [63:0] resp_tdata;
   wire        resp_tlast;
   wire        resp_tvalid;
   reg         resp_tready = 1;

   reg  [63:0] vita_time = 64'h1234;

   wire        set_stb;
   wire [7:0]  set_addr;
   wire [31:0] set_data;

   reg         ready = 1;
   reg  [63:0] readback = 64'hAAAABBBBCCCCDDDD;
   wire [31:0] debug;

   integer     errors = 0;
   integer     strobes = 0;
   reg [7:0]   cap_addr;
   reg [31:0]  cap_data;
   reg [63:0]  resp_words [0:8];
   integer     resp_n = 0;

   always #5 clk = ~clk;

   radio_ctrl_proc dut (
      .clk(clk), .reset(reset), .clear(clear),
      .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast),
      .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast),
      .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
      .vita_time(vita_time),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ready(ready), .readback(readback), .debug(debug));

   // settings-bus capture
   always @(posedge clk) begin
      if (set_stb) begin
         strobes  <= strobes + 1;
         cap_addr <= set_addr;
         cap_data <= set_data;
      end
      if (resp_tvalid && resp_tready) begin
         if (resp_n < 9) resp_words[resp_n] <= resp_tdata;
         resp_n <= resp_n + 1;
      end
   end

   task check(input cond, input [8*96-1:0] msg);
      begin
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
         end
      end
   endtask

   // drive one word and hold until accepted
   task send(input [63:0] w, input last);
      begin
         @(negedge clk);
         ctrl_tdata = w; ctrl_tlast = last; ctrl_tvalid = 1;
         @(posedge clk);
         while (!ctrl_tready) @(posedge clk);
         @(negedge clk);
         ctrl_tvalid = 0;
         ctrl_tlast  = 0;
      end
   endtask

   // request header: bit63 = IS_EC, bit61 = HAS_TIME, [59:48] = seq, [31:0] = SID
   function [63:0] req(input has_time, input [11:0] seq, input [31:0] sid);
      begin
         req = {1'b1, 1'b0, has_time, 1'b0, seq, 16'h0000, sid};
      end
   endfunction

   initial begin
      repeat (3) @(posedge clk);
      reset = 0;
      repeat (2) @(posedge clk);

      // ---------------------------------------------------------------- test 1
      // untimed write: addr 24, data 0xDEADBEEF, SID 0x40, seq 0x5A5
      $display("[1] untimed control packet");
      send(req(1'b0, 12'h5A5, 32'h40), 1'b0);
      send({16'h0, 8'd24, 32'hDEADBEEF}, 1'b1);
      repeat (6) @(posedge clk);

      check(strobes == 1,                 "one settings strobe");
      check(cap_addr == 8'd24,            "address is 24 (SR_CORE_COMPAT)");
      check(cap_data == 32'hDEADBEEF,     "data is 0xDEADBEEF");
      check(resp_n == 3,                  "three response words");
      check(resp_words[0] == 64'hA5A5001800400000, "response header: type A, seq echo, size 24, SID flipped");
      check(resp_words[1] == 64'h0000000000001234, "response time = vita_time at strobe");
      check(resp_words[2] == 64'hAAAABBBBCCCCDDDD, "response data = readback");

      // ---------------------------------------------------------------- test 2
      // timed write in the past: addr 16, SID 0x20, seq 0x123
      $display("[2] timed control packet, timestamp in the past");
      resp_n = 0;
      send(req(1'b1, 12'h123, 32'h20), 1'b0);
      send(64'h0000000000000000, 1'b0);           // time word: 0 < vita_time
      send({16'h0, 8'd16, 32'hC0FFEE00}, 1'b1);
      repeat (6) @(posedge clk);

      check(strobes == 2,             "second strobe fired");
      check(cap_addr == 8'd16,        "address is 16 (SR_CORE_MISC)");
      check(cap_data == 32'hC0FFEE00, "data is 0xC0FFEE00");
      check(resp_n == 3,              "three response words");
      check(resp_words[0] == 64'hA123001800200000, "timed response header seq 0x123, SID 0x20 flipped");
      check(resp_tlast === 1'b0,      "no lingering tlast");

      // ---------------------------------------------------------------- test 3
      // future timestamp must hold
      $display("[3] timed control packet, timestamp in the future");
      resp_n = 0;
      send(req(1'b1, 12'h7C0, 32'h10), 1'b0);

      @(negedge clk);
      ctrl_tdata = {32'd0, 32'h1234 + 32'd100};  // future time
      ctrl_tlast = 1'b0; ctrl_tvalid = 1'b1;
      repeat (6) @(posedge clk);
      check(strobes == 2, "command held while time is in the future");
      check(ctrl_tready == 1'b0, "controller back-pressures the time word");

      vita_time = 64'h1234 + 64'd100;            // time catches up
      @(posedge clk);                            // time word accepted
      @(negedge clk); ctrl_tvalid = 1'b0;

      send({16'h0, 8'd10, 32'h5A5A1234}, 1'b1);
      repeat (6) @(posedge clk);

      check(strobes == 3,             "command fired after the timestamp");
      check(cap_addr == 8'd10,        "address is 10 (SPI data register)");
      check(cap_data == 32'h5A5A1234, "data is 0x5A5A1234");
      check(resp_n == 3,              "three response words");
      $display("    actual header: %016x", resp_words[0]);
      check(resp_words[0] == 64'hA7C0001800100000, "response header seq 0x7C0, SID 0x10 flipped");

      // ---------------------------------------------------------------- result
      if (errors == 0) $display("PASS: control ABI (3 packets, %0d checks)", 3 * 6);
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #200000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
