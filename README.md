# B210 open FPGA

Our own FPGA design and host software for the OpenSourceSDRLab B210
(Kintex-7 `xc7k325t-ffg676`, AD9361, Cypress FX3 running its stock
firmware). The FPGA is built from Verilog with open tools only (Yosys,
nextpnr-himbaechel, Project X-Ray), every tool from pinned sources. The host
side is a Rust crate talking to the board over USB, with no UHD.

- `fpga/rtl/`, `fpga/b210.xdc`: the FPGA; `fpga/tests/`: its benches
- `host/b210/`: the Rust crate, binaries `b210`, `b210-radio` and `b210-plot`
- `scripts/`: the build flow (`build.sh`, `assemble.sh`, `toolchain.sh`) and
  the mutation campaign (`mutate.sh`, `mutate.py`: one small RTL change per
  mutant, the benches must notice; survivors are listed for classification)
- `container/`: the Yosys / Project X-Ray image and the tool patches
- `docs/PROTOCOL.md`: the USB protocol and register map; `docs/DESIGN.md`: the design

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

`scripts/build.sh` takes `NAME`, `PARAMS` (`BUILD_COMMIT` defaults to HEAD),
`SRCS`, `XDC`, `ALLOW_TIMING_FAIL`, `PNR_EXTRA`; see its header. The build
record `build/fpga/usrp_<NAME>.txt` holds the image hash, sources, tools and timing.

## Command line

```sh
b210 load <IMAGE> [--firmware FILE.hex]  # FX3 firmware if needed, then the FPGA image; start the bus
b210 state                 # FX3 firmware state (1 ready, 2 configuring, 4 running)
b210 read <ADDR>           # read a register (hex 0x.. or decimal)
b210 write <ADDR> <VALUE>  # write a register
b210 monitor [--interval-ms 500]       # live status, event counters, USB events
b210 rx-test [STREAM]      # stream the pattern f(t); every sample and timestamp checked
b210 loop-test [STREAM]    # one timed tx burst through the FPGA loopback, back on rx
b210 capture [STREAM] [--out capture.raw] [--source pattern|tone|radio] [--prbs]
b210-radio id|apply CONFIG.toml|peek REGS...|reset|test CONFIG.toml MODE|scan CONFIG.toml
b210-plot <FILE> [--config FILE] [--rate HZ] [--view ...] [--fft N] [--lo HZ] [--hi HZ]
```

`STREAM` options: `--seconds`, `--format sc16|sc12`, `--channels 1|2`,
`--depth-ms`. The sample clock is the AD9361's, so any stream needs the
chip running: `b210-radio apply host/b210/examples/config.toml` first, or
the stream stops with "no sample clock". `capture` writes interleaved i16
I/Q, one file per channel (`--prbs` with `--source radio` checks the AD9361's
BIST sequence instead, after `b210-radio test CONFIG prbs`); `capture` refuses a
radio stream whose ADC saturated (it prints the per-channel fraction and
exits 1), refuses to analyse a stream that lost sample times (the file is a
splice), and analyses the file in bounded memory. `b210-radio test` selects the
AD9361's digital test mode at its data port (`tone`, `prbs`, `loopback`,
`none`); `b210-radio scan` sweeps its rx clock/data delays with the PRBS and
prints the eye. `b210-plot` writes a report (level, DC, I/Q
balance, tone, floor, spurs, findings) and draws the spectrum, waterfall,
time, histogram and constellation in the terminal; `--png PREFIX` writes the
same image views as grayscale PNG files (`PREFIX_spectrum.png`,
`PREFIX_waterfall.png`, `PREFIX_time.png`, `PREFIX_hist.png`,
`PREFIX_iq.png`) for browsing, and `--png PREFIX --sheet` also composes them
into one `PREFIX_sheet.png` (two per row, no labels: the fixed layout is the
caption) so a whole receive state is one image. `--help` on any command
gives the full list and defaults.

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
b210-plot /tmp/cap_ch0.raw --view spectrum
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
It needs a config with one rx channel (ch0) and one tx channel (ch0), and its
tone is only above the receiver's floor with the tx gain near 89.75 dB
(0 dB attenuation): `cargo run --release --example rf_tone -- rf.toml`.

`capture` exits 1 when the ADC saturates (lower the gain in the config's
`gain_db`), only for `--source radio`: the pattern and the host tone reach
the code rails by construction and are reported, not refused. A crowded
band such as FM overloads at 70 dB and is clean from 55 dB down, so a strong
band needs a lower gain than a weak one (`docs/DESIGN.md`, "antenna").

## v1

The first version (Ettus's UHD-compatible image built with open tools, plus
Python helpers) is tagged `v1-ettus-uhd`: `git checkout v1-ettus-uhd`, or
`git show v1-ettus-uhd:<path>` for a single file.
