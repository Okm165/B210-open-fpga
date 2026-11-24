# Project X-Ray: FASM -> frames -> .bit.
#
# This image contains only the Project X-Ray C++ frame tools and the small
# Python environment used by fasm2frames. The final toolchain image copies
# /opt/fpga from here.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

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
 && "${FPGA_HOME}/venv/bin/fasm2frames" --help >/dev/null \
 && rm -rf /src/prjxray

ENV PATH="${FPGA_HOME}/venv/bin:${FPGA_HOME}/bin:${PATH}"

RUN test -x "${FPGA_HOME}/bin/xc7frames2bit" \
 && test -x "${FPGA_HOME}/bin/bittool"
