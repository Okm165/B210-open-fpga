# Bug report draft: xc7frames2bit emits a single FDRI burst that crosses block boundaries

## Summary

Bitstreams produced by `fasm2frames` + `xc7frames2bit` for large 7-series
parts configure successfully (CRC checks pass, DONE asserts) but the
fabric does not run.  We traced this to the frame-data packetization:
`Configuration<Series7>::createConfigurationPackage()` writes **all**
frames in a single type-2 FDRI packet starting at FAR=0, relying on the
device's frame-address auto-increment to traverse the whole die.

On 7 series, FAR auto-increment does not carry across configuration
block/column boundaries.  Vivado never relies on it: it rewrites FAR for
every contiguous run of frames (typically per column, chunks of a few
frames).  With a single burst, every frame after the first block boundary
is written to a wrong physical location, so the configuration memory ends
up scrambled while the configuration interface still reports success.

## Evidence (measured on hardware, USRP B210-class board, XC7K325T-FFG676)

1. Vendor Vivado bitstream (4,583,732 B, compressed, 19,681 explicit FAR
   writes): device works (UHD probe, loopback tests, streaming).
2. Same design's FASM re-emitted with prjxray's writer (11,443,710 B, 2
   FAR writes, one 2,860,320-word type-2 burst): configures, DONE high,
   **no functional response** (control interface dead).
3. Same FASM content, re-packaged with explicit FAR per frame
   (27,852 FAR writes): packet-level decode of the emitted bitstream is
   content-identical (1,030,764 FASM features, 0 differences) - pending
   hardware confirmation at time of writing.
4. Two independent P&R toolchains (YosysHQ/nextpnr f745549 and
   openXC7/nextpnr 42d06c5) produce equally non-functional images; the
   round-trip control (2) shows the defect is in the writer, not in
   placement/routing or the device database.

## Suggested fix

In `Configuration<Series7>::createConfigurationPackage()` (and the
UltraScale(+)/Spartan6 paths), split the frame data into per-run FDRI
packets with an explicit FAR write before each run - matching the frame
ordering that `fasm2frames` emits - instead of one monolithic type-2
packet.  Optionally implement the vendor's compression style (MFWR +
CTL1 bit 12) later; uncompressed-but-correct is enough to unblock.

## Reproduction

- Part: xc7k325tffg676-1 (kintex7 DB), prjxray master.
- Any design large enough to span more than one configuration block.
- Observe with `build/pkt_dump.py`-style packet dump: vendor vs prjxray.
