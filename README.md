# B210 Open FPGA

Source-first, terminal-only FPGA build for the B210 Kintex-7 firmware. The
design is the B200/B210 Verilog RTL, rebuilt with open tools. No vendor IDE,
license, Nix, or GUI is required.

```text
Yosys v0.69            Verilog synthesis
nextpnr f745549        placement and routing (himbaechel/Xilinx)
Project X-Ray          FASM -> frames -> .bit
```

The result is an independent open-flow image, not a vendor-supplied image.

[AUDIT.md](AUDIT.md) records the measured receive-path claims: the distortion
budget, the throughput at every stage, and the test that guards each one.

## Design

| Item | Value |
| --- | --- |
| FPGA | `xc7k325tffg676-1` (Kintex-7 325T, FFG676; device IDCODE `0x3651093`) |
| Top module | `b200` |
| HDL | Verilog-2001 |
| Constraints | `src/constraints/b210.xdc` |
| Clocking | `src/top/b200_clk_gen.v` (`MMCME2_ADV`, 40 MHz in, 40/100/100 MHz out) |
| Halfband filters | `src/ip/hbdec.v` (49-tap, `src/ip/hb47.coe`) |
| Device data | `third_party/prjxray-db` (Project X-Ray, CC0) |

## Toolchain

All tools are built from source in atomic container images:

| Image | Dockerfile | Contents |
| --- | --- | --- |
| `b210-open-fpga-base` | `container/base.Dockerfile` | Ubuntu 24.04 build environment |
| `b210-open-fpga-yosys` | `container/yosys.Dockerfile` | Yosys `v0.69` |
| `b210-open-fpga-nextpnr` | `container/nextpnr.Dockerfile` | nextpnr `f745549`, Xilinx himbaechel, xc7k325t chipdb |
| `b210-open-fpga-prjxray` | `container/prjxray.Dockerfile` | Project X-Ray `ed3331c` frame tools |
| `b210-open-fpga` | `container/toolchain.Dockerfile` | composed final image |

Repositories and official documentation are listed under
[References](#references).

The host needs Podman or Docker, GNU Make, Git, Python 3, and Icarus Verilog
(`iverilog`, `vvp`) for the host tests.

## Layout

```text
src/                 RTL, constraints, and portable IP
tests/               self-checking host tests
scripts/             source manifest and small Python helpers
container/           atomic toolchain images
third_party/         Project X-Ray xc7k325t data (CC0)
Makefile             build interface
README.md            this file
AUDIT.md             measured receive-path claims and their tests
build/               generated output; ignored by Git
```

## Commands

```sh
make tools       # build the atomic images and the final toolchain
make build       # synthesize, place, route, and write the bitstream
make synth       # Yosys synthesis only
make pnr         # place and route only (requires make synth)
make bitstream   # FASM -> frames -> .bit/.bin (requires make pnr)
make analyze     # Yosys netlist analysis
make timing      # nextpnr timing/utilization summary
make test        # every bench, the constraint check, and whole-design elaboration
make elab        # elaborate the complete design against the primitive models
make hello       # compile the hello world through the whole toolchain
make doctor      # check host tools and the toolchain image
make verify      # check the committed source state
make release-check # verify + image identity + every bench (the signoff gate)
make plots       # the loop pages: whole-radio spectra, ends, losses
make plots-levels # converter utilisation and transmitter headroom
make plots-extra # band edge, rates, MIMO match, dense probe, retune
make deploy      # assemble build/deploy: image + provenance + checklist
make shell       # interactive shell in the toolchain image
make clean       # remove only this repository's build/ directory
make image-clean # remove all toolchain images
```

Overrides:

```sh
make build CONTAINER_ENGINE=docker
make build FPGA_PART=xc7k325tffg676-1
make build FPGA_ALLOW_TIMING_FAIL=1   # bring-up only; not timing signoff
```

## Outputs

```text
build/fpga/synth/b200.json                  Yosys netlist
build/fpga/pnr/b200.fasm                    nextpnr FASM
build/fpga/pnr/b200.frames                  Project X-Ray frames
build/fpga/bitstream/b200.bit               TLV bitstream
build/fpga/bitstream/b200.bin               raw payload (FX3 format)
build/fpga/bitstream/usrp_b210_fpga.bin     copy with the UHD filename
build/fpga/logs/                            tool logs
build/fpga/reports/                         timing and utilization reports
```

The `.bin` is the exact `e` payload of the `.bit`, including the 7-series
bus-width/sync preamble. The `.bit` wrapper records the build time, so its
hash varies; the raw `.bin` is reproducible.

## Validation

`make release-check` is the signoff gate: it refuses a dirty tree, checks the
image against its recorded sha256 and against a digest of the RTL/source
list/XDC/defines, and runs every bench.  Current state: **105 benches pass**.

- Yosys synthesis completes; place and route reports 0 errors; every clock
  passes with at least 5 % margin; the raw image carries IDCODE `0x3651093`.
- A fresh checkout reproduces the raw `.bin` byte-for-byte
  (`bcf0a6fc17be573e23d1d44a8e5867d4ce122f93340e0ea4500814484ec8d5bb`).
- The whole-radio loop is measured in simulation, in both directions, both
  channels, at every shipping rate: `plots/` pages are byte-reproducible and
  the numbers behind them are in `docs/FINAL-REPORT.md`.

Detailed reports are written under `build/fpga/reports/`.

## References

- Yosys: <https://github.com/YosysHQ/yosys>
- Yosys `synth_xilinx`:
  <https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/synth_xilinx.html>
- nextpnr: <https://github.com/YosysHQ/nextpnr>
- nextpnr Himbächel:
  <https://github.com/YosysHQ/nextpnr/blob/main/docs/himbaechel.md>
- Project X-Ray: <https://github.com/F4PGA/prjxray>
- Project X-Ray database: <https://github.com/F4PGA/prjxray-db>
- F4PGA: <https://f4pga.org/>
