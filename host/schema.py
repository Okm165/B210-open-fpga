"""schema.py - every setting of the board, defined once.

A configuration is one dict (or TOML file) of this shape:

    rate = 30.72e6            # samples per second, every channel, both directions
    otw  = "sc16"             # sample format on the wire: sc16, sc12, sc8
    test = "none"             # none, tone, prbs, loopback (AD9361 digital sources)
    [rx]
    channels = [0, 1]
    freq     = 100e6          # one receive synthesizer: shared by both channels
    gain     = [30, 30]       # dB, per channel
    antenna  = ["RX2", "RX2"] # RX2 or TX/RX, per channel
    [tx]
    channels = [0, 1]
    freq     = 100e6          # one transmit synthesizer: shared by both channels
    gain     = [0, 0]         # dB, per channel

`normalize()` fills defaults, checks every value against its range and
returns a complete configuration; `diff()` says which settings two complete
configurations disagree on.  The device applies only those.
"""

# name: (default, kind, limits, meaning).  kind 'scalar' | 'per-channel' | 'channels'.
# The 2-channel limit on rate is checked in normalize().
DEVICE = {
    'rate': (30.72e6, 'scalar', (0.52e6, 61.44e6), 'samples per second (all channels, both directions)'),
    'otw':  ('sc16', 'scalar', ('sc16', 'sc12', 'sc8'), 'sample format on the wire'),
    'test': ('none', 'scalar', ('none', 'tone', 'prbs', 'loopback'), 'AD9361 digital source in place of the antennas'),
}
RX = {
    'channels': ([0, 1], 'channels', (0, 1), 'receive channels in use'),
    'freq':     (100e6, 'scalar', (70e6, 6e9), 'centre frequency, Hz (one synthesizer for both channels)'),
    'gain':     (30.0, 'per-channel', (0.0, 76.0), 'gain, dB'),
    'antenna':  ('RX2', 'per-channel', ('RX2', 'TX/RX'), 'antenna port'),
}
TX = {
    'channels': ([0, 1], 'channels', (0, 1), 'transmit channels in use'),
    'freq':     (100e6, 'scalar', (70e6, 6e9), 'centre frequency, Hz (one synthesizer for both channels)'),
    'gain':     (0.0, 'per-channel', (0.0, 89.75), 'gain, dB'),
}
SECTIONS = {'rx': RX, 'tx': TX}


def _check(name, value, kind, limits):
    if isinstance(limits[0], str):
        if value not in limits:
            raise ValueError(f'{name} = {value!r}: one of {", ".join(limits)}')
        return value
    lo, hi = limits
    value = float(value) if kind != 'channels' else int(value)
    if not lo <= value <= hi:
        raise ValueError(f'{name} = {value:g}: outside {lo:g} .. {hi:g}')
    return value


def normalize(cfg=None):
    """A complete, checked configuration from a partial one."""
    cfg = dict(cfg or {})
    unknown = set(cfg) - set(DEVICE) - set(SECTIONS)
    out = {}
    for name, (default, kind, limits, _) in DEVICE.items():
        out[name] = _check(name, cfg.get(name, default), kind, limits)
    for sec, table in SECTIONS.items():
        given = dict(cfg.get(sec, {}))
        unknown |= {f'{sec}.{k}' for k in set(given) - set(table)}
        chans = given.get('channels', table['channels'][0])
        chans = chans if isinstance(chans, (list, tuple)) else [chans]
        chans = sorted({_check(f'{sec}.channels', c, 'channels', (0, 1)) for c in chans})
        part = {'channels': chans}
        for name, (default, kind, limits, _) in table.items():
            if kind == 'per-channel':
                v = given.get(name, default)
                v = list(v) if isinstance(v, (list, tuple)) else [v] * len(chans)
                if len(v) != len(chans):
                    raise ValueError(f'{sec}.{name}: {len(v)} values for {len(chans)} channels')
                part[name] = [_check(f'{sec}.{name}', x, kind, limits) for x in v]
            elif kind == 'scalar':
                part[name] = _check(f'{sec}.{name}', given.get(name, default), kind, limits)
        out[sec] = part
    if unknown:
        raise ValueError('unknown settings: ' + ', '.join(sorted(unknown)))
    if max(len(out['rx']['channels']), len(out['tx']['channels'])) == 2 and out['rate'] > 30.72e6:
        raise ValueError(f'rate = {out["rate"]:g}: two channels run at 30.72e6 at most')
    return out


def diff(old, new):
    """Dotted names of the settings that differ between two complete configurations."""
    names = [k for k in DEVICE if old.get(k) != new[k]]
    for sec in SECTIONS:
        names += [f'{sec}.{k}' for k in new[sec] if old.get(sec, {}).get(k) != new[sec][k]]
    return names


def table():
    """Markdown table of every setting (for the README)."""
    rows = ['| Setting | Default | Range | Meaning |', '| --- | --- | --- | --- |']
    for prefix, tab in (('', DEVICE), ('rx.', RX), ('tx.', TX)):
        for name, (default, kind, limits, meaning) in tab.items():
            rng = ', '.join(limits) if isinstance(limits[0], str) else f'{limits[0]:g} .. {limits[1]:g}'
            rows.append(f'| `{prefix}{name}` | {default} | {rng} | {meaning}'
                        f'{" (per channel)" if kind == "per-channel" else ""} |')
    return '\n'.join(rows)
