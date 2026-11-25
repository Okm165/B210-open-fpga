# B210 open FPGA

The FPGA image for the OpenSourceSDRLab B210 (Kintex-7 `xc7k325t-ffg676`,
AD9361, Cypress FX3): two receive and two transmit channels, working with
stock UHD, built from Verilog with open tools only (Yosys, nextpnr-himbaechel,
Project X-Ray). Every tool, the host driver (UHD) and the chip database are
built from pinned sources on top of the operating system's own packages
(Ubuntu in the container, the host's distribution outside it). The one
prebuilt file in the flow is the FX3's stock firmware, fetched from Ettus with
its hash checked.

- `docs/STATUS.md`: what is measured to be true today, and what is open
- `docs/DSP.md`: what the signal chains compute and how that is proven

## Quick start

```sh
just container    # Yosys + Project X-Ray tools in a container image          ~15 min
just toolchain    # .tools/: place-and-route engine, chip database, UHD 3.15   ~10 min
just udev         # once, as root: USB access to the board
just build        # Verilog -> build/fpga/usrp_b200.bin + build record       1.5 h and up
just gate         # hardware acceptance on the connected board                ~40 min
```

`just` alone lists every command. The ones used day to day:

| Command | What it does |
| --- | --- |
| `just load [img]` | reboot the FX3, load the image, read every configuration layer over USB, with no UHD |
| `just probe [img]` | UHD loads the image and initialises both radio cores |
| `just stream rx 0,1 30.72e6` | stream for 10 s and count every lost sample (`dir` rx, tx or rxtx; `otw` sc16, sc12, sc8) |
| `just eye [img]` | AD9361 interface eye scan and the timing margin at UHD's operating point |
| `just gate [img]` | the full acceptance (below) |
| `just test` | every simulation bench in parallel (`just test-<name>` for one) |
| `just shell` | a shell in the tool container |

`img` defaults to `build/fpga/usrp_b200.bin`.

## What the host needs

- `just`, `podman`, `git`, `curl`, `cmake`, a C++20 compiler, boost, eigen3 and
  libusb-1.0 headers, `python3` with `mako`, `numpy` and `pyusb`, Icarus
  Verilog; about 6 GB of disk, and network access while the tools build;
- for the streaming measurements, permission to run at real-time priority
  (`ulimit -r` 50 or more). Without it the tools still run and say so.

No UHD package, no vendor IDE and no vendor image is used.

## Acceptance

`just gate` runs every step on the board in this order. All requirements
are absolute; nothing is compared with another image.

| Step | Passes when |
| --- | --- |
| identity | the build record belongs to exactly these bytes, built from committed sources; all three clocks and all four clock-domain crossings meet their constraints |
| raw | FX3 reboot and FPGA load; FPGA registers written and read back, the AD9361 product ID read over the FPGA's SPI master, 64 control transactions and an 8 MB drain, all without UHD |
| init | UHD initialises both radio cores (register and codec loopback) |
| eye | at 61.44 MHz the AD9361 interface has at least 8 delay steps of margin on receive and transmit |
| samples | test tone and loopback tones with the level, SFDR, SINAD, DC and channel phase of a healthy image; the AD9361 pseudo-random sequence with zero errors in 8 two-channel sessions and at 61.44 MS/s |
| dsp | the board's DSP output equals the RTL simulation on every sample, at decimation 1, 2, 3, 4, 8, 16 and loopback x1, x4 |
| bus margin | the FX3 bus still works with its clock moved 2.1 ns earlier and later |
| throughput | 10 s with no lost sample at 2 RX x 30.72, 2 TX x 30.72, 1 RX x 61.44 and 2R2T x 30.72 MS/s (12-bit), counted on a quiet host |

Exit 0 is a pass, 1 a failure, 3 inconclusive (the host never stayed quiet
through a throughput run), which is not a pass. Everything is written to
`build/hw-gate-<UTC>/`, one file per step.

## Board LEDs

Green means data flowing, amber transmitting, red an alarm and nothing else.

| LED | Meaning |
| --- | --- |
| TX/RX, RX2 (per channel) | green shimmering: receiving on this port; amber shimmering: transmitting; red for 0.2 s: samples lost (overflow or late command on RX2; underflow, late or out-of-sequence packet on TX/RX); dark: idle. The shimmer runs at the sample rate (7 blinks a second at 30.72 MS/s) |
| CLK | green: the AD9361 clock runs, with a blink at every PPS; red: FPGA clocks unlocked or input delays not calibrated; dark: AD9361 not initialised yet |
| USR | green flash: a control packet from the host; red: samples lost on some channel within the last 2 s |
| STATUS | blue heartbeat |

## How the board is controlled

One USB 3 cable carries data and configuration. The layers, from the host
down:

| Layer | Carried by | Set there | Checked by |
| --- | --- | --- | --- |
| FX3 | USB control requests to the stock firmware | firmware load, FPGA load, FX3 reset | `just load` |
| FPGA registers | control packets, endpoints 4 out / 8 in, local address 0x40 | reference and time source, MIMO mode, AD9361 reset, front-end switches, SPI master | `just load`: readback registers, a write read back |
| AD9361 | the FPGA's SPI master | rates, frequencies, gains, filters, interface delays | `just load` (product ID), UHD for the rest |
| Radio cores (two) | control packets to 0x10 and 0x20 | DSP tuning, decimation, interpolation, scaling; stream commands, packet size, time | `just probe` (register loopback), gate step `dsp` |
| Sample streams | endpoints 6 in / 2 out, VITA packets | none | `just stream`, gate steps `samples` and `throughput` |
| Host side | UHD device arguments | USB buffer pool (`num_recv_frames`, `recv_frame_size`, ...), wire format | `just stream` uses a deep pool (34 ms of receive data at 245 MB/s) |

The FPGA implements every register UHD 3.15 writes; none is ignored on the
streaming path.

## Layout

```text
src/top/           b200.v (top), b200_io.v (AD9361 port), b200_leds.v, b200_core.v,
                   b200_clk_gen.v, diag_echo.v (the FX3 bus alone, for bus tests)
src/rtl/           radio, DSP, FIFO, FX3 bus and control RTL
src/constraints/   b210.xdc: pins, clocks, buffer sites, crossing bounds
scripts/           build flow (toolchain, build, assemble) and board instruments
container/         the tool container (Dockerfile) and the upstream patches
tests/             simulation benches, their runner and the Ettus reference RTL
justfile           every command
```

| Instrument | Measures |
| --- | --- |
| `scripts/fx3_raw_load.py` | FX3 and FPGA load and the control path without UHD (`--regs`, `--peek N`); `--echo N` the bus alone, bit exact, on `diag_echo` |
| `scripts/eyescan.sh` | the AD9361 interface eye over all 31 x 31 clock/data delays |
| `scripts/sample_check.py` | tone, loopback and pseudo-random captures against fixed requirements |
| `scripts/dsp_exact.py` | board captures against the RTL simulation, every sample |
| `scripts/bus_window.py` | the FX3 bus timing window, by moving the forwarded clock in the bitstream |
| `scripts/rx_dump.cpp` | the capture tool all of the above use (built by `just toolchain`) |

## Settings

| Variable | Used by | Meaning |
| --- | --- | --- |
| `SERIAL` | board commands | board serial, only with several B2xx on the host |
| `WAIT_QUIET` | gate | seconds to wait, in all, for a quiet host before throughput runs (default 0) |
| `QUIET_PSI` | gate | CPU pressure in percent below which the host counts as quiet (default 1) |
| `FPGA_IMAGE` | container, build | container image name (default `b210-open-fpga:0.3.0`) |
| `DESIGN`, `NAME`, `PARAMS` | build | another top from `src/top`, its output name, parameter overrides |

The headers of `scripts/build.sh` and `scripts/hw_gate.sh` list the rest.

## Licence

The RTL under `src/rtl` and `src/top` derives from Ettus Research's USRP FPGA
sources (LGPL-3.0-or-later); files written here carry their own SPDX line.
Everything else is GPL-3.0; see `LICENSE`.
