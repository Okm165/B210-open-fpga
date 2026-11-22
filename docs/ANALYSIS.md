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
