# Yosys: the Verilog compiler.
#
# This image contains only Yosys. It installs into /opt/fpga and leaves no
# source tree behind. The final toolchain image copies /opt/fpga from here.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG JOBS=32
# Pinned validated release.
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

ENV PATH="${FPGA_HOME}/bin:${PATH}"

RUN yosys -V
