# nextpnr-himbaechel: placement and routing for the Xilinx 7-series fabric.
#
# This image contains only nextpnr and the Project X-Ray device data it needs
# to generate the xc7k325t chip database. The final toolchain image copies
# /opt/fpga from here.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG JOBS=32
# f745549 is the upstream fix immediately after nextpnr-0.11.1 that enforces
# a shared SLICEM write-enable (WEMUX_OUT) net. Without it, co-located SRLs
# with different write enables make router2 abort on this design.
ARG NEXTPNR_REV=f7455496240cee1a5a6de262be5bdb1d1e7a3911

COPY third_party/prjxray-db /opt/fpga/share/prjxray-db

RUN git init nextpnr \
 && cd nextpnr \
 && git remote add origin https://github.com/YosysHQ/nextpnr.git \
 && git fetch --depth 1 origin "${NEXTPNR_REV}" \
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
