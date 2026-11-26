# B210 open FPGA

An independent, fully open FPGA image and Rust host for the
[OpenSourceSDRLab B210-Kintex-7](https://opensourcesdrlab.com/products/b210-kintex-7)
software-defined radio - a USRP B210-compatible board pairing the Analog
Devices AD9361 RF transceiver (70 MHz .. 6 GHz, 2 x 2 full duplex) with a
Xilinx Kintex-7 `xc7k325t-ffg676` and a Cypress FX3 USB 3.0 controller.

The board ships with a Vivado-based, UHD-compatible FPGA image
([OpenSourceSDRLab/B210-Kintex-7](https://github.com/OpenSourceSDRLab/B210-Kintex-7)
holds its schematic, mechanical files and that image). This repository is a
different route to the same hardware:

- **The FPGA is built with open tools only** - Yosys, nextpnr-himbaechel and
  Project X-Ray, every tool from pinned sources. No Vivado, no vendor IP.
- **We own the protocol end to end.** The USB wire format, the register map
  and the host are designed here from scratch (`docs/PROTOCOL.md`); the host
  is one small Rust crate (`b210`), no UHD. The vendor's UHD image and this
  image are alternatives for the same board, not interchangeable software:
  each speaks its own protocol.
- **Everything claimed is measured.** `docs/DESIGN.md` records the decisions
  with the board measurements that back them; `just check` runs the FPGA
  benches and the host tests, including fault-injection cases that must fail.

## Quick start

```sh
just setup                                 # container, nextpnr + chipdb, UHD sources + FX3 firmware
just udev                                  # once: USB access to the board (2500:0020)
just build                                 # fpga/rtl -> build/fpga/usrp_v2.bin + build record (hours)
(cd host && cargo build --release)
just load                                  # b210 load build/fpga/usrp_v2.bin
just check                                 # FPGA benches + cargo test + clippy
```

After a power-up the FX3 is in its ROM bootloader (04b4:00f3); `b210 load`
then first loads Ettus's stock FX3 firmware from `.tools/uhd315/images`
(`--firmware FILE.hex` for another path; the file must match the SHA-256
`scripts/toolchain.sh` pins), waits for 2500:0020 and loads the image.

## Command line

```sh
b210 load <IMAGE> [--firmware FILE.hex]  # FX3 firmware if needed, then the FPGA image; start the bus
b210 state | monitor                     # FX3 state; live status, event counters, USB events
b210 read <ADDR> | write <ADDR> <VALUE>  # registers (hex 0x..)
b210 rx-test [STREAM]                    # stream the FPGA's pattern; every sample checked
b210 loop-test [STREAM]                  # a timed tx burst through the FPGA loopback, back on rx
b210 capture [STREAM] [--out F] [--source radio|loopback|pattern] [--prbs]
b210-radio id | apply CONFIG.toml | peek REGS | reset | test CONFIG.toml MODE | scan CONFIG.toml
b210-plot FILE [--view ...] [--fft N] [--lo HZ] [--hi HZ] [--png PREFIX [--sheet]]
```

`--help` on any command gives the full options. The essentials:

- The sample clock is the AD9361's: apply a configuration first
  (`b210-radio apply host/b210/examples/config.toml`, a TOML of radio state:
  rate, LO, bandwidth, gains), or a stream stops with "no sample clock".
- `capture` writes interleaved i16 I/Q, one file per channel plus a `.toml`
  sidecar any tool can read. It refuses a radio stream whose ADC saturated
  and refuses to analyse a stream that lost sample times (a splice); a
  digital source (`pattern`, `loopback`) is checked bit for bit instead.
- `b210-plot` prints a report (level, DC, I/Q balance, tone, floor, spurs,
  findings with causes) and draws the spectrum, waterfall, time, histogram
  and constellation in the terminal; `--png PREFIX [--sheet]` writes the
  same views as grayscale PNG files, `--sheet` composing them into one image.

The RX inputs' absolute maximum is +2.5 dBm peak (AD9361 data sheet Rev. F,
p. 15), whatever the gain: no setting protects the receiver from a stronger
signal at the port, which must be attenuated before it.

## Is the antenna receiving?

Apply a configuration, capture, and read the report. A real signal answers
the LO test: move the LO by 100 kHz and capture again; a station moves by
100 kHz in baseband, an internal spur does not.

```sh
b210-radio apply host/b210/examples/config.toml     # 2.45 GHz ISM, 2 x 2
b210 capture --seconds 2 --out /tmp/cap.raw
b210-plot /tmp/cap_ch0.raw --view report
b210-plot /tmp/cap_ch0.raw --png /tmp/cap_ch0 --sheet   # images to browse, plus one sheet
```

The same stream from your own Rust code, in the order the hardware
requires (open, bring up, apply, set the rx source, stream):

```sh
cd host && cargo run --release --example stream -- b210/examples/config.toml 5
```

`host/b210/examples/stream.rs` is the minimal client: its callback gets each
packet's I/Q and its `Check` reports lost samples, bad values and bad
headers; it exits 1 if the stream was not clean.
`host/b210/examples/rf_tone.rs` is the duplex one: it transmits a +1 MHz tone
through the RF TX port while receiving, and prints the level the antenna sees
at each rx gain - the TX RF path, which the digital loopback never reaches.

## Repository layout

- `fpga/rtl/`, `fpga/b210.xdc`: the FPGA; `fpga/tests/`: its benches, one
  file per module, each case stating the result it must give
- `host/b210/`: the Rust crate and the three binaries; `host/b210/examples/`:
  the client examples above
- `scripts/`: the build flow (`build.sh` writes the build record:
  image hash, sources, tools, timing) and the mutation campaign
  (`mutate.sh`, `mutate.py`)
- `container/`: the Yosys / Project X-Ray image and the tool patches
- `docs/PROTOCOL.md`: the USB protocol and register map
- `docs/DESIGN.md`: the design decisions and the measurements behind them

## Licence

GPL-3.0-or-later (see `LICENSE`); every source file's first line is its
SPDX header.
The Ettus FX3 firmware and UHD sources this flow downloads for the bring-up
keep their own licences and are pinned by hash, not committed.
