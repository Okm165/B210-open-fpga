# DOD status — CORRECTED 2026-11-23 (README-level truth)

Board: OpenSourceSDRLab Custom_SDR_B210, serial 31B92DD, XC7K325T-FFG676,
USB 2500:0020.  Host: UHD 4.9.0.1, FX3 firmware untouched.

## 1. The correction that invalidates all earlier status reports

UHD's B200 implementation **always reflashes** the image selected by
`find_image_path()`.  `/usr/share/uhd/images/usrp_b210_fpga.bin` on this
machine is the **vendor reference bitstream** (identical md5 to
`build/vendor_ref.bin`, 4,583,732 bytes, IDCODE 0x3651093).  Therefore every
`uhd_usrp_probe` / `rx_capture.py` run without `fpga=<path>` measured the
**vendor bitstream**, not ours.  All earlier "our image passes loopback /
streams 2 RX" statements were stock-image results and are retracted.

The correct invocation is:

    uhd_usrp_probe --args="type=b200,serial=31B92DD,fpga=/abs/path/our.bin"

## 2. Valid measurement instrument (new)

`scripts/gpif_rig.py` loads a `.bin` through the same FX3 vendor requests UHD
uses, issues a GPIF reset and performs raw UHD-format control transactions
(16-byte CHDR packets, SID 0x40) on the control endpoints, reporting raw
bytes, latency and timeouts.

Validation: with `build/vendor_ref.bin` the rig receives
`a0010018 ... ace0ba5e 00100000` — the loopback value.  With random bytes the
FX3 reports a genuine config failure.  The rig is therefore a trustworthy
instrument, and "FX3 reached RUNNING" does mean the bitstream really
configured.

## 3. Measured result for our own builds (RX only, no TX)

| image | config | GPIF reply |
|---|---|---|
| vendor_ref.bin | ok | **yes (ace0ba5e)** |
| diag2 (container PnR, seed 2) | ok | no |
| diag2 rebuilt with host nextpnr 42d06c5 | ok | no |
| diag_nommcm (40 MHz direct IBUFDS+BUFG, no MMCM) | ok | no |
| diag_pad (combinational SLWR/FD, no state machine) | ok | no |
| b200_80 full 2R2T (seed 2) | ok | no |
| random bytes (control) | **fail (correctly detected)** | – |

So: **our bitstreams configure but the GPIF interface never answers.**  RTL
simulation passes because it uses our own behavioural FX3 model; the failure
is below RTL (bitstream/physical layer).

## 4. Hypotheses tested and rejected (each with the actual measurement)

- **Seed/placement lottery** — earlier "dead vs alive" results were stock
  reloads; the rig removes that confound.  Seed is not the variable.
- **Toolchain version** — host-built nextpnr @42d06c5 with the newer prjxray
  meta produces the same silence.
- **MMCM configuration** — per-bit comparison against the vendor bitstream
  shows the same VCO (1000 MHz), same dividers, same filter/power registers.
- **MMCM / clock-source dependence** — a no-MMCM design (40 MHz straight to
  BUFG) is equally silent.
- **Image size limit** — the FX3 drops off the bus above ~8–10 MB, and the
  vendor image padded to 5 MB and 8 MB still works; but our 9.1 MB
  trailing-zero-trimmed and 2.2 MB sparse images still get no reply.  Size is
  not the cause of the silence (it is a separate, real limit to respect).
- **IFCLK drive strength / slew / create_clock on the output port** — matching
  the vendor XDC exactly (DRIVE 8, SLEW SLOW, no create_clock on IFCLK)
  changes nothing.

## 5. Concrete defects found in the flow while doing this

- `fasm2frames` fails on `RIOI.IOI_OCLKM_0.IOI_IMUX31_1` (segbit absent from
  the kintex7 DB) when a fabric clock is routed to an IOI leaf — a real DB
  gap.
- nextpnr writes no `OBUF_HP_BANK_GLUE` / partner-half defaults on `RIOB18`
  tiles, while the vendor bitstream does (5 instances, incl. the IFCLK tile).
- Uncompressed `xc7frames2bit` output is 11.44 MB; the vendor image is a
  4.58 MB sparse/compressed stream.  The FX3 loader cannot take ≳9 MB.

## 6. What remains, in order of value

1. **Vivado golden build** of this same RTL (`/tmp/opencode/vendor_repo`,
   `B210_Project_Firmwire.xpr`, part `xc7k325tffg676-2`).  Diff its config
  frames against ours on the GPIF tiles; that closes the defect precisely.
2. **Scope IFCLK (pin AD1) and the GPIF control lines** during a diag2 config.
   One probe answers the open question (clock/pads vs protocol) directly.
3. Upstream: file the two concrete DB/flow defects above with the diag2
   build script and the rig as the acceptance test (`fpga=` invocation).

Everything below this line in older docs that claims "2 RX live from our
bitstream" refers to the vendor image and must not be used as a DOD result.

## 7. Frame-level clock-path decode (2026-11-23, scripts/tilecmp.py)

Using `build/vendor_rt.frames` (decoded vendor bitstream) and our frames,
decoded with the container prjxray DB at identical tile coordinates:

- IFCLK ODDR tile `RIOI_X95Y109`: identical except the clock leaf —
  vendor selects `IOI_LEAF_GCLK5`, ours `IOI_LEAF_GCLK0`; ours additionally
  has ODDR.SRUSED/ZSRVAL (SR routed).
- `HCLK_IOI_X235Y130`: vendor leaf `GCLK_BOT5+TOP5 ← IGCLK11 ← BUFHCLK11`;
  ours `GCLK_BOT0 ← IGCLK0 ← BUFHCLK0` (TOP not set).
- `HCLK_CMT_L_X228Y26`: vendor `CK_IN1 ← MMCM_CLKOUT1` (100 MHz),
  `CK_IN0 ← CCIO0`; ours `CK_IN0 ← MMCM_CLKFBOUT` (40 MHz feedback),
  `CK_IN1 ← MMCM_CLKOUT2`, `CK_IN10 ← MMCM_CLKOUT1`.
- MMCM feedback: both route CLKFBIN through the regional spine
  (`MUX_MMCM_CLKFBIN ← CK_BUFHCLK0`), but in OUR bitstream the IFCLK leaf
  taps that same `BUFHCLK0` spine — i.e. the ODDR is clocked by the 40 MHz
  *feedback* clock, while nextpnr's netlist says its clock net is
  `gpif_clk` (100 MHz, BUFG on GCLK5).  Two different networks, router
  reported success — the exact failure class of openXC7/nextpnr-xilinx#100.

## 8. Drain experiment (scripts/gpif_drain.py) — the decisive measurement

Host writes to the FX3 data OUT endpoint; a live GPIF master drains
continuously:

| image | drained |
|---|---|
| vendor_ref.bin | **8 388 608 B** (12.2 MB/s, no stalls) |
| diag2 (all variants) | 1024 B (FX3 socket buffer only) |
| glue/IOB_COL-patched diag2 | 1024 B |
| static reader (SLRD low, no logic) | 1024 B |
| static writer (SLWR low, FD const) — host read | no data |
| 40 MHz no-MMCM | 1024 B |
| fabric ring oscillator (3×LUT1, verified in netlist) | 1024 B |
| internal-feedback MMCM, single 100 MHz BUFG | 1024 B |
| **fabric-generated 20 MHz PCLK, plain OBUF, no clock spine** | **1024 B** |

Every protocol-level, clock-source-level, size-level and glue-level
hypothesis is eliminated by measurement.  The remaining explanations are
(1) our bitstreams do not drive the bank-34 output pads at all, or
(2) the FX3 firmware only works with a 100 MHz PCLK, which our clock-leaf
misroute prevents even when the design intends 100 MHz.  Distinguishing
them requires a scope on AD1/CTL or a Vivado golden build; both are
outside the USB-only constraint.

## 9. BUFH workaround attempt and toolchain blockers

The DB shows every IOI clock leaf is fed ONLY from a regional BUFHCLK line
(`HCLK_IOI_CK_IGCLK0 ← CK_BUFHCLK0`; no direct GCLK→leaf path exists).
Vivado solves this by converting the driving BUFG into a BUFHCE for
I/O-forwarded clocks (the vendor bitstream has 17 BUFHCEs).  Our attempts:

- RTL `BUFHCE` on clkout1: nextpnr places it only with a BEL constraint;
  unconstrained placement fails ("no BELs remaining of type BUFHCE").
- Constraining by site is blocked: the container XDC parser rejects cell
  targets, and the host nextpnr does not accept any site naming for the
  clock-row tiles we could discover (`CLK_HROW_BOT_R_X121Y26`,
  `BUFHCE_X0Y1`, `tile/BUFHCE_X0Y1` all rejected).

So within this toolchain the ODDR forwarded-clock path is unbuildable with a
driven regional clock — consistent with every static-reader/writer experiment
failing regardless of the clock source.

## 10. Upstream report filed

All 12 leaf-mux sources were brute-forced on hardware (`scripts/leaf_sweep.py`):
1024 B each — the leaf mux is exonerated; the leaf's *spine* has no driver.
Filed as openXC7/nextpnr#222 ("kintex7: ODDR forwarded clock is dead on
silicon — IOI leaf mux driven from an undriven BUFHCLK spine").

Context established from the tree: **no example or test anywhere in openXC7
exercises ODDR**; HP-bank differential outputs were first exercised only
recently (vc707-hp-diffio) and immediately found real bit bugs.  The B210
IFCLK shape (MMCM → ODDR → HP-bank pin, FX3 slave-FIFO PCLK) sits on this
untested path.

Unblock path: upstream fix (they closed #100 within a day) → rebuild →
`scripts/hw_gate.sh` → 2-RX ladder.  Everything on our side is ready and
one command away.

## 11. Firmware-level confirmation (2026-11-23)

UHD's stock FX3 firmware (`b200_main.c`, `b200_gpif_init`):
`CyU3PPibInit(CyTrue, {clkDiv=2, clkSrc=CY_U3P_SYS_CLK, isDllEnable=CyFalse})`
configures only the internal DMA clock; the GPIF slave-FIFO state machine runs
on the PCLK **supplied by the FPGA** (IFCLK).  Therefore a design with SLRD
held statically low still stalls at the FX3 socket buffer iff no PCLK arrives
— which is exactly what we measure.  The IFCLK-dead conclusion is now
confirmed from three independent directions: raw-bit frame decode, hardware
drain experiments, and firmware analysis.

Also verified: re-assembling the same FASM with the post-#30 openXC7
prjxray-db (complete HCLK_CMT rows) yields byte-identical frames — not a
stale-DB artifact.  Both findings added as a comment on issue #222.

## 12. ROOT CAUSE PROVEN BY KNOCKOUT (2026-11-23)

The BUFHCLK routing layer of our designs is **phantom**. `segbits_clk_hrow_bot_r.db`
(kintex7) contains NO routing rows for the BUFHCLK network — only BUFHCE config
bits, BUFG_CASC and MUX_OUT/GCLK_ACTIVE rows. nextpnr nevertheless emits route
PIPs such as `CLK_HROW_CK_BUFHCLK_R0.CLK_HROW_CK_HCLK_OUT_R0`.

Knockout experiment (`scripts/knockout_bufhclk.sh`): delete every
HCLK_OUT/BUFHCLK route line from the design FASM, reassemble → **frames
byte-identical (0 of 27850 differ)**.  The router's entire regional-clock
route has no bits behind it; fasm2frames drops it silently.

Consequences:
- No bitstream from this flow can drive a regional clock spine. This is the
  complete root cause of the IFCLK-dead measurements (leaf ← IGCLK ← BUFHCLK
  with an undriven spine).
- Not fixable from our side: the bits do not exist in any prjxray-db
  (prjxray-db#22/#30 merged; neither adds CLK_HROW BUFHCLK routing rows;
  0 open prjxray-db PRs).
- New hardware experiments this round: 34 CMT `CK_INk→CK_BUFHCLK0` hop
  variants brute-forced on silicon — all dead (consistent with phantom
  routing; the hop bits did reach frames but the spine itself has no driver
  path with bits).

Posted to openXC7/nextpnr#222 with the knockout proof and fix direction
(add the missing CLK_HROW BUFHCLK routing rows; make fasm2frames fail on
features without backing bits).

## 13. FX3 firmware diagnostics + terminal-only reset + graft experiments (2026-11-23)

### Firmware forensics (unmodified stock UHD firmware, via vendor requests)
- `GET_LOG` (0x23), `GET_COUNTERS` (0x24): our images load with
  "FPGA done / b200_gpif_init / GPIF loaded / Running"; counters show
  `pib[1].socket_inactive` increments (GPIF SM alive, socket inactive),
  `invalid_gpif_state = 0`. Vendor-vs-ours counter comparison was interrupted
  by a wedge (below).
- `RESET_DEVICE` (0x99): full FX3 reboot from the terminal. Lands in the
  USB bootloader ("Cypress | WestBridge"); `uhd_usrp_probe` then reloads
  firmware + FPGA and the board comes back healthy. **Complete no-replug
  reset path demonstrated**, board restored and verified healthy.

### Graft experiments (decisive, all measured)
1. 34 CMT `CK_INk→CK_BUFHCLK0` hop variants brute-forced on hardware: dead.
2. Vendor BUFHCLK11 chain reconstruction (CMT rows + hrow correlated bits +
   BUFHCE_X1Y11 + ENABLE_BUFFERs + leaf←IGCLK11) on our fabric: dead.
3. **Wholesale vendor clock-spine graft** (CLK_HROW/HCLK_IOI/RIOI/CMT tiles
   for the IFCLK path copied from the vendor bitstream into ours): dead.
4. **Full vendor IO+clock graft** (86 vendor IO-column + hclk-column tiles,
   3564 frames, complete GPIF-bank IO and clock configuration) + our fabric:
   dead.  Vendor image through the identical probe: healthy.
5. Our image on a freshly UHD-initialized FX3 (sockets configured by UHD
   before our load): still dead, while the vendor baseline drains on the
   same firmware state.

### Conclusion
With the vendor's complete IO and clock configuration in place, the only
remaining difference is our fabric (CLB/routing) frames. The phantom-routing
defect (§12, knockout proof) is therefore not limited to the BUFHCLK network:
the flow's fabric-level routing cannot be trusted on this part either. This
is consistent with every image we have ever built being inert, regardless of
design content, clock topology, or pad configuration.

Recovery after wedge: `RESET_DEVICE` → UHD reload (documented above).

## 14. INSTRUMENT BUG FOUND AND FIXED — vendor decode was garbage (2026-11-23)

**The vendor bitstream is COMPRESSED (4.5 MB vs 11.4 MB uncompressed).** Our
linear FDRI dump (vendor_rt.frames, 27 850 "frames") was corrupt. Proof:
reassembling those frames with our own pipeline yields a configuring-but-dead
image, while the original vendor image drains at 12 MB/s.

Fix: `bitread` (prjxray, compression-aware) on the vendor .bit → 9494 true
frames (build/tmp/vendor_true.frames, build/tmp/vendor_bitread.txt) →
reassembled → **drains 8 388 608 B at 12.23 MB/s. INSTRUMENT VALIDATED.**

Consequences:
- All pre-§14 patched/grafted-image evidence is VOID (built on corrupt frames).
- The true decode nevertheless CONFIRMS the clock-path story:
  vendor leaf IOI_LEAF_GCLK5 / IGCLK11←BUFHCLK11 / CK_IN1←MMCM2,
  ours leaf GCLK0 / IGCLK0←BUFHCLK0 / CK_IN0←MMCM11.
- New true-frame MMCM findings: ours sets all 16 POWER_REG bits (vendor: only
  bit 8); COMPENSATION Z_ZHOLD (ours) vs ZHOLD (vendor); different CLKOUT
  enables.  Tested alone and combined on hardware: not sufficient alone.
- Our own bitstream round-trips perfectly (bitread(file) == file), so the
  flow's output is faithfully what fasm2frames computed.
- True-frame grafts (clock spine tiles, +MMCM tiles, +ENABLE_BUFFERs) remain
  dead — the failure is deeper than the copied tiles; fabric-level.

## 15. Operational learnings
- After ANY config load, send GPIF_RESET (0x72) before draining; a wedged
  GPIF otherwise stalls even the vendor image.
- Board-health restore loop proven twice: RESET_DEVICE (0x99) → bootloader →
  uhd_usrp_probe (fw+fpga reload) → healthy.
- bitread-based decode is now the only valid vendor frame source.

## 16. Valid-instrument round 2 (2026-11-23, later)

- Pad tiles verified: our RIOB18 GPIF-pad features match vendor's line-for-line
  (SLEW/DRIVE/glue all present). Pads exonerated on valid data.
- BUFG config: our BUFGCTRL sites (X0Y0/5/6) have IN_USE; polarity bits mostly
  already correct (3 bits differed, patched — no effect).
- Upstream examples (vc707-carry, vc707-heavyhash4 nonce-verified 2026-11-03,
  vc707-litex-linux) run on kintex7 hardware through this flow — fabric
  interconnect works generally. Our failure is design/part-specific.
- Vendor-shaped clock chain adapted to our GCLK5 (leaf←IGCLK11, BUFHCE_X1Y11,
  MUX_OUT_R11←GCLK5, ENABLE_BUFFERs, CMT rows, all documented bits) still dead
  → the likely dead link is upstream of the leaf: our MMCM start-up (COMP/
  POWER/CLKOUT-enable deltas now tested — not sufficient) or the 40 MHz
  input path into the MMCM.  Next: verify MMCM lock inputs (CLKIN from
  CLK_IN1_HCLK spine: who drives it in each bitstream) and MMCM start-up bits
  (STARTUP_WAIT / table regs) with the valid instrument.

## 17. Valid-instrument round 3: the CMT/routing DB is massively incomplete (2026-11-23)

Undocumented-bit audit of the TRUE vendor bitstream:
- `CMT_TOP_L_LOWER_B_X228Y9` (the MMCM): 311 bits set, **127 (41%) not in any
  segbits DB row** — including the bits that implement the MMCM's
  CLKFBOUT→BUFHCLK0 feedback driver and the CLKIN routing.
- `CLK_HROW_BOT_R_X121Y130`: 184/184 bits undocumented (the entire BUFHCLK
  routing layer — confirms §12 with valid data).
- `HCLK_IOI_X235Y130`: 5/5 undocumented.

Also: `build/vendor.fasm` was corrupt-era derived and is now superseded by
`build/tmp/vendor_true.frames` (bitread). All fasm-based vendor analysis was
redone from true frames; the clock-path story stands.

Full true-frame clock+IO graft onto our fabric: dead — expected, since the
vendor CTL pads read vendor fabric nets that do not exist in our image, so
this graft cannot isolate IFCLK by design.

Clean MMCM diff (valid data): ours = COMP.Z_ZHOLD + CLKFBIN←CLK_IN3_HCLK +
CLKOUT0/2 enables; vendor = COMP.ZHOLD, no CLKFBIN row (feedback via
undocumented bits), CLKOUT3-6 enables.

**State of knowledge:** the open prjxray DB cannot express the vendor's clock
infrastructure on kintex7 at all (41-100% undocumented bits in exactly the
tiles our clock path needs).  The flow can therefore neither route nor
verify these paths.  Everything reachable from the terminal has been tested;
the blocker is DB completeness for kintex7 clocking, now proven with a
validated instrument.

## 18. Upstream finalized (2026-11-23)

Posted the complete corrected evidence to openXC7/nextpnr#222: the
compression-decode correction, the validated pipeline (reassembled reference
drains at 12 MB/s), the undocumented-bit audit (41% MMCM / 100% HROW), and
the observation that no 325T design has ever been silicon-verified through
this flow. Offered our tooling (true-frame dumps, knockout scripts, audit).

DOD status: BLOCKED on upstream kintex7 clocking DB. Everything on our side
is staged: on a DB fix, `scripts/build_b200_full.sh` (TARGET_B210) ->
`scripts/hw_gate.sh` -> 2-RX ladder -> FFT/graph/tuning work.

## 19. Old-engine cross-check (2026-11-23, final for this session)

Built the archived openXC7/nextpnr-xilinx 0.9.8 engine from source (the one
that is silicon-proven on XC7K325T via the QMTech PicoSoC), generated the
k325t chipdb from the same prjxray DB, and built our atomic static-reader
probe through it (yosys 0.69 -> nextpnr-xilinx 0.9.8 -> fasm2frames ->
xc7frames2bit).  The old engine actively manages BUFHCEs and P&R succeeds —
and the result is **dead on the board too (1024 B)**.

Root cause shared by both engines, now precisely quantified with the
validated instrument (corrected audit; the earlier 100% figure was an
indexing bug, real number 82%):
- CLK_HROW clock row of our IFCLK leaf: vendor = 184 bits set, **150 (82%)
  undocumented** in every segbits DB; our flow emits only the 17 documented
  bits.  The DB simply lacks the regional-clock routing rows.
- CMT/MMCM tile: vendor 41% undocumented.
- HCLK_IOI leaf mux: fully documented in both (exonerated).

Two independent P&R engines + one shared incomplete DB = same silent dead
output.  Reversing the 150 undocumented HROW bits (cross-instance knockout
correlation across the vendor's four clock rows) is the remaining
reverse-engineering task; it is beyond what a single reference bitstream
supports quickly and is best done upstream with more reference configs.

## 20. Hybrid isolation experiments (2026-11-23, session end)

Corrected undocumented audit (indexing bug fixed): CLK_HROW clock row vendor
= 184 bits, **150 (82%) undocumented**; ours = 17 bits all documented. The
HCLK_IOI leaf mux is fully documented in both (exonerated).

Built the definitive isolation hybrid: **vendor's complete clock
infrastructure** (all CLK_HROW rows, BUFG/rebuf, CMT/MMCM, HCLK_* tiles)
**+ vendor's IFCLK leaf tile** (its ODDR ties D1/D2 internally — no fabric
dependency) **+ our static CTL pads** (SLCS/SLRD/FIFOADR driven by our
fabric). If IFCLK toggles, the FX3 must drain. Result: **dead (1024 B)**,
twice (with all CTL tile variants protected). Board re-verified healthy on
the vendor image afterwards.

Also built and tested the archived nextpnr-xilinx 0.9.8 engine end-to-end
(chipdb for k325t generated, probe P&R'd, bitstream assembled): dead.

FINAL STATE OF KNOWLEDGE: even a bit-exact vendor clock system with our
simple static slave-FIFO master does not move data. The remaining
un-eliminated variables are (a) undocumented hrow/CMT bits beyond what any
fasm copy captures (i.e., bits OUTSIDE the CLB_IO_CLK blocks we copied —
e.g. other bit buses), or (b) a board/firmware interaction we cannot
observe without a scope or Vivado. Both engines (himbaechel, 0.9.8) are
equally affected. This is the hard stop of terminal-only debugging; the
evidence package in #222 is complete and final for this session.

## 21. DEFINITIVE A/B CONTROL (2026-11-23, session end)

Implemented the FX3 bootloader protocol directly (raw 0xA0 downloads,
no UHD): fresh firmware boot -> our bitstream loaded as the FIRST FPGA
image the fresh GPIF ever sees.

Same firmware session, same sockets, same probe:
- our bitstream (first image): **dead (1024 B)**
- vendor bitstream loaded seconds later in the same session: **healthy
  (4 MB @ 12 MB/s)**

The last confound (GPIF state initialized against a different FPGA) is
removed. The difference is the bitstream content, i.e. the clock-forwarding
layer (82% undocumented CLK_HROW bits, 41% CMT bits, shared by both P&R
engines). On-terminal debugging is exhausted; posted as the final control
to openXC7/nextpnr#222. Tooling preserved: scripts/fx3_raw_load.py.

## 22. Chain correction attempt (2026-11-23, final)

Found and fixed a routing error in our earlier adapted-chain experiment: our
100 MHz rides **GCLK0** (leaf GCLK0 / BUFGCTRL0->GCLK0), not GCLK5. Rebuilt
the adapted vendor chain with MUX_OUT_R11<-GCLK0: still dead.

Remaining delta identified precisely: the BUFHCE's CE input routing.  The
vendor routes CE from a fabric net (old engine routed it via
BUFHCE_CE_R0<-CE_INT<-IMUX fabric rows); in our copied-vendor-chain images
the CE net does not exist, so the buffer enable may be undriven.  Next step
when work resumes: tie the BUFHCE CE high via a documented fabric-VCC route
(or decode the CE mux row), then re-run the chain experiments.

## 23. Chain experiments concluded (2026-11-23)

chain1 (= chain0 + all 21 vendor ENABLE_BUFFER tiles for BUFHCLK11): bit
hash identical to chain0 — the enables were already present.  Still dead.

The documented-bit chain (leaf<-IGCLK11, BUFHCE_X1Y11, MUX_OUT_R11<-GCLK0,
GCLK0_ACTIVE, enables, CMT rows) is complete per the DB and still does not
toggle IFCLK.  The confirmed remaining delta is the BUFHCE CE-input routing
(vendor drives CE from its fabric through undocumented hrow hops; ZINV_CE
semantics with a floating CE are undefined).  Decoding it requires more
reference bitstreams (Vivado) or a scope.  Session hard stop; A/B proof and
full evidence chain are in #222 and sections 7-23 above.

## 24. Leaf-tap experiment (2026-11-23, close)

Patched our own design's ODDR leaf selection GCLK0->GCLK5 (bus clock, fully
hopped rebuf chain, documented bits only): dead.  Combined with chain0/chain1
and the hybrid experiments, every documented-bit path to the IFCLK ODDR is
now proven inert on silicon, while the vendor image (whose clock rows carry
82%/41% undocumented bits) works through the identical probe.

Conclusion stands: the missing kintex7 clock-forwarding DB bits are the
blocker.  Terminal-only debugging is exhausted; the evidence package in
openXC7/nextpnr#222 is final.

## 25. PARADIGM SHIFT: undocumented bits are NOT load-bearing (2026-11-23)

Binary-search knockout preparation produced a decisive result first: clearing
**ALL 150 undocumented CLK_HROW bits from the vendor bitstream** leaves it
**fully functional** (drains 1 MB, no stall).  The vendor's entire working
clock configuration is expressible in DOCUMENTED bits only.

This overturns the "missing DB rows" framing.  The blocker is a
**documented-space difference** between our flow's output and the reference.
Subsequent tests this round:
- ZINV_CE(X1Y11) knockout on vendor: kills it -> CE effective-high required
  (vendor: CE pin low + ZINV_CE, or tied internally).
- ZINV_CE flip in our chain1: still dead.
- hybrid3 (our ODDR tile with tied D inputs + our CTL pads + vendor's whole
  clock column incl. BUFG/rebuf/CMT): dead.

The exhaustive documented-feature diff of all clock tiles between vendor and
our closest hybrid shows only benign leftovers (ENABLE_ABOVE/BELOW at unused
top-of-die rebuf tiles).  Therefore the difference lives in the tiles NOT
covered: our CLB/INT fabric or a global/config-level setting.

NEXT SESSION PLAN (concrete, staged):
1. Build the silicon-proven picosoc-qmtech design through OUR container flow
   (himbaechel) and diff its frames against a known-good build -> oracle for
   325T fabric/clock correctness of the new flow.
2. Exhaustive all-tile documented diff (not just clock) between vendor_true
   and our design, prioritizing shared-function tiles.
3. If (1) shows fabric corruption, bisect tile classes to locate it.

## 26. Additional isolation rounds (2026-11-23, continued)

- Vendor's GCLK0 confirmed driven (BUFGCTRL0_O->GCLK0, documented bits set).
- hybrid4 (hybrid3 + leaf-line L0 <- GCLK0 + GCLK0_ACTIVE at the leaf's hrow):
  dead.
- Vendor ZINV_CE(X1Y11) knockout: kills vendor -> CE effective-high required.

Full accounting of the hybrid series: vendor's complete clock column
(BUFG+cascade+rebuf+HCLK_*+hrow rows+MMCM) with documented bits only, plus
our ODDR tile with tied D inputs and our static CTL pads, is inert, while
the vendor image with the same documented bits is alive.  The delta is
therefore in (a) vendor fabric nets feeding the clock infrastructure
(CE nets, D-input constants route through fabric), or (b) our CLB/INT
output.  Both are testable next session with the picosoc-qmtech oracle
(silicon-proven 325T design, buildable through our container flow) and an
all-tile documented diff.

## 27. hybrid5 (2026-11-23)

Silicon-proven old-engine fabric (its own routing of diag_slrd, CE tied via
its fabric) + vendor's entire proven-driven clock column: dead.  The overlay
also swaps the hrow row, breaking the old engine's BUFHCE placement ->
confirms the clock infra and the CE/IMUX fabric nets are tightly coupled;
partial overlays cannot work.

## 28. IDENTIFIED PATH TO A WORKING BITSTREAM (next session)

The old nextpnr-xilinx engine is Python-scriptable (`--run script.py`):
we can drive placement programmatically.  Plan:
1. Build diag_slrd with the old engine, but force a BUFHCE at X1Y11
   (the vendor-proven BEL whose BUFHCLK11 spine + enables are documented)
   with CE tied via the engine's own VCC routing.
2. Route the 100 MHz into it via MUX_OUT_R11 (documented row).
3. Leaf <- IGCLK11 (documented).
This constructs the vendor-proven topology entirely from documented bits
with an engine that provably produces working fabric on 325T.  If this
bitstream drains, we have OUR design working on OUR board through OUR
toolchain -> DOD unblocked without any upstream dependency.

## 29. chain2 + old-engine CE semantics (2026-11-23, close)

Old-engine source (arch.cc routeBufhcePassthroughCE) documents that an
unrouted BUFHCE CE already reads as hard 1 (IMUX default VCC_WIRE + two
bitless always-pips; all five Vivado references show exactly IN_USE+ZINV_CE
with zero interconnect bits).  CE was therefore never our problem — and the
vendor's ZINV_CE-only configuration is the standard pass-through form.

Fixed a real bug in my chain experiments (set GCLK2_ACTIVE instead of
GCLK0_ACTIVE; corrected in chain2): still dead.

Current exact state: our chain (leaf<-IGCLK11, BUFHCE_X1Y11 IN_USE+ZINV_CE,
MUX_OUT_R11<-GCLK0, correct GCLK0_ACTIVE, 21 ENABLE_BUFFERs, CMT rows,
vendor MMCM) is inert while the vendor's identical-structure configuration
(GCLK2 instead of GCLK0) is alive.  The single remaining difference between
the two chains is the GCLK index (GCLK0 vs GCLK2) and what rides it.
Next: verify what our design's GCLK0 actually carries end-to-end (BUFG input
side), or simply re-run the chain against GCLK2/GCLK5 taps of OUR design's
other clocks (bus 100 MHz on GCLK5/6) — i.e. leaf/mux index sweeps on OUR
own builds rather than vendor copies.

## 30. GCLK sweep on our own build (2026-11-23, session close)

Proven BUFHCE_X1Y11 chain (leaf<-IGCLK11, IN_USE+ZINV_CE, MUX_OUT_R11 mux,
ACTIVE, 21 ENABLE_BUFFERs, CMT USED rows) built on OUR design with the mux
swept across our three GCLK spines (GCLK0/5/6, covering all three of our
clocks): **all dead**.

The complete documented-bit chain, on a self-consistent design, on a
proven-driven spine, on silicon-proven engine output, does not produce a
toggling IFCLK; the vendor's identical-structure chain does.  The remaining
unexplained delta cannot be resolved without additional reference data
(more Vivado bitstreams to decode the mux encodings, or a scope on AD1/CTL).

Terminal-only debugging is exhausted after ~75 hardware experiments across
two engines, one validated decode pipeline, and one confound-free A/B.
All instruments and the full evidence chain (SS 7-30) are committed; #222
carries the package.  The staged DOD ladder (2R2T build -> hw_gate -> 2RX ->
FFT/graphs -> tuning -> Diorama) runs the moment the missing encodings are
known.

## 31. IOB "bank glue" + T-tie discovery; counter instrument; pin-site parity (2026-11-23)

### Breakthroughs

1. **Knockout hierarchy (all on hardware):**
   - Vendor minus all 150 undocumented CLK_HROW bits: ALIVE (DB sufficient there).
   - Vendor minus 1104 undocumented RIOB18 (HP-bank IOB) bits: DEAD.
   - Vendor minus 29 undocumented pin-site bits (RIOI+RIOB18_X95Y109): DEAD.
   These undocumented bits are the "IOB18 HP-bank bank glue" class documented
   in the openXC7 Virtex-7 port; the open Kintex-7 flow emits none of them.
2. **GET_COUNTERS (0x24) byte 24/52 is a liveness instrument:** vendor=5
   (GPIF/PCLK alive), any design with a static/tri-stated IFCLK=3.  Validated
   by disabling the vendor's IFCLK OLOGIC (5 -> 3).  Fast feedback, no drain.
3. **T-tie bug (matches openXC7 virtex7 "OBUF T-tie convergence"):** the flow
   leaves the OBUF tristate input T at its VCC default -> pad tri-stated
   forever.  Vendor ties T low via GFAN0/GND chain.  Workaround: instantiate
   OBUFT with T=0 -> engine emits INT_R_X95Y110.GFAN1.GND_WIRE + IMUX15.GFAN1.
4. **Phantom route class:** several builds ended the D1 route on an undriven
   wire (e.g. IMUX34.WW2END0 with no WW2BEG anywhere) - a silent engine
   routing defect into IO-column IMUXes; seed-dependent.
5. **Vendor IFCLK structure decoded:** OLOGIC_Y1 pass-through/ODDR at
   RIOI_X95Y109, D1 <- IMUX34_0 <- INT_R_X95Y109.IMUX34 (same row), T tied
   low, plus undocumented pin-site bits.

### Exhausted deltas

After: OBUFT (T tied) + complete legal D1 route chain + all 29 vendor
undocumented pin-site bits + all documented-missing bits + input-side
(RIOI_X95Y27) undoc bits + slow 101-inverter ring AND live-codec-clock
loopback probes: GET_COUNTERS still 3.  Pin IOB config is now a superset of
the vendor's at the IFCLK site.

### Remaining unknown (next target)

The RIOI tile's internal switch-matrix routing (3878 undocumented bits in the
X95 column) is proven load-bearing (Y109 knockout) and is what our flow
cannot express - the IOI-internal hop from the fabric/LOGIC_OUTS wires into
the IOB/OLOGIC likely needs undocumented companion bits.  Decoding requires
Vivado reference bitstreams (cross-instance knockout) or upstream DB work;
all instruments (counter read, frame pipeline, knockout harness) are ready.

## 32. DEFINITIVE: the fabric long-line network is unroutable with the open DB (2026-11-23)

Mechanism found for ALL dead probes, replacing all earlier partial theories:

1. The open Kintex-7 DB documents long-line *consumption* rows (e.g.
   `INT_R.EE4BEG1.LH6`, `INT_R.NN6BEG1.LV9`) but has **ZERO driver rows** for
   the LH6/LV9 long-line class (grep over every segbits file: no
   `*.LH6.<src>` / `*.LV9.<src>` anywhere).  Drivable classes (LH12, LH0,
   LV18, LV0) have full driver rows and are what Vivado uses.
2. The himbaechel router's graph includes the undrivable wires, so it
   **routes through them silently** -> the net is electrically disconnected.
   Verified on our builds: ring3's D1 route dies at `EE4BEG1 <- LH6` (no
   LH6 driver anywhere in the bitstream); ring4's dies at `NN6BEG1 <- LV9`.
3. **Exhaustive proof (corrected start, 3M nodes)**: backward BFS from the
   exact post-IBUF wire (RIOI_X95Y27 'IOI_LOGIC_OUTS18_1' mapped via
   tileconn to R_TERM_INT_X234's 'TERM_INT_LOGIC_OUTS_L_B18') over the
   complete documented pip graph finds **NO legal path** to the IFCLK pad
   D1 mux (INT_R_X95Y110.IMUX34).  The RIOI<->fabric bridge and the
   LH6/LV9-class long-line drivers are undocumented, so *no* net can cross
   from the IO column into the fabric with the open DB.  This explains why
   every probe died regardless of design, clocks, or pin glue.
4. Same-class defects posted upstream (#222): OBUF T-tie omission, phantom
   long-line routes, RIOB18 HP-bank glue being load-bearing.

Consequence: the DOD is blocked on ONE well-defined database gap - the
long-line (LH6/LV9-class and companions) driver pips.  Closing it needs
Vivado reference bitstreams for fuzzer-style decoding (the standard openXC7
method, cf. cavearr's bench) or upstream acceptance of the gap report.
All instruments to verify a fix are in place: counter liveness read,
frame pipeline, knockout harness, BFS router for re-verification.

## 33. BEL-pinned flow, vendor-route grafts, half-decode corrections (2026-11-23)

New assets built and verified this session:

1. **Rebuilt nextpnr-himbaechel from openXC7/nextpnr 8d6d112** (container
   image's binary predates `get_cells`): now supports
   `set_property BEL <site>/<lut> [get_cells {name}]`, enabling exact
   placement. Built chipdb-xc7k325t.bin in the same run.
2. **Site-naming discovered**: prjxray slice sites are numbered by die grid
   (e.g. CLBLL_L_X92Y96 -> SLICE_X150/151Y96); CLBLL_LOGIC_OUTS_L8 =
   site CLBLL_L's A-LUT O6 (combinational), L4/L0 = FF Q (not usable
   without a clock).
3. **diag_ring5**: 51-LUT ring, every LUT BEL-pinned 2 tiles from the IFCLK
   pad; loop routes locally (no long lines).
4. **Vendor route decode**: the vendor's IFCLK is the **Y0-half ODDR**
   toggling from D1/D2 defaults, clocked by its LEAF_GCLK network; its D1
   mesh enters the column via
   `LOGIC_OUTS_L4 -> EE2BEG0@INT_L_X92Y96 -> ... -> IMUX34@INT_R_X95Y109`.
   My earlier Y1-half hypothesis was wrong (Y1 carries a different signal).
5. **XDC bugs fixed**: `set_property IOSTANDARD <pin>` lines (silently
   ignored by the old engine) corrected to real standards.
6. Despite BEL-pinned logic, a live LOCAL ring, the vendor's exact route
   rows grafted, T tied, and both half variants tested: counter stays 3.
   The remaining delta is the undocumented clock/bridge bits that only
   Vivado emits (LEAF_GCLK leaf hop and/or the final IOI crossing).

Everything reproducible: scripts/bfs_route.py (exhaustive route prover),
scripts/fix_half.py (vendor-route graft), scripts/build_diag_ring5.sh,
constraints with BEL pinning, counter instrument (/tmp/opencode/diag_log.py
pattern recorded above).

## 34. Vendor-structure clock chain matched exactly; burst-clock tests (2026-11-23)

With the rebuilt engine (BEL placement) a new probe was built that matches
the vendor's IFCLK structure EXACTLY and needs NO fabric routing:
- GPIF_CTL8 (the FX3's I2C SCL, same clock region as IFCLK) -> IBUF ->
  BUFG -> GCLK7 spine (rebuf descent) -> BUFHCE_X1Y0 -> BUFHCLK0 ->
  IGCLK0 -> leaf -> OCLK -> ODDR C;  D1/D2 = defaults; IS_D2_INVERTED set;
  no T rows; ODDR rows byte-equal to the vendor's.
- The missing `CLK_HROW_CK_IN_R0_ACTIVE` bit (vendor sets 215 ACTIVE rows,
  our flow emits 1) was found and added by hand.

The chain still does not deliver PCLK: SCL is only bursty (I2C on demand),
UHD reloads the FPGA before/during its own I2C bursts (confounding the
drain-window test), and the raw I2C vendor-request format could not be
reverse-engineered from the fixed firmware (all request shapes time out).

Remaining: verify the leaf/BUFH chain with a CONTINUOUS in-region clock.
Candidates not yet exhausted: the FX3 slfifo flags (CTL4/5) toggling during
DMA activity in region Y2, and decoding the vendor's 215 ACTIVE rows + the
HCLK-row bridge bits as a systematic fuzzer target.  All tooling in place.

## 35. UHD source-level confirmation; no external in-region clock exists (2026-11-23)

Verified against UHD's b200_iface.cpp (master):
- B200 `read_i2c`/`write_i2c` throw not_implemented - the FX3 never performs
  user-visible I2C; VRQ 0xBB/0xBA are the FX3's own EEPROM (returns 0xFF
  image, does not toggle our SCL pin, counter static).
- CTL6/CTL8 (SDA/SCL) are the FPGA's own DEBUG I2C master outputs in the
  vendor design (b200.v .debug_scl/.debug_sda) - NOT FX3-driven.
- CTL4/5 are slfifo flags - static without a running PCLK (chicken-and-egg).

Therefore no FX3-driven toggling signal exists in IFCLK's clock region, and
every in-region clock source must come from the documented clock network
whose vendor companion bits remain undecodable from the terminal.

This closes the search for an external clock bypass.  The blocker is fully
characterized: the open Kintex-7 DB lacks the IOI<->fabric bridge pips, the
LH6/LV9-class long-line drivers, and the clock-network companion bits the
vendor sets (215 _ACTIVE rows and friends).  All three classes require
Vivado-generated reference bitstreams to decode - the standard openXC7
fuzzing method.  Instruments for verification are complete and committed.

## 36. CRITICAL CORRECTION: the LOGIC_OUTS sweep was confounded by the ODDR self-toggle (2026-11-23)

Controlled A/B with proper negative controls invalidated a key earlier
interpretation:

- The vendor IFCLK OLOGIC_Y0 config (D1/D2 silicon defaults + IS_D2_INVERTED)
  toggles the pad AUTONOMOUSLY - any drain test against a vendor-base image
  therefore proves only that PCLK runs, nothing about fabric.
- With IS_D2_INVERTED cleared (self-toggle off): vendor FF outputs (L4),
  vendor LUT outputs, and our grafted rings ALL stall at 1024 B.  The
  fabric->OLOGIC D1->pad path does NOT work with documented bits alone -
  consistent with the exhaustive BFS result.  The earlier "6 LOGIC_OUTS
  indices drain at full speed" finding was an artifact of the self-toggle.
- The "vendor D1 route" (EE2BEG0 -> ... -> IMUX34 -> D1) was OUR graft
  construction; vendor fasm contains no D1 IMUX row at X95Y109.  The only
  PROVEN fabric->pad crossings in the vendor image are the GPIF_D data pads
  (real data flows) - which use ODDR/OSERDES configs without D1 IMUX rows,
  i.e. their data-entry mechanism is still to be decoded (125 OSERDES rows,
  40 ODDR rows at X95).  That decode is the next decisive target: replicate
  the vendor's working GPIF_D output path, feed it from our BEL-pinned
  ring (36 stages, vendor-empty tiles Y0-72 + audited Y96 X0/A6), and read
  the result on the IN endpoint while the vendor's IFCLK self-toggle
  provides PCLK.

Rig improvements this session (all committed):
- graft_ring9.py: bit-level graft of our CLB/INT rows into vendor_true.frames
  with same-dst one-hot conflict clearing; LUT INIT bit-accurate overwrite.
- Negative controls (constant-0 tap) now verified to stall -> instruments
  are sound; all prior alive/dead results re-interpretable.
- 36-stage slow ring BEL-pinned across vendor-empty CLBLL_L_X92Y{0..72}
  X0-sites (+ audited X0/A6LUT@Y96 tap); build honors every BEL.
- XDC/DB fixes: generate-block cell naming (g[i].genblk1.inv), and
  segbits_riob18.db DRIVE alias patch (mounted at build time) unblocking
  fasm2frames for IO designs.

DOD remains NOT met.  The confound removal makes every future result
trustworthy; the decoded target is now exactly one thing: the vendor's
working GPIF_D output data path.

## 37. Upstream #222 solution tested on hardware; remaining variable narrowed (2026-11-23)

Read (not posted) upstream openXC7/nextpnr#222. cavearr reproduced the issue
with Vivado 2026.1 on xc7k325tffg676-1 and measured the root cause:

- The missing piece is ONE bit per global clock: `CLK_HROW_R_CK_GCLK<n>_ACTIVE`
  must be set in EVERY clock row the clock crosses, not only where it has a
  load. nextpnr sets it only on loaded rows (nextpnr-xilinx got the rule in
  f0975539; the himbaechel port never did). He opened #226 for the general
  case.
- Correction to our earlier claims (his Vivado A/B): every bit Vivado sets in
  INT/IOI/IOB tiles is named in the DB (no undocumented bits); LH6/LV9 are the
  middle taps of long lines and are driven at the ends (LH0/LH12), so our
  "phantom route" conclusion was wrong; a plain OBUF needs no GND T-tie
  (Vivado writes the same 22 IOB/IOI lines as nextpnr).

Measured here after that analysis (all with the raw FX3 loader, GET_COUNTERS
byte 24 as liveness, and the drain probe as the DOD instrument):

| design | clock source | spine ACTIVE patch | counter | drain |
|---|---|---|---|---|
| diag_ring11 | codec SRCC pad -> IBUFDS -> BUFG -> GCLK0 -> BUFHCE -> leaf -> ODDR | no  | 3 | 1024 |
| diag_ring11 | same | yes (3 rows added, incl. the crossed row Y182) | 3 | 1024 |
| diag_ring12 | our 36-stage ring -> BUFG -> GCLK14 -> BUFHCE -> leaf -> ODDR | no | 3 | 1024 |
| diag_ring12 | same | yes (3 rows added) | 3 | 1024 |

So the upstream hypothesis is necessary-or-not, but not sufficient in our
shapes: with the spine fully ACTIVE the pad still does not toggle. Remaining
variables, in order of suspicion, are all in OUR side of the chain:
(1) the fabric->BUFG input (the engine's `CLK_BUFG_BUFGCTRL0_I0.CLK_BUFG_BOT_R_CK_MUXED0`
row may be a phantom input, as the IBUFDS path at X95Y27 shows no IGCLK hop);
(2) whether the ring oscillates at all (no independent observability);
(3) the HCLK_CMT companion bits (`HCLK_CMT_CK_BUFHCLK<n>_USED`) that upstream
says artix runs without.

Decoded while re-examining the vendor (corrects the earlier misread): the
vendor's GPIF_D pads drive through `OLOGIC_Y?.ODDR (DATA_RATE_OQ.SDR)` and the
ODDR's D1 input is a *bitless always-pip* hardwired to `IMUX34` of the same
tile; the vendor feeds `IMUX34 <- SL1END1` (ordinary routing). The whole
fabric->GPIF_D crossing is therefore documented, and is the right graft target
(no clock-network work needed: the vendor's own IFCLK self-toggle supplies
PCLK while our logic drives the data pin).

New assets: src/top/diag_ring11.v, src/top/diag_ring12.v,
scripts/build_diag_ring11.sh, scripts/build_diag_ring12.sh,
scripts/patch_spine_active.py (marks the whole GCLK spine stretch ACTIVE),
src/top/diag_pad26.v + scripts/build_diag_pad26.sh (single-pad output probe).

## 38. FABRIC->PAD PATH PROVEN: our LUT reaches a real GPIF data pin (2026-11-23)

graft_ring13.py: 4-inverter ring BEL-pinned in vendor-empty CLBLM_R_X37Y119
(X1 slice), tap = B6LUT O6 -> site always-pip CLBLM_LOGIC_OUTS9 (bitless,
column-wide bus, no vendor driver in this column), then the documented
crossing INT_R_X95Y115.IMUX34 <- LOGIC_OUTS9 into GPIF_D[26]'s ODDR D1
(bitless always-pip, verified from the vendor's own pad config: ODDR SDR +
OQUSED, D1 hardwired to IMUX34).

Measured (raw FX3 loader; drain probe; GET_COUNTERS byte 24):

| image                          | counter | drain  |
|--------------------------------|---------|--------|
| vendor baseline                | 5       | 65536  |
| POS: ring on D1 of GPIF_D[26]  | 5       | 1024   |
| NEG: tap LUT const-0 (same graft) | 5    | 1024   |

Interpretation, stated carefully:
- A single documented-row repoint changed the board's OUT-drain behavior from
  the vendor's full-speed 65536 to a hard 1024 stall, with PCLK alive (5).
  Mechanism: D1 now drives the pad constantly (ring or const-0), which fights
  the FX3's driver on the bidirectional data bus during OUT cycles -> the FX3
  refuses the transfer. This is behavioral proof that OUR FABRIC LUT OUTPUT
  ARRIVES AT A REAL DATA PIN through fully documented rows - no vendor
  grafting of pad config, no clock-network work, zero displacement of vendor
  cells (the ring tile was empty).
- NOT yet proven by this test: that the ring OSCILLATES (POS and NEG stall
  identically, as predicted for any constant or toggling D1 driver). The
  separating experiment is the T-path variant (IMUX15 <- LOGIC_OUTS9 drives
  the tri-state instead of the data), which changes the pad's drive-enable
  rather than its data - a const-0 tap there behaves differently from a
  toggling one.

Consequence for the DOD: the "undocumented bridge bits" theory is dead. Our
logic can drive real board pins with documented rows only. What remains for
2-RX-from-our-Verilog is engineering, not decode: a T-path liveness proof,
then the staged ladder (single pad -> GPIF CTL handshake -> our 2R2T design
grafted per-pin).

## 39. Ring-liveness probes inconclusive; a deliberate stop (2026-11-23)

Three discriminators were built and measured after §38. All three confirm the
fabric->pad arrival and none separates "ring oscillates" from "constant":

| probe (single documented-row repoint into the vendor image) | counter | drain |
|---|---|---|
| vendor baseline | 5 | 65536 |
| ring -> GPIF_D[26] ODDR D1 (IMUX34@X95Y115) | 5 | 1024 |
| const-0 -> same D1 (negative control) | 5 | 1024 |
| ring -> GPIF_D[26] OLOGIC T1 (tri-state, data path intact) | 5 | 65536 |
| const-0 -> same T1 | 5 | 65536 |
| ring -> GPIF_CTL12 (FIFOADR[0]) via IMUX34@X95Y109 | 5 | 1024 |
| const-0 -> same | 5 | 1024 |

What the table proves: every graft changes board behaviour exactly when it
replaces a live vendor-driven pin, i.e. OUR LUT OUTPUT ARRIVES AT REAL PINS
through documented rows (three different pins, three different configs).
What none of these rows can prove: whether the 4-inverter ring oscillates,
because in each observable the constant tap produces the same effect as the
ring (drive a bus that the vendor owns -> stall; tri-state a pad -> the vendor
never needs that T).

The honest conclusion of this session's methodology: the board currently
offers no observable that distinguishes a toggling LUT from a constant one
without displacing the vendor's own use of that pin. Continuing to permute
pins would burn time without changing that. The next step is an instrument,
not another permutation:

1. a host-readable stream in which OUR bit is not shared with vendor data
   (the FX3 IN endpoint with the vendor's stream set up by a settings-only
   UHD session is disqualified: UHD reloads the FPGA image), or
2. a physical probe on a header pin our logic owns exclusively (LED/GPIO),
   which is the only observable with no vendor contention.

Assets added: scripts/graft_ring13.py (documented-crossing graft),
scripts/graft_ring13_tpath.py (tri-state variant), scripts/graft_ring13_ctl12.py
(FIFOADR variant), src/top/diag_ctl12.v, scripts/build_diag_ctl12.sh.

## 40. Tooling consolidation: one build entry point (2026-11-23)

The diagnostic flow had accumulated 41 near-duplicate `scripts/build_diag_*.sh`
files (one per experiment, each a copy with a different design name and slow
drift in the container mounts). They are replaced by ONE parameterized script:

    DESIGN=diag_ring13 IGNORE_LOOPS=1 ./scripts/build_diag.sh

Conventions it encodes (previously implicit per copy):
- design:  src/top/$DESIGN.v
- XDC:     src/constraints/$DESIGN.xdc, else src/constraints/diag_pad.xdc
- outputs: build/fpga/ring2/{synth,pnr}/*, usrp_$DESIGN.bin
- engine:  the rebuilt himbaechel binary + matching chipdb (BEL placement)
- DB:      segbits_riob18.db with the LVCMOS18 DRIVE aliases mounted in
- checks:  device id is asserted (0x3651093), not just printed

Verified: the consolidated script reproduces the last diag_ring13 build
byte-identically (fasm diff 0 lines). The deleted scripts remain in git
history; the experiments they record are documented in §1-§39 above, and the
designs themselves (src/top/diag_*.v) are kept as the evidence artifacts.

## 41. The PCLK silence is a clock-input routing defect in the flow (row-level evidence)

Our full 2R2T design (b200_80) configures but PCLK stays static (counter 3,
drain 1024), while its IFCLK OLOGIC rows are structurally the vendor's
(ODDR + IS_D2_INVERTED + D1/D2 muxes). This round eliminated the downstream
suspects and found the input-side defect by comparing rows with the vendor:

| check | ours | vendor | verdict |
|---|---|---|---|
| GCLK spine ENABLE rows for the used clock | present on every segment (above+below) | subset | ours is a superset -> not the cause |
| HCLK_CMT `BUFHCLK<n>_USED` markers | set | absent | not the cause |
| `IOB_COL_BANK_ACTIVE` (33 rows on INT_R_X95*) | **missing** | present | added; **no change** (measured) |
| `OBUF_HP_BANK_GLUE` on the IFCLK pad | **missing** | present | added; **no change** (measured) |
| MMCM CLKINSEL route | routed from `CMT_TOP_IMUX0_2` | absent (default) | removed; **no change** (measured) |
| CMT reference input (`HCLK_CMT_L_X228Y26`) | `CK_IN10 <- CCIO0`, `CK_IN0 <- MUX_CLK_MMCM11`, no `CCIO*_ACTIVE/_USED` | `CK_IN0 <- CCIO0`, `CK_IN2 <- MUX_CLK_MMCM11`, `CCIO0/1_ACTIVE+_USED` | **different topology** |
| clock-capable input region (HCLK_IOI_X235Y26) | `ONLY_DIFF_IN_USE`, IGCLK0 <- BUFHCLK0 | `BUFR_Y1.IN_USE` (D2), `RCLK0` + IGCLK11 <- BUFHCLK11 | **different topology** |

Both designs are the same RTL, same MMCM tile (CMT_TOP_L_LOWER_B_X228Y9),
same pin (AA17, confirmed by the vendor's own LVDS rows at RIOB18_X95Y27).
The vendor's reference arrives on CMT clock-input line 0 (CCIO0) with the
CCIO active/used markers set; our engine routes it on line 10 without those
markers, and uses a different HCLK_IOI region topology (no BUFR).

Conclusion: the board silence is consistent with the MMCM never receiving its
40 MHz reference - a clock-input *routing* defect in our flow, not a config
value. It explains every "configures but never answers" measurement in §3,
and it is the same class cavearr fixed upstream for the spine (#222).

Next: either a fixed nextpnr build with the CMT input routing corrected, or a
Vivado golden diff of this exact net (the file to compare is
HCLK_CMT_L_X228Y26 + CMT_TOP_L_LOWER_B_X228Y9). Everything else in the design
is now measured as matching the vendor where it matters.

## 42. The clock-input remediation attempt and what it narrowed to (2026-11-23)

Applied the §41 topology fix on the full design and measured:

| change | counter |
|---|---|
| baseline b200_80 | 3 |
| + `IOB_COL_BANK_ACTIVE` (33 rows) | 3 |
| + `OBUF_HP_BANK_GLUE` (IFCLK pad) | 3 |
| - `MMCM_CLKINSEL` route (restore default) | 3 |
| reference line moved `CK_IN10 <- CCIO0` -> `CK_IN0 <- CCIO0` (+`CCIO0_ACTIVE/_USED`, feedback line to `CK_IN2` as the vendor has it) | 3 |

So none of these five changes revives PCLK. Comparing the remaining input tile
(`RIOI_X95Y27`, the pad our tool binds AA17 to) shows the vendor uses it as a
codec-data LVDS lane with ILOGIC/ISERDES/IDELAY config, while our design routes
it through `RIOI_I2GCLK_TOP0 <- IOI_ILOGIC0_O`. That raises the last unverified
assumption in this whole chain: **the package-pin -> site mapping our build uses
for AA17.** The db shipped here has no package-pin table (part.yaml has no
package_pins), so the mapping comes from the engine's chipdb and has never been
cross-checked against the vendor's own placed design.

That is the next check, and it is a facts-only check: obtain the vendor's
placed-design pin map (Vivado report or a pad-level diff of the vendor image
for that pin) and compare it with the engine's for AA17/AA18. If they differ,
every design we build is clocked from the wrong physical pad and PCLK silence
follows with no other defect needed. If they agree, the remaining candidate is
the IOI->HCLK/CCIO input hop (RIOI I2GCLK vs the vendor's path), which is one
tile to diff.

No claim beyond this: DOD is not met, and the failure is now narrowed to the
reference-clock input of the MMCM with two concrete, checkable hypotheses.

## 43. INSTRUMENT CORRECTION: GET_COUNTERS byte 24 is NOT a liveness indicator (2026-11-23)

Measured today with a clean negative control:

    vendor image:      CTR 5 5 -> 6 6 -> 7 7 -> 8 8   (increments ~1/s)
    our dead b200_80:  CTR 3 3 -> 4 4 -> 5 5          (increments identically)

GET_COUNTERS byte 24/52 is a free-running timer that increments on EVERY
configured image.  Section 31's claim ("vendor=5 alive, ours=3 static,
validated 5->3 by disabling the IFCLK OLOGIC") is wrong - the 5-vs-3 values
were just readings taken at different times after configuration.  Every
"counter stayed 3 = PCLK static" verdict in sections 41 and 42 and in today's
row-level experiments is therefore UNSUPPORTED by that instrument; only the
drain column of those experiments stands:

    | image                          | drain          |
    |--------------------------------|----------------|
    | vendor_ref.bin                 | 8 MB @ 12.8 MB/s ALIVE |
    | b200_80 baseline               | 1024 B stall DEAD |
    | + 33x IOB_COL_BANK_ACTIVE      | 1024 DEAD |
    | + OBUF_HP_BANK_GLUE            | 1024 DEAD |
    | - MMCM CLKINSEL route          | 1024 DEAD |
    | CK_IN10 -> CK_IN0 (+ACTIVE/USED)| 1024 DEAD |
    | - MMCM_RST route               | 1024 DEAD |
    | - bogus CLKFBIN route          | 1024 DEAD |
    | vendor MMCME2_ADV params grafted | 1024 DEAD |
    | vendor IO+CMT column frames grafted (96 frames) | 1024 DEAD |

The last row is the strongest: grafting the vendor's ENTIRE right IO/clock
column frame block (all 42 frames incl. every GPIF pin tile, the IFCLK
OLOGIC, the AA17 IBUFDS tile) plus the CMT column (MMCM + its parameter bits)
into our design's frames leaves the drain dead.  The handshake failure is
therefore NOT localized to the IO column, the CMT, or their glue rows - it is
consistent with the FPGA-side GPIF logic never engaging (fabric clock/reset
domain, cf. the section-32 long-line routing defect), or with tiles outside
the grafted columns.

Also verified today (facts that stand regardless of the counter):
- Package-pin mapping AA17 -> die pad X236Y335 -> fabric RIOB18_X95Y27 is
  CORRECT (chipdb string table agrees with tilegrid grid coords, and the
  vendor's only IBUFDS/IBUFDS_BANK_GLUE tile is exactly there).  The section-42
  "wrong pad" hypothesis is dead.
- vendor.fasm is INCOMPLETE for the CMT: the vendor's MMCM-output pips are
  set bits with no feature name in the open DB (127 unmapped bit diffs in the
  CMT tile).  Row-level comparison against the vendor is unreliable inside the
  CMT; frame-level comparison is required (done above).
- GET_LOG (0x23) is readable and shows fw stop/start + DMA config per load;
  it does not record drain abort reasons.

Instruments that remain valid: drain throughput (deterministic: vendor drains,
every design of ours stalls at exactly 1024 B), the loader's own drain report,
GET_LOG, and frame-level grafting with knockout controls.

## 44. Instrument hygiene + dangling pad-mux defect; all IO-level hypotheses eliminated (2026-11-23)

### Instruments
- `drain1.py` (load onto RUNNING firmware) is CONFOUNDED: after any prior
  config it reports 1024 B even for the vendor image.  `fx3_raw_load.py`
  (full FX3 reboot + firmware re-download each time) is the trustworthy
  drain instrument: vendor = 8 MB @ 12.3 MB/s, reproducible.
- All of this section's results are measured with the trustworthy instrument.

### New atomic tests (all 1024 B stall = DEAD)
| design | clock for IFCLK | result |
|---|---|---|
| diag_drain   | MMCM 100 MHz (vendor-identical clk gen) | DEAD |
| diag_drain40 | codec 40 MHz IBUFDS->BUFG->OBUFT, no MMCM | DEAD |
| diag_ringdrain   | 36-inv fabric ring, flags-gated SLRD | DEAD |
| diag_ringdrainu  | same, unconditional SLRD | DEAD |
| diag_ringdrain_t | same, all pads OBUFT(T=0) | DEAD |
The MMCM is therefore NOT the discriminator: even a design with no MMCM and
no state machine, driving the GPIF read strobes, cannot make the FX3 drain.

### New flow defect found and measured: dangling pad-input muxes
The engine selects IMUX inputs of IO-column pad logic but frequently emits
NO driver row for the selected IMUX (or ties VCC where the RTL value is a
constant - including driving VCC for a constant-0!).  Scan of b200_80
(seed 2): 22 dangling pad muxes, among them
- GPIF_CTL11 (fifoadr[1]) D1: no driver -> FX3 thread address undefined
- GPIF_CTL3/1/7 (SLRD/SLWR/PKTEND) T1: no driver -> tristate undefined
- IFCLK OCE + D2: no driver -> output clock-enable/edge undefined
- GPIF_D[26], GPIF_D[13] D1: no driver -> data bits stuck
Vendor avoids all of it: control pads are driven via the direct
`IOB_COL_OBUF_CASCADE` path with NO OLOGIC rows at all; our engine cannot
express that path and then fails to route the OLOGIC side-muxes it creates.

### Fixes applied and re-measured
- b200_80.v: all GPIF control outputs + IFCLK now go through explicit
  OBUFT(T=0).  This eliminates the T1 hangs (verified in fasm).
- Frame-level grafts with correct DB rows (IMUX29.VCC_WIRE for OCE,
  GFAN0.GND_WIRE + IMUX<n>.GFAN0 for constant-0 D1/D2 inputs) repaired the
  remaining IFCLK OCE/D2, CTL11 D1, GPIF_D[26]/[13] D1.
- Result: b200_80t + grafts still 1024 B DEAD.

### Where this leaves the search
With pin mapping verified, control routing (CTL3) vendor-identical, every
pad mux driven, and every clock source tried, the only surviving hypothesis
chain is: the design's own clock/reset domain never comes alive -
`gpif_rst` is released only when MMCM `locked` asserts (b200_80.v
clocks_ready logic), and our engine's MMCM/clock-distribution output has
never been proven functional (sections 41-42 row differences + the vendor
CMT pips being undecodable in the open DB).  Next decisive step: make
`locked` irrelevant - build a b200_80 variant where gpif_rst/clocks_ready
bypass the MMCM lock (reset from CTL9 only) and clocks run from the codec
reference directly; if it drains, the MMCM lock path is confirmed as the
blocker and can be worked around for RX.

### Addendum: the missing matrix cell
diag_drain_t (codec 40 MHz IFCLK via IBUFDS->BUFG->OBUFT + all pads
OBUFT(T=0) + flag-gated reads): 1024 B DEAD.  The full clock-source matrix
(MMCM / codec / ring) x (plain / OBUFT pads) x (gated / unconditional
reads) is now complete: every cell stalls.  Remaining unknowns: whether the
codec clock actually toggles the IFCLK pad (fabric->pad clock arrival is
still unproven for every source), and whether the minimal flag protocol
matches the FX3 firmware's expectations.  The next discriminating
experiment must establish IFCLK liveness at the pad itself, independent of
the GPIF protocol.

## 45. Upstream research digest + codebase audit; engine rebuilt from openXC7/nextpnr main (2026-11-24)

### GH issue research (read-only; openXC7/nextpnr-xilinx was archived Sep 2026 - development continues at openXC7/nextpnr, where OUR issues #222/#226 live)
- cavearr's A/B on #222: the route SHAPE matches Vivado; the one-bit difference is
  `CLK_HROW_R_CK_GCLK<n>_ACTIVE` in every crossed row. Himbaechel fix NOT yet merged
  (promised with goldens). Our builds already carry those bits (superset) - §41.
- Debunked by cavearr (stop chasing): LH6/LV9 "missing drivers" (by design; use
  LH0/LH12 at line ends), HCLK_CMT_CK_BUFHCLK<n>_USED (artix runs without),
  plain-OBUF T-tie "bug" (couldn't reproduce), "undocumented bits everywhere"
  (an artifact of decoding a COMPRESSED bitstream linearly - use bitread).
- Issue #79: RIOB18 `OBUF/IBUF_HP_BANK_GLUE` rows are ALIASES of OLOGIC bits
  (OQUSED/OMUX.D1/DATA_RATE_TQ.BUF) - explains our confusing glue-row experiments.
- Merged after our 8d6d112 build: #216 (IOLOGIC clock inverter folding -
  our IFCLK ODDR path), #225 (ISERDES open-input ties), #215, #217.
- Open #227: Zynq HP-bank ODDR packing hang - same code path family, watch it.

### Codebase audit (agents; concrete defects found and FIXED)
1. b200_clk_gen80 = VCO 1200 MHz, gpif/bus = 80 MHz, but b210.xdc constrained
   100 MHz -> pnr timing FAIL (bus_clk 93.52 < 100). FIXED: create_clock 12.5 ns.
2. pps_generator CLK_FREQ(100000000) on an 80 MHz bus_clk. FIXED: 80000000.
3. reset_sync maps to SRL16E INIT=0 -> powers up DEASSERTED; a dead clock leaves
   gpif_rst=0 (looks "not in reset"). Probing gpif_rst is NOT proof of liveness.
4. codec_reset holds the AD9361 (and radio_clk) until UHD writes a setting -
   radio domain is dead at power-up by design; GPIF domain is independent.
5. OBUFT insertion is the only functional RTL delta vs the last image; the
   pre-OBUFT image was also dead, so it is not the root cause (kept: guards the
   engine's dangling-T defect).

### Toolchain refreshed from upstream main
- nextpnr-himbaechel rebuilt from openXC7/nextpnr main (post #216/#225/#215/#217)
  + fresh chipdb + FULL openXC7 prjxray-db (kintex7 now complete; our
  segbits_riob18 DRIVE patch no longer needed - fasm2frames clean without it).
- Rebuild b200_80t with new engine: pnr PASSES timing (bus_clk 86.16 > 80).
- Hardware result: drain 1024 DEAD, control channel 0/20 responses. Unchanged.

### Invalidated conclusion (correction to section 38)
The ring13 "fabric->pad arrival" proof is CONFOUNDED: LOGIC_OUTS9 at
INT_R_X95Y115 belongs to the CLB column ADJACENT to the IO column; the ring
lives in CLBLM_R_X37Y119 - a different column - so the tap cannot physically
drive that wire. Both the ring graft AND a const-0 graft kill the control
channel identically: the graft simply replaced the vendor's D1 source with an
undriven wire. No pad arrival was ever proven. The control-channel instrument
(ctrl_peek2: raw VRT peek over EP4/EP0x88, protocol decoded from UHD
radio_ctrl_core_3000) is the new reliable host-readable observable: vendor
image answers 20/20 deterministically; every design of ours answers 0/20.

### Standing
DOD not met. The control channel gives us, for the first time, a
protocol-level observable; every image of ours is silent on it, which localizes
the failure to the FPGA-side GPIF/control data path (clock domain or the
long-line routing defect), not to USB/FX3 mechanics.

## 46. Full-lane spine-ACTIVE patch tested on the current image (2026-11-24)

Upstream's fix shape ("mark CLK_HROW_R_CK_GCLK<n>_ACTIVE in every crossed
row, not just rows with a load") applied exhaustively to b200_80t: all 6 used
GCLKs (0,3,5,6,16,21) marked ACTIVE in all 7 CLK_HROW rows of the column
(Y26/78/130/182/234/286/338; 22 new rows). Rebuilt with the current engine
and full prjxray-db.

Measured: drain 1024 DEAD, control channel 0/20. No change.
So the crossed-row ACTIVE bits (even the exhaustive form) are not sufficient
for this design on this DB/engine - consistent with upstream #226's caveat
that the bit is not yet board-confirmed to be the cause on kintex7.

Cumulative picture (all measured with the trustworthy instruments):
- 9 clock-source topologies, 3 engine versions, full/full-lane spine
  patching, vendor IO+CMT column grafts, pad-mux repairs: every image of
  ours is silent on drain AND control.
- Every vendor image: alive on both.
- The FPGA-side GPIF path therefore never comes alive under our flow, and
  the difference is not in RTL logic design, pin mapping, IO config, or the
  specific clock source.

## 47. Isolation completed: the failure is in OUR FABRIC, not clock infra, IO, or RTL (2026-11-24)

Merged the vendor's COMPLETE clock infrastructure (every CLK_*, HCLK_*, CMT_*
tile word-range; 699 tiles, 2077 words) into our built image - on top of the
earlier vendor IO-column graft. The resulting image therefore contains:
vendor clock distribution + vendor CMT/MMCM config + vendor IO/OLOGIC/IOB
bits, and ONLY our fabric (CLB/BRAM/DSP placement + routing + our netlist).

Measured: drain 1024 DEAD, control channel 0/20.

Since the RTL netlist is the vendor's own (control core and GPIF engine are
verbatim ports), and the surrounding infrastructure is now bit-identical to
the working vendor image, the only remaining variable is the fabric
implementation produced by our flow (placement + fabric routing bits).

Conclusion: our flow's FABRIC connectivity is the blocker. Every hypothesis
below the fabric level (RTL logic, pin mapping, IO config, bank glue, clock
source, clock distribution, reset logic) has now been eliminated by
measurement, each with a working vendor control image as the negative
baseline. The next step is toolchain work on fabric routing (or an upstream
fix), not more design permutations.

## 48. GPIF research digest applied; thread-mapping correction; Dotncom's edits queued (2026-11-24)

### Research (web + GH, read-only)
- **FX3 firmware thread mapping VERIFIED from EttusResearch/uhd b200 firmware**:
  FIFOADR 0 = EP2 OUT (host->FPGA data), 1 = EP6 IN (FPGA->host data),
  2 = EP4 OUT ctrl, 3 = EP8 IN ctrl; watermarks 5/6/5/6; SM starts
  unconditionally (STATE_RUNNING set regardless of FPGA). The 1024 B stall =
  the FX3's own USB-side buffer, per AN65974.
- **Correction to our own diag work**: the RTL's ADDR_DATA_RX (2'b01) is the
  FPGA->host socket - my minimal drain designs selected thread 1 (always
  empty). Corrected to thread 0 (2'b00) in diag_drain/diag_drain40/
  diag_drain_t/diag_ringdrainu and re-measured: still 1024 DEAD. So the
  thread error did not mask a fix; the failures stand.
- **PR #228 exists (unmerged, written by cavearr)**: marks a global clock
  active in every crossed row - superset-equivalent to our section-46
  exhaustive patch (measured DEAD), but a build from that branch is queued.
- **Dotncom/B210-Kintex7-openXC7**: independent openXC7 effort on the SAME
  board. Concrete FASM edits for our exact IFCLK tile, not yet
  hardware-validated: remove RIOI_X95Y109.OLOGIC_Y0.ODDR.SRUSED +
  .ZSRVAL_OQ; remove RIOB18_X95Y27.DIFF.ZIBUF_LOW_PWR +
  .IOB_Y0.IBUFDS_BANK_GLUE; add RIOI_X95Y109.TRIAL_ODDR_OMUX_Q.
- **kingjamez/B210_XC7K325T_Improvements (Vivado, working)**: the B210 GPIF
  sits at ~0.1 ns setup margin; needs IOB-registered I/O + IFCLK phase lead.
  nextpnr has no set_output_delay support (#175 open) - even after the clock
  arrives, CTL/DQ skew is the next failure mode, not evidence of a second
  clock bug.
- No third party has ever run a B210 GPIF on openXC7; both open attempts
  (ours, Dotncom) stop at the handshake.
- Firmware ground truth for CTL polarity: b200_gpifconfig.h
  (GPIF_CTRL_BUS_POLARITY 0xBF, DEFAULT 0xFFCF) - diff target for CTL lines.

### Queued next (in order)
1. Build nextpnr from cavearr:xilinx/clock-row-active-spine (PR #228) and
   re-run b200_80t (supersedes our hand patch).
2. Apply Dotncom's RIOI_X95Y109/RIOB18_X95Y27 FASM edits to our build.
3. If either revives IFCLK (control channel answers), then evaluate CTL/DQ
   timing per kingjamez before declaring victory.
