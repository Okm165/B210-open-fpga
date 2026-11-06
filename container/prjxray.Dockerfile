# Project X-Ray: FASM -> frames -> .bit.
#
# This image contains only the Project X-Ray C++ frame tools and the small
# Python environment used by fasm2frames. The final toolchain image copies
# /opt/fpga from here.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG JOBS=32
# Pinned validated revision.
ARG PRJXRAY_REV=ed3331c6200f421164101388759fc2860b0f5634

RUN git init prjxray \
 && cd prjxray \
 && git remote add origin https://github.com/f4pga/prjxray.git \
 && git fetch --depth 1 origin "${PRJXRAY_REV}" \
 && git checkout --detach FETCH_HEAD \
 && git submodule update --init --depth 1 \
      third_party/abseil-cpp \
      third_party/cctz \
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

RUN python3 -m venv "${FPGA_HOME}/venv" \
 && "${FPGA_HOME}/venv/bin/pip" install --upgrade pip setuptools wheel \
 && "${FPGA_HOME}/venv/bin/pip" install \
      fasm intervaltree numpy pyjson5 pyyaml simplejson \
 && cd /src/prjxray \
 && sed -i "s/packages=\['prjxray'\]/packages=['prjxray', 'utils']/" setup.py \
 && "${FPGA_HOME}/venv/bin/pip" install --no-deps . \
 && "${FPGA_HOME}/venv/bin/fasm2frames" --help >/dev/null \
 && rm -rf /src/prjxray

ENV PATH="${FPGA_HOME}/venv/bin:${FPGA_HOME}/bin:${PATH}"

RUN test -x "${FPGA_HOME}/bin/xc7frames2bit" \
 && test -x "${FPGA_HOME}/bin/bittool"
