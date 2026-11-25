# The B210 open FPGA container image: synthesis (Yosys) and bitstream
# assembly (Project X-Ray).  `just setup` builds it.
#
# Place and route is NOT in here: nextpnr is built on the host from pinned
# sources by scripts/toolchain.sh, together with the device database that
# scripts/assemble.sh mounts into this image at /opt/fpga/share/prjxray-db.
#
# Two build stages compile the tools into /opt/fpga; the image itself is the
# same base with the run-time libraries only, no compiler and no sources.

# Pinned by manifest-list digest, not by tag: `24.04` is mutable and a silent
# base-image refresh changes package versions.  Changing the digest means
# rebuilding and re-measuring (scripts/build.sh records the image with every
# bitstream).
ARG UBUNTU=ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8

# ---------------------------------------------------------------------------
FROM ${UBUNTU} AS build
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 FPGA_HOME=/opt/fpga
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config git ca-certificates \
      bison flex gawk \
      python3 python3-dev python3-venv \
      libreadline-dev zlib1g-dev libffi-dev tcl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src

# ---------------------------------------------------------------------------
# Yosys: the Verilog compiler.
FROM build AS yosys
ARG JOBS=32
ARG YOSYS_REV=v0.69
RUN git clone --depth 1 --branch "${YOSYS_REV}" \
      https://github.com/YosysHQ/yosys.git yosys \
 && cd yosys \
 && git submodule update --init --recursive --depth 1 \
 && cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${FPGA_HOME}" \
 && cmake --build build --parallel "${JOBS}" \
 && cmake --install build --strip \
 && rm -rf /src/yosys

# ---------------------------------------------------------------------------
# Project X-Ray: FASM -> frames -> .bit.
FROM build AS prjxray
ARG JOBS=32
# openXC7's fork: it carries the HP-bank (1.8 V) I/O handling the Kintex-7
# flow needs, and from 658b304 on it no longer forces the OLOGIC bypass on a
# pad whose OLOGIC holds a register (which kept every ODDR output static).
ARG PRJXRAY_REV=6dabf706681c604ce7cc4f6f8e99fe8a15c0a91d

# The network steps are retried: a dropped connection to the source host
# must not decide whether the image builds.
RUN retry() { for n in 1 2 3 4 5 6; do "$@" && return 0; sleep $((n * 15)); done; return 1; } \
 && git init prjxray \
 && cd prjxray \
 && git remote add origin https://github.com/openXC7/prjxray.git \
 && retry git fetch --depth 1 origin "${PRJXRAY_REV}" \
 && git checkout --detach FETCH_HEAD \
 && retry git submodule update --init --depth 1 \
      third_party/abseil-cpp \
      third_party/gflags \
      third_party/googletest \
      third_party/yaml-cpp \
      third_party/sanitizers-cmake \
 && sed -i 's/add_compile_options(-Wall -Werror)/add_compile_options(-Wall)/' CMakeLists.txt \
 && cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${FPGA_HOME}" \
      -DPRJXRAY_BUILD_TESTING=OFF \
 && cmake --build build --parallel "${JOBS}" \
 && cmake --install build

# pip retries by itself; a build dependency it fetches in a sub-process
# (cython, for fasm) does not inherit that, hence the outer retry as well.
ENV PIP_RETRIES=8 PIP_DEFAULT_TIMEOUT=60
RUN retry() { for n in 1 2 3 4 5 6; do "$@" && return 0; sleep $((n * 15)); done; return 1; } \
 && python3 -m venv "${FPGA_HOME}/venv" \
 && retry "${FPGA_HOME}/venv/bin/pip" install \
      pip==26.3 setuptools==84.2.1 wheel==0.48.0 \
 && retry "${FPGA_HOME}/venv/bin/pip" install \
      fasm==0.0.2.post88 \
      intervaltree==3.2.1 \
      numpy==2.5.5 \
      packaging==26.3 \
      pyjson5==2.0.1 \
      pyyaml==6.0.3 \
      simplejson==4.3.0 \
      sortedcontainers==2.4.0 \
      textx==4.4.0 \
 && cd /src/prjxray \
 && "${FPGA_HOME}/venv/bin/pip" install --no-deps . \
 && rm -rf /src/prjxray

# ---------------------------------------------------------------------------
FROM ${UBUNTU}
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
# What the tools load at run time: the interpreter behind the venv and the
# four shared libraries Yosys links against.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 libreadline8t64 libtcl8.6 libffi8 zlib1g \
 && rm -rf /var/lib/apt/lists/*

COPY --from=yosys /opt/fpga /opt/fpga
COPY --from=prjxray /opt/fpga /opt/fpga

ENV FPGA_HOME=/opt/fpga
ENV PATH="/opt/fpga/venv/bin:/opt/fpga/bin:${PATH}"

RUN yosys -V \
 && fasm2frames --help > /dev/null \
 && test -x "$(command -v xc7frames2bit)" \
 && test -x "$(command -v bittool)"

WORKDIR /work
CMD ["/bin/bash"]
