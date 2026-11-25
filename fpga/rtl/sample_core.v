// SPDX-License-Identifier: GPL-3.0-or-later
//
// sample_core - everything that must happen on the sample clock: the time
// counter, rx sample times out with their time, tx sample times played at
// theirs. Everything else runs on the bus clock (rx_framer, tx_player).
//
// Clock and strobe: sclk is the radio's data clock; stb marks the cycles
// that carry a sample time (every cycle with 1 channel, every other with
// 2). "Time" counts strobes: one tick per sample time.
//
// Time: now += 1 per strobe. To set it, the bus side puts the new value on
// set_value, keeps it there and toggles set_req; at the next strobe now
// becomes set_value and set_ack takes set_req's value.
//
// rx: at every strobe {now, sample} goes into the rx cdc_fifo; the sample
// is the radio's (mode 0), the pattern f(now) (mode 1: I0 = t, Q0 = ~t,
// I1 = 7 t, Q1 = 13 t + 5, 12 bits each) or the tx sample of this strobe
// (mode 2, loopback). An entry the FIFO cannot take counts in rx_lost.
//
// tx: entries from tx_player through the tx cdc_fifo, one per strobe:
//   idle    the DAC gets 0. An entry with START_OF_BURST and a time waits
//           for the strobe where now == time; if now has passed it, the
//           burst is LATE and discarded up to its END_OF_BURST (or the next
//           START_OF_BURST) entry. Any other entry plays at once.
//   burst   one entry per strobe; END_OF_BURST ends the burst after its
//           sample (or before the strobe for an entry without a sample) and
//           counts one BURST_ACK - but only if a burst was playing: a
//           header-only END_OF_BURST in idle counts nothing.
//           No entry at a strobe: UNDERFLOW (counted once per gap), the DAC
//           gets 0, no BURST_ACK is possible for this burst any more, and
//           the burst goes on when entries come. Because a packet carries a
//           time only at START_OF_BURST, every sample after the gap plays
//           shifted by the gap; the host must therefore treat an UNDERFLOW
//           as "this burst's timeline is broken" and start a new burst.
//           A timed START_OF_BURST during a burst ends the burst (no
//           BURST_ACK) and waits for its time.
// Discard: entries are taken until END_OF_BURST, or until a START_OF_BURST
// of the next burst, which is left at the head and starts it.
// Event counts leave Gray-coded (gray_sync on the bus side), so do now.
`default_nettype none

module sample_core (
  input  wire         sclk, srst,
  input  wire         stb,
  input  wire [47:0]  adc,           // radio sample, {Q1, I1, Q0, I0}
  output reg  [47:0]  dac = 0,       // valid at the strobe after a tx strobe
  input  wire [1:0]   mode_async,    // 0 radio, 1 pattern, 2 loopback (static)
  // time
  input  wire [63:0]  set_value,     // stable while set_req != set_ack
  input  wire         set_req,
  output reg          set_ack = 0,
  output wire [63:0]  now_gray,
  // rx: to the rx cdc_fifo
  output wire         rx_valid,
  output wire [111:0] rx_entry,      // {time, sample}
  input  wire         rx_full,
  // tx: from the tx cdc_fifo, {present, sob, eob, timed, time, sample}
  input  wire         tx_valid,
  input  wire [115:0] tx_entry,
  output wire         tx_take,
  // events, Gray-coded counts
  output wire [15:0]  rx_lost_gray, underflow_gray, late_gray, ack_gray,
  output reg          tx_active = 0, // in a burst (for antenna switches and LEDs)
  output wire         sclk_alive      // toggles every 2 sclk cycles: the bus side checks the clock, not the strobes
);
  function [15:0] gray16(input [15:0] b); gray16 = b ^ (b >> 1); endfunction

  // -- configuration from the bus side ------------------------------------------------
  (* ASYNC_REG = "TRUE" *) reg [1:0] mode1 = 0, mode = 0;
  (* ASYNC_REG = "TRUE" *) reg set1 = 0, set2 = 0;
  always @(posedge sclk) begin mode1 <= mode_async; mode <= mode1; set1 <= set_req; set2 <= set1; end

  // -- time ------------------------------------------------------------------------------
  reg [63:0] now = 0, now_g = 0;
  assign now_gray = now_g;
  wire [63:0] now_n = set2 != set_ack ? set_value : now + 1;
  always @(posedge sclk)
    if (srst) begin now <= 0; now_g <= 0; end
    else if (stb) begin
      now <= now_n; now_g <= now_n ^ (now_n >> 1);
      if (set2 != set_ack) set_ack <= set2;
    end
  // Setting the time jumps the counter: its Gray copy then changes in many
  // bits at once and the bus side may see one mixed value. The bus side
  // reads the time only after set_ack, 4 bus clocks later (see regs).

  // -- tx ----------------------------------------------------------------------------------
  wire        e_present = tx_entry[115], e_sob = tx_entry[114], e_eob = tx_entry[113], e_timed = tx_entry[112];
  wire [63:0] e_time    = tx_entry[111:48];
  wire [47:0] e_data    = tx_entry[47:0];
  localparam IDLE = 0, BURST = 1, DISCARD = 2;
  reg [1:0]  state = IDLE;
  reg        gap = 0;                  // in an underflow: the DAC is silent
  reg        gapped = 0;               // this burst had an underflow: no BURST_ACK
  reg [15:0] underflows = 0, lates = 0, acks = 0, lost = 0;

  // At a strobe, in IDLE or BURST, the entry at the head decides:
  //   timed START_OF_BURST, time ahead   wait (a burst in progress ends)
  //   timed START_OF_BURST, time passed  LATE: discard to END_OF_BURST
  //   no sample                          END_OF_BURST: the burst ends
  //   else                               play it; END_OF_BURST ends the burst
  wire timed = tx_valid && e_sob && e_timed;
  wire early = timed && e_time > now;
  wire late  = timed && e_time < now;
  wire live  = stb && state != DISCARD && tx_valid && !early;   // the head is used now
  wire play  = live && !late && e_present;
  wire resync = state == DISCARD && tx_valid && e_sob;     // next burst's start, left in place
  assign tx_take = live || (state == DISCARD && tx_valid && !resync);

  always @(posedge sclk) begin
    if (srst) begin
      state <= IDLE; gap <= 0; gapped <= 0;
    end else begin
      if (live) begin
        gap <= 0;
        if (late) begin lates <= lates + 1; state <= e_eob ? IDLE : DISCARD; gapped <= 0; end
        else if (!e_present || e_eob) begin
          // one ack per burst that played through without a gap: a
          // header-only END_OF_BURST in idle (no burst) counts nothing, and
          // neither does one after an underflow (its samples played shifted)
          if (state == BURST && !gapped) acks <= acks + 1;
          state <= IDLE; gapped <= 0;
        end else begin
          if (state != BURST) gapped <= 0;      // a new burst starts here
          state <= BURST;
        end
      end
      if (stb && state == BURST && early) begin state <= IDLE; gap <= 0; gapped <= 0; end
      if (stb && state == BURST && !tx_valid) begin
        if (!gap) underflows <= underflows + 1;
        gap <= 1; gapped <= 1;
      end
      if (state == DISCARD && tx_valid && (e_eob || e_sob)) state <= IDLE;
    end
    // a gap means the DAC is silent: antenna switches and the PA follow
    tx_active <= state == BURST && !gap;
  end
  // one wire for the DAC and for the loopback source, so a bench checks
  // what the DAC really gets
  wire [47:0] dac_now = play ? e_data : 48'd0;
  always @(posedge sclk) if (stb) dac <= dac_now;

  // -- rx ----------------------------------------------------------------------------------
  wire [11:0] t = now[11:0];
  wire [47:0] pattern = {t * 12'd13 + 12'd5, t * 12'd7, ~t, t};
  wire [47:0] rx_sample = mode == 2'd1 ? pattern : mode == 2'd2 ? dac_now : adc;
  assign rx_valid = stb;
  assign rx_entry = {now, rx_sample};
  always @(posedge sclk) if (stb && rx_full) lost <= lost + 1;

  // the clock itself, not the strobe: a slow strobe divider must not look
  // like a stopped clock
  reg [1:0] hb = 0;
  always @(posedge sclk) hb <= hb + 1;
  assign sclk_alive = hb[1];

  assign rx_lost_gray   = gray16(lost);
  assign underflow_gray = gray16(underflows);
  assign late_gray      = gray16(lates);
  assign ack_gray       = gray16(acks);
endmodule

`default_nettype wire
