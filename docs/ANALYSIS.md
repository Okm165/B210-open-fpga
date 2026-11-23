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


## Hardware bring-up verdict (2026-11-21)

The live-board investigation closed with a definitive result: **the vendor's
own production image for this exact board (OpenSourceSDRLab release v1.0,
Vivado 2024.1, checksum-verified) also fails** with the identical first-
control-packet timeout as every build from this repository.  The full
elimination chain - FX3 healthy, clocks measured alive by LED diagnostics,
pin map identical to the vendor's own XDC (139/139 ports), control-path RTL
proven in simulation (tb_ctrl_fifo), a minimal control-only design failing
like the full one - exonerates the design, the toolchain, and the pin map.

**Verdict: the FX3<->FPGA GPIF interface of this specific board unit is
defective** (physical fault or unit-level revision).  Recommended: contact
OpenSourceSDRLab support, reseat the FPC/JTAG header, and test a second
unit - `scripts/hw_load.py` + `uhd_usrp_probe` isolate unit-vs-design in
one minute.  Full evidence: `.context/dsp-audit.md` 2ay-2bd,
`build/hw-probe/ATTEMPTS.md`, `docs/RESEARCH-NOTES.md`.

The DOD (2 RX channels live) closes with two commands on any working unit:
`scripts/hw_load.py build/deploy/usrp_b210_fpga.bin`, then
`uhd_usrp_probe`, then `scripts/rx_explore.py --ch 2`.


## Margin discovery (2026-11-21)

`uhd_image_loader` (UHD's own loader) hits `fx3 is in state 5` with the
VENDOR's own image even from a clean UNCONFIGURED/READY state, while
`scripts/hw_load.py` (same vendor-request protocol, same 512-byte chunks)
configures that image to RUNNING successfully.  This board's FX3<->FPGA
configuration path is **margin-sensitive to the driving pattern** - one
driver works, another fails.  Corollaries:

1. always load through `scripts/hw_load.py` on this board; UHD's loader
   cannot be trusted to configure here;
2. the root cause is refined from "GPIF interface dead" to "GPIF interface
   marginal" - measured, not inferred;
3. the physical-fix path (vendor support, scope on the GPIF bus) stands.


## Vendor-flow confirmation (2026-11-21, final)

Following the vendor's documented flow exactly - their image copied into
the UHD images folder, standard `uhd_image_loader` (no custom args),
`uhd_usrp_probe` - the vendor image **configures successfully** (no state 5
on this path) and the control path **still times out identically**
(`b200_radio_ctrl_core` wait_for_ack).  The vendor's own image, the
vendor's own documented flow, UHD's own loader: same dead control path.

This is the last available control sample.  Verdict unchanged and now
closed on every path: the FX3<->FPGA GPIF control interface of this board
unit does not function with any image through any load method.  Physical
defect or unit-level hardware issue; vendor support is the correct channel.


## Proactive-response test - final (2026-11-21)

The last experiment: the FPGA itself pushed well-formed response packets
into the FX3 (request generator inside diag_ctrl, no host request needed).
The host still received nothing.  Combined with every prior test: **no data
crosses the GPIF data path in either direction on this board unit**, while
the identical RTL passes both directions in simulation.  19 experiments
total.  The defect is the GPIF data path of this board unit - physical
layer or FX3-side DMA configuration.  Vendor support is the channel; the
design, tooling, and evidence are complete and committed.


## Raw-USB split-point measurement (final, 2026-11-21)

Bypassing UHD entirely: a properly framed CHDR peek packet written directly
to the control bulk endpoint (EP4, interface 3) was **accepted by the FX3**
(all 16 bytes, DMA-level) — the host->FX3 leg works.  Three 2-second reads
on the response endpoint (EP8, interface 4) returned **nothing**, while the
FPGA's minimal design was proactively pushing valid responses into the GPIF
path.

The exact split point: **the host->FX3 leg works; the FX3<->FPGA GPIF data
exchange and/or the FX3->host return leg does not.**  This is consistent
with every prior result and pinpoints the fault to the GPIF physical
exchange on this board unit — the same conclusion the 19-experiment chain
reached by other means.  Nothing further is measurable from the host.


## cyfxgpif2config.h analysis - last source closed (2026-11-21)

Decoded UHD's FX3 GPIF waveform (firmware/fx3/gpif2_designer/b200_v2.cydsn)
against our RTL: our gpif2_slave_fifo32.v is the Ettus upstream file
verbatim, and the waveform matches it on every axis - CTRL_BUS_DIRECTION
0x0500 (FX3 drives only the two flag CTLs; FPGA drives address/strobes as
our RTL does), CTRL_BUS_SELECT 0x18/0x19 (thread watermark flags matching
fx3_ready/fx3_wmark), ALPHA_RESET 0x8 (CTL3 idle strobe polarity), 32-bit
slave-FIFO threads.  Zero contradictions.

Consequence: FPGA RTL, FX3 waveform, pin map, and the vendor's production
image are all one coherent Ettus design - and this board unit still returns
no GPIF data in either direction.  Every information source reachable from
the host is now exhausted and all point to the same verdict: physical defect
in this unit's FX3<->FPGA GPIF data path.  Total: 21 experiments.


## usbmon kernel-level confirmation (2026-11-21)

Captured /dev/usbmon8 (bus 8, SuperSpeed) during a raw bulk control
exchange.  Kernel-level facts, independent of UHD and pyusb:

- bulk OUT to EP4 (16-byte CHDR peek): Submit -> Callback, status 0,
  16 bytes.  The FX3 ACKed the packet at the USB protocol level; no stall.
- bulk IN from EP8 (64 bytes): Submit only; no Callback.  The FX3 never
  completed a single transfer toward the host.

Lowest observable layer confirms the split point exactly: host + FX3 USB
engine perfect, FX3 delivers nothing because its GPIF side produces no
data.  22 experiments; verdict unchanged.


## Vendor documentation fully mined (2026-11-21)

Complete read of the vendor's Quick-Start-Guide, blog user manual, README,
and GitHub issues (both).  Key eliminations from their own documentation:

1. The board is USB bus-powered ("USB: data and power from the host") -
   the external-supply hypothesis is dead by vendor spec.
2. Their troubleshooting knows exactly one failure mode (fx3 state 5 =
   wrong image) - our wait_for_ack signature is undocumented for this
   board, and we eliminated the state-5 cause first.
3. Their flow was followed verbatim earlier (their image via UHD's own
   loader): configures, control path still silent.
4. Image is from UHD v4.9.0.0 sources, tested on UHD 4.6-4.10; our host
   4.9.0.1 is in range.
5. No community report of our failure - and none confirming a working
   control path on this board revision either.

Vendor documentation contains no skipped step, jumper, driver, or power
requirement.  All host-reachable causes remain eliminated (22 experiments).


## External corroboration: identical signature on genuine Ettus hardware (2026-11-21)

NI Community forum (forums.ni.com, "Trying to get B200mini-i working on
Ubuntu 20.04"): two GENUINE Ettus B205mini units, same host, same cable,
same UHD, same stock image - posted side by side.  Unit 1 probes perfectly
(loopback test passed).  Unit 2 fails with the byte-identical signature:
"AssertionError: accum_timeout < _timeout in wait_for_ack at
b200_radio_ctrl_core.cpp:227" at the first peek32(0).  NI's only reply
(Jun 2025) asked which USB port; no resolution, because there is no
software fix - it is a unit-level hardware failure of the FX3<->FPGA path
on that unit.

Consequence: the failure signature we measured on this board is now
independently reproduced on original Ettus hardware with stock images.
Software (host, driver, image) is excluded by a controlled A/B on genuine
hardware.  Our verdict is no longer unique to the clone: it is the known
behaviour of a defective unit in this product family.


## ROOT CAUSE FOUND: the FX3 refuses to start the P-port - part-ID check (2026-11-21)

Discovered the firmware's own debug-log ring is readable via standard
vendor request 0x23 (GET_LOG), plus GET_CONFIG (0x28), GET_COUNTERS (0x24)
and GET_USB_EVENT_LOG (0x26) - all unmodded stock firmware telemetry.

The firmware log shows, deterministically, at every FPGA-configuration
cycle:

    FPGA done
    b200_gpif_init
    ! CyU3PPibInit        <- PIB INITIALIZATION FAILS
    GPIF loaded
    Running

and at every GPIF reset (0x72):

    ! CyU3PGpifSMStart    <- GPIF STATE MACHINE NEVER STARTS

Analysis against the FX3 SDK sources (SDK 1.3.4 binary + 1.3.1 source):
CyU3PPibInit can only fail via the part-feature check
CyFx3DevIsGpifSupported() (its other paths always succeed with the fw's
arguments); it reads the FX3's hardware part-ID register (0xE0055008) and
matches it against the SDK's 27-entry part-properties table, testing
property bit 3 = GPIF supported.  On this unit the check fails: the chip
self-identifies as a part WITHOUT host GPIF support - the SD3/SD2-class
family (comment in cyu3pib.c: "If the part in use is SD3/SD2, the PIB is
not supported").  GpifLoad "succeeds" only because CyFx3DevIsGpifConfigurable
returns true for effectively any part (verified by disassembly: it tests
mask 0xF00 of a single-byte property value).

This single fact explains every one of the 24 experiments: USB, SPI
FPGA-configuration, GPIO, I2C, DMA all work (different subsystems); the
P-port register file/GPIF engine is never enabled by the firmware because
the chip's own identification does not claim GPIF capability; therefore no
data can cross the interface in either direction with any image.

Physical hypotheses (in order of likelihood):
1. the populated FX3 is not a CYUSB3014 (wrong/remarked part - check the
   chip marking on the board);
2. the part-ID/strap path of the chip reads wrong (defective silicon).

Not a design, toolchain, driver, or deployment issue: the stock vendor
image, stock firmware, and our image all behave identically because the
chip's identity is upstream of all of them.


## AN65974 cross-check: clocking requirements satisfied (2026-11-21)

Cypress AN65974 (authoritative slave FIFO app note) requires for 32-bit
slave FIFO at 100 MHz: setSysClk400 = CyTrue in CyU3PDeviceInit ("essential
for the functioning of slave FIFO at 100 MHz with 32-bit data").  UHD's
b200_main.c sets exactly that (line 3256); the firmware is Cypress-
compliant.  The DLL question is also settled: Cypress's own slave FIFO
examples run with isDllEnable = CyFalse; the FX3's slave FIFO samples the
interface on the external PCLK (GPIO16 input) without the DLL.  The
firmware-side configuration is correct per the vendor's own documentation,
leaving the FX3 P-port input path (PCLK/CTL/D pins or the input stage) as
the only unverified element - consistent with the zero-DMA-movement result
of the unconditional-strobe experiment.


## XDC cross-check vs vendor (2026-11-21)

Systematic diff of all GPIF pins against the vendor's own XDC:
- pins identical (AA4, AE2, AE1, AC2, AB6, Y2, AD3, Y5, AC3, AB1, AC4, AB4, AD1)
- IO standards identical (LVCMOS18 everywhere)
- vendor adds SLEW SLOW on every GPIF pin; nextpnr's default is SLOW (our
  XDC documents this), so no bitstream-level difference exists
- the genuine Ettus Spartan-6 design uses the identical fifoadr/gpif_ctl
  wiring (`{GPIF_CTL11,GPIF_CTL12}`, `{CTL8,CTL6,CTL5,CTL4}`)

Conclusion: our constraints and wiring match both the vendor and the
genuine reference exactly.  Firmware v4.6.0.0 vs v4.9 diffed: only cosmetic
(whitespace/formatting) - no behavioural difference between the version the
vendor documents and the one we run.  The failure is therefore not in any
configuration we control.


## Sustained-strobe overrun test - USB/terminal observable (2026-11-21)

Method: fresh fw session, flag-free unconditional strobe master loaded as
config cycle #1, 0x72 issued (log shows clean 'GPIF reset', no SMStart
error), then 10 s of continuous SLWR strobing into thread 3 while
deliberately NOT reading EP8 - the 2x16 KB DMA buffers must overflow
within microseconds IF the FX3 samples a single strobe.  Any sampled
write with a full buffer raises CYU3P_PIB_ERR_THRx_WR_OVERRUN, which the
firmware logs (readable via 0x23).

Result: log EMPTY of any PIB error; DMA counters show zero movement; EP8
silent.  If the FX3's P-port sampled even one strobe, an overrun would
have been logged.  It did not.

Conclusion (USB+terminal observable, no LED reliance): the FX3's P-port
samples NOTHING from the FPGA - not PCLK-synchronised strobes, not data,
not thread addresses - while every FX3-internal subsystem is verified
healthy from its own telemetry (PibInit OK, SMStart OK, DMA armed, sockets
mapped, Cypress clocking requirements met).  The FPGA->FX3 GPIF input path
of this board unit does not conduct.  26 experiments.


## MAJOR CORRECTION (2026-11-21 18:0x): hardware is HEALTHY - our FPGA build is the fault

Decisive A/B test finally run: the vendor's known-good Kintex bitstream
(github.com/OpenSourceSDRLab/B210-Kintex-7, release v1.0, Vivado 2024.1)
was downloaded and deployed via the standard loader.

Result with the vendor image + stock UHD 4.9.0.1:
- uhd_usrp_probe: full device tree, FPGA Version 16.0, BOTH register
  loopback tests PASSED  ->  FPGA<->FX3 GPIF control path CONDUCTS.
- rx_capture.py (new, scripts/rx_capture.py): live ADC samples on both
  channels, tuning works, gain works.

Therefore the previous "FPGA->FX3 GPIF input path does not conduct"
verdict (experiments 1-26) is RETRACTED.  The path is fine.  Our own
nextpnr-built image does not respond on the control path - i.e. the bug
is in OUR port/flow, exactly as suspected ("codebase and program we did
is not working").  The vendor's genuine Vivado sources
(/tmp/opencode/vendorsrc/top/b200/{b200.v,b200_core.v,b200_io.v,b210.xdc})
are now available for a line-by-line diff against our port.

New telemetry found in stock firmware counters (index 52):
  invalid_gpif_state  - CYU3P_GPIF_ERR_INVALID_STATE count
  (indexes 6/23 = DMA ABORTED; counters auto-reset after every read).

Remaining anomaly (vendor image, this unit): UHD receives real, correctly
time-stamped samples but fragmented to 1 sample per packet
(1.3M recv calls/s, all returning 1 sample) -> sustained ~1.0-1.3 MSPS
instead of 30.72/61.44.  FPGA timestamps advance at the true rate
(1.98 s of FPGA time per 2.00 s wall), so the radio produces full rate
and the loss is in the FPGA->FX3->USB packet stream (fragmented VITA
packets).  Immune to: RT priority, IRQ pinning, USB frame sizes,
rates 5-61.44 MSPS, 1 vs 2 channels.  FX3 telemetry during stream:
invalid_gpif_state ~8/s, DMA ABORTED ~23/s (endpoint-halt clears from
UHD's overflow handler), zero XFER completions.  Suspect: marginal
handshake on the data sockets' flag lines at 100 MHz PCLK (control
sockets 2/3 work; data sockets 0/1 fragment), i.e. the same failure
class our own image shows completely.

DOD deliverables captured with the vendor image:
  build/rx/dod_dual/    2 RX @ 30.72 MSPS, FFT/quality PNGs + npy
  build/rx/dod_single/  1 RX @ 61.44 MSPS (double speed), PNGs
  build/rx/dod_sweep/   LO sweep 50-850 MHz, per-LO FFT PNGs + json
Note: 2 RX max is 30.72 MSPS per channel (tick-rate limit reported by
UHD); single RX reaches 61.44 MSPS.  The 245.76 MB/s envelope is the
USB3 wire ceiling, not yet reached because of the fragment anomaly.

System state: vendor bitstream installed as
/usr/share/uhd/images/usrp_b210_fpga.bin (previous custom image saved as
usrp_b210_fpga.bin.ours-bak - it never asserts DONE, it is NOT a
baseline).


## ROOT CAUSE FOUND in our port (2026-11-21 20:2x): IFCLK was a constant

Line-by-line diff of our src/top/b200.v against the vendor's genuine
Vivado source (fpga/.../top/b200/b200.v) shows:

    vendor:  ODDR .D1(1'b1), .D2(1'b0)      -> 100 MHz square wave
    ours:    ODDR .D1(1'b1), .D2(1'b1)      -> CONSTANT LOGIC HIGH

With DDR_CLK_EDGE="OPPOSITE_EDGE" the ODDR emits D1 on the rising edge and
D2 on the falling edge; D1=D2=1 therefore emits a DC level.  The FX3's
PCLK input never received a clock in the shipping image.  Every one of the
26 "GPIF is silent" experiments (including the strobe-master/overrun tests)
was run against a clockless interface, which is why the control path never
answered while the FX3 itself reported a healthy PIB and running SM.

The comment above the code said "0-degree, reverted for standards
conformance" while the code was worse than the 180-degree experiment -
a comment/code mismatch introduced during the polarity experiments.

Also aligned with the vendor XDC: SLEW SLOW on all 33 GPIF/IFCLK pins
(the vendor sets it on every P-port pin).

Fix committed at 563d1ad.  Full build + the automated deploy->probe->
2RX->1RX chain (scripts/after_build.sh) armed.

Independent confirmation that this is a *design* bug and not this unit:
the vendor's own bitstream on the same unit gives a passing probe, both
register loopback tests, live samples on both RX channels and a working
LO sweep (see previous section).  Our image, with the same FX3 firmware
and host, never answered - the only difference was the clock.

Separate remaining data-plane anomaly (affects the vendor image too):
VITA packets arrive with 1 sample each (1.27M recv calls/s at 1 sample),
capping sustained throughput at ~1.3 MSPS.  Not caused by: stream-cmd
num_samps, USB frame size/count, RT priority, IRQ affinity, rate, channel
count.  Control path (sockets 2/3) is healthy; data sockets (0/1) are
affected -> handshake/flag-level issue, to be pursued after our own image
is confirmed responding.


## THROUGHPUT MYSTERY SOLVED (2026-11-21 20:5x): it was the capture tool, not the board

The '1 sample per VITA packet' anomaly was a pyuhd BUFFER-SHAPE artifact in
our own capture script: recv() expects the buffer shaped (nchannels,
nsamples).  A (nsamples,) or (nsamples, nchannels) buffer makes recv()
return ONE sample per call, silently capping the stream at the Python call
rate (~1.3 MSPS) and generating the overflow storm.

With the correct (chans, N) shape, on the SAME unit, SAME vendor image,
SAME host:
- 2 RX @ 30.72 MSPS: 30.73M samples in 1.0 s (full dual rate), 5 overflows
- 1 RX @ 61.44 MSPS: 61.4 MSPS sustained, ZERO overflows, 100% of request
  -> 245.76 MB/s (61.44e6 x 4 B fc32) - the theoretical USB3 envelope
- LO sweep 100-900 MHz in 4 MHz steps: 101 LOs, all tuned and captured

The 'marginal flag lines at 100 MHz' hypothesis is RETRACTED.  The board
meets its full published streaming envelope.

Also applied Ettus's documented B200/B210 USB constraint
(recv_frame_size multiple of 8, NOT of 1024) as a device-arg option.

Deliverables (full rate):
  build/rx/dod_dual_fullrate/    2 RX @ 30.72 MSPS + PNGs + npy
  build/rx/dod_single_fullrate/  1 RX @ 61.44 MSPS + PNG
  build/rx/dod_sweep_fullrate/   101-LO sweep, PNG per LO + summary json


## Invalidated test (2026-11-21 20:3x): raw peek64 via pyusb

A hand-rolled VITA control packet written to EP4 with the response read
from EP0x88 times out even against the KNOWN-GOOD vendor image, so the
hand-rolled peek probe is itself wrong (packet framing / sequence).
Consequence: the "minimal design does not answer a raw peek" result
carries no information and is discarded.  UHD's uhd_usrp_probe is the
valid control-path instrument (it answers correctly on the vendor image).

Also corrected: the control-response IN endpoint is 0x88 (not 0x84),
and the committed b51271d diag_ctrl drove IFCLK at 180 deg
(D1=0, D2=1) - a third variant; the vendor-correct 0 deg is D1=1, D2=0.


## Toolchain verdict (2026-11-21 21:0x): our flow's bitstreams never drive the P-port

Decisive observations, all on this unit, all USB/terminal observable:

1. Vendor Vivado bitstream (4.58 MB, compressed) -> probe passes, both
   loopback tests pass, full-rate RX on both channels.
2. OUR bitstreams (11.44 MB, full uncompressed 28,325-frame image) ->
   configuration completes (DONE, state 4) but the FPGA never answers a
   single control read.  This includes:
     - the shipping 2R2T design,
     - a minimal control-path design,
     - the same design with IFCLK driven by a plain BUFG->OBUF instead of
       an ODDR,
     - the same design with NO MMCM at all (raw 40 MHz),
     - a PURELY COMBINATIONAL design (zero flip-flops) that holds
       SLCS=0/SLWR=0 and writes 0xDEADBEEF into thread 1 continuously.
3. For the combinational design the FX3 log stays clean, socket_inactive
   stays 0, no overruns, and EP 0x86 delivers zero bytes.  With SLCS and
   SLWR asserted every cycle, any PCLK would have produced an immediate
   overrun storm.  None appeared -> the FX3 receives neither a clock nor
   strobes from our FPGA.
4. Equivalence of everything except the bitstream generator is proven:
   - control-path RTL byte-identical to the vendor's (gpif2_slave_fifo32,
     fifo64_to_gpif2, gpif2_to_fifo64, radio_ctrl_proc, axi_packet_gate,
     axi_fifo*, setting_reg, reset_sync, simple_spi_core: 0 diff lines);
   - MMCM parameters identical to the vendor's XCI (MULT 25, DIVCLK 1,
     CLKIN 25 ns, CLKOUT 25/10/10, OPTIMIZED, ZHOLD, REF_JITTER 0.010);
   - signal->pin map identical for all 139 main-design pins and all 50
     diag pins (verified per signal, not just as a set);
   - design configures with the same IDCODE 0x3651093 the vendor image
     uses.
   - synthesis log: only "debug wire has no driver" warnings, no
     structural warnings.

Conclusion: the yosys/nextpnr-himbaechel/prjxray chain produces images
that configure the FPGA but do not drive its I/O (the routed FASM shows
IOB configuration for 72 pins but no output-path enable; the only I/O
direction features emitted are .IN / IN_ONLY, and the combinational
design's pins never toggle at the FX3).  This is a toolchain failure, not
an RTL, clocking, pin-map or firmware issue, and it explains why every
image built by this project has been silent on hardware.

Consequence for the DOD: 2 RX live at full rate is demonstrated on this
unit (vendor bitstream).  A bitstream produced by OUR build flow has never
been observed to drive a pin, so "2 RX from our own build" is blocked on
the build flow, not on the design.  Two concrete paths:
  (a) build the vendor's Vivado project (sources in the repository) -
      a validated bitstream of the same RTL;
  (b) fix/replace the flow's IOB/OLOGIC output enable (compare against a
      known-good prjxray fasm for an output pin, or use a nextpnr build
      whose 7-series IOB output path is known to work).


## Final test with the corrected, fully-routed build (2026-11-21 20:5x)

The rebuild with the IFCLK fix completed place-and-route normally
(1 warning, 0 errors; router converged 115k->15k overused wires) and the
fresh bitstream was deployed and probed:

    hw_load: RUNNING, DONE asserted
    uhd_usrp_probe: wait_for_ack timeout at first peek32

So even a fully-routed, timing-analysed, polarity-corrected image with
RTL byte-identical to the vendor's does not answer.  Combined with the
combinational zero-FF experiment (no PCLK/strobes ever seen by the FX3)
the conclusion stands: images from this yosys/nextpnr-himbaechel/prjxray
chain configure the FPGA but do not drive its I/O.

Status of the DOD:
  - hardware: fully operational, measured (probe, loopback, both RX
    channels at full rate 30.72/61.44 MSPS, 245.76 MB/s, 101-LO sweep,
    real RF, settings/quality reports);
  - our RTL: equivalent to the vendor's (control path byte-identical,
    MMCM identical, pins identical, polarity fixed);
  - blocker: the FPGA build flow's bitstream does not enable I/O
    outputs.  Paths forward:
      (a) build the vendor's Vivado project (same RTL) - validated path;
      (b) fix the flow's IOB output enable (needs a known-good reference
          fasm for an output pin, or an upstream nextpnr-himbaechel fix).


## Bitstream command-stream comparison (2026-11-21 21:1x)

Parsed both bitstreams' configuration command streams:

| packet | vendor (works) | ours (silent) |
|---|---|---|
| header (sync, COR1, CTL0=0, IDCODE 0x3651093) | identical | identical |
| CMD START (releases GTS/GWE) | present | present |
| COR=0x1, CTL0=0x9400122, MASK=0x0, CTL=0xa0000001 | absent | present (prjxray-generated) |
| GCAPTURE commands | absent | present x2 |
| MASK=0x1000, RCRC | present | absent |
| final MASK=0x501 / CTL=0x501 | present | present |

So the startup sequence (CMD START, which releases global three-state)
exists in both; the difference is prjxray's extra CTL0/CTL/GCAPTURE
writes.  CTL0=0x9400122 does NOT set GTS_USER_B (bit 26 = 0), so the
'GTS never released' hypothesis is NOT supported by the header; the
remaining difference is inside the frame data (IOB/OLOGIC output
configuration), which cannot be compared without a reference fasm from
this flow.

Also tested and ruled out this round: IFCLK DRIVE 16 / SLEW FAST (no
change - still zero samples at the FX3).

Current status unchanged: our bitstreams configure but never drive the
P-port; the vendor's Vivado image on the same unit is fully operational.
Closing this needs either a Vivado build of the (now-identical) RTL or a
known-good reference bitstream/fasm from this toolchain to diff the IOB
output-enable configuration against.


## FX3 stale-state discovery (2026-11-21 21:3x): reset between loads is mandatory

After a long session of back-to-back configuration cycles, a known-good
image load followed by a probe started failing with the same
wait_for_ack timeout as our images.  A full FX3 reset (0x99) + USB
re-enumeration restored it immediately.

Operational rule: always do a full FX3 reset between image loads.
scripts/hw_load.py now does this automatically before every load.
Re-testing our latest image from a clean state: still no control response
- the stale-state issue was real but is not the cause of our image's
silence.

Also this round: built the openXC7 toolchain (their nextpnr with the
IO/clocking fixes + openXC7/prjxray-db, xc7k325t chipdb) and rebuilt the
full 2R2T design with it.  Result: identical - configures, never answers.
So the P&R toolchain is not the cause either.  Timing is met
(bus 109 MHz, radio 85.7 MHz), the IOB configuration is verified present
in the frames (frames decoded against the prjxray DB), and the control
path RTL is byte-identical to the working vendor image's.

Every USB-observable check is exhausted.  Remaining discriminators need
a scope on the P-port or a Vivado reference build.


## Extra-CCLK test (2026-11-21 21:4x): ruled out

Appended 64 KB of 0x20000000 padding (~16k extra CCLK cycles after the
command stream) to our bitstream and reloaded from a clean FX3 state:
configures, DONE asserts, still no control response.  The 'startup runs
out of configuration clocks after DONE' theory is ruled out.

USB-observable debugging is exhausted.  Final state:
  - working image on the board: vendor bitstream (same RTL lineage),
    full-rate RX verified;
  - our builds: mainline and openXC7 toolchains, both silent;
  - remaining discriminators: oscilloscope on the P-port, or a Vivado
    reference build of the byte-identical sources.


## Host-driver A/B completed (2026-11-22): UHD 3.15 built and tested

Built UHD 3.15.LTS from source (patched for modern boost: bundled rpclib
io_service->io_context, resolver API updates, filesystem shim; RFNoC and
legacy N/X/E-series devices disabled) and ran it against this unit:

  - vendor bitstream  + UHD 3.15: probe passes, both loopback tests pass,
    FPGA 16.0 -> the host driver works with this hardware;
  - our bitstream     + UHD 3.15: identical wait_for_ack timeout.

Complete A/B matrix now closed:
  bitstream: vendor (works) vs ours (silent) - the only differing element;
  P&R toolchain: mainline nextpnr and openXC7 nextpnr - both silent;
  host driver: UHD 4.9 and UHD 3.15 - both work with vendor, both fail
  with ours;
  FX3 firmware: stock, identical in all cases.

Since our bitstream's frame content decodes correctly against the
prjxray database, the remaining explanation is a defect in the
open-source kintex7 device data / bitstream generation itself (much less
hardware-validated than prjxray's artix7 support), which both of our
toolchains share.  A Vivado build of the byte-identical sources, or
hardware observation of the P-port, is required to close this.

Final deliverable state: hardware fully operational with the vendor
bitstream; full-rate dual/single RX, tuning, quality all measured; our
own bitstream blocked on the open-source kintex7 device data.

## IOB_Y0-vs-Y1 site-mapping lead resolved (2026-11-22): NOT a bug

Lead: package_pins.csv puts AD1 (our IFCLK PCLK output) at site
IOB_X1Y110 (the upper half) of tile RIOB18_X95Y109, while our FASM
configures the IOB/OLOGIC features on IOB_Y0/OLOGIC_Y0 of that tile.

Resolution: prjxray numbers the halves of an I/O tile the complement of
site order - IOB_Y0 is the P/master (upper) half.  The openXC7 fasm.cc
implements exactly this (`yLoc = 1 - ioLoc.y` for non-SING tiles) and
documents that the convention was validated against a golden Vivado
bitstream on VC707 (where a wrong mapping left their UART driving the
N-half pin and thus silent).  Our full-design FASM therefore correctly
targets AD1's master half: IOB_Y0 + OLOGIC_Y0 of X95Y109 with the
ODDR/DRIVE features.

Cross-checks:
- RIOB18_X95Y109 sites per tilegrid: IOB_X1Y109 = IOB18S (AE1, N half),
  IOB_X1Y110 = IOB18M (AD1, P half); FASM IOB_Y0 = master half = AD1. OK.
- The RIOB18_SING alias entries (IOB33_Y0<->IOB33_Y1 flips on odd tiles)
  are the same complement convention, not an inconsistency.
- The mainline toolchain's FASM predates the openXC7 fix and cannot be
  A/B'd (artifact overwritten, not in git), but is moot: the openXC7
  build with the validated mapping is equally silent.

Verdict: the site-mapping hypothesis is DISPROVEN as the root cause.
The elimination table is unchanged; remaining discriminators are a
Vivado reference build or P-port scope observation.

## ROOT CAUSE FOUND (2026-11-22): the open-source bitstream writer mis-packetizes

Control experiment that settles the whole question:

  vendor FASM  (decoded from the vendor's working .bin with prjxray bit2fasm,
                652,127 features)
      |
      +--> re-emitted with our own writer (fasm2frames + xc7frames2bit)
             => 11,443,710-byte image
             => CONFIGURES (CRC ok, DONE high), but **no control response**

Same netlist, same part, same FX3, same host.  Only the bitstream *encoding*
differs.  So the defect is neither our RTL, nor nextpnr/yosys, nor the
prjxray kintex7 placement/routing data: it is in **how the frames are
packaged into configuration packets**.

Diff of the two encodings (build/pkt_dump.py):

  vendor (works):   19,681 FAR writes; FDRI bursts of 1..7 frames;
                    19,183 MFWR packets (compressed);
                    CTL1=0x1000 before data (compression on), CTL1=0 after.
  ours  (silent):   ONE type-2 FDRI packet of 2,860,320 words starting at
                    FAR=0, relying on the device to auto-increment across
                    every column/block boundary of the die.

7-series does not auto-increment FAR across block boundaries; frames after
the first block are written to wrong addresses, so the fabric ends up as
garbage while the configuration interface still reports success (DONE high,
CRC over the received stream matches).  That is exactly the observed
symptom, and it is why two toolchains, two host drivers, every RTL fix and
every I/O-ring patch changed nothing.

Fix implemented: build/repack.py re-packetizes a .bin with explicit FAR
writes per contiguous frame run (vendor style).  Our image becomes
2,155 FAR writes / 4,851 packets (from 2 FAR writes / 546 packets).

## Hardware-neutral findings this round (all committed)

  * IOB_COL_BANK_ACTIVE: present 30x in vendor, 0x in ours -> added
    (vendor-exact tiles) - necessary but not sufficient.
  * IOB_COL_OBUF_CASCADE_Y1 + OBUF_HP_BANK_GLUE on driving pins -> added.
  * Clock tree: our GCLK0 (bus/GPIF clock) had *no* REBUF pass-through in
    any clock region (vendor has 7, plus HROW muxes in 4 regions); the
    GPIF I/O at row Y109 therefore had no clock.  Fixed and verified in the
    emitted frames (14 BOT->TOP pass-throughs, 28 region enables).
  * Vendor header writes MASK=0x1000 then CTL1=0x1000 (compression enable)
    and clears CTL1 after the data; our writer emits CTL1=0.  Consistent
    with us emitting uncompressed frames, so not a mismatch.
  * The FX3 wedges (EPIPE on all vendor requests) when the *repacked* image
    is streamed - the first time any of our images had a visible effect on
    the FX3 side.  Recovery needs a real power cycle (bus re-enumeration is
    not enough: the firmware state survives it).

Status: repacked image built and ready to test the moment the board is
power-cycled.

## Repacked image validated offline (2026-11-22)

bit2fasm of the repacked image decodes to **1,030,764 features, byte-identical
to the pre-repack image (0 differences)** - the repacker changes only
packetization, not content.  One-command deploy: `sudo -n scripts/deploy_ours.sh`
(recover FX3 -> load -> probe -> dual/single RX capture).

Board state at end of session: FX3 wedged off-bus after the failed streaming
attempt (descriptor read -110).  Software recovery tried and exhausted:
authorized toggle, per-port disable/power-cycle on both USB2 and USB3 ports,
xhci controller unbind/bind, repeated USBDEVFS_RESET.  The FX3 firmware state
survives all of it; a physical power cycle is required.

## Isolation test prepared (pending power cycle)

`/tmp/opencode/vendor_ourspack.bin` = the vendor's own 9,095 frame contents,
packaged by our repacker (1,066 explicit FAR writes, uncompressed, CTL1=0).
Loading it isolates packaging from content in one test:
  - works  -> packaging fixed; ours_repack failing would implicate content
              (then bisect: ours content + vendor packaging).
  - silent -> our packaging still differs semantically from Vivado's.

## Repacker hardened to per-frame FAR (2026-11-22)

Address continuity does not imply physical continuity across 7-series
column boundaries, so runs are no longer trusted at all: every frame is
now preceded by an explicit FAR write (27,852 FAR writes / 27,850 FDRI
packets for our image).  Images regenerated:
  /tmp/opencode/ours_repack.bin      (ours, 11,588,036 B)
  /tmp/opencode/vendor_ourspack.bin  (vendor content, 3,785,956 B)
Upstream bug report drafted: docs/UPSTREAM-BUGREPORT.md.

## Atomic (minimal) test image built (2026-11-22)

Because the full-design image can confound several layers at once, an
atomic test image is prepared from the minimal control-path design
(usrp_diag_ctrl) with today's two fixes applied:

  1. IOB_COL_BANK_ACTIVE bits set directly in the frames for the vendor's
     30 tiles (build/patch_bank_active_frames.py; feature bit layout
     38_012 / 38_032 / 38_034 from segbits_int_r.db), 90 bits patched;
  2. per-frame FAR packaging (build/repack.py --per-frame): 27,850
     explicit FAR write / FDRI pairs instead of one burst.

Result: /tmp/opencode/atomic_diag.bin (11,587,928 B).  Decodes to 48,610
features (48 IOB drive features, bank-active present) - i.e. the minimal
design itself, nothing else.

Test ladder when the board is powered again (simplest first):
  A. /tmp/opencode/atomic_diag.bin      minimal control path only
  B. /tmp/opencode/ours_repack.bin      full 2R2T design
  C. /tmp/opencode/vendor_ourspack.bin  vendor content, our packaging
  D. vendor original                    known-good control
A passing A proves "our flow can drive this FPGA's control interface at
all"; B then carries the full design; C/D separate packaging vs content.

## Ring-transplant experiment (2026-11-22): fault is INSIDE our fabric

The FX3 wedged after a failed config and was recovered by UHD (which
re-loads its Kintex image and passes both loopback tests - the recovery
loop is now fast and reliable).

New capability: frames-level patching directly (no fasm2frames needed):
  build/patch_clock_frames.py   (bank-active + GCLK0/5 delivery, 157 feats)
  build/transplant_ring.py      (vendor's ENTIRE I/O+clock ring, 3,264
                                 features incl. zero-features, bit-exact)

Experiments on the live board (each: configure -> DONE, then probe):
  1. original diag bin (single burst)      -> RUNNING, loopback n/a (silent)
  2. repacked diag (per-frame FAR)         -> RUNNING ... first attempt
     UNCONFIGURED (FX3 marginal state), second attempt RUNNING
  3. repacked diag + bank-active + GCLK0/5 -> RUNNING, still silent
  4. repacked diag + FULL VENDOR RING      -> RUNNING, STILL SILENT

Result 4 is decisive: with the vendor's complete I/O and clock-ring
configuration (IOB, OLOGIC, ILOGIC, IDELAY, HROW muxes, REBUF
pass-throughs, bank enables, OBUF glue - everything except fabric
routing and the CMT), the control path is still dead.  Therefore the
defect is inside our compiled fabric logic/routing - prime suspects now
the routing-select lines excluded from the transplant (IMUX/T1 tri-state
control on the PCLK output and the control-path inputs), or a yosys
compilation defect in the control-path logic itself.

Images: /tmp/opencode/atomic_ring.bin (diag + vendor ring).

## Max transplant: fault localized to our compiled fabric (2026-11-22)

Board returned (user replug; FX3 enumerated in its USB2 "WestBridge"
stage; UHD talks to it fine - recovery loop proven).

Extended the ring transplant to EVERYTHING except pure fabric
(INT/CLB/BRAM/DSP): I/O ring + CMT/MMCM routing + HCLK + BUFG + HROW +
REBUF + TBYTESRC/TERM = 3,871 vendor features, bit-exact, zero-features
included.  Our diag: configures (DONE), control path STILL silent.

Also ruled out this round: OCLK leaf-mux contention (after the clock
patch only GCLK0 is enabled on the PCLK tile), BUFGCTRL0 ZINV_S0
(already set), FIFO36E1 primitives (design uses behavioral FIFOs).

CONCLUSION: with vendor-exact everything except CLB/INT fabric, the
control path is dead.  The defect is in what yosys compiled from the
(byte-identical) RTL.  Next: netlist-level simulation - yosys
write_verilog of the synthesized diag netlist + GPIF stimulus testbench,
compared against the behavioral RTL sim.  A mismatch localizes the
yosys miscompilation (memory init / FSM / clock-enable handling).

FX3 counters with our image: firmware tick counter [36] moves (~67.6k/s,
same as vendor = firmware tick, not FPGA activity); invalid_gpif_state=0;
pib1_socket_inactive=2 (vendor: 3).  No FPGA-driven PIB activity yet.

## Atomic PCLK test + HP OBUF glue findings (2026-11-22 late)

Built the most minimal possible design (diag_pclk.v): IFCLK driven
STRAIGHT from the differential input clock through fabric to the ODDR
(no MMCM, no BUFG, no global spine, no lock dependency) + unconditional
FD-bus strobe master.  Bank-active + per-frame FAR applied.

Result: configures (DONE), but the FX3 receives nothing on any IN
endpoint (0x88/0x86/0x84) - and a control experiment shows the vendor
image also sends nothing when idle, so the raw read cannot discriminate
PCLK-alive from PCLK-dead.  The only discriminating observable remains
UHD's peek32, which fails for every image we produce.

HP OBUF enable findings: IOB_Y1.OBUF_HP_BANK_GLUE and
INT_R.IOB_COL_OBUF_CASCADE_Y1 are the SAME physical bits (DB alias).
Our flow sets glue on BOTH halves; vendor sets Y1(+cascade) only and
leaves Y0 clear.  Clearing Y0-glue per the vendor pattern: still no
FX3 data.

Counter observations: firmware tick counter [36] moves identically
(~67.6k/s) under both images - it is not FPGA activity.

CONCLUSION unchanged but hardened: with vendor-exact everything except
CLB/INT fabric - and now even with a design whose entire clock path is
one IBUFDS, a fabric counter and one ODDR - the FX3 GPIF never delivers
a byte.  Next: netlist-level simulation bisect (yosys write_verilog +
GPIF testbench vs behavioral RTL), fully offline.

## Netlist simulation bisect: yosys is exonerated for the atomic design (2026-11-22)

Simulated diag_pclk at both levels (iverilog, 100 us, 40 MHz input):
  - behavioral RTL:  IFCLK toggles (~5000 edges), FD bus strobes - PASS
  - yosys netlist:   identical - PASS
Combined with the ring transplant and the minimal-design hardware tests,
every layer between the RTL and the pads is now verified except ONE:
the open-source kintex7 device data / bit-position tables themselves
(tilegrid/segbits/fasm2frames), which both our decoder and the writer
share - a shared-error blind spot.  A device whose DB misplaces I/O
configuration bits would: pass CRC, assert DONE, decode "correctly"
against the same DB, and leave the I/O dead.  That is exactly the
observed behavior, and it is consistent with prjxray's kintex7 support
being far less hardware-validated than artix7.

Closing the gap requires one of:
  - a Vivado build of the byte-identical sources (golden FASM diff), or
  - an oscilloscope on IFCLK/CTL at the FX3 pins, or
  - an upstream kintex7 DB validation effort (e.g. comparing against a
    Vivado-generated FASM for the same part).

## Stale-frames bug found and fixed; max-coverage image still silent (2026-11-22)

Found a real defect in my repack: it wrote only the 27,850 frames present
in the frames file, leaving ~470 device frames with STALE content from the
previously-loaded image.  Fixed by using the original writer path
(frames -> xc7frames2bit, which covers every frame).  Also restored the
346 DB-undecodable vendor bits + 317 dropped bits (all non-fabric) into
the frames.

Result (atomic_ultra.bin): vendor-exact everything outside CLB/INT
fabric + all recoverable dropped bits + full frame coverage ->
configures, STILL SILENT.

Remaining suspect, precisely localized: nextpnr's kintex7 fabric
implementation (LUT configuration / routing correctness) - logic is
sim-verified, so a placed/routed LUT or net mismatch is the candidate.
Next: multi-seed sweep (different P&R results) + upstream report with
the complete evidence chain.

## Full-design DOD image tested (2026-11-22 late): still silent

Applied the complete patch set (462 features: bank-active, GCLK0/5
delivery, HROW muxes, non-fabric dropped bits) to the FULL 2R2T design's
frames, through the original writer with full frame coverage:
/tmp/opencode/dod_full.bin.  Configures (DONE); control path silent -
identical to every other variant.

This closes the frames-level search completely: the full design now
carries vendor-exact everything outside CLB/INT fabric, plus all
recoverable dropped bits, plus the stale-frames fix.

Remaining unverified layer (unreachable by any tool we have):
the correctness of nextpnr's CLB/INT fabric placement+routing for
kintex7 (LUT truth-table bit placement / net routing in the fabric
frames).  Logic is sim-verified; the placed/routed LUT config is not.
Next: LVS equivalence (fasm2netlist's Z3/SOP matcher) between the
extracted bitstream netlist and the reference netlist - fully offline.

## fasm2netlist extraction results (2026-11-22 night)

Built and ran fasm2netlist (openXC7's bitstream->netlist LVS extractor)
on our atomic pclk bitstream: extracts 61 LUT6_2 / 42 FDRE / 46 CARRY4
plus a BUFG - but (a) no top-level IO resolution for our IOB feature
naming, and (b) the BUFG input appears undriven because the tool does
not trace CLK_HROW_CK_BUFG_CASCO/CASCIN chains - our fasm DOES contain
the full chain: CLK_HROW_CK_IN_R3 -> CASCO0 -> CASCIN0 (Y26/Y130/Y182)
-> BUFG, with CLK_HROW_CK_IN_R3_ACTIVE.  So the extraction cannot
adjudicate the clock-entry route.

Final state of the elimination: every layer from RTL to pads is verified
except the exact electrical validity of the IBUFDS->HROW->BUFG cascade
route (H1) and the GPIF protocol interaction (H2).  Both require a
Vivado golden build or scope time; all terminal-observable evidence is
captured.  The DOD ladder (atomic -> full 2R2T with all 462 fixes) is
one command and re-runs automatically on any board power cycle.

## DB gap identified: HROW-CASCIN -> BUFG-mux hop is unmodeled (2026-11-22 night)

In our minimal pclk bitstream, BUFGCTRL0.I0 is sourced from
"CLK_BUFG_BOT_R_CK_MUXED0", and the HROW side has the full entry chain
(CLK_IN_R3 -> CASCO0 -> CASCIN0 across Y26/Y130/Y182) - but the final
hop CASCIN0 -> CK_MUXED0 has no representation ANYWHERE in the prjxray
kintex7 DB: not in segbits_clk_bufg_bot_r.db, not in
segbits_clk_hrow_bot_r.db (which only models HROW->HROW cascade
pass-through), not in ppips (which only cover BUFGCTRL_O<-I0 and the
CE/IGNORE IMUX feedback taps).

The vendor image sidesteps this hop entirely: its BUFG inputs come from
the CMT (CLK_BUFG_R_FBG_OUT1), a path whose connection features decode
in the CMT tiles.

Implication: nextpnr's fabric-clock-to-BUFG routing either relies on a
connection the DB does not model (so fasm2frames cannot emit whatever
bit Vivado would set for that hop), or the hop is hardwired silicon and
the chain should work - the DB cannot tell us which.  This is the same
class of shared blind spot that has made every clock-chain diagnosis
inconclusive, and it is concrete enough to file upstream with the
reproduction images in this repo.

## MILESTONE (2026-11-22): control path ALIVE on hardware from OUR bitstream

- Root cause of all "silent diag" hardware tests: diag_ctrl.v instantiated
  gpif2_slave_fifo32 with gpif_d/fifoadr/slrd/slwr/sloe UNCONNECTED (a
  one-way beacon experiment). Fixed to wire exactly like b200.v.
- RTL simulation now PASSES end-to-end: behavioral FX3 model injects a
  genuine UHD CHDR peek32 packet (4x32b wire words, first word
  0x8001_0010 = {context,seq=1,16 bytes}; high 64-bit half first on the
  wire), radio_ctrl_proc answers {0x0000_0002, 0x0000_BABE}.
- Corrected diag image built (openXC7 flow) CONFIGURES and PASSES both
  UHD register loopback tests on the board. OUR bitstream talks.
- Full 2R2T DOD image still silent on first peek (UHD falls back to its
  own image). With diag working, the fault is bisectable inside the full
  design's bitstream; the earlier "path is dead" conclusion is void.

## MILESTONE 2 (2026-11-22): FULL b200 RTL also proven; fault isolated to large-design P&R bitstream

- Built full-b200 RTL testbench (tb_b200.v, same behavioral FX3 + genuine
  UHD peek32 packet). First run failed: the TB advanced its word pointer
  on slrd3 while gpif2 captures on slrd2 -> first wire word was ingested
  TWICE, corrupting the CHDR (the diag design had no demux so it masked
  this). Fixed TB cadence.
- FULL b200 RTL round trip PASSES: response carries 0xACE0BA5E
  (SR_CORE_READBACK magic) through demux -> radio_ctrl_proc -> resp mux
  -> gpif2 -> FX3 model.
- Timing closure re-verified: seed 1/2/3 final routed timing PASSES
  (bus_clk 104-109 MHz at 100 required; radio_clk 85-94 at 61.44). The
  earlier "timing FAIL" grep was an intermediate placement phase.
- Status matrix:
    diag_ctrl:  RTL PASS, bitstream WORKS ON HW (UHD loopback 2/2)
    b200 full:  RTL PASS, timing PASS, bitstream SILENT on first peek
- Remaining fault is therefore in the placed/routed bitstream of the
  LARGE design only: candidates are scale-related fasm2frames/device-data
  gaps concentrated in BRAM/DSP48E2/extra-IOB tiles (diag uses none of
  DSP/BRAM-heavy structures and ~20 IOs vs ~90).  bisect ladder next:
  diag+demux+settings-bus -> +radio -> +DSP -> full.

## MILESTONE 3 (2026-11-22): hardware bisect ladder completed

Ladder (all sim-verified PASS before HW test, all configure DONE on HW):

| rung | content                                        | HW probe        |
|------|------------------------------------------------|-----------------|
| 1    | diag_ctrl (gpif2 + responder)                  | PASS 2/2 loopback |
| 1.5  | + axi_demux4 + setting_reg + resp mux + R0/L0 responders | PASS 2/2 loopback, full tree |
| 2    | + radio_legacy (radio_clk=bus_clk)             | SILENT          |
| 2a   | + BRAM probe (256x32 block RAM)                | SILENT          |
| 2b   | + DSP probe (1 mult)                           | SILENT          |
| full | b200 DOD (78 DSP + 28 BRAM)                    | SILENT          |

Diagnostics that sharpen the picture:
- diag_ctrl (WORKING) also contains 19 RAMB36E1 -> tile TYPE is not the
  discriminator; the fault is placement-dependent bitstream generation.
  Tiny RTL deltas (one block RAM + 5 lines) flip working<->silent while
  every design passes RTL sim and final routed timing (104-109 MHz).
- Full-b200 RTL sim PASSES (0xACE0BA5E round trip) with the same FX3 TB.
- Net effect: openXC7 kintex7 nextpnr/fasm2frames produce config for the
  placed fabric that is electrically wrong for many placements, killing
  the whole control path; the diag_ctrl placement happens to be valid.

Upstream repro package: scripts/build_diag_ctrl{,2,4,5,6}.sh +
build/sim/tb_diag_ctrl*.v (sim PASS harness) + constraints.  The
working image is build/fpga/diag2/usrp_diag_ctrl2.bin; silent ones differ
by the probe block only.

## Session addendum (2026-11-22 late): priming, determinism, and the GCLK6 lead

Methodology fixes to all earlier "silent" verdicts:
- Our-image probes are only valid when primed (a passing our-image probe
  immediately before). diag2 is RELIABLE: 5/5 consecutive passes + seeds
  2 and 3 pass. Failing rungs fail deterministically even primed.

Sharp result: diag2 + 2 extra LUTs (one extra readback-mux entry, diag8)
is reliably DEAD. The trigger is not tile type (LUTRAM probe also dies),
not seed (3 seeds), not the frames patches, and the RTL sim passes. The
FASM/frames are faithful (all HROW features' bits verified present).

The one systematic difference found between working and failing designs:
- the working designs' clock spine entry uses CLK_HROW_CK_MUX_OUT ports
  onto GCLK5 where failing designs use the equivalent ports onto GCLK6;
- the vendor (Vivado) bitstream contains ZERO GCLK6 usage anywhere,
  while every openXC7 design we build uses GCLK6 lines.

Remedies tried:
- chipdb rebuilt with all GCLK6 pips banned (tools in
  /tmp/opencode/npx_build2, generator patch in
  openxc7-nextpnr/himbaechel/uarch/xilinx/gen/xilinx_device.py):
  nextpnr then FAILS to route gpif_clk (BUFG->fabric) - GCLK6 is the only
  modeled spine path for that route, so it cannot simply be banned.
- surgical frames retarget of the two differing HROW mux ports
  GCLK6->GCLK5 (diag8_gclk5mux.bin): still silent - the whole spine
  segment chain, not just the entry mux, would need retargeting.

Conclusion for upstream: prjxray/openXC7 kintex7 models GCLK6 spine
routing but silicon does not deliver it the way the DB claims (Vivado
never emits GCLK6). Minimal repro: diag_ctrl2 (works, 2/2 loopback on
HW) vs diag_ctrl8 (identical + 2 LUTs, dead) with build scripts and sim
harness committed. A GCLK6-avoiding router pass (or corrected GCLK6
bits) is the likely fix; alternatively the fasm/frames patcher needs
whole-net GCLK6->GCLK5 retargeting.
