# What we built, what we learned, where the line is

A reflection on this repository and the live-board debugging of 2026-11-20.
It exists so the same mistakes are not repeated in the next round of work.

---

## 1. What this project is

A re-implementation of the Ettus B210 FPGA for a **Kintex-7 XC7K325T**
board ("OpenSourceSDRLab Custom_SDR_B210", serial 31B92DD), built entirely
from this repository's RTL with an open toolchain (yosys + nextpnr +
prjxray), not from vendor bitstreams:

- 2 RX channels through one 12-bit DDR converter bus (61.44 MSPS total),
  DDC chains, framing, packet gate, FX3 slave-FIFO interface;
- 2 TX channels, interpolation chains (halfband + CIC), DAC slice;
- a settings/control path: USB bulk -> FX3 -> GPIF slave FIFO -> settings
  bus -> radio cores, with CHDR framing and responses;
- MIMO clock switching, ATR frontend control, SPI codec configuration;
- 122 self-checking benches, 24 graph pages, a reproducible bitstream
  (`c1cc09dd…653`, IDCODE 0x3651093) and a bench package.

Measured capability: 61.44 MSPS aggregate, sc16 = **245.76 MB/s**, which is
100 % of the converter's ability and 61.5 % of the 400 MB/s GPIF bus
(sim: 245.3 MB/s delivered vs 244.4 demanded, 2.008 words/beat).

---

## 2. The concepts we actually met (and where the traps are)

### 2.1 The FX3 bridge is two links, not one
- **Firmware/USB side** (the FX3's own ARM core and USB 3.0): independent of
  the FPGA, always alive, answers vendor requests regardless of FPGA state.
- **GPIF side** (32-bit slave FIFO to the FPGA): clocked by **IFCLK, which
  the FPGA generates**. If the FPGA has no clock, this side stops while the
  USB side keeps working — producing exactly the confusing signature we saw
  (device enumerates, firmware answers, FPGA "configured", control dead).

Research: Infineon AN65974 (FX3 slave FIFO), and upstream UHD B200 FPGA
source where `IFCLK` is driven from `gpif_clk`
(`S6CLK2PIN .I(gpif_clk), .O(IFCLK)`).

### 2.2 "Configured" and "answering" are different facts
- DONE is a **static configuration pin**: a bitstream can configure and the
  fabric sit silent.
- The control ACK requires clocks (GPIF + settings bus) — a different
  question entirely.
- UHD's loader waits for `FX3_STATE_RUNNING` as its success condition
  (`b200_iface.cpp:657`), and state 5 is `UNCONFIGURED` = *DONE never
  asserted*, not a "wedged FX3". The stock B210 image is a **Spartan-6**
  bitstream and can never configure a Kintex — which is why every
  UHD-initiated load appeared to "fail identically".

### 2.3 CHDR framing has enforceable rules
- The USB control stream is 32-bit CHDR: word0 = {flags, seq, **length**},
  word1 = SID, then payload.
- `gpif2_error_checker` drops a packet unless `length` equals the **whole
  packet length in bytes** — the ABI bench never noticed because
  `radio_ctrl_proc` ignores the field; on the wire it decides survival.
- Responses use PKTEND to release the FX3 DMA buffer; 64-bit beats are split
  **high half first** on egress (`axi_fifo64_to_fifo32` state 0).

### 2.4 AXI stream conventions are load-bearing
- The 64<->32 converters assume a protocol-correct partner. A source that
  re-offers an already-consumed beat (data updated a cycle after the
  handshake, tvalid held high) **corrupts** the splitter: we watched a word
  duplicate and a word vanish. The RTL is not wrong; the master was.

### 2.5 Converter arithmetic sets the bandwidth ceiling
- The AD9361 in CMOS mode has **one 12-bit DDR bus**, 61.44 MSPS total:
  1 RX at full rate OR 2 RX at 30.72 MSPS each. "2 x 61.44" does not exist;
  Ettus' knowledge base lists no such mode (2 RX tops out at 56 MSPS).
- Link format sc16 costs 4 bytes/sample: 61.44 MSPS -> 245.76 MB/s.
  A 12-bit packed wire (184.32 MB/s) buys link headroom, never sample rate.
- 16-bit host words clip before anything else: keep peaks <= 32767,
  reference drive -18.7 dBFS rms for the -55 dBc loopback floor rule.

### 2.6 Clock trees are single points of failure
This design has exactly one clock input: `codec_main_clk_p/n` 40 MHz at
pin AA17 -> one MMCM -> bus (100 MHz), GPIF (100 MHz), radio (61.44), and
**IFCLK to the FX3**. `GPIF_CTL9` (from the FX3) resets that MMCM. A missing
input or a held reset kills the FPGA, the GPIF bridge and the FX3's data
path at once, while DONE stays high and USB stays alive.

---

## 3. Assumptions I got wrong, and what caught each

| wrong assumption | what caught it | lesson |
|---|---|---|
| "state 5 = wedged FX3, needs power cycle" | reading UHD's own enum: 5 = UNCONFIGURED | read the code that prints the error before theorising |
| "the stock image works, so our RTL is suspect" | stock b210 is a Spartan-6 bitstream; it can never configure this board | a control experiment is worthless if the control cannot run |
| "UHD loads our image" | UHD always offers its stock path; only hw_load.py loads ours | verify what was actually loaded, not what you asked for |
| "our control path is fine, it's the board" | no bench drove the ctrl path through the FIFO at all — so we wrote one (tb_ctrl_fifo, PASS) | untested is not the same as correct |
| "the splitter duplicated a word, RTL bug" | tracing showed my testbench source was AXI-noncompliant | before convicting RTL, check the model driving it |
| "any control byte pattern will do" | error checker drops wrong-length CHDR silently | the wire format is part of the contract; bench it |

Every one of these was caught by **reading source or measuring**, never by
reasoning from plausibility.

---

## 4. Awareness rules for the next round (swarm hygiene)

1. **Name the evidence class** for every claim: measured / source-verified /
   simulated / assumed. Only the last is allowed to be wrong silently.
2. **Never trust a testbench model of an RTL block** until it has been
   compared against the block (a model that re-offers beats looks fine and
   corrupts the DUT).
3. **Check pin and clock directions in source** before reasoning about a
   board (IFCLK is an FPGA *output* here).
4. **A gate target that is never called runs no benches** — and a hop with
   no bench is unproven, however many benches pass around it.
5. **Draw each figure from the capture its own target made**; never hand-run
   a plot script after a sweep.
6. **One physical unknown at a time**, with a discriminator that can only
   give two answers. The LED diagnostic is the model: smallest possible
   design, one bit of state, an unambiguous readout.
7. **State the retraction out loud** when an earlier claim is disproved —
   silent corrections poison the record.

---

## 5. Measurement update (after the LED diagnostics)

The LED diagnostics settled the clock question **by measurement**:

* v1/v2 (raw 40 MHz, known-wired LED): green and blue LEDs **blink** ->
  the 40 MHz reference reaches the FPGA pins.  The clock-absent hypothesis
  is **refuted**.
* RX1 LED steady -> the MMCM **locks** when its reset is tied low.
* v3 now wires the MMCM reset to the real `GPIF_CTL9` pin from the FX3, so
  the next reading separates "clocks fine" from "FX3 holds the design in
  reset".  If RX1 is dark while the blue LED blinks, `GPIF_CTL9` is the
  root cause.

With the clock alive, the remaining suspects are, in order: (i) GPIF_CTL9
held (v3 tests it), (ii) GPIF source-synchronous input timing - our own XDC
records a 0-1 ns margin on the FX3->FPGA flag inputs and no way to
constrain it in nextpnr, and the Kintex-port community reports exactly this
failure mode (docs/RESEARCH-NOTES.md D2), (iii) a logic defect in the port -
now the least likely, since tb_ctrl_fifo proves that logic correct when
clocked and out of reset.

## 6. Where the line is (2026-11-20)

Proven: image builds and configures on the real Kintex; FX3 healthy through
every reset; control-path RTL correct in simulation; full-rate data path
characterised; 2-RX tooling ready (rx_explore.py / rx_probe.py).

Open: why the configured, clocked FPGA does not answer the control packet.
The candidates are now hardware-interface level (`GPIF_CTL9` reset state, or
GPIF input sampling phase), and both are testable with the board as oracle:
the LED diagnostics measure them, and a re-phased/requalified rebuild tests
the fix.

The next datapoint in this project is the RX1 LED reading of diag v3.
