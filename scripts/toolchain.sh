# SPDX-License-Identifier: GPL-3.0-or-later

#!/usr/bin/env bash
# toolchain.sh - build the place-and-route engine of this flow from pinned
# sources.  Output (used by scripts/build.sh):
#
#   .tools/nextpnr-himbaechel
#   .tools/chipdb-xc7k325t.bin
#
# Sources and the local fixes:
#
#   openXC7/nextpnr              $NEXTPNR_REV
#     + container/patches/nextpnr-rioi-zinv-t1.patch
#         HP-bank tristates were inverted: OLOGIC ZINV_T1 was never written
#         for RIOI tiles.
#     + container/patches/nextpnr-bufrclk-enable.patch
#         a BUFR output routed to a BUFG carried no clock: the buffer enables
#         of that line in the clock row and the CMT column were never written.
#     + container/patches/nextpnr-dsp48e1-timing.patch
#         the Kintex-7 chipdb has no timing for DSP48E1, and a cell without
#         timing is ignored: no path into or out of a multiplier was checked.
#         The arcs are worked out from each cell's register parameters with
#         the data sheet's figures (DS182 table 35, speed grade -1).
#   openXC7/nextpnr-xilinx-meta  $META_REV
#     + kintex7/site_type_BUFR.json copied from artix7
#         the Kintex-7 metadata lacks the BUFR site type, so the chipdb had
#         no placeable BUFR although the device and the database have them.
#   openXC7/prjxray-db           $DB_REV, in third_party/prjxray-db-openxc7
#     + container/patches/prjxray-db-kintex7-hclk-ioi-bufr-ppips.patch
#         the HP-bank HCLK_IOI tile lacks the 24 always-on pseudo pips of
#         the BUFR datapath (CE, CLR, output to the clock row) that the
#         HR-bank HCLK_IOI3 tile lists, which left every BUFR in an HP bank
#         unroutable.  scripts/assemble.sh reads the same patched database.
#
# Host build: the engine links against the host boost, and the container
# image's nextpnr predates these revisions.  Needs git, cmake, a C++20
# compiler, boost, eigen3, python3.  About 6 minutes on 40 cores.
#
#   scripts/toolchain.sh uhd
#
# builds the host side instead, the only UHD the flow uses: EttusResearch/uhd
# $UHD_REV + container/patches/uhd-3.15-eyescan.patch: the sources in
# .tools/src/uhd (the AD9361 driver that host/b210/tests/ad9361_golden/
# generate.sh compiles), libuhd, uhd_usrp_probe and benchmark_rate in
# .tools/uhd315, and into .tools/uhd315/images the stock FX3 firmware, unmodified:
# Ettus's b2xx_common_fw_default archive of UHD 4.9.0.1, checked against the
# sha256 that release's images/manifest.txt lists for it and against the
# sha256 of the firmware file itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/.tools"

# pin <dir> <url> <rev>: leave <dir> a pristine checkout of exactly <rev>, so
# a rerun starts from the same tree as the first run.
pin() {
  mkdir -p "$1" && cd "$1"
  if [[ ! -e .git ]]; then git init -q . && git remote add origin "$2"; fi
  if [[ "$(git rev-parse -q --verify HEAD 2>/dev/null || true)" != "$3" ]]; then
    local try                       # connections to the source host drop now and then
    for try in 1 2 3 4 5 fail; do
      [[ $try != fail ]] || { echo "toolchain: cannot fetch $3 from $2" >&2; exit 1; }
      git fetch -q --depth 1 origin "$3" && break
      sleep $((try * 10))
    done
    git checkout -q -f --detach FETCH_HEAD
  fi
  git checkout -q -f -- .
}

if [[ "${1:-}" == uhd ]]; then
  UHD_REV=ea137aa3f0800311de56c54598bb8a9253d65c02
  pin "$T/src/uhd" https://github.com/EttusResearch/uhd.git "$UHD_REV"
  git apply "$ROOT/container/patches/uhd-3.15-eyescan.patch"
  cmake -S host -B build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_B200=ON -DENABLE_USB=ON -DENABLE_UTILS=ON -DENABLE_EXAMPLES=ON \
    -DENABLE_B100=OFF -DENABLE_USRP1=OFF -DENABLE_USRP2=OFF -DENABLE_X300=OFF -DENABLE_N230=OFF \
    -DENABLE_MPMD=OFF -DENABLE_OCTOCLOCK=OFF -DENABLE_RFNOC=OFF -DENABLE_E300=OFF -DENABLE_E320=OFF \
    -DENABLE_N300=OFF -DENABLE_N320=OFF -DENABLE_PYTHON_API=OFF -DENABLE_TESTS=OFF \
    -DENABLE_MANUAL=OFF -DENABLE_DOXYGEN=OFF -DENABLE_MAN_PAGES=OFF > "$T/uhd-cmake.log" 2>&1 \
    || { tail -20 "$T/uhd-cmake.log" >&2; exit 1; }
  cmake --build build --parallel "${JOBS:-$(nproc)}" --target uhd uhd_usrp_probe benchmark_rate \
    > "$T/uhd-build.log" 2>&1 || { grep -E "error|Error" "$T/uhd-build.log" | tail -20 >&2; exit 1; }
  mkdir -p "$T/uhd315/lib" "$T/uhd315/bin"
  cp -a build/lib/libuhd.so* "$T/uhd315/lib/"
  cp build/utils/uhd_usrp_probe build/examples/benchmark_rate "$T/uhd315/bin/"
  FW_ZIP=b2xx/uhd-7f7d016/b2xx_common_fw_default-g7f7d016.zip
  mkdir -p "$T/uhd315/images"
  curl -fsSL -o "$T/uhd315/images/fw.zip" "https://files.ettus.com/binaries/cache/$FW_ZIP"
  python3 -I - "$T/uhd315/images" <<'PY'
import hashlib, sys, zipfile
d = sys.argv[1]
z = open(d + '/fw.zip', 'rb').read()
assert hashlib.sha256(z).hexdigest() == '22ac0e54cc90d53d8494d481439447a0c89b9bbaced6fabe24df260eda3ce3a3', 'archive'
fw = zipfile.ZipFile(d + '/fw.zip').read('usrp_b200_fw.hex')
assert hashlib.sha256(fw).hexdigest() == 'cc8e4bc968d91d1a67c63871ce5b2c1613c49676fe363bf2f6e336059899ae5c', 'firmware'
open(d + '/usrp_b200_fw.hex', 'wb').write(fw)
PY
  rm "$T/uhd315/images/fw.zip"
  echo "host side: $T/uhd315 ($UHD_REV), FX3 firmware in $T/uhd315/images"
  exit 0
fi
NEXTPNR_REV=be38ec6ff1233c0eb01022e17b0e332510118522
META_REV=0acd2cf0361009c24efee6af9851a92ae9afc0e7
DB_REV=0c3504f26f5cf77b6a7605c7bc83ebe1ac67b26f
DB="$ROOT/third_party/prjxray-db-openxc7"
SRC="$T/src/nextpnr"

mkdir -p "$T/tmp"
pin "$DB" https://github.com/openXC7/prjxray-db.git "$DB_REV"
git apply "$ROOT/container/patches/prjxray-db-kintex7-hclk-ioi-bufr-ppips.patch"

pin "$SRC" https://github.com/openXC7/nextpnr.git "$NEXTPNR_REV"
for patch in "$ROOT"/container/patches/nextpnr-*.patch; do git apply "$patch"; done
pin "$SRC/himbaechel/uarch/xilinx/meta" https://github.com/openXC7/nextpnr-xilinx-meta.git "$META_REV"
cp artix7/site_type_BUFR.json kintex7/
cd "$SRC"

cmake -S . -B build \
  -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
  -DHIMBAECHEL_PRJXRAY_DB="$DB" -DHIMBAECHEL_XILINX_DEVICES=xc7k325t \
  -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DCMAKE_BUILD_TYPE=Release > "$T/cmake.log" 2>&1
# The chipdb is generated from the database and the metadata; cmake does not
# track either, so it is always regenerated.
rm -f build/himbaechel/uarch/xilinx/chipdb-xc7k325t.* build/share/himbaechel/xilinx/chipdb-xc7k325t.bin
# The LTO link writes gigabytes of temporaries; keep them off a tmpfs /tmp.
TMPDIR="$T/tmp" cmake --build build --parallel "${JOBS:-$(nproc)}" > "$T/build.log" 2>&1 \
  || { tail -20 "$T/build.log" >&2; exit 1; }

# An engine is installed only if it times DSP48E1 paths: scripts/dsp_timing.v
# has a multiplier without registers between flip-flops, 4.39 ns that must
# show as the critical path and miss the 5 ns clock.  An engine that ignores
# the cell reports over 1 GHz and passes.
cd "$ROOT"
mkdir -p build/tmp
podman run --rm -i --userns=keep-id -v "$ROOT:/work:z" -w /work -e HOME=/work/build \
  "${FPGA_IMAGE:-b210-open-fpga:0.3.0}" yosys -q -p "read_verilog scripts/dsp_timing.v;
    synth_xilinx -flatten -abc9 -family xc7 -nodsp -top dsp_timing; write_json build/tmp/dsp_timing.json" \
  > build/tmp/dsp_timing-synth.log 2>&1 || { tail -5 build/tmp/dsp_timing-synth.log >&2; exit 1; }
"$SRC/build/nextpnr-himbaechel" --device xc7k325tffg676-1 --chipdb "$SRC/build/share/himbaechel/xilinx/chipdb-xc7k325t.bin" \
  --json build/tmp/dsp_timing.json -o xdc=scripts/dsp_timing.xdc --timing-allow-fail > build/tmp/dsp_timing-pnr.log 2>&1 \
  || { tail -5 build/tmp/dsp_timing-pnr.log >&2; exit 1; }
grep -Eq "Source u_comb\.P[0-9]+" build/tmp/dsp_timing-pnr.log && grep -q "(FAIL at 200.00 MHz)" build/tmp/dsp_timing-pnr.log \
  || { echo "toolchain: this engine does not time DSP48E1 paths; see build/tmp/dsp_timing-pnr.log" >&2; exit 1; }
echo "engine times DSP48E1 paths: $(grep 'Max frequency' build/tmp/dsp_timing-pnr.log | tail -1 | sed 's/^[A-Za-z]*: //')"
cd "$SRC"

install -m755 build/nextpnr-himbaechel "$T/nextpnr-himbaechel"
install -m644 build/share/himbaechel/xilinx/chipdb-xc7k325t.bin "$T/chipdb-xc7k325t.bin"
rm -rf "$T/tmp"
echo "engine: $T/nextpnr-himbaechel ($NEXTPNR_REV)"
sha256sum "$T/nextpnr-himbaechel" "$T/chipdb-xc7k325t.bin"
