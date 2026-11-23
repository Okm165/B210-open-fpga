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
