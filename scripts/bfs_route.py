#!/usr/bin/env python3
"""bfs_route.py - backward BFS over the documented prjxray pip graph.

Finds a fully-drivable wire path from a start wire to a target mux input,
using ONLY pip rows that exist in the segbits DB (so every emitted row is
legal).  Avoids the engine bug of routing through undrivable long-line wires
(LV9/LH6 have no driver rows anywhere).
"""
import json, sys, collections

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))
tc = json.load(open(f'{DB}/xc7k325t/tileconn.json'))

# grid -> tile name
grid = {}
for t, i in tg.items():
    if 'bits' in i:
        grid[(i['grid_x'], i['grid_y'])] = t

# pip rows per tile type: dst <- set(src)
pips = collections.defaultdict(lambda: collections.defaultdict(set))
import os
for tt in ('INT_R', 'INT_L', 'IO_INT_INTERFACE_R', 'IO_INT_INTERFACE_L',
           'RIOI', 'R_TERM_INT', 'L_TERM_INT', 'INT_INTERFACE_R', 'INT_INTERFACE_L'):
    for suf in ('.db', '_sing.db'):
        p = f'{DB}/segbits_{tt.lower()}{suf}'
        if not os.path.exists(p):
            continue
        for line in open(p):
            feat, _, bits = line.strip().partition(' ')
            parts = feat.split('.')
            if len(parts) != 3:
                continue
            dst, src = parts[1], parts[2]
            pips[tt][dst].add(src)

# tileconn: for tiles of type A at (x,y), neighbor at (x+dx, y+dy) of type B:
# wire_a <-> wire_b
adj = collections.defaultdict(list)   # (typeA) -> list of (dx, dy, typeB, {wa:wb})
for e in tc:
    (ta, tb), (dx, dy) = e['tile_types'], e['grid_deltas']
    m = {a: b for a, b in e['wire_pairs']}
    adj[ta].append((dx, dy, tb, m))
    mb = {b: a for a, b in e['wire_pairs']}
    adj[tb].append((-dx, -dy, ta, mb))


def solve(start, goal, max_nodes=400000):
    """start/goal: (x, y, wire) grid coords."""
    # backward BFS from goal: find which wires, if driven, drive the goal
    prev = {}          # node -> (node,pipinfo) predecessor
    q = collections.deque([goal])
    seen = {goal}
    n = 0
    while q and n < max_nodes:
        n += 1
        node = q.popleft()
        x, y, w = node
        t = grid.get((x, y))
        if t is None:
            continue
        tt = tg[t]['type']
        # in-tile: w driven by src (pip tt.src->w? no: pips[tt][w] = sources)
        for src in pips[tt].get(w, ()):
            snode = (x, y, src)
            if snode not in seen:
                seen.add(snode)
                prev[snode] = (node, ('pip', t, src, w))
                q.append(snode)
        # cross-tile: wire w here is driven as wire w2 in a neighbor tile
        for dx, dy, tb, m in adj[tt]:
            w2 = m.get(w)
            if w2 is None:
                continue
            nnode = (x + dx, y + dy, w2)
            if nnode not in seen:
                seen.add(nnode)
                prev[nnode] = (node, ('wire', t, w))
                q.append(nnode)
    if start not in seen:
        return None, n
    # reconstruct
    path = []
    node = start
    while node != goal:
        nxt, info = prev[node]
        path.append(info)
        node = nxt
    return path, n


if __name__ == '__main__':
    # start: the codec IBUF output wire available in the INT column at Y27
    # goal: IMUX34 in INT_R_X95Y110 (D1 of the IFCLK OLOGIC)
    # The IBUF feeds LOGIC_OUTS18 into the INT column (engine row:
    #   RIOI_X95Y27.IOI_LOGIC_OUTS18_1.IOI_ILOGIC0_O and
    #   IO_INT_INTERFACE_R_X95Y28.INT_INTERFACE_LOGIC_OUTS18...)
    start = (233, 251, 'INT_INTERFACE_LOGIC_OUTS18')   # grid of X95Y28 iface
    goal = (232, 249, 'IMUX34')                        # INT_R_X95Y110
    path, n = solve(start, goal)
    print('nodes explored:', n)
    if path is None:
        print('NO PATH with documented pips')
    else:
        print('path length:', len(path))
        for step in path[:80]:
            print('  ', step)
