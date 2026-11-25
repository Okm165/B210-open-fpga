# B210 open FPGA (v2). `just` lists the commands; scripts/ holds the flow they call.

set shell := ["bash", "-euo", "pipefail", "-c"]

image := env("FPGA_IMAGE", "b210-open-fpga:0.3.0")

[private]
default:
    just --list --unsorted

# Build every tool from pinned sources: container, place and route, UHD sources + FX3 firmware
setup:
    podman build --build-arg JOBS=$(nproc) -t {{ image }} -f container/Dockerfile container
    scripts/toolchain.sh
    scripts/toolchain.sh uhd

# Give this account USB access to the board (once, as root)
udev:
    echo 'SUBSYSTEMS=="usb", ATTRS{idVendor}=="2500", ATTRS{idProduct}=="0020", MODE:="0666"' \
      | sudo tee /etc/udev/rules.d/10-b210.rules > /dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger

# fpga/rtl -> build/fpga/usrp_v2.bin and its build record
build:
    scripts/build.sh

# FPGA benches (fpga/tests/run.sh), optionally filtered by text
test-fpga filter='':
    sh fpga/tests/run.sh {{ filter }}

# Host crate: tests and clippy
test-host:
    cd host && cargo test && cargo clippy --all-targets

# Both test suites
check: test-fpga test-host

# Load an image into the board's FPGA
load img="build/fpga/usrp_v2.bin":
    host/target/release/b210 load {{ img }}
