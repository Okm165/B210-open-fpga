#!/usr/bin/env bash
# knockout_bufhclk.sh - prove that the BUFHCLK routing layer of a FASM is
# phantom for kintex7: delete every BUFHCLK/HCLK_OUT route line, reassemble,
# compare frames.  Byte-identical => the router emitted route PIPs with no
# backing bits in prjxray-db (segbits_clk_hrow_bot_r.db has no BUFHCLK
# routing rows) => no bitstream from this flow can drive a regional clock.
#
# usage: knockout_bufhclk.sh <design.fasm> <out.frames> <stripped.frames>
set -euo pipefail
FASM=$1; OUT=$2; STRIP=$3
grep -v "HCLK_OUT" "$FASM" > "$STRIP"
for f in "$FASM" "$STRIP"; do
  podman run --rm -v "$PWD:/work:z" -w /work -e HOME=/work/build \
    b210-open-fpga:0.1.0 bash -c "fasm2frames --db-root /opt/fpga/share/prjxray-db/kintex7 \
      --part xc7k325tffg676-1 /work/$f /work/${f%.fasm}.frames >/dev/null 2>&1"
done
python3 - "$OUT" "${STRIP%.fasm}.frames" <<'PY'
import sys
def load(p):
    fr={}
    for line in open(p):
        line=line.strip()
        if not line: continue
        a,ws=line.split(); fr[int(a,16)]=[int(x,16) for x in ws.split(',')]
    return fr
A=load(sys.argv[1]); B=load(sys.argv[2])
d=sum(1 for a in set(A)|set(B) if A.get(a)!=B.get(a))
print(f"frames differing: {d} of {len(set(A)|set(B))}")
print("PHANTOM ROUTING CONFIRMED" if d==0 else "routing has real bits")
PY
