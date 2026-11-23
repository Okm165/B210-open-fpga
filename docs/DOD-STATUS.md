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
