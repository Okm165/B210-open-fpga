#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate the golden traces (*.trace here) from UHD's own AD9361 driver.
#
#   host/b210/tests/ad9361_golden/generate.sh
#
# Compiles UHD 3.15's ad9361_device.cpp unmodified (the tree v1 runs:
# .tools/src/uhd, from `scripts/toolchain.sh uhd`; another with UHD_SRC=...)
# with harness.cpp, which stands in for the SPI bus and records every
# poke8/peek8/sleep, and runs scenarios.txt. Needs g++ and the boost headers.
# UHD's logging and exceptions live in libuhd; stub/ replaces those two
# headers, nothing else. Flags as UHD's Release build (-O3, baseline x86-64:
# no FMA, so -ffp-contract=off changes nothing and pins it).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
uhd=${UHD_SRC:-$root/.tools/src/uhd}
drv=$uhd/host/lib/usrp/common/ad9361_driver
[[ -f $drv/ad9361_device.cpp ]] || { echo "no UHD driver at $drv (set UHD_SRC)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
flags=(-std=gnu++17 -O3 -ffp-contract=off -w -I"$here/stub" -I"$drv" -I"$uhd/host/include")
g++ "${flags[@]}" -include "$here/prelude.hpp" -c "$drv/ad9361_device.cpp" -o "$work/ad9361_device.o"
# the filter classes the driver's (unused) filter API constructs
g++ "${flags[@]}" -c "$uhd/host/lib/types/filters.cpp" -o "$work/filters.o"
g++ "${flags[@]}" -c "$here/harness.cpp" -o "$work/harness.o"
g++ "$work/ad9361_device.o" "$work/filters.o" "$work/harness.o" -o "$work/harness"
rm -f -- "$here"/*.trace
"$work/harness" "$here/scenarios.txt" "$here"
