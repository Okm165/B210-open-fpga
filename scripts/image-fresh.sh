#!/bin/sh
# image-fresh.sh - fail if the image predates any input that feeds its digest.
#
# `make record-image` writes down "this tree produced this image".  That is only
# true if the image was built after the last edit to an input.  Checking file
# times is the one cheap proof available without rebuilding: if any digest input
# is newer than the .bin, the .bin is stale and recording it would launder an old
# image into a deployment claim.
#
# Only record-image calls this.  image-check does not: a fresh clone resets
# every mtime, so a time comparison there would be meaningless and would fail
# for the wrong reason.  Content, not time, is what image-check verifies.
set -eu
cd "$(dirname "$0")/.."

img=build/fpga/bitstream/usrp_b210_fpga.bin
[ -s "$img" ] || { echo "ERROR: no image at $img"; exit 1; }

stale=0
for f in $(LC_ALL=C sort scripts/sources.txt) \
         scripts/sources.txt src/constraints/b210.xdc src/Define.vh; do
  [ -f "$f" ] || { echo "ERROR: missing digest input $f"; exit 1; }
  if [ "$f" -nt "$img" ]; then
    echo "STALE: $f is newer than the image"
    stale=1
  fi
done

if [ "$stale" -ne 0 ]; then
  echo "ERROR: the image predates its own sources; run make build first."
  exit 1
fi
echo "fresh: image is newer than every digest input"
