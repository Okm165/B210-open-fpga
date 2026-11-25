# B210 open FPGA

Our own FPGA design and host software for the OpenSourceSDRLab B210
(Kintex-7 `xc7k325t-ffg676`, AD9361, Cypress FX3 running its stock
firmware). The FPGA is built from Verilog with open tools only (Yosys,
nextpnr-himbaechel, Project X-Ray), every tool from pinned sources. The host
side is a Rust crate talking to the board over USB, with no UHD.

- `fpga/rtl/`, `fpga/b210.xdc`: the FPGA; `fpga/tests/`: its benches
- `host/b210/`: the Rust crate, binaries `b210` and `b210-plot`
- `scripts/`: the build flow (`build.sh`, `assemble.sh`, `toolchain.sh`)
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

`b210` needs the FX3 running Ettus's stock firmware and does not load it
itself; after a power-up, `python3 scripts/fx3_raw_load.py <image> --drain 0` (pyusb)
loads the firmware from `.tools/uhd315/images` and then the image.

`scripts/build.sh` takes `NAME`, `PARAMS` (`BUILD_COMMIT` defaults to HEAD),
`SRCS`, `XDC`, `ALLOW_TIMING_FAIL`, `PNR_EXTRA`; see its header. The build
record `build/fpga/usrp_<NAME>.txt` holds the image hash, sources, tools and timing.

## Command line

```sh
b210 load <IMAGE>          # load an FPGA image and start the bus
b210 state                 # FX3 firmware state (1 ready, 2 configuring, 4 running)
b210 read <ADDR>           # read a register (hex 0x.. or decimal)
b210 write <ADDR> <VALUE>  # write a register
b210 monitor [--interval-ms 500]       # live status, event counters, USB events
b210 rx-test [STREAM]      # stream the pattern f(t); every sample and timestamp checked
b210 loop-test [STREAM]    # one timed tx burst through the FPGA loopback, back on rx
b210 capture [STREAM] [--out capture.raw] [--source pattern|loopback]
b210-plot <FILE> [--rate HZ] [--view spectrum|time|both] [--fft N] [--lo HZ] [--hi HZ]
```

`STREAM` options: `--seconds`, `--format sc16|sc12`, `--channels 1|2`,
`--div`, `--depth-ms`. `capture` writes interleaved i16 I/Q, one file per
channel; `b210-plot` draws spectrum and I/Q in the terminal. `--help` on
any command gives the full list and defaults.

## v1

The first version (Ettus's UHD-compatible image built with open tools, plus
Python helpers) is tagged `v1-ettus-uhd`: `git checkout v1-ettus-uhd`, or
`git show v1-ettus-uhd:<path>` for a single file.
