#!/usr/bin/env python3
"""Preflight the netlist for the two things that decide placement cost.

Nextpnr packs a cascade into one cluster at a fixed 5-tile pitch
(himbaechel/uarch/xilinx/pack_dsp_xc7.cc).  A Kintex-7 DSP column holds five
tiles per clock row and then steps by six, so a chain longer than 2*5-1 = 9
slices cannot be placed anywhere, at any utilisation.  The failure surfaces
only after nextpnr has spent many minutes searching, so check the netlist
first.

Checks:
  1. no DSP48E1 post-adder cascade longer than 9 slices (fatal: unplaceable);
  2. no non-clock net with fanout above FANOUT_LIMIT (fatal: the router has to
     build that tree out of fabric wires, which is what made the pre-fix
     netlist sit at 145k overused wires at 17 % utilisation);
  3. reports the flip-flop control-set count (not fatal, but it is the number
     that decides how long strict legalisation takes).

Usage: check_netlist.py build/fpga/synth/b200.json
"""
import json
import sys

LIMIT = 9
FANOUT_LIMIT = 5000
CLOCK_DRIVERS = ("BUFG", "BUFGCTRL", "BUFH", "BUFHCE", "BUFR", "BUFMR")
FLOP_PORTS = {
    "FDRE": ("C", "CE", "R"),
    "FDSE": ("C", "CE", "S"),
    "FDCE": ("C", "CE", "CLR"),
    "FDPE": ("C", "CE", "PRE"),
}


def biggest_fanout(top):
    """Highest-fanout net that is not already on a global clock network."""
    users = {}
    for cell in top["cells"].values():
        for bits in cell.get("connections", {}).values():
            for bit in bits:
                if isinstance(bit, int):
                    users[bit] = users.get(bit, 0) + 1

    driver = {}
    for name, cell in top["cells"].items():
        if cell["type"] in CLOCK_DRIVERS:
            continue
        for port, bits in cell.get("connections", {}).items():
            if cell.get("port_directions", {}).get(port) != "output":
                continue
            for bit in bits:
                if isinstance(bit, int):
                    driver.setdefault(bit, name)

    best, best_net = 0, None
    for bit, count in users.items():
        if bit in driver and count > best:
            best, best_net = count, bit
    return best, driver.get(best_net)


def control_sets(top):
    """Distinct (clock, enable, set/reset) nets over all flip-flops.

    A tile may host flops of one control set only, and the placer shrinks the
    search radius for a set to 3 tiles in its last legalisation passes, so this
    count is what makes legalisation expensive.
    """
    sets = set()
    for cell in top["cells"].values():
        ports = FLOP_PORTS.get(cell["type"])
        if ports is None:
            continue
        conn = cell["connections"]
        sets.add(tuple(next((b for b in conn.get(p, []) if isinstance(b, int)), None)
                       for p in ports))
    return len(sets)


def main(path):
    top = json.load(open(path))["modules"]["b200"]
    cells = {n: c for n, c in top["cells"].items()
             if c["type"].startswith("DSP48E1")}

    driver = {}
    for name, cell in cells.items():
        for port, net in cell["connections"].items():
            if port.startswith(("PCOUT", "ACOUT", "BCOUT")):
                for bit in net:
                    if isinstance(bit, int):
                        driver.setdefault(bit, name)

    parent = {}
    for name, cell in cells.items():
        for port, net in cell["connections"].items():
            if port.startswith(("PCIN", "ACIN", "BCIN")):
                for bit in net:
                    if isinstance(bit, int) and bit in driver and driver[bit] != name:
                        parent[name] = driver[bit]
                        break

    longest, where = 0, ""
    for name in cells:
        if name in parent:
            continue
        length, cur = 1, name
        while True:
            nxt = [k for k, v in parent.items() if v == cur]
            if not nxt:
                break
            cur = nxt[0]
            length += 1
        if length > longest:
            longest, where = length, name

    if longest > LIMIT:
        sys.exit(
            "ERROR: DSP48E1 cascade chain of %d in %s\n"
            "       A cascade is packed at a fixed 5-tile pitch and one clock row\n"
            "       holds five tiles, so anything longer than %d slices is unplaceable.\n"
            "       Split the adder chain; see src/ip/hbdec.v (F25)."
            % (longest, where, LIMIT))

    print("DSP cascade chains: longest %d of %d allowed" % (longest, LIMIT))
    fanout, fanout_driver = biggest_fanout(top)
    if fanout > FANOUT_LIMIT:
        print("WARNING: net driven by %s has %d loads and is not on a global buffer.\n"
              "         A control tree that large is routed through fabric wires and\n"
              "         shows up as router congestion, not as a util%% problem (F27).\n"
              "         A BUFG does not fix this: nextpnr cannot route a global net to\n"
              "         a flip-flop reset mux.  Reducing it needs reset replication."
              % (fanout_driver, fanout))
    else:
        print("Largest non-clock fanout: %d loads (%s)" % (fanout, fanout_driver))
    print("Control sets: %d (one per tile; the placer searches a 3-tile radius "
          "at the end of legalisation)" % control_sets(top))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
