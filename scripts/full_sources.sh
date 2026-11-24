#!/usr/bin/env bash
# Source list of the full 2R2T design at 80 MHz bus/GPIF clock: scripts/sources.txt
# with the 100 MHz top and clock generator swapped for the 80 MHz ones.
cd "$(dirname "$0")/.." && { grep '^src/' scripts/sources.txt \
  | grep -v -e '^src/top/b200\.v$' -e '^src/top/b200_clk_gen\.v$' -e '^src/top/diag'; \
  echo src/top/b200_clk_gen80.v; echo src/top/b200_80.v; } | tr '\n' ' '
