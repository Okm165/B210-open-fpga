# B210 open FPGA

The USRP B200/B210 FPGA design (2 RX + 2 TX, AD9361, Cypress FX3) for the
OpenSourceSDRLab B210 board (Kintex-7 `xc7k325t-ffg676`), built from Verilog
with open tools only: Yosys, nextpnr-himbaechel and Project X-Ray. No vendor
IDE, licence or prebuilt image is involved in what gets loaded on the board.

`docs/STATUS.md` holds what is measured to be true today and what is open.

## Flow

```text
scripts/toolchain.sh   place-and-route engine and device database, from pinned
                       upstream sources plus the fixes in container/patches
scripts/build.sh       Verilog -> build/fpga/usrp_b200.bin (+ a build record)
scripts/hw_gate.sh     acceptance of that image on the board
```

| Step | Tool | Where it runs |
| --- | --- | --- |
| synthesis | Yosys v0.69 | container `b210-open-fpga` (`make tools`) |
| place and route | openXC7 nextpnr-himbaechel `be38ec6` + two patches | host, `.tools/` |
| FASM -> frames -> bit -> bin | openXC7 Project X-Ray `6dabf70` | container |
| device database | openXC7 prjxray-db `0c3504f` + patch | `third_party/prjxray-db-openxc7` |

```sh
make tools        # container image: yosys + Project X-Ray tools
make toolchain    # .tools/: nextpnr, chipdb, and the measuring UHD
make build        # build/fpga/usrp_b200.bin
make gate         # hardware acceptance on the connected board
make test         # simulation benches, constraint check, elaboration
```

Host requirements: podman, git, cmake, a C++20 compiler, boost, eigen3,
python3 with pyusb/numpy/matplotlib, Icarus Verilog, and UHD (the stock host
driver the image is validated against).

## Layout

```text
src/top/           b200.v (top), b200_io.v (AD9361 interface), b200_core.v,
                   b200_clk_gen.v, diag_echo.v (the FX3 bus alone)
src/rtl/           radio, DSP, FIFO, GPIF and control RTL (Ettus, LGPL)
src/constraints/   b210.xdc: pins, clocks, buffer sites, crossing bounds
scripts/           the flow and the hardware instruments
container/         the container image (Dockerfile) and the upstream patches
tests/             simulation benches (make test)
build/             generated output, ignored by git
```

## Hardware instruments

| Script | What it measures |
| --- | --- |
| `scripts/hw_gate.sh <bin>` | the full acceptance, in order: build identity, raw FX3 path, stock UHD init and streaming, interface eye, sample content, throughput. Where a number depends on the board or the host it is measured on the vendor image in the same run |
| `scripts/fx3_raw_load.py <bin> --peek N` | FX3 reboot, FPGA load, raw control transactions and an 8 MB drain, without UHD |
| `scripts/eyescan.sh <bin> [rate]` | the AD9361 interface eye: UHD's codec loopback over every clock/data delay, with the margin at UHD's fixed operating point |
| `scripts/sample_check.py <bin> --prbs` | receive path, bit exact: every sample of the AD9361's pseudo-random test sequence is checked, on both channels and for their alignment |
| `scripts/sample_check.py <bin> --tone` / `--loopback F` | receive and transmit paths, spectral: level, SFDR, SINAD, DC and channel phase relation of a known tone, optionally against a reference image (`--ref`) |
| `scripts/dsp_exact.py rx\|loop <capture>` | the DSP chains on the board against the repository's RTL: every captured sample compared with the Icarus simulation of the same input |
| `scripts/bus_window.py <routed.fasm>` | the FX3 bus timing window: the forwarded clock moved through its range in the bitstream, a bit-exact bus loopback at each setting |
| `scripts/fx3_raw_load.py <bin> --echo N` | both directions of the FX3 bus, bit exact, on the bus-only design `src/top/diag_echo.v` |
| `scripts/rx_capture.py` | a capture through the stock UHD Python API with spectrum graphs (antenna signal) |
| `scripts/fast_test.py` | a FASM-level patch assembled and measured without re-running place and route |

UHD only tests the image named in `fpga=<path>` of its device arguments; a
plain UHD call loads the vendor image from `/usr/share/uhd/images`.

## Where the measurements are

Everything below is written by the tools above and is not in git (`build/`):

| Path | What it holds |
| --- | --- |
| `build/fpga/usrp_b200.txt` | the build record of the image beside it: every source file with a hash, the tool versions, the three clock frequencies place and route measured and every clock-domain crossing with its bound. `scripts/hw_gate.sh` refuses an image whose record does not match its bytes |
| `build/fpga/logs/<name>-pnr.log` | the full place-and-route log: the critical path of every clock and crossing, and the routed result |
| `build/hw-gate-<UTC>/` | one acceptance run, one file per step: `00-identity`, `01-raw` (FX3 bus without UHD), `02-init` and `02-stock-rx-*` (stock UHD), `03-eye`, `04-samples-*` (tone, PRBS, loopback), `05-dsp-*` (board against RTL, sample by sample), `06-bus-margin`, `07-<mode>-{vendor,ours}-*` (throughput, each run of this image between two runs of the vendor image) |
| `build/rx_look/{ours,vendor}/` | an antenna capture through the stock UHD Python API with its spectrum PNG and the numbers behind it (`scripts/rx_capture.py`) |
| `build/tmp/` | scratch: patched bitstreams, intermediate logs, `build/tmp/benchfix/` mutant runs |

The numbers those files contain, and what the vendor image does under the
same conditions, are collected in `docs/STATUS.md`.

Streaming measurements at 245 MB/s need the host: the tools ask for
real-time priority (`chrt`) when the account may use it, and the gate
reports "inconclusive" rather than a verdict when even the vendor image
loses samples.

## Licence

The RTL under `src/rtl` and `src/top` derives from Ettus Research's USRP FPGA
sources (LGPL-3.0-or-later). Everything else in this repository is GPL-3.0;
see `LICENSE`.
