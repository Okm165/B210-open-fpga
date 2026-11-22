# nextpnr-openxc7.Dockerfile - nextpnr-himbaechel with the openXC7 xilinx
# micro-architecture, which carries the IO/clocking/BRAM/DSP fixes the
# mainline build lacks.  Same layout as nextpnr.Dockerfile so the final
# toolchain image can be built from this stage unchanged.
#
# Motivation: bitstreams produced by the mainline build configure the FPGA
# but never drive its I/O (see docs/ANALYSIS.md, toolchain verdict).

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG JOBS=32
ARG OPENXC7_REV=main

COPY third_party/prjxray-db-openxc7 /opt/fpga/share/prjxray-db

RUN git init nextpnr \
 && cd nextpnr \
 && git remote add origin https://github.com/openXC7/nextpnr.git \
 && git fetch --depth 1 origin "${OPENXC7_REV}" \
 && git checkout --detach FETCH_HEAD \
 && git submodule update --init --depth 1 himbaechel/uarch/xilinx/meta \
 && cmake -S . -B build -G Ninja \
      -DARCH=himbaechel \
      -DHIMBAECHEL_UARCH=xilinx \
      -DHIMBAECHEL_PRJXRAY_DB="${FPGA_HOME}/share/prjxray-db" \
      -DHIMBAECHEL_XILINX_DEVICES=xc7k325t \
      -DUSE_OPENMP=ON \
      -DBUILD_GUI=OFF \
      -DBUILD_PYTHON=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${FPGA_HOME}" \
 && cmake --build build --parallel "${JOBS}" \
 && cmake --install build \
 && install -m755 build/bba/bbasm "${FPGA_HOME}/bin/bbasm" \
 && mkdir -p "${FPGA_HOME}/share/nextpnr/himbaechel/uarch/xilinx" \
 && cp -r himbaechel/uarch/xilinx/gen \
          "${FPGA_HOME}/share/nextpnr/himbaechel/uarch/xilinx/" \
 && cp -r himbaechel/uarch/xilinx/meta \
          "${FPGA_HOME}/share/nextpnr/himbaechel/uarch/xilinx/" \
 && cp himbaechel/uarch/xilinx/constids.inc \
          "${FPGA_HOME}/share/nextpnr/himbaechel/uarch/xilinx/" \
 && cp -r himbaechel/himbaechel_dbgen \
          "${FPGA_HOME}/share/nextpnr/himbaechel/" \
 && test -s "${FPGA_HOME}/share/nextpnr/himbaechel/xilinx/chipdb-xc7k325t.bin" \
 && rm -rf /src/nextpnr

ENV PATH="${FPGA_HOME}/bin:${PATH}"

RUN nextpnr-himbaechel --version 2>/dev/null || nextpnr-himbaechel --help >/dev/null
