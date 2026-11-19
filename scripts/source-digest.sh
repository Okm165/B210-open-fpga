#!/bin/sh
# source-digest.sh - one hash of everything that determines the bitstream.
#
# The netlist is a function of the ordered source list, the RTL those paths
# name, the timing constraints and the build defines.  Hash them in a fixed
# order with their paths, so a rename, a reorder, an edit or a constraint
# change all move the digest.  The toolchain version is not included: pin it
# separately (the container image tag) because it is not part of the tree.
set -eu
cd "$(dirname "$0")/.."

{
  echo "format 1"
  echo "list scripts/sources.txt"
  cat scripts/sources.txt
  for f in $(LC_ALL=C sort scripts/sources.txt) src/constraints/b210.xdc src/Define.vh; do
    echo "file $f"
    cat "$f"
  done
} | sha256sum | cut -d' ' -f1
