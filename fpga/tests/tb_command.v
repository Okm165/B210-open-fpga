// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_command - command packets -> packet_fifo -> command (+ spi_master) ->
// packet_fifo -> results, against a reference model of PROTOCOL.md section
// 4, with the two SPI devices modelled at the pins (spi_model.v, data-sheet
// timing checked on every edge).
//
// The generator builds random command packets and, for each, the result it
// must produce, from shadow state updated in command order (command is the
// only writer, so the order is the execution order): the register file,
// the AD9361's registers, the list of words the ADF4001 latches, and the
// operation POLL repeats (the last READ or SPI executed). Mixed in:
// unknown opcodes and SPI to a device other than 0 and 1 (that operation
// and all later ones answered with status 3 and not executed), packets cut
// short (missing operations answered with status 3), extra words after the
// length (up to 256 words in all, the FX3 control buffer), and malformed packets (wrong version, wrong type, bad length,
// shorter than a header) that must be dropped and counted. The result
// reader stalls at random.
//
// Register file of the bench: addresses 0..63 read back what was written;
// 0xF0 is a free-running counter (cycle / 10) to POLL on. AD9361: SPI
// writes and reads of random registers (the read must return the shadow
// byte exactly), POLL over an SPI read (once with an exact expected value
// and status, and until a nibble of the model's counter register 0x3FF
// matches), POLL after any other SPI (repeats it: an ADF4001 word is
// latched twice). At the end the model's register file must equal the
// shadow and the ADF4001's latched words the expected list, in order.
// Timing: between two register writes the gap must be at least the WAITs
// between them times 100 (cycles per microsecond) plus 50 half periods per
// SPI frame; within one packet at most that plus 12 cycles per operation,
// 200 per POLL of a register and the bound of each POLL over SPI.
// H0, H1: the SPI master's half periods (bus cycles) for the AD9361 and the
// ADF4001 (the design's are 50 and 5000).
//
// FAULT 1: one READ of a plain register returns a flipped bit (must be caught).
// FAULT 2: command believes the clock is 99 MHz: WAITs 1 % short (must be caught).
// FAULT 3: AD9361 words go out LSB first (must be caught).
// FAULT 4: the 6th AD9361 frame is cut after 23 bits (must be caught).
// FAULT 5: AD9361 MOSI reaches the pin 1.5 H0 cycles late: it changes on the
//          falling edge the AD9361 samples on (must be caught).
// FAULT 6: AD9361 MISO arrives H0 cycles late: the master takes each bit
//          half an SCLK period early (must be caught).
// FAULT 7: ADF4001 DATA reaches the pin H1 / 2 cycles late: it changes on
//          the rising edge the ADF4001 samples on (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_command;
  parameter N = 300, SEED = 1, FAULT = 0, H0 = 4, H1 = 6;
  localparam MAXOPS = 126;
  localparam integer CNT_CYC = 64 * H0;        // the model's counter: one step per 64 H0 cycles, longer than a frame
  localparam integer FRAME0 = 50 * H0, FRAME1 = 50 * H1;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // -- design -----------------------------------------------------------------------
  wire        cmd_room, cmd_avail, cmd_last, cmd_take, res_room, res_valid, res_last, q_avail, q_last;
  wire [31:0] cmd_data, res_data, q_data, cmd_dropped;
  reg         w_valid = 0, w_last = 0, q_take = 0;
  reg  [31:0] w_data = 0;
  wire        reg_we, reg_re;
  wire [15:0] reg_addr;
  wire [31:0] reg_wdata;
  reg  [31:0] reg_rdata = 0;
  wire        spi_start, spi_dev, spi_done;
  wire [23:0] spi_word;
  wire [7:0]  spi_rdata;
  wire        cat_ce, cat_sclk, cat_mosi, pll_ce, pll_sclk, pll_mosi;
  wire        cat_miso;

  packet_fifo #(.AW(9), .MAX(256)) cmd (.clk(clk), .rst(rst), .w_room(cmd_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .w_used(),  .r_avail(cmd_avail), .r_data(cmd_data),
    .r_last(cmd_last), .r_take(cmd_take), .r_used());
  command #(.CLK_MHZ(FAULT == 2 ? 99 : 100)) dut (.clk(clk), .rst(rst),
    .r_avail(cmd_avail), .r_data(cmd_data), .r_last(cmd_last), .r_take(cmd_take),
    .w_room(res_room), .w_valid(res_valid), .w_last(res_last), .w_data(res_data),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .spi_start(spi_start), .spi_dev(spi_dev), .spi_word(spi_word), .spi_done(spi_done), .spi_rdata(spi_rdata),
    .cmd_dropped(cmd_dropped));
  packet_fifo #(.AW(9), .MAX(256)) rsp (.clk(clk), .rst(rst), .w_room(res_room), .w_valid(res_valid),
    .w_last(res_last), .w_data(res_data), .w_used(),  .r_avail(q_avail), .r_data(q_data),
    .r_last(q_last), .r_take(q_take), .r_used());

  function [23:0] rev24(input [23:0] w);
    integer j;
    for (j = 0; j < 24; j = j + 1) rev24[j] = w[23 - j];
  endfunction
  spi_master #(.HALF0(H0), .HALF1(H1)) sp (.clk(clk), .rst(rst), .start(spi_start), .dev(spi_dev),
    .word(FAULT == 3 && !spi_dev ? rev24(spi_word) : spi_word), .done(spi_done), .rdata(spi_rdata),
    .cat_ce(cat_ce), .cat_sclk(cat_sclk), .cat_mosi(cat_mosi), .cat_miso(cat_miso),
    .pll_ce(pll_ce), .pll_sclk(pll_sclk), .pll_mosi(pll_mosi));

  // -- the SPI devices, at the pins, with the faults between ----------------------------
  reg  cut = 0;                     // FAULT 4: CS forced high
  integer f_frames = 0, f_falls = 0;
  always @(negedge cat_sclk) if (!cat_ce) begin
    f_falls = f_falls + 1;
    if (FAULT == 4 && f_frames == 5 && f_falls == 23) cut = 1;
  end
  always @(posedge cat_ce) begin f_frames = f_frames + 1; f_falls = 0; cut = 0; end
  reg  m_mosi = 0, p_mosi = 0;
  wire m_miso;
  reg  d_miso = 0;
  always @(cat_mosi) m_mosi <= #(FAULT == 5 ? 15.0 * H0 : 0.0) cat_mosi;
  always @(pll_mosi) p_mosi <= #(FAULT == 7 ? 5.0 * H1 : 0.0) pll_mosi;
  always @(m_miso)   d_miso <= #(FAULT == 6 ? 10.0 * H0 : 0.0) m_miso;
  assign cat_miso = d_miso;
  pulldown (m_miso);                // SPI_DO released: the bench reads 0
  ad9361_spi_model #(.CNT_NS(10.0 * CNT_CYC)) ad (.ce(cat_ce | cut), .sclk(cat_sclk), .mosi(m_mosi), .miso(m_miso));
  adf4001_model pll (.le(pll_ce), .clk(pll_sclk), .data(p_mosi));
  integer both = 0;
  always @(cat_ce or pll_ce) if (!cat_ce && !pll_ce) both = both + 1;

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
  reg [7:0]  shadow9361 [0:1023];
  reg [23:0] adf_exp [0:4095];
  integer    adf_n = 0;
  initial begin
    for (i = 0; i < 64; i = i + 1) shadow[i] = 0;
    for (i = 0; i < 1024; i = i + 1) shadow9361[i] = 0;
  end
  // what POLL repeats: 0 READ of prev_addr, 1 SPI of prev_word to prev_dev
  reg        prev_spi = 0, prev_dev = 0;
  reg [15:0] prev_addr = 0;
  reg [23:0] prev_word = 0;
  // coverage: every kind must have run, or the bench proves nothing about it
  integer    n_spi_wr = 0, n_spi_rd = 0, n_adf = 0, n_poll_exact = 0, n_poll_cnt = 0, n_poll_rep = 0, n_bad_dev = 0;

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

  // the effect of one executed SPI frame (an operation or a POLL's try) on
  // the shadow state, and the byte it reads back
  task spi_effect(input dev, input [23:0] w, output [7:0] v);
    begin
      v = 0;
      if (dev) begin adf_exp[adf_n] = w; adf_n = adf_n + 1; end
      else if (w[23]) shadow9361[w[17:8]] = w[7:0];
      else v = shadow9361[w[17:8]];
    end
  endtask

  // a command packet in words, built by gen()
  reg [31:0] pkt [0:4 + 2*MAXOPS + 8];
  integer    pkt_words;
  reg        patch [0:MAXOPS-1];       // a POLL whose value is chosen when the shadow is known

  // Packet p: first the operations, then what becomes of each:
  //   malformed packet         nothing runs, no answer
  //   cut before the op        {0, 3, 0}, 0
  //   cut inside the op        {opcode, 3, addr}, 0
  //   unknown or after one     {opcode, 3, addr}, 0, not run
  //   else                     runs: shadow state, timing, result
  task gen(input integer p);
    integer n, k, kind, len, base, skip, cut, addr, sa, fr, tries;
    reg [31:0] a, b;
    reg [3:0]  nib;
    reg [7:0]  v, st, r1, r2, op;
    begin
      kind = rnd(12);          // 0 malformed, 1 cut short, 2 extra words, else normal
      n = rnd(8) == 0 ? MAXOPS : rnd(8) == 0 ? 0 : 1 + rnd(12);
      len = 16 + 8 * n;
      pkt[0] = {4'd1, 8'd0, 4'd2, len[15:0]};
      pkt[1] = {16'd0, p[15:0]};
      pkt[2] = 0; pkt[3] = 0;
      for (k = 0; k < n; k = k + 1) patch[k] = 0;
      for (k = 0; k < n; k = k + 1) begin
        addr = rnd(64);
        sa = rnd(1023);        // an AD9361 register, not the counter 0x3FF
        r1 = rnd(256); r2 = rnd(256);
        case (rnd(27))
          0, 1, 2, 3, 4, 5:   begin a = {8'd1, 8'd0, addr[15:0]}; b = $random(seed); end   // WRITE
          6, 7, 8, 9, 10, 11: begin a = {8'd2, 8'd0, addr[15:0]}; b = 0; end               // READ
          12, 13:             begin a = {8'd4, 24'd0}; b = rnd(21); end                     // WAIT 0..20 us
          14, 15, 16:         if (k + 1 < n) begin                // READ the counter, POLL a nibble (1 ms: matches)
                                pkt[4 + 2*k] = {8'd2, 8'd0, 16'hF0}; pkt[5 + 2*k] = 0;
                                k = k + 1; nib = rnd(16);
                                a = {8'd5, 8'd1, 16'd0}; b = {16'h000F, 12'd0, nib};
                              end else begin a = {8'd2, 8'd0, 16'hF0}; b = 0; end
          17:                 begin a = {8'd5, 24'd0}; b = {16'hFFFF, 16'h1234}; end         // POLL, one try
          // SPI: data[31:24] and the address field must not matter
          18, 19:             begin a = {8'd3, 8'd0, addr[15:0]}; b = {r1, 1'b1, 5'd0, sa[9:0], r2}; end   // AD9361 write
          20:                 begin a = {8'd3, 8'd0, addr[15:0]}; b = {r1, 1'b0, 5'd0, sa[9:0], r2}; end   // AD9361 read
          21:                 if (k + 1 < n) begin                // SPI read the counter, POLL a nibble (1 ms: matches)
                                pkt[4 + 2*k] = {8'd3, 8'd0, 16'd0}; pkt[5 + 2*k] = {8'd0, 1'b0, 5'd0, 10'h3FF, 8'd0};
                                k = k + 1; nib = rnd(16);
                                a = {8'd5, 8'd1, 16'd0}; b = {16'h000F, 12'd0, nib};
                              end else begin a = {8'd3, 8'd0, 16'd0}; b = {8'd0, 1'b0, 5'd0, 10'h3FF, 8'd0}; end
          22:                 if (k + 1 < n) begin                // SPI read, POLL it once (value set below)
                                pkt[4 + 2*k] = {8'd3, 8'd0, addr[15:0]}; pkt[5 + 2*k] = {8'd0, 1'b0, 5'd0, sa[9:0], 8'd0};
                                k = k + 1; patch[k] = 1;
                                a = {8'd5, 8'd0, 16'd0}; b = {16'h00FF, 16'd0};
                              end else begin a = {8'd3, 8'd0, addr[15:0]}; b = {8'd0, 1'b0, 5'd0, sa[9:0], 8'd0}; end
          23:                 begin a = {8'd3, 8'd1, addr[15:0]}; b = $random(seed); end   // ADF4001
          24:                 begin r1 = 2 + rnd(254); a = {8'd3, r1, addr[15:0]}; b = $random(seed); end   // no such device
          default:            begin op = rnd(2) ? 0 : 7 + rnd(249); a = {op, 8'd0, addr[15:0]}; b = 0; end // unknown
        endcase
        pkt[4 + 2*k] = a; pkt[5 + 2*k] = b;
      end
      pkt_words = 4 + 2 * n;
      cut = 2 * n;
      if (kind == 1 && n > 0) begin cut = rnd(2 * n); pkt_words = 4 + cut; end
      // extra words up to 256 in all: one FX3 control buffer, the FIFO's MAX
      if (kind == 2) for (k = 0; k < 1 + rnd(5); k = k + 1) if (pkt_words < 256) begin
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
          else if (skip || !(a[31:24] == 1 || a[31:24] == 2 || (a[31:24] == 3 && a[23:16] < 2) ||
                             a[31:24] == 4 || a[31:24] == 5)) begin
            if (!skip && a[31:24] == 3) n_bad_dev = n_bad_dev + 1;
            skip = 1; exp_a[base + k] = {a[31:24], 8'd3, a[15:0]};
          end else begin
            exp_a[base + k] = {a[31:24], 8'd0, a[15:0]};
            case (a[31:24])
              1: begin
                   shadow[addr] = b;
                   gap_min[writes_expected] = gap_lo; gap_max[writes_expected] = gap_hi;
                   writes_expected = writes_expected + 1; gap_lo = 0; gap_hi = 0;
                 end
              2: begin
                   if (a[15:0] == 16'hF0) exp_kind[base + k] = 1; else exp_b[base + k] = shadow[addr];
                   prev_spi = 0; prev_addr = a[15:0];
                 end
              3: begin
                   fr = a[16] ? FRAME1 : FRAME0;
                   spi_effect(a[16], b[23:0], v);
                   if (!a[16] && !b[23] && b[17:8] == 10'h3FF) exp_kind[base + k] = 1;   // the counter
                   else exp_b[base + k] = v;
                   if (a[16]) n_adf = n_adf + 1; else if (b[23]) n_spi_wr = n_spi_wr + 1; else n_spi_rd = n_spi_rd + 1;
                   prev_spi = 1; prev_dev = a[16]; prev_word = b[23:0];
                   gap_lo = gap_lo + fr; if (gap_hi >= 0) gap_hi = gap_hi + fr;
                 end
              4: begin gap_lo = gap_lo + 100 * b; if (gap_hi >= 0) gap_hi = gap_hi + 100 * b; end
              5: if (!prev_spi) begin
                   exp_kind[base + k] = 2; exp_b[base + k] = b; if (gap_hi >= 0) gap_hi = gap_hi + 200;
                 end else begin
                   fr = prev_dev ? FRAME1 : FRAME0;
                   gap_lo = gap_lo + fr;
                   if (!prev_dev && !prev_word[23] && prev_word[17:8] == 10'h3FF) begin
                     // the counter: tries until the nibble comes round (one step per try at most)
                     exp_kind[base + k] = 2; exp_b[base + k] = b; n_poll_cnt = n_poll_cnt + 1;
                     if (gap_hi >= 0) gap_hi = gap_hi + 17 * CNT_CYC + 2 * (fr + 20);
                   end else begin
                     // one try (arg 0 in every such POLL here): the frame again, exact result
                     spi_effect(prev_dev, prev_word, v);
                     if (patch[k]) begin
                       b[7:0] = rnd(2) ? v : v ^ (8'd1 << rnd(8));
                       pkt[5 + 2*k] = b; n_poll_exact = n_poll_exact + 1;
                     end else n_poll_rep = n_poll_rep + 1;
                     st = ((v & b[31:16]) == b[15:0]) ? 8'd0 : 8'd1;
                     exp_a[base + k] = {8'd5, st, a[15:0]}; exp_b[base + k] = v;
                     if (gap_hi >= 0) gap_hi = gap_hi + fr + 20;
                   end
                 end
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
      while (!cmd_room) @(posedge clk);
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
    if (cmd_dropped != malformed) begin errors = errors + 1; $display("dropped %0d, malformed %0d", cmd_dropped, malformed); end
    if (wr_count != writes_expected) begin errors = errors + 1; $display("%0d writes, expected %0d", wr_count, writes_expected); end
    for (i = 0; i < 64; i = i + 1) if (regs[i] !== shadow[i]) begin
      errors = errors + 1; $display("register %0d = %h, expected %h", i, regs[i], shadow[i]);
    end
    // the SPI devices
    for (i = 0; i < 1023; i = i + 1) if (ad.r[i] !== shadow9361[i]) begin
      errors = errors + 1; if (errors < 20) $display("AD9361 register %h = %h, expected %h", i, ad.r[i], shadow9361[i]);
    end
    if (pll.n != adf_n) begin errors = errors + 1; $display("ADF4001 latched %0d words, expected %0d", pll.n, adf_n); end
    else for (i = 0; i < adf_n; i = i + 1) if (pll.log[i] !== adf_exp[i]) begin
      errors = errors + 1; if (errors < 20) $display("ADF4001 word %0d = %h, expected %h", i, pll.log[i], adf_exp[i]);
    end
    if (ad.errors != 0 || pll.errors != 0) begin
      errors = errors + 1; $display("SPI timing or framing: AD9361 %0d errors, ADF4001 %0d", ad.errors, pll.errors);
    end
    if (both != 0) begin errors = errors + 1; $display("both devices selected %0d times", both); end
    if (n_spi_wr == 0 || n_spi_rd == 0 || n_adf == 0 || n_poll_exact == 0 || n_poll_cnt == 0 || n_poll_rep == 0 ||
        n_bad_dev == 0) begin
      errors = errors + 1; $display("coverage: an SPI case never ran");
    end
    $display("%0d packets: %0d answered, %0d dropped; %0d register writes", N, got, cmd_dropped, wr_count);
    $display("SPI: AD9361 %0d writes, %0d reads, %0d frames; ADF4001 %0d words; POLL over SPI %0d exact, %0d counter, %0d repeats; %0d bad devices",
             n_spi_wr, n_spi_rd, ad.frames, pll.n, n_poll_exact, n_poll_cnt, n_poll_rep, n_bad_dev);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
