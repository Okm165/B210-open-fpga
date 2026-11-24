#!/usr/bin/env python3
"""mk_ettus_ref.py - build the golden reference for the radio DSP benches.

The reference is the original Ettus Research DSP (tests/ref/ettus_dsp/, byte
for byte the files of the UHD tree, see MANIFEST there).  A bench instantiates
it next to this repository's chain, and both define modules of the same name
(ddc_chain, cic_decim, ...).  So this script writes a copy of the reference in
which every module of the reference set carries the prefix `ettus_`.  That is
the only change: an identifier is renamed if and only if it is the name of a
module in the set, wherever it occurs, so the copy means what the original
means.

Before anything is written, every file is checked against its git blob id in
the manifest.  A reference that has been edited is not a reference.

    mk_ettus_ref.py OUTDIR [--netlists DIR]

--netlists DIR adds the two Xilinx FIR Compiler netlists of the stock B200
image, DIR/hbdec1.v and DIR/hbdec2.v (fpga/usrp3/top/b200/coregen_dsp/ in a
UHD checkout), renamed the same way.  The reference chain then uses the vendor
filters instead of this repository's replacements.  Those two files are
Xilinx's and are not kept in this repository.
"""
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "ref", "ettus_dsp")
PREFIX = "ettus_"
NETLISTS = ("hbdec1.v", "hbdec2.v")


def blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def manifest():
    entries = []
    with open(os.path.join(REF, "MANIFEST")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                digest, name = line.split()
                entries.append((digest, name))
    return entries


def main(argv):
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--netlists"):
        sys.exit(__doc__)
    outdir = argv[1]
    netdir = argv[3] if len(argv) == 4 else None

    sources = {}
    for digest, name in manifest():
        with open(os.path.join(REF, name), "rb") as f:
            data = f.read()
        if blob_id(data) != digest:
            sys.exit("ERROR: tests/ref/ettus_dsp/%s is not the upstream file "
                     "(blob %s, manifest %s)" % (name, blob_id(data), digest))
        sources[name] = data.decode("ascii")
    if netdir:
        for name in NETLISTS:
            with open(os.path.join(netdir, name), "rb") as f:
                sources[name] = f.read().decode("latin-1")

    modules = set()
    for text in sources.values():
        modules.update(re.findall(r"^\s*module\s+([A-Za-z_]\w*)", text, re.M))
    # `glbl` is the netlists' own copy of the Xilinx global-reset stub, guarded
    # by an `ifndef; it is not part of the design and keeps its name.
    modules.discard("glbl")

    rename = re.compile(r"(?<![\w$])(%s)(?![\w$])"
                        % "|".join(sorted(map(re.escape, modules), key=len, reverse=True)))

    os.makedirs(outdir, exist_ok=True)
    for stale in os.listdir(outdir):
        if stale.endswith(".v"):
            os.remove(os.path.join(outdir, stale))
    for name, text in sorted(sources.items()):
        with open(os.path.join(outdir, PREFIX + name), "w", encoding="latin-1",
                  newline="") as f:
            f.write(rename.sub(lambda m: PREFIX + m.group(1), text))

    print("ettus reference: %d files verified against the manifest, %d modules "
          "prefixed%s -> %s"
          % (len(manifest()), len(modules),
             ", vendor halfband netlists included" if netdir else "", outdir))


if __name__ == "__main__":
    main(sys.argv)
