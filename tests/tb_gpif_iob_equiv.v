// tb_gpif_iob_equiv.v - gpif2_slave_fifo32 with its boundary registers in the
// I/O blocks (IDDR / ODDR / IOBUF) against the module it was derived from
// (tests/ref/gpif2_slave_fifo32_ref.v, the HEAD version with fabric
// registers), cycle for cycle.
//
// One stimulus engine, two modules.  The FX3 model and the four AXI-stream
// partners react to the REFERENCE's outputs only and their signals go to
// both modules, so the two always see the same inputs and the first cycle
// in which they answer differently is reported as such; nothing can drift.
//
// What is compared, on every gpif_clk cycle, at three points of the cycle:
//
//      posedge  +2.5 ns      +7.5 ns   +8.5        +9.5 ns   posedge
//         |        A            B        [ FX3 drives ]  C   |+0.5]
//
//   A, B  each module is alone on its data bus: the value AND the
//         high-impedance state of all 32 lines as seen from outside the
//         pads, in both halves of the cycle (an output register that moved
//         on the falling edge would show at B), plus sloe, slrd, slwr,
//         pktend, fifoadr and slcs.
//   C     the FX3 model drives the bus when it saw SLOE low: this is what
//         the input registers sample.  Both buses must be fully defined, so
//         a module that still drives during a read shows as contention.
//
// and every AXI-stream output and ready (tx, ctrl data/last/valid, rx and
// resp ready) at every falling edge of fifo_clk and at A.  Comparison is
// 4-state (===).  After the first reset an x is a failure on any strobe,
// address, valid or ready, on tdata/tlast while valid, and on a data line
// (z is the legal third state there).
//
// Sampling away from the clock edge, and stimulus that changes 1 ns after
// it, keep delta-cycle ordering out of the result.
//
// The bench also counts what it exercised and FAILS if a part of the state
// machine was not reached, so a pass cannot be vacuous.
//
//   iverilog -g2005 -I src/rtl/control -s tb_gpif_iob_equiv ... && vvp ... [+cycles=N] [+seed=N]
//   -P tb_gpif_iob_equiv.DATA_FIFO_SIZE=12  -P tb_gpif_iob_equiv.FIFO_HALF_PS=4100  for other shapes

`timescale 1ns/1ps

module tb_gpif_iob_equiv;

   parameter integer DATA_FIFO_SIZE = 14;      // DATA_RX / DATA_TX_FIFO_SIZE, as b200.v
   parameter integer CTRL_FIFO_SIZE = 5;       // CTRL_RX / CTRL_TX_FIFO_SIZE
   parameter integer FIFO_HALF_PS   = 5350;    // fifo_clk half period: 93.46 MHz, unrelated to gpif_clk

   localparam [1:0] ADDR_DATA_TX = 2'b00, ADDR_DATA_RX = 2'b01,
                    ADDR_CTRL_TX = 2'b10, ADDR_CTRL_RX = 2'b11;

   integer cycles_goal = 2000000;
   integer seed_arg    = 1;
   integer seed_g, seed_f;                     // gpif-side and fifo-side random streams

   function integer rnd_g; input integer n; begin rnd_g = {$random(seed_g)} % n; end endfunction
   function integer rnd_f; input integer n; begin rnd_f = {$random(seed_f)} % n; end endfunction

   // ------------------------------------------------------------ clocks ---
   reg gpif_clk = 1'b0, fifo_clk = 1'b0;
   always #5 gpif_clk = ~gpif_clk;                         // 100 MHz
   always #(FIFO_HALF_PS / 1000.0) fifo_clk = ~fifo_clk;   // asynchronous to it

   // ------------------------------------------- stimulus (both modules) ---
   reg         gpif_rst = 1'b1, fifo_rst = 1'b1, gpif_enb = 1'b1;
   reg  [3:0]  gpif_ctl = 4'b0000;
   reg  [63:0] rx_tdata = 64'd0, resp_tdata = 64'd0;
   reg         rx_tlast = 1'b0, rx_tvalid = 1'b0, resp_tlast = 1'b0, resp_tvalid = 1'b0;
   reg         tx_tready = 1'b0, ctrl_tready = 1'b0;

   reg         fx3_oe = 1'b0, fx3_window = 1'b0;
   reg  [31:0] fx3_dout = 32'd0;
   wire        fx3_drive = fx3_oe && fx3_window;

   // ----------------------------------------------------------- modules ---
   wire [31:0] d_ref, d_new;
   wire        sloe_ref, slrd_ref, slwr_ref, slcs_ref, pktend_ref;
   wire        sloe_new, slrd_new, slwr_new, slcs_new, pktend_new;
   wire [1:0]  fifoadr_ref, fifoadr_new;
   wire [63:0] tx_tdata_ref, tx_tdata_new, ctrl_tdata_ref, ctrl_tdata_new;
   wire        tx_tlast_ref, tx_tvalid_ref, ctrl_tlast_ref, ctrl_tvalid_ref, rx_tready_ref, resp_tready_ref;
   wire        tx_tlast_new, tx_tvalid_new, ctrl_tlast_new, ctrl_tvalid_new, rx_tready_new, resp_tready_new;
   wire [31:0] debug_ref, debug_new;

   assign d_ref = fx3_drive ? fx3_dout : 32'bz;
   assign d_new = fx3_drive ? fx3_dout : 32'bz;

   gpif2_slave_fifo32_ref #(
      .DATA_RX_FIFO_SIZE(DATA_FIFO_SIZE), .DATA_TX_FIFO_SIZE(DATA_FIFO_SIZE),
      .CTRL_RX_FIFO_SIZE(CTRL_FIFO_SIZE), .CTRL_TX_FIFO_SIZE(CTRL_FIFO_SIZE)) u_ref (
      .gpif_clk(gpif_clk), .gpif_rst(gpif_rst), .gpif_enb(gpif_enb),
      .gpif_d(d_ref), .gpif_ctl(gpif_ctl),
      .sloe(sloe_ref), .slrd(slrd_ref), .slwr(slwr_ref), .slcs(slcs_ref), .pktend(pktend_ref),
      .fifoadr(fifoadr_ref),
      .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
      .tx_tdata(tx_tdata_ref), .tx_tlast(tx_tlast_ref), .tx_tvalid(tx_tvalid_ref), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready_ref),
      .ctrl_tdata(ctrl_tdata_ref), .ctrl_tlast(ctrl_tlast_ref), .ctrl_tvalid(ctrl_tvalid_ref), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready_ref),
      .debug(debug_ref));

   gpif2_slave_fifo32 #(
      .DATA_RX_FIFO_SIZE(DATA_FIFO_SIZE), .DATA_TX_FIFO_SIZE(DATA_FIFO_SIZE),
      .CTRL_RX_FIFO_SIZE(CTRL_FIFO_SIZE), .CTRL_TX_FIFO_SIZE(CTRL_FIFO_SIZE)) u_new (
      .gpif_clk(gpif_clk), .gpif_rst(gpif_rst), .gpif_enb(gpif_enb),
      .gpif_d(d_new), .gpif_ctl(gpif_ctl),
      .sloe(sloe_new), .slrd(slrd_new), .slwr(slwr_new), .slcs(slcs_new), .pktend(pktend_new),
      .fifoadr(fifoadr_new),
      .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
      .tx_tdata(tx_tdata_new), .tx_tlast(tx_tlast_new), .tx_tvalid(tx_tvalid_new), .tx_tready(tx_tready),
      .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready_new),
      .ctrl_tdata(ctrl_tdata_new), .ctrl_tlast(ctrl_tlast_new), .ctrl_tvalid(ctrl_tvalid_new), .ctrl_tready(ctrl_tready),
      .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready_new),
      .debug(debug_new));

   // --------------------------------------------------------- comparison ---
   wire [6:0]   ctl_ref = {slcs_ref, sloe_ref, slrd_ref, slwr_ref, pktend_ref, fifoadr_ref};
   wire [6:0]   ctl_new = {slcs_new, sloe_new, slrd_new, slwr_new, pktend_new, fifoadr_new};
   wire [3:0]   hs_ref  = {rx_tready_ref, resp_tready_ref, tx_tvalid_ref, ctrl_tvalid_ref};
   wire [3:0]   hs_new  = {rx_tready_new, resp_tready_new, tx_tvalid_new, ctrl_tvalid_new};
   wire [129:0] pay_ref = {tx_tlast_ref, tx_tdata_ref, ctrl_tlast_ref, ctrl_tdata_ref};
   wire [129:0] pay_new = {tx_tlast_new, tx_tdata_new, ctrl_tlast_new, ctrl_tdata_new};

   reg     armed = 1'b0;                 // set inside the first reset
   integer cycles = 0, fifo_cycles = 0;
   integer mismatches = 0, xfails = 0, shown = 0;
   integer cyc = 0;                      // gpif_clk cycle number (stimulus side)

   // an x on a data line; z is the legal third state
   function has_x;
      input [31:0] v;
      integer i;
      begin
         has_x = 1'b0;
         if (^v === 1'bx && v !== 32'bz)
            for (i = 0; i < 32; i = i + 1)
               if (v[i] === 1'bx) has_x = 1'b1;
      end
   endfunction

   task pad_check;
      input integer pt;                  // 0 = A, 1 = B, 2 = C
      reg bad_x;
      begin
         if (ctl_new !== ctl_ref || d_new !== d_ref) begin
            mismatches = mismatches + 1;
            if (shown < 16) begin
               shown = shown + 1;
               $display("MISMATCH pads  cycle %0d point %s t=%0t", cyc, (pt == 0) ? "A" : (pt == 1) ? "B" : "C", $time);
               $display("    ref: slcs=%b sloe=%b slrd=%b slwr=%b pktend=%b fifoadr=%b d=%b",
                        slcs_ref, sloe_ref, slrd_ref, slwr_ref, pktend_ref, fifoadr_ref, d_ref);
               $display("    new: slcs=%b sloe=%b slrd=%b slwr=%b pktend=%b fifoadr=%b d=%b",
                        slcs_new, sloe_new, slrd_new, slwr_new, pktend_new, fifoadr_new, d_new);
            end
         end
         bad_x = (^ctl_ref === 1'bx) || (^ctl_new === 1'bx);
         if (pt == 2) bad_x = bad_x || (^d_ref === 1'bx) || (^d_new === 1'bx);   // must be driven, by exactly one side
         else         bad_x = bad_x || has_x(d_ref) || has_x(d_new);
         if (bad_x) begin
            xfails = xfails + 1;
            if (shown < 16) begin
               shown = shown + 1;
               $display("UNDEFINED pads cycle %0d point %s t=%0t", cyc, (pt == 0) ? "A" : (pt == 1) ? "B" : "C", $time);
               $display("    ref: ctl=%b d=%b", ctl_ref, d_ref);
               $display("    new: ctl=%b d=%b", ctl_new, d_new);
            end
         end
      end
   endtask

   task axi_check;
      reg bad_x;
      begin
         if (hs_new !== hs_ref || pay_new !== pay_ref || debug_new !== debug_ref) begin
            mismatches = mismatches + 1;
            if (shown < 16) begin
               shown = shown + 1;
               $display("MISMATCH axi   cycle %0d t=%0t", cyc, $time);
               $display("    ref: rx_tready=%b resp_tready=%b tx v=%b l=%b d=%h  ctrl v=%b l=%b d=%h", rx_tready_ref,
                        resp_tready_ref, tx_tvalid_ref, tx_tlast_ref, tx_tdata_ref, ctrl_tvalid_ref, ctrl_tlast_ref, ctrl_tdata_ref);
               $display("    new: rx_tready=%b resp_tready=%b tx v=%b l=%b d=%h  ctrl v=%b l=%b d=%h", rx_tready_new,
                        resp_tready_new, tx_tvalid_new, tx_tlast_new, tx_tdata_new, ctrl_tvalid_new, ctrl_tlast_new, ctrl_tdata_new);
            end
         end
         bad_x = (^hs_ref === 1'bx) || (^hs_new === 1'bx)
              || (tx_tvalid_ref   === 1'b1 && ^{tx_tlast_ref, tx_tdata_ref}     === 1'bx)
              || (tx_tvalid_new   === 1'b1 && ^{tx_tlast_new, tx_tdata_new}     === 1'bx)
              || (ctrl_tvalid_ref === 1'b1 && ^{ctrl_tlast_ref, ctrl_tdata_ref} === 1'bx)
              || (ctrl_tvalid_new === 1'b1 && ^{ctrl_tlast_new, ctrl_tdata_new} === 1'bx);
         if (bad_x) begin
            xfails = xfails + 1;
            if (shown < 16) begin
               shown = shown + 1;
               $display("UNDEFINED axi  cycle %0d t=%0t  ref hs=%b new hs=%b", cyc, $time, hs_ref, hs_new);
            end
         end
      end
   endtask

   // ---------------------------------------- what the run has exercised ---
   integer rd_beats = 0, rd_single = 0, wr_beats = 0, pktends = 0, pad_write = 0, pad_think = 0;
   integer turn_to_fx3 = 0, turn_to_fpga = 0, nf_stops = 0, enb_low = 0, n_resets = 0;
   integer write_pkts_2n = 0;
   integer state_seen [0:7];
   integer rd_bufs = 0, wr_bufs = 0, wr_overrun = 0;
   integer src_beats [0:1], src_pkts [0:1];        // 0 = rx, 1 = resp
   integer snk_beats [0:1], snk_pkts [0:1];        // 0 = tx, 1 = ctrl
   reg     bus_was_z = 1'b0;
   reg [3:0] st_prev = 4'd0;
   reg       pad_prev = 1'b0;

   // pads of the reference as the FX3 sees them, taken at B
   reg        s_sloe = 1'b1, s_slrd = 1'b1, s_slwr = 1'b1, s_pktend = 1'b1;
   reg [1:0]  s_fifoadr = 2'b00;

   task coverage;
      begin
         if (s_slrd === 1'b0) begin
            rd_beats = rd_beats + 1;
            if (u_ref.state == 4'd7) rd_single = rd_single + 1;
         end
         if (s_slwr === 1'b0)   wr_beats = wr_beats + 1;
         if (s_pktend === 1'b0) pktends  = pktends + 1;
         // direction of the data bus, from the pads of the module under test
         if (d_new === 32'bz && !bus_was_z) turn_to_fx3  = turn_to_fx3 + 1;
         if (d_new !== 32'bz && bus_was_z)  turn_to_fpga = turn_to_fpga + 1;
         bus_was_z = (d_new === 32'bz);
         if (u_ref.state <= 4'd7) state_seen[u_ref.state[2:0]] = state_seen[u_ref.state[2:0]] + 1;
         // the padding cycle of a transfer that ends on a multiple of 256 words
         if (u_ref.pad === 1'b1 && !pad_prev) begin
            if (st_prev == 4'd3) pad_write = pad_write + 1;
            if (st_prev == 4'd1) pad_think = pad_think + 1;
         end
         if (s_pktend === 1'b0 && pad_prev) write_pkts_2n = write_pkts_2n + 1;
         if (u_ref.state == 4'd2 && u_ref.fifo_nearly_full === 1'b1) nf_stops = nf_stops + 1;
         if (!gpif_enb) enb_low = enb_low + 1;
         st_prev  = u_ref.state;
         pad_prev = (u_ref.pad === 1'b1);
      end
   endtask

   always @(posedge gpif_clk) begin
      #2.5;                                         // A
      if (armed) begin pad_check(0); axi_check; end
      #5.0;                                         // B
      s_sloe = sloe_ref; s_slrd = slrd_ref; s_slwr = slwr_ref; s_pktend = pktend_ref; s_fifoadr = fifoadr_ref;
      if (armed) begin pad_check(1); coverage; end
      #1.0;                                         // the FX3 turns its drivers on
      fx3_oe     = (s_sloe === 1'b0);
      fx3_window = 1'b1;
      #1.0;                                         // C
      if (armed) begin pad_check(2); cycles = cycles + 1; end
   end
   always @(posedge gpif_clk) #0.5 fx3_window = 1'b0;    // hold time after the edge

   // --------------------------------------------------------- FX3 model ---
   // Threads 0 and 2 hold data for the FPGA to read (one CHDR-shaped packet
   // per DMA buffer), threads 1 and 3 take what the FPGA writes.  Flag 0 is
   // "ready", flag 1 the watermark, both for the addressed thread.
   integer    rd_rem [0:3], rd_gap [0:3], rd_wmk [0:3], rd_seq [0:3];
   reg [31:0] rd_word [0:3];
   integer    wr_space [0:3], wr_gap [0:3], wr_wmk [0:3];
   integer    snk_mode [0:1], snk_left [0:1];             // how the tx (0) and ctrl (1) streams are being taken
   reg        slrd_d1 = 1'b1, slrd_d2 = 1'b1;
   reg [1:0]  fl_p0 = 2'b00, fl_p1 = 2'b00, fl_p2 = 2'b00, fl_out;
   integer    seg_left = 0, flag_mode = 0, flag_lat = 0, enb_mode = 0;
   integer    glitch_left = 0, glitch_val = 0, hold_left = 0, rand_val = 0;
   integer    rst_hold = 40, next_rst = 0, rst_kind = 0;
   reg        fifo_rst_req = 1'b1;
   integer    t, a, n, r, hdr_len;
   reg        adv;

   task new_rd_buf;
      input integer th;
      begin
         r = rnd_g(100);
         if (th == 0) begin
            if      (r < 6)  n = 1;
            else if (r < 20) n = 2 + rnd_g(7);
            else if (r < 79) n = 9 + rnd_g(600);
            else if (r < 92) n = 601 + rnd_g(1500);
            else if (r < 96) n = 4080 + rnd_g(17);          // fills the 4096-word read buffer
            else             n = 4097 + rnd_g(300);
         end else begin
            if      (r < 10) n = 1;
            else if (r < 70) n = 2 + rnd_g(14);
            else if (r < 95) n = 16 + rnd_g(200);
            else             n = 4080 + rnd_g(140);
         end
         rd_rem[th] = n;
         // The watermark falls as many words before the end as the read
         // pipeline is long (5, plus the flag latency of this segment), which
         // is how the FX3 is configured; one buffer in eight has another value.
         rd_wmk[th] = (rnd_g(8) == 0) ? 1 + rnd_g(12) : 5 + flag_lat;
         hdr_len = (rnd_g(20) == 0) ? rnd_g(65536) : (4 * n - rnd_g(4));
         // While the stream this thread feeds is not being taken, the FX3
         // sometimes has twice what the local FIFOs hold, under a header that
         // claims the largest legal packet: the read burst then runs into
         // fifo_nearly_full, which is the only thing that can stop it.
         if (snk_mode[th / 2] >= 2 && rnd_g(100) < ((snk_mode[th / 2] == 3) ? 50 : 20)) begin
            n = 8300 + rnd_g(1000);
            rd_rem[th] = n;
            hdr_len = 16384 - rnd_g(4);
         end
         rd_word[th] = {4'd0, rd_seq[th][11:0], hdr_len[15:0]} | (rnd_g(16) << 28);
         rd_seq[th] = rd_seq[th] + 1;
      end
   endtask

   task new_wr_buf;
      input integer th;
      begin
         r = rnd_g(100);
         wr_wmk[th] = (rnd_g(6) == 0) ? rnd_g(10) : 4;
         if (r < 30) begin
            // Room for a little more than 256 words and a watermark that stops
            // the burst short of the 256th: a 256-word packet then ends on a
            // single-beat write, the padding case of STATE_THINK.
            n = 256 + rnd_g(8);
            wr_wmk[th] = 6 + rnd_g(10);
         end else if (th == 1) begin
            if      (r < 74) n = 4096;                      // a 16 KB DMA buffer
            else if (r < 86) n = 1 + rnd_g(1100);
            else if (r < 94) n = 250 + rnd_g(6);            // full just short of a 256-word boundary
            else             n = 1 + rnd_g(12);
         end else begin
            if (r < 74) n = 4096; else n = 1 + rnd_g(40);
         end
         wr_space[th] = n;
         wr_bufs      = wr_bufs + 1;
      end
   endtask

   function integer some_gap;
      input integer k;
      begin
         r = rnd_g(100);
         if      (r < 50) some_gap = rnd_g(20);
         else if (r < 92) some_gap = rnd_g(400);
         else             some_gap = rnd_g(k);
      end
   endfunction

   task fx3_step;
      begin
         cyc = cyc + 1;
         if (cyc == 8) armed = 1'b1;                        // inside the first reset
         if (cyc % 250000 == 0)
            $display("  ... %0d cycles, %0d mismatching and %0d undefined samples so far", cycles, mismatches, xfails);

         // ---- resets: both, the bus side alone, the fifo side alone ----
         if (rst_hold > 0) begin
            rst_hold = rst_hold - 1;
            if (rst_hold == 0) begin gpif_rst = 1'b0; fifo_rst_req = 1'b0; end
         end else if (cyc >= next_rst) begin
            rst_kind     = (n_resets % 4 == 1) ? 1 : (n_resets % 4 == 3) ? 2 : 0;
            gpif_rst     = (rst_kind != 2);
            fifo_rst_req = (rst_kind != 1);
            rst_hold     = 3 + rnd_g(60);
            n_resets     = n_resets + 1;
            next_rst     = cyc + cycles_goal / 10 + rnd_g(cycles_goal / 20 + 1);
         end

         // ---- a new segment: how the flags and gpif_enb behave for a while ----
         if (seg_left == 0) begin
            seg_left  = 500 + rnd_g(20000);
            r         = rnd_g(100);
            flag_mode = (r < 62) ? 0 : (r < 84) ? 1 : 2;    // true, glitching, arbitrary
            flag_lat  = (rnd_g(10) < 6) ? 0 : 1 + rnd_g(2);
            enb_mode  = (rnd_g(8) == 0);
         end
         seg_left = seg_left - 1;
         gpif_enb = enb_mode ? (rnd_g(4) != 0) : 1'b1;

         a = (^s_fifoadr === 1'bx) ? 0 : s_fifoadr;

         // ---- reads: the word on the bus is taken when slrd, two cycles on, is low ----
         adv     = !slrd_d2;
         slrd_d2 = slrd_d1;
         slrd_d1 = !(s_slrd === 1'b0);
         if (adv && !a[0] && rd_rem[a] > 0) begin
            rd_rem[a] = rd_rem[a] - 1;
            if (rd_rem[a] > 0) rd_word[a] = $random(seed_g);
            else begin rd_gap[a] = some_gap(6000); rd_bufs = rd_bufs + 1; end
         end
         for (t = 0; t < 4; t = t + 2)
            if (rd_rem[t] == 0) begin
               if (rd_gap[t] == 0) new_rd_buf(t); else rd_gap[t] = rd_gap[t] - 1;
            end

         // ---- writes: a word per cycle of slwr low; pktend or a full buffer commits it ----
         if (s_slwr === 1'b0 && a[0]) begin
            if (wr_space[a] > 0) wr_space[a] = wr_space[a] - 1; else wr_overrun = wr_overrun + 1;
            if (wr_space[a] == 0 && wr_gap[a] == 0) wr_gap[a] = 1 + some_gap(3000);
         end
         if (s_pktend === 1'b0 && a[0] && wr_gap[a] == 0) begin
            wr_space[a] = 0;
            wr_gap[a]   = 1 + some_gap(3000);
         end
         for (t = 1; t < 4; t = t + 2)
            if (wr_gap[t] > 0) begin
               wr_gap[t] = wr_gap[t] - 1;
               if (wr_gap[t] == 0) new_wr_buf(t);
            end

         // ---- flags of the addressed thread ----
         fl_p2 = fl_p1; fl_p1 = fl_p0;
         if (a[0]) fl_p0 = {wr_space[a] > wr_wmk[a], wr_space[a] > 0};
         else      fl_p0 = {rd_rem[a] > rd_wmk[a],   rd_rem[a] > 0};
         fl_out = (flag_lat == 0) ? fl_p0 : (flag_lat == 1) ? fl_p1 : fl_p2;
         if (flag_mode == 1) begin
            if (glitch_left > 0) begin fl_out = glitch_val; glitch_left = glitch_left - 1; end
            else if (rnd_g(200) == 0) begin glitch_left = 1 + rnd_g(6); glitch_val = rnd_g(4); end
         end else if (flag_mode == 2) begin
            if (hold_left == 0) begin rand_val = (rnd_g(2) == 0) ? 3 : rnd_g(4); hold_left = rnd_g(30); end
            else hold_left = hold_left - 1;
            fl_out = rand_val;
         end
         gpif_ctl[1:0] = fl_out;
         gpif_ctl[3:2] = $random(seed_g);                  // not flags: the module must ignore them

         fx3_dout = a[0] ? (32'hF0F00000 | cyc[15:0]) : rd_word[a];
      end
   endtask

   always @(posedge gpif_clk) begin
      #1.0;
      fx3_step;
   end

   // ------------------------------------------------ AXI-stream partners ---
   reg         s_rx_tready = 1'b0, s_resp_tready = 1'b0;      // reference outputs, taken mid-cycle
   reg         s_tx_tvalid = 1'b0, s_tx_tlast = 1'b0, s_ctrl_tvalid = 1'b0, s_ctrl_tlast = 1'b0;
   reg         src_valid [0:1], src_last [0:1];
   reg  [63:0] src_data [0:1];
   integer     src_left [0:1], src_gap [0:1], src_mode [0:1], src_run [0:1];
   reg         snk_ready [0:1];
   integer     q, i;

   always @(negedge fifo_clk) begin
      if (armed) begin axi_check; fifo_cycles = fifo_cycles + 1; end
      s_rx_tready = rx_tready_ref; s_resp_tready = resp_tready_ref;
      s_tx_tvalid = tx_tvalid_ref; s_tx_tlast = tx_tlast_ref;
      s_ctrl_tvalid = ctrl_tvalid_ref; s_ctrl_tlast = ctrl_tlast_ref;
   end

   function integer new_len;
      input integer k;
      begin
         q = rnd_f(100);
         if (k == 0) begin
            if (src_run[k] > 0) begin new_len = 128; src_run[k] = src_run[k] - 1; end   // 256 words: the FX3 corner case
            else if (q < 3) begin new_len = 128; src_run[k] = 3 + rnd_f(12); end       // ... and they come in runs
            else if (q < 34) begin
               // and the lengths around the 256-word (128-beat) boundaries
               case (rnd_f(18))
                 0: new_len = 1;     1: new_len = 2;     2: new_len = 3;     3: new_len = 4;
                 4: new_len = 8;     5: new_len = 16;    6: new_len = 32;    7: new_len = 64;
                 8: new_len = 127;   9: new_len = 128;  10: new_len = 129;  11: new_len = 255;
                12: new_len = 256;  13: new_len = 257;  14: new_len = 384;  15: new_len = 512;
                16: new_len = 1024; default: new_len = 2000;
               endcase
            end
            else if (q < 44) new_len = 1 + rnd_f(4);
            else if (q < 88) new_len = 1 + rnd_f(300);
            else             new_len = 1 + rnd_f(1024);
         end else begin
            if (src_run[k] > 0) begin new_len = 128; src_run[k] = src_run[k] - 1; end
            else if (q < 3) begin new_len = 128; src_run[k] = 3 + rnd_f(12); end
            else if (q < 15) new_len = 1;
            else if (q < 60) new_len = 2 + rnd_f(7);
            else if (q < 90) new_len = 127 + rnd_f(3);            // 254, 256, 258 words
            else             new_len = 1 + rnd_f(400);
         end
      end
   endfunction

   task src_step;
      input integer k;
      input s_ready;
      begin
         if (src_valid[k] && s_ready === 1'b1) begin
            src_beats[k] = src_beats[k] + 1;
            if (src_last[k]) src_pkts[k] = src_pkts[k] + 1;
            src_valid[k] = 1'b0;
            src_left[k]  = src_left[k] - 1;
            if (src_left[k] == 0) begin
               q = rnd_f(100);
               if (k == 0) src_gap[k] = (q < 60) ? 0 : (q < 92) ? rnd_f(50)  : rnd_f(4000);
               else        src_gap[k] = (q < 30) ? 0 : (q < 80) ? rnd_f(300) : rnd_f(8000);
            end else begin
               case (src_mode[k])
                 2:       src_gap[k] = (rnd_f(4) == 0)  ? 1 + rnd_f(3) : 0;
                 3:       src_gap[k] = (rnd_f(16) == 0) ? rnd_f(200)   : 0;
                 default: src_gap[k] = 0;                    // back to back
               endcase
            end
         end
         if (!src_valid[k]) begin
            if (src_gap[k] > 0) src_gap[k] = src_gap[k] - 1;
            else begin
               if (src_left[k] == 0) begin
                  src_left[k] = new_len(k);
                  src_mode[k] = rnd_f(4);
               end
               src_valid[k] = 1'b1;
               src_data[k]  = {$random(seed_f), $random(seed_f)};
               src_last[k]  = (src_left[k] == 1);
            end
         end
      end
   endtask

   task snk_step;
      input integer k;
      input s_valid;
      input s_last;
      begin
         if (snk_ready[k] && s_valid === 1'b1) begin
            snk_beats[k] = snk_beats[k] + 1;
            if (s_last === 1'b1) snk_pkts[k] = snk_pkts[k] + 1;
         end
         if (snk_left[k] == 0) begin
            q = rnd_f(100);
            snk_mode[k] = (q < 45) ? 0 : (q < 75) ? 1 : (q < 88) ? 2 : 3;   // open, random, slow, stalled
            snk_left[k] = (snk_mode[k] == 3) ? 200 + rnd_f(40000) : 200 + rnd_f(20000);
         end
         snk_left[k] = snk_left[k] - 1;
         case (snk_mode[k])
           0:       snk_ready[k] = 1'b1;
           1:       snk_ready[k] = rnd_f(2);
           2:       snk_ready[k] = (rnd_f(8) == 0);
           default: snk_ready[k] = 1'b0;
         endcase
      end
   endtask

   always @(posedge fifo_clk) begin
      #1.0;
      fifo_rst = fifo_rst_req;
      src_step(0, s_rx_tready);
      src_step(1, s_resp_tready);
      snk_step(0, s_tx_tvalid, s_tx_tlast);
      snk_step(1, s_ctrl_tvalid, s_ctrl_tlast);
      rx_tvalid   = src_valid[0]; rx_tdata   = src_data[0]; rx_tlast   = src_last[0];
      resp_tvalid = src_valid[1]; resp_tdata = src_data[1]; resp_tlast = src_last[1];
      tx_tready   = snk_ready[0]; ctrl_tready = snk_ready[1];
   end

   // ----------------------------------------------------------- power-up ---
   // Before the first clock edge the pads show the INIT of the I/O-block
   // registers.  It has to be the idle bus the original registers came up
   // with (strobes high, FPGA driving zeros, thread 0), and the fabric copies
   // of the strobes have to come up equal to their pad copies.  (The reference
   // is all x at this point in simulation, so this is checked on its own.)
   integer powerup_bad = 0;
   initial begin
      #1.0;
      if ({slcs_new, sloe_new, slrd_new, slwr_new, pktend_new, fifoadr_new} !== 7'b0_1111_00 || d_new !== 32'd0)
         powerup_bad = powerup_bad + 1;
      if ({u_new.sloe_r, u_new.slrd_r, u_new.slwr_r, u_new.pktend_r} !== {sloe_new, slrd_new, slwr_new, pktend_new})
         powerup_bad = powerup_bad + 1;
      $display("GPIF-IOB-EQUIV: power-up pads slcs=%b sloe=%b slrd=%b slwr=%b pktend=%b fifoadr=%b d=%h, fabric strobe copies %b%b%b%b: %0s",
               slcs_new, sloe_new, slrd_new, slwr_new, pktend_new, fifoadr_new, d_new,
               u_new.sloe_r, u_new.slrd_r, u_new.slwr_r, u_new.pktend_r, powerup_bad ? "WRONG" : "idle bus, as the original");
   end

   // ---------------------------------------------------------------- run ---
   integer holes;
   task need;
      input integer count;
      input [8*64-1:0] what;
      begin
         if (count == 0) begin
            holes = holes + 1;
            $display("NOT EXERCISED: %0s", what);
         end
      end
   endtask

   initial begin
      if ($value$plusargs("cycles=%d", cycles_goal)) ;
      if ($value$plusargs("seed=%d", seed_arg)) ;
      seed_g = seed_arg * 7919 + 1;
      seed_f = seed_arg * 104729 + 2;
      for (i = 0; i < 8; i = i + 1) state_seen[i] = 0;
      for (i = 0; i < 4; i = i + 1) begin
         rd_rem[i] = 0; rd_gap[i] = 20 + 37 * i; rd_wmk[i] = 5; rd_seq[i] = 0; rd_word[i] = 32'd0;
         wr_space[i] = 0; wr_gap[i] = 10 + 23 * i; wr_wmk[i] = 4;
      end
      for (i = 0; i < 2; i = i + 1) begin
         src_valid[i] = 1'b0; src_last[i] = 1'b0; src_data[i] = 64'd0;
         src_left[i] = 0; src_gap[i] = 5; src_mode[i] = 0; src_run[i] = 0; src_beats[i] = 0; src_pkts[i] = 0;
         snk_mode[i] = 0; snk_left[i] = 0; snk_ready[i] = 1'b0; snk_beats[i] = 0; snk_pkts[i] = 0;
      end
      next_rst = cycles_goal / 10;

      wait (cycles >= cycles_goal);
      @(negedge gpif_clk);

      $display("GPIF-IOB-EQUIV: seed %0d, DATA fifos 2^%0d, CTRL fifos 2^%0d, fifo_clk period %0d ps",
               seed_arg, DATA_FIFO_SIZE, CTRL_FIFO_SIZE, 2 * FIFO_HALF_PS);
      $display("  compared: %0d gpif_clk cycles (3 points each, every pad), %0d fifo_clk cycles (every AXI output)",
               cycles, fifo_cycles);
      $display("  bus reads:  %0d beats (%0d of them single-beat), %0d FX3 buffers emptied, %0d bursts stopped by a full local fifo",
               rd_beats, rd_single, rd_bufs, nf_stops);
      $display("  bus writes: %0d beats, %0d pktend, %0d padded 2^n transfers (pad set in WRITE %0d, in THINK %0d), %0d FX3 buffers",
               wr_beats, pktends, write_pkts_2n, pad_write, pad_think, wr_bufs);
      $display("  turnarounds: %0d to the FX3 driving, %0d back to the FPGA driving", turn_to_fx3, turn_to_fpga);
      $display("  packets: rx in %0d (%0d beats), resp in %0d (%0d beats), tx out %0d (%0d beats), ctrl out %0d (%0d beats)",
               src_pkts[0], src_beats[0], src_pkts[1], src_beats[1], snk_pkts[0], snk_beats[0], snk_pkts[1], snk_beats[1]);
      $display("  resets mid-run: %0d, cycles with gpif_enb low: %0d, words written with the FX3 flag saying full: %0d",
               n_resets, enb_low, wr_overrun);
      $display("  cycles per state: IDLE %0d THINK %0d READ %0d WRITE %0d WAIT %0d READ_FLUSH %0d WRITE_FLUSH %0d READ_SINGLE %0d",
               state_seen[0], state_seen[1], state_seen[2], state_seen[3], state_seen[4], state_seen[5], state_seen[6], state_seen[7]);
      $display("  mismatching samples: %0d, undefined samples: %0d", mismatches, xfails);

      holes = 0;
      for (i = 0; i < 8; i = i + 1) need(state_seen[i], "a state of the bus state machine");
      need(rd_beats - rd_single, "burst reads");
      need(rd_single, "single-beat reads");
      need(nf_stops, "read burst stopped by a full local fifo");
      need(wr_beats, "writes");
      need(pktends, "pktend");
      need(pad_write, "2^n padding cycle from a burst");
      need(pad_think, "2^n padding cycle from a single-beat write");
      need(write_pkts_2n, "padded 2^n transfer ended");
      need(turn_to_fx3, "bus turnaround to the FX3");
      need(turn_to_fpga, "bus turnaround to the FPGA");
      need(src_pkts[0], "rx packets");   need(src_pkts[1], "resp packets");
      need(snk_pkts[0], "tx packets");   need(snk_pkts[1], "ctrl packets");
      need(n_resets, "a reset mid-run");
      need(enb_low, "gpif_enb low");

      if (mismatches == 0 && xfails == 0 && holes == 0 && powerup_bad == 0 && cycles >= cycles_goal)
         $display("PASS: gpif2_slave_fifo32 with I/O-block registers equals the reference on every pad and stream, every cycle");
      else
         $display("FAIL: %0d mismatching and %0d undefined samples, %0d parts not exercised, power-up %0s",
                  mismatches, xfails, holes, powerup_bad ? "wrong" : "right");
      $finish;
   end

endmodule
