// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_ctrl - command packets -> packet_fifo -> ctrl -> packet_fifo -> results,
// against a reference model of PROTOCOL.md section 4.
//
// The generator builds random command packets and, for each, the result it
// must produce, from a shadow register file updated in command order (ctrl
// is the only writer, so the order is the execution order). Mixed in:
// unknown opcodes (that operation and all later ones answered with status 3
// and not executed), packets cut short (missing operations answered with
// status 3), extra words after the length, and malformed packets (wrong
// version, wrong type, bad length, shorter than a header) that must be
// dropped and counted. The result reader stalls at random.
//
// Register file of the bench: addresses 0..63 read back what was written;
// 0xF0 is a free-running counter (cycle / 10) to POLL on. WAIT is checked
// in cycles: between two register writes the gap must be at least the
// WAITs between them times 100 (cycles per microsecond); within one packet
// at most that plus 12 cycles per operation and 200 per POLL.
//
// FAULT 1: one READ of a plain register returns a flipped bit (must be caught).
// FAULT 2: ctrl believes the clock is 99 MHz: WAITs 1 % short (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_ctrl;
  parameter N = 300, SEED = 1, FAULT = 0;
  localparam MAXOPS = 126;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // -- design -----------------------------------------------------------------------
  wire        c_room, c_avail, c_last, c_take, r_room, r_valid, r_last, q_avail, q_last;
  wire [31:0] c_data, r_data, q_data, dropped;
  reg         w_valid = 0, w_last = 0, q_take = 0;
  reg  [31:0] w_data = 0;
  wire        reg_we, reg_re;
  wire [15:0] reg_addr;
  wire [31:0] reg_wdata;
  reg  [31:0] reg_rdata = 0;

  packet_fifo #(.AW(9), .MAX(256)) cmd (.wclk(clk), .w_rst(rst), .w_room(c_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .rclk(clk), .r_rst(rst), .r_avail(c_avail), .r_data(c_data),
    .r_last(c_last), .r_take(c_take));
  ctrl #(.CLK_MHZ(FAULT == 2 ? 99 : 100)) dut (.clk(clk), .rst(rst),
    .c_avail(c_avail), .c_data(c_data), .c_last(c_last), .c_take(c_take),
    .r_room(r_room), .r_valid(r_valid), .r_last(r_last), .r_data(r_data),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .dropped(dropped));
  packet_fifo #(.AW(9), .MAX(256)) rsp (.wclk(clk), .w_rst(rst), .w_room(r_room), .w_valid(r_valid),
    .w_last(r_last), .w_data(r_data), .rclk(clk), .r_rst(rst), .r_avail(q_avail), .r_data(q_data),
    .r_last(q_last), .r_take(q_take));

  // -- register file ---------------------------------------------------------------
  reg [31:0] regs [0:63];
  integer i, reads = 0;
  reg     faulted = 0;
  initial for (i = 0; i < 64; i = i + 1) regs[i] = 0;
  integer wr_cyc = -1, wr_count = 0;   // when the last register write happened
  always @(posedge clk) begin
    reg_rdata <= 0;
    if (reg_re) begin
      reg_rdata <= reg_addr == 16'hF0 ? cyc / 10 : reg_addr < 64 ? regs[reg_addr] : 32'hDEAD0000 | reg_addr;
      reads = reads + 1;
      if (FAULT == 1 && reads >= 77 && !faulted && reg_addr < 64) begin   // a READ checked exactly
        reg_rdata <= regs[reg_addr] ^ 32'h100; faulted = 1;
      end
    end
    if (reg_we) begin
      if (reg_addr < 64) regs[reg_addr] <= reg_wdata;
      check_gap(cyc);
    end
  end

  // -- reference model and generator ---------------------------------------------------
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction
  reg [31:0] shadow [0:63];
  initial for (i = 0; i < 64; i = i + 1) shadow[i] = 0;

  // expected results, per answered packet p: header and n operations
  integer    exp_n [0:N-1], exp_len [0:N-1], exp_seq [0:N-1];
  reg [31:0] exp_a [0:N*MAXOPS-1], exp_b [0:N*MAXOPS-1];
  reg [1:0]  exp_kind [0:N*MAXOPS-1];   // 0 exact, 1 data not checked, 2 POLL property
  integer    answered = 0, malformed = 0;
  // per register write, in execution order: the least gap after the previous
  // write and, if both are in one packet, the most
  integer    gap_min [0:N*MAXOPS-1], gap_max [0:N*MAXOPS-1];
  integer    writes_expected = 0, gap_lo = 0, gap_hi = -1;

  task check_gap(input integer now);
    integer d;
    begin
      d = now - wr_cyc;
      if (wr_cyc >= 0 && (d < gap_min[wr_count] || (gap_max[wr_count] >= 0 && d > gap_max[wr_count]))) begin
        errors = errors + 1;
        $display("%0t write %0d: %0d cycles after the previous, expected %0d .. %0d", $time, wr_count,
                 d, gap_min[wr_count], gap_max[wr_count]);
      end
      wr_cyc = now; wr_count = wr_count + 1;
    end
  endtask

  // a command packet in words, built by gen()
  reg [31:0] pkt [0:4 + 2*MAXOPS + 8];
  integer    pkt_words;

  // Packet p: first the operations, then what becomes of each:
  //   malformed packet         nothing runs, no answer
  //   cut before the op        {0, 3, 0}, 0
  //   cut inside the op        {opcode, 3, addr}, 0
  //   unknown or after one     {opcode, 3, addr}, 0, not run
  //   else                     runs: shadow registers, WAIT time, result
  task gen(input integer p);
    integer n, k, kind, len, base, skip, cut, addr;
    reg [31:0] a, b;
    reg [3:0]  nib;
    begin
      kind = rnd(12);          // 0 malformed, 1 cut short, 2 extra words, else normal
      n = rnd(8) == 0 ? MAXOPS : rnd(8) == 0 ? 0 : 1 + rnd(12);
      len = 16 + 8 * n;
      pkt[0] = {4'd1, 8'd0, 4'd2, len[15:0]};
      pkt[1] = {16'd0, p[15:0]};
      pkt[2] = 0; pkt[3] = 0;
      for (k = 0; k < n; k = k + 1) begin
        addr = rnd(64);
        case (rnd(20))
          0, 1, 2, 3, 4, 5:   begin a = {8'd1, 8'd0, addr[15:0]}; b = $random(seed); end   // WRITE
          6, 7, 8, 9, 10, 11: begin a = {8'd2, 8'd0, addr[15:0]}; b = 0; end               // READ
          12, 13:             begin a = {8'd4, 24'd0}; b = rnd(21); end                     // WAIT 0..20 us
          14, 15, 16:         if (k + 1 < n) begin                // READ the counter, POLL a nibble (1 ms: matches)
                                pkt[4 + 2*k] = {8'd2, 8'd0, 16'hF0}; pkt[5 + 2*k] = 0;
                                k = k + 1; nib = rnd(16);
                                a = {8'd5, 8'd1, 16'd0}; b = {16'h000F, 12'd0, nib};
                              end else begin a = {8'd2, 8'd0, 16'hF0}; b = 0; end
          17:                 begin a = {8'd5, 24'd0}; b = {16'hFFFF, 16'h1234}; end         // POLL, one try
          default:            begin a = {rnd(2) ? 8'd3 : 8'd7, 8'd0, addr[15:0]}; b = 0; end // unknown
        endcase
        pkt[4 + 2*k] = a; pkt[5 + 2*k] = b;
      end
      pkt_words = 4 + 2 * n;
      cut = 2 * n;
      if (kind == 1 && n > 0) begin cut = rnd(2 * n); pkt_words = 4 + cut; end
      if (kind == 2) for (k = 0; k < 1 + rnd(5); k = k + 1) begin
        pkt[pkt_words] = 32'hEEEE0000 + k; pkt_words = pkt_words + 1;
      end
      if (kind == 0) begin
        case (rnd(4))
          0: pkt[0][31:28] = 4'd2;
          1: pkt[0][19:16] = 4'd0;
          2: pkt[0][15:0]  = len + 4;
          default: pkt_words = 1 + rnd(3);
        endcase
        malformed = malformed + 1;
      end else begin
        base = answered * MAXOPS; skip = 0;
        gap_hi = -1;                       // a new packet: no upper bound across it
        for (k = 0; k < n; k = k + 1) begin
          a = pkt[4 + 2*k]; b = pkt[5 + 2*k]; addr = a[5:0];
          exp_kind[base + k] = 0; exp_b[base + k] = 0;
          if (gap_hi >= 0) gap_hi = gap_hi + 12;
          if (2 * k >= cut)          exp_a[base + k] = {8'd0, 8'd3, 16'd0};
          else if (2 * k + 1 == cut) exp_a[base + k] = {a[31:24], 8'd3, a[15:0]};
          else if (skip || !(a[31:24] == 1 || a[31:24] == 2 || a[31:24] == 4 || a[31:24] == 5)) begin
            skip = 1; exp_a[base + k] = {a[31:24], 8'd3, a[15:0]};
          end else begin
            exp_a[base + k] = {a[31:24], 8'd0, a[15:0]};
            case (a[31:24])
              1: begin
                   shadow[addr] = b;
                   gap_min[writes_expected] = gap_lo; gap_max[writes_expected] = gap_hi;
                   writes_expected = writes_expected + 1; gap_lo = 0; gap_hi = 0;
                 end
              2: if (a[15:0] == 16'hF0) exp_kind[base + k] = 1; else exp_b[base + k] = shadow[addr];
              4: begin gap_lo = gap_lo + 100 * b; if (gap_hi >= 0) gap_hi = gap_hi + 100 * b; end
              5: begin exp_kind[base + k] = 2; exp_b[base + k] = b; if (gap_hi >= 0) gap_hi = gap_hi + 200; end
            endcase
          end
        end
        exp_n[answered] = n; exp_len[answered] = len; exp_seq[answered] = p;
        answered = answered + 1;
      end
    end
  endtask

  // -- send ---------------------------------------------------------------------------
  integer sent = 0, w;
  initial begin
    wait (!rst);
    for (sent = 0; sent < N; sent = sent + 1) begin
      gen(sent);
      @(posedge clk);
      while (!c_room) @(posedge clk);
      for (w = 0; w < pkt_words; w = w + 1) begin
        w_valid <= 1; w_data <= pkt[w]; w_last <= w == pkt_words - 1;
        @(posedge clk);
      end
      w_valid <= 0; w_last <= 0;
      repeat (rnd(30)) @(posedge clk);
    end
  end

  // -- receive and check ------------------------------------------------------------
  integer got = 0, j = 0, x;
  reg [31:0] rx [0:4 + 2*MAXOPS];
  always @(posedge clk) begin
    if (q_take) begin
      rx[j] = q_data;
      j = j + 1;
      if (q_last) begin check(got, j); got = got + 1; j = 0; end
    end
    q_take <= q_avail && !(q_take && q_last) && rnd(4) != 0;
  end

  task check(input integer p, input integer words);
    integer k, base;
    reg [31:0] e;
    begin
      base = p * MAXOPS;
      if (words != 4 + 2 * exp_n[p] || rx[0] !== {4'd1, 8'd0, 4'd3, exp_len[p][15:0]} || rx[1] !== exp_seq[p]) begin
        errors = errors + 1;
        $display("%0t result %0d: %0d words, header %h %h, expected %0d words, length %0d, sequence %0d",
                 $time, p, words, rx[0], rx[1], 4 + 2 * exp_n[p], exp_len[p], exp_seq[p]);
      end else for (k = 0; k < exp_n[p]; k = k + 1) begin
        x = exp_kind[base + k];
        e = exp_b[base + k];
        // POLL (kind 2): status 0 exactly when the value matches, else 1
        if ((x == 2 ? {rx[4 + 2*k][31:24], rx[4 + 2*k][15:0]} !== {exp_a[base + k][31:24], exp_a[base + k][15:0]}
                    : rx[4 + 2*k] !== exp_a[base + k])
            || (x == 0 && rx[5 + 2*k] !== e)
            || (x == 2 && rx[4 + 2*k][23:16] !== (((rx[5 + 2*k][15:0] & e[31:16]) == e[15:0]) ? 8'd0 : 8'd1))) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t result %0d op %0d: %h %h, expected %h %h (kind %0d)", $time, p, k,
                                    rx[4 + 2*k], rx[5 + 2*k], exp_a[base + k], e, x);
        end
      end
    end
  endtask

  // -- run --------------------------------------------------------------------------------
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    wait (sent == N);
    while (got < answered && cyc < 50_000_000) @(posedge clk);
    repeat (100) @(posedge clk);
    if (got != answered) begin errors = errors + 1; $display("%0d results of %0d", got, answered); end
    if (dropped != malformed) begin errors = errors + 1; $display("dropped %0d, malformed %0d", dropped, malformed); end
    if (wr_count != writes_expected) begin errors = errors + 1; $display("%0d writes, expected %0d", wr_count, writes_expected); end
    for (i = 0; i < 64; i = i + 1) if (regs[i] !== shadow[i]) begin
      errors = errors + 1; $display("register %0d = %h, expected %h", i, regs[i], shadow[i]);
    end
    $display("%0d packets: %0d answered, %0d dropped; %0d register writes", N, got, dropped, wr_count);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
