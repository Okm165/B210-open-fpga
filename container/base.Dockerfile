# Shared build environment for the B210 Open FPGA toolchain.
#
# This image contains only the compiler/build dependencies. It intentionally
# contains no FPGA tool. The atomic tool images (yosys, nextpnr, prjxray)
# start from this base, and the final toolchain image composes their outputs.

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG JOBS=32

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config \
      git ca-certificates curl \
      bison flex gawk \
      python3 python3-dev python3-venv python3-pip \
      libboost-all-dev libeigen3-dev libreadline-dev \
      zlib1g-dev libffi-dev libssl-dev tcl-dev uuid-dev \
      default-jre-headless pypy3 \
 && rm -rf /var/lib/apt/lists/*

ENV FPGA_HOME=/opt/fpga

WORKDIR /src
