# B210 open FPGA

The USRP B200/B210 FPGA design (2 RX + 2 TX, AD9361, Cypress FX3) for the
OpenSourceSDRLab B210 board (Kintex-7 `xc7k325t-ffg676`), built from Verilog
with open tools only: Yosys, nextpnr-himbaechel and Project X-Ray. No vendor
IDE, licence or prebuilt image is involved in what gets loaded on the board.

`docs/STATUS.md` holds what is measured to be true today and what is open.

## Flow

```sh
make tools        # container image b210-open-fpga: Yosys, Project X-Ray tools     14 min
make toolchain    # .tools/: place-and-route engine, chip database, measuring UHD
make build        # build/fpga/usrp_b200.bin and its build record                  1.5 h and up
make gate         # acceptance of that image on the connected board                40 min
make test         # simulation benches (needs the container image)                 15 min
```

| Step | Tool | Where it runs |
| --- | --- | --- |
| synthesis | Yosys v0.69 | container (`container/Dockerfile`) |
| place and route | openXC7 nextpnr-himbaechel `be38ec6` + three patches | host, `.tools/` |
| FASM -> frames -> bit -> bin | openXC7 Project X-Ray `6dabf70` | container |
| device database | openXC7 prjxray-db `0c3504f` + patch | `third_party/prjxray-db-openxc7` |

Every source is pinned to a revision; the patches are in `container/patches`
and each is explained at the head of `scripts/toolchain.sh` and in
`docs/STATUS.md`. `scripts/build.sh` writes beside each image what it was
built from and what timing place and route measured; `scripts/hw_gate.sh`
accepts an image only with that record, built from committed sources, with
every clock and every clock-domain crossing inside its constraint.

### What the host needs

- podman, git, cmake, ninja, a C++20 compiler, boost and eigen3 headers
  (engine), libusb-1.0 headers and python3-mako (measuring UHD), about 6 GB
  of disk for the two tool builds and network access to GitHub, PyPI and
  Docker Hub while they run;
- Icarus Verilog and python3 with numpy for `make test`;
- for the board: UHD with its Python module and its image package (the FX3
  firmware `usrp_b200_fw.hex` and the vendor image `usrp_b210_fpga.bin`, which
  the gate uses as its reference device), python3 with pyusb, read/write
  access to USB device `2500:0020` (UHD's udev rule), and for the streaming
  measurements permission to run at real-time priority (`ulimit -r` of 50 or
  more; without it the tools run and say so).

### Settings

| Variable | Used by | Meaning |
| --- | --- | --- |
| `SERIAL` | gate, eyescan, sample_check | board serial; only needed with several B2xx on the host |
| `UHD_IMAGES_DIR` | gate and instruments | where the FX3 firmware and the vendor image are (default `/usr/share/uhd/images`) |
| `WAIT_QUIET` | gate | seconds to wait for an idle host before the throughput step (default 0) |
| `FPGA_IMAGE` | build, assemble, make | container image (default `b210-open-fpga:0.3.0`) |
| `TEST_JOBS` | make test | benches run at a time (default 8) |
| `DESIGN`, `NAME`, `PARAMS` | build | another top from `src/top`, its output name, parameter overrides |

The heads of `scripts/build.sh` and `scripts/hw_gate.sh` list the rest.

## Layout

```text
src/top/           b200.v (top), b200_io.v (AD9361 interface), b200_core.v,
                   b200_clk_gen.v, diag_echo.v (the FX3 bus alone)
src/rtl/           radio, DSP, FIFO, GPIF and control RTL (Ettus, LGPL)
src/constraints/   b210.xdc: pins, clocks, buffer sites, crossing bounds
scripts/           the flow and the hardware instruments
container/         the container image (Dockerfile) and the upstream patches
tests/             simulation benches and their runner (make test)
build/             generated output, ignored by git
```

## Hardware instruments

| Script | What it measures |
| --- | --- |
| `scripts/hw_gate.sh <bin>` | the full acceptance, in order: build identity, raw FX3 path, stock UHD init and streaming, interface eye, sample content, DSP against RTL, bus margin, throughput. Where a number depends on the board or the host it is measured on the vendor image in the same run |
| `scripts/fx3_raw_load.py <bin> --regs` | FX3 reboot, FPGA load, then the control path through USB, FPGA registers (written and read back) and the AD9361 (product ID), without UHD; `--peek N` repeats control transactions, the default 8 MB drain moves data |
| `scripts/eyescan.sh <bin> [rate]` | the AD9361 interface eye: UHD's codec loopback over every clock/data delay, with the margin at UHD's fixed operating point |
| `scripts/sample_check.py <bin> --prbs` | receive path, bit exact: every sample of the AD9361's pseudo-random test sequence is checked, on both channels and for their alignment |
| `scripts/sample_check.py <bin> --tone` / `--loopback F` | receive and transmit paths, spectral: level, SFDR, SINAD, DC and channel phase relation of a known tone, optionally against a reference image (`--ref`) |
| `scripts/dsp_exact.py rx\|loop <capture>` | the DSP chains on the board against the repository's RTL: every captured sample compared with the Icarus simulation of the same input |
| `scripts/bus_window.py <routed.fasm>` | the FX3 bus timing window: the forwarded clock moved through its range in the bitstream, a bit-exact bus loopback at each setting |
| `scripts/fx3_raw_load.py <bin> --echo N` | both directions of the FX3 bus, bit exact, on the bus-only design `src/top/diag_echo.v` |
| `scripts/rx_capture.py` | a capture through the stock UHD Python API with spectrum graphs (antenna signal) |

UHD only tests the image named in `fpga=<path>` of its device arguments; a
plain UHD call loads the vendor image from `UHD_IMAGES_DIR`.

## How the board is controlled

One USB 3 cable carries everything; the layers, from the host down:

| Layer | Carried by | What is set there | Seen and tested by |
| --- | --- | --- | --- |
| FX3 | USB control requests to the FX3 firmware (stock Ettus) | firmware load, FPGA load, FX3 reset | `fx3_raw_load.py` (every step) |
| FPGA local registers | control packets on USB endpoints 4 (out) and 8 (in), local address 0x40 | reference and time source, MIMO mode and AD9361 reset, front-end switches, SPI master | `fx3_raw_load.py --regs`: readback registers and a write read back |
| AD9361 | the FPGA's SPI master | rates, frequencies, gains, filters, interface delays | `fx3_raw_load.py --regs`: product ID; UHD for everything else |
| Radio cores (two) | control packets to addresses 0x10 and 0x20, in the radio clock domain | DSP: tuning, decimation and interpolation, scaling; stream commands, packet size, time | UHD's register loopback (gate step `init`), `dsp_exact.py` |
| Sample streams | USB endpoints 6 (in) and 2 (out), 64-bit VITA packets | — | `benchmark_rate`, `sample_check.py`, `rx_capture.py` |
| Host side | UHD device arguments | USB buffer pool (`num_recv_frames`, `recv_frame_size`, ...), wire format (`sc16`, `sc12`, `sc8`) | gate step `throughput` |

The FPGA side of every register UHD 3.15 writes is implemented and none is
ignored on the streaming path (an audit of every address against
`b200_impl.cpp` and the RTL); the radio cores answer only once UHD has
started the AD9361, whose data clock is their clock.

## Where the measurements are

Everything below is written by the tools above and is not in git (`build/`):

| Path | What it holds |
| --- | --- |
| `build/fpga/usrp_b200.txt` | the build record of the image beside it: source commit, tool hashes, the three clock frequencies place and route measured and every clock-domain crossing with its bound |
| `build/fpga/logs/b200-pnr.log` | the full place-and-route log: utilisation, the critical path of every clock and crossing |
| `build/hw-gate-<UTC>/` | one acceptance run, one file per step: `00-identity`, `01-raw` (FX3 bus without UHD), `02-init` and `02-stock-rx-*` (stock UHD), `03-eye`, `04-samples-*` (tone, PRBS, loopback), `05-dsp-*` (board against RTL, sample by sample), `06-bus-margin`, `07-<mode>-{vendor,ours}-*` (throughput, each run of this image between two runs of the vendor image) |
| `build/sim/` | one log per simulation bench |

The numbers those files contain, and what the vendor image does under the
same conditions, are collected in `docs/STATUS.md`.

## Licence

The RTL under `src/rtl` and `src/top` derives from Ettus Research's USRP FPGA
sources (LGPL-3.0-or-later). Everything else in this repository is GPL-3.0;
see `LICENSE`.
