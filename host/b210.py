"""b210.py - the B210 from Python, configured by one declarative dict.

    from b210 import B210
    with B210({'rate': 30.72e6, 'rx': {'freq': 433.9e6, 'gain': [40, 40]}}) as sdr:
        x = sdr.rx(1 << 20)                  # complex64 (channels, n); raises on any loss
        sdr.tx(waves, secs=5)                # one array per transmit channel, repeated
        with sdr.stream() as s:              # continuous receive (and transmit)
            for block in s:                  # block.data, block.time, block.lost
                ...
        sdr.apply({'rx': {'freq': 868e6}})   # changes only what differs
        sdr.config                           # the complete configuration in force

The settings, their ranges and defaults are in schema.py.  Samples are
complex floats with full scale 1.0, or with cpu='sc16' the 16-bit integers
exactly as the FPGA sends them (int16, shape (..., 2) holding I, Q).

Backend: UHD's C API in the libuhd this repository builds (.tools/uhd315),
through ctypes.  The test sources ('tone', 'prbs', 'loopback') are the
AD9361's own digital signals, switched by the patched UHD at open time.
"""
import ctypes as C
import os
import sys
import threading

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import schema  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UHD = os.path.join(ROOT, '.tools', 'uhd315')
IMAGE = os.path.join(ROOT, 'build', 'fpga', 'usrp_b200.bin')
TESTS = {'tone': ('UHD_AD936X_BIST', '0x1B'), 'prbs': ('UHD_AD936X_BIST', '0x09'),
         'loopback': ('UHD_AD936X_LOOPBACK', '1')}
# Settings that need new streamers: UHD fixes the master clock and the wire
# format when a streamer is made, so these are set before making them.
REOPEN = {'rate', 'otw', 'test', 'rx.channels', 'tx.channels'}
# UHD's USB buffer pool: 512 receive and 256 transmit frames (34 ms and 17 ms
# at 245 MB/s; the default 16 frames hold 0.5 ms and lose samples whenever the
# host stalls longer).  Frames hold 4088-4090 samples, inside what the
# receive framer delivers cleanly.
FRAME = {'sc16': 16360, 'sc12': 12264, 'sc8': 8176}
BYTES = {'sc16': 4, 'sc12': 3, 'sc8': 2}
BUS = 400e6                                    # FX3 bus: 32 bits at 100 MHz, both directions together


class TuneRequest(C.Structure):
    _fields_ = [('target_freq', C.c_double), ('rf_freq_policy', C.c_int), ('rf_freq', C.c_double),
                ('dsp_freq_policy', C.c_int), ('dsp_freq', C.c_double), ('args', C.c_char_p)]


class TuneResult(C.Structure):
    _fields_ = [(n, C.c_double) for n in
                ('clipped_rf_freq', 'target_rf_freq', 'actual_rf_freq', 'target_dsp_freq', 'actual_dsp_freq')]


class StreamArgs(C.Structure):
    _fields_ = [('cpu_format', C.c_char_p), ('otw_format', C.c_char_p), ('args', C.c_char_p),
                ('channel_list', C.POINTER(C.c_size_t)), ('n_channels', C.c_int)]


class StreamCmd(C.Structure):
    _fields_ = [('stream_mode', C.c_int), ('num_samps', C.c_size_t), ('stream_now', C.c_bool),
                ('time_spec_full_secs', C.c_int64), ('time_spec_frac_secs', C.c_double)]


P, S, D, B, I, R, T, L = C.c_void_p, C.c_size_t, C.c_double, C.c_bool, C.c_int, C.POINTER, C.c_char_p, C.c_int64
SIGNATURES = {
    'usrp_make': [R(P), T], 'usrp_free': [R(P)], 'usrp_set_time_now': [P, L, D, S],
    'usrp_set_rx_rate': [P, D, S], 'usrp_set_tx_rate': [P, D, S], 'usrp_get_rx_rate': [P, S, R(D)],
    'usrp_set_rx_freq': [P, R(TuneRequest), S, R(TuneResult)],
    'usrp_set_tx_freq': [P, R(TuneRequest), S, R(TuneResult)],
    'usrp_set_rx_gain': [P, D, S, T], 'usrp_set_tx_gain': [P, D, S, T], 'usrp_set_rx_antenna': [P, T, S],
    'usrp_get_rx_stream': [P, R(StreamArgs), P], 'usrp_get_tx_stream': [P, R(StreamArgs), P],
    'rx_streamer_make': [R(P)], 'rx_streamer_free': [R(P)], 'rx_streamer_issue_stream_cmd': [P, R(StreamCmd)],
    'rx_streamer_recv': [P, R(P), S, R(P), D, B, R(S)],
    'rx_metadata_make': [R(P)], 'rx_metadata_free': [R(P)], 'rx_metadata_error_code': [P, R(I)],
    'rx_metadata_time_spec': [P, R(L), R(D)],
    'tx_streamer_make': [R(P)], 'tx_streamer_free': [R(P)], 'tx_streamer_send': [P, R(P), S, R(P), D, R(S)],
    'tx_streamer_recv_async_msg': [P, R(P), D, R(B)],
    'tx_metadata_make': [R(P), B, L, D, B, B], 'tx_metadata_free': [R(P)],
    'async_metadata_make': [R(P)], 'async_metadata_free': [R(P)], 'async_metadata_event_code': [P, R(I)],
    'get_last_error': [T, S],
}
RX_ERRORS = {0x1: 'timeout', 0x2: 'late command', 0x4: 'broken chain', 0x8: 'overflow',
             0xC: 'alignment', 0xF: 'bad packet'}
TX_LOSS = {0x2: 'underflow', 0x4: 'sequence error', 0x8: 'late', 0x10: 'underflow in packet',
           0x20: 'sequence error in burst'}
_lib = None


def lib():
    global _lib
    if _lib is None:
        os.environ.setdefault('UHD_IMAGES_DIR', os.path.join(UHD, 'images'))
        _lib = C.CDLL(os.path.join(UHD, 'lib', 'libuhd.so'))
        for name, argtypes in SIGNATURES.items():
            f = getattr(_lib, 'uhd_' + name)
            f.argtypes, f.restype = argtypes, C.c_int
    return _lib


def call(name, *args):
    if getattr(lib(), 'uhd_' + name)(*args) != 0:
        msg = C.create_string_buffer(1024)
        lib().uhd_get_last_error(msg, 1024)
        raise RuntimeError(f'uhd_{name}: {msg.value.decode()}')


class Block:
    """One stream block: data (channels, n), time of its first sample (s), samples lost before it."""
    __slots__ = ('data', 'time', 'lost')

    def __init__(self, data, time, lost):
        self.data, self.time, self.lost = data, time, lost


class B210:
    def __init__(self, config=None, fpga=IMAGE, args='', cpu='fc32'):
        self.fpga, self.args, self.cpu = fpga, args, cpu
        self.config, self.h = {}, None
        self.apply(config or {})

    # -- configuration -------------------------------------------------------
    def apply(self, config):
        """Make `config` (partial: the rest stays) the configuration in force."""
        merged = {k: v for k, v in self.config.items()}
        for k, v in config.items():
            merged[k] = {**merged.get(k, {}), **v} if isinstance(v, dict) else v
        new = schema.normalize(merged)
        changed = schema.diff(self.config, new)
        if self.h is None or REOPEN & set(changed):
            self.close()
            self._open(new)
        else:
            self._set(new, changed)
        self.config = new
        return changed

    def _open(self, cfg):
        for var, _ in TESTS.values():
            os.environ.pop(var, None)
        if cfg['test'] != 'none':
            var, value = TESTS[cfg['test']]
            os.environ[var] = value
        serial = os.environ.get('SERIAL')
        f = FRAME[cfg['otw']]
        pool = f'num_recv_frames=512,recv_frame_size={f},num_send_frames=256,send_frame_size={f}'
        B210.opens = getattr(B210, 'opens', 0) + 1
        # A unique key per open: UHD caches devices by their arguments and would
        # hand a reopen the old device, still being torn down.
        dev = ','.join(a for a in ('type=b200' if 'type=' not in self.args else '',
                                   serial and 'serial=' + serial, pool, f'open={B210.opens}',
                                   self.fpga and 'fpga=' + os.path.realpath(self.fpga), self.args) if a)
        self.h, self.rxs, self.txs, self.md = P(), P(), P(), P()
        call('usrp_make', C.byref(self.h), dev.encode())
        self._set(cfg, schema.diff({}, cfg))
        call('rx_metadata_make', C.byref(self.md))
        for d, s in (('rx', self.rxs), ('tx', self.txs)):
            chans = cfg[d]['channels']
            if chans:
                lst = (S * len(chans))(*chans)
                args = StreamArgs(self.cpu.encode(), cfg['otw'].encode(), b'', lst, len(chans))
                call(f'{d}_streamer_make', C.byref(s))
                call(f'usrp_get_{d}_stream', self.h, C.byref(args), s)

    def _set(self, cfg, changed):
        tune = lambda d, ch: call(f'usrp_set_{d}_freq', self.h, C.byref(  # noqa: E731
            TuneRequest(cfg[d]['freq'], 65, 0.0, 65, 0.0, b'')), ch, C.byref(TuneResult()))
        for d in ('rx', 'tx'):
            for i, ch in enumerate(cfg[d]['channels']):
                if 'rate' in changed:
                    call(f'usrp_set_{d}_rate', self.h, cfg['rate'], ch)
                if f'{d}.freq' in changed:
                    tune(d, ch)
                if f'{d}.gain' in changed:
                    call(f'usrp_set_{d}_gain', self.h, cfg[d]['gain'][i], ch, b'')
                if d == 'rx' and 'rx.antenna' in changed:
                    call('usrp_set_rx_antenna', self.h, cfg['rx']['antenna'][i].encode(), ch)
        chans = cfg['rx']['channels'] or cfg['tx']['channels']
        got = D()
        call('usrp_get_rx_rate', self.h, chans[0], C.byref(got))
        if abs(got.value - cfg['rate']) > 1e-6 * cfg['rate']:
            raise RuntimeError(f"rate {cfg['rate']:g} asked for, the hardware runs at {got.value:g}")
        self.rate = cfg['rate']                   # exact; the hardware's double differs by rounding only

    # -- samples -------------------------------------------------------------
    def _buffer(self, n):
        k = len(self.config['rx']['channels'])
        return np.empty((k, n, 2), np.int16) if self.cpu == 'sc16' else np.empty((k, n), np.complex64)

    def _recv(self, out, got, want, timeout=1.0):
        ptrs = (P * len(out))(*[row.ctypes.data + got * (8 if self.cpu == 'fc32' else 4) for row in out])
        step, code, full, frac = S(), I(), L(), D()
        call('rx_streamer_recv', self.rxs, ptrs, want, C.byref(self.md), timeout, False, C.byref(step))
        call('rx_metadata_error_code', self.md, C.byref(code))
        call('rx_metadata_time_spec', self.md, C.byref(full), C.byref(frac))
        return step.value, code.value, full.value + frac.value

    def rx(self, n, tx=None):
        """n samples per receive channel in one timed burst; with `tx` (one array
        per transmit channel, sent over and over) the transmitters run meanwhile."""
        out = self._buffer(n)
        call('usrp_set_time_now', self.h, 0, 0.0, 0)
        sender = self._sender(tx, 0.2)
        call('rx_streamer_issue_stream_cmd', self.rxs, C.byref(StreamCmd(100, n, False, 0, 0.3)))
        got = 0
        try:
            while got < n:
                step, code, _ = self._recv(out, got, n - got)
                got += step
                if code:
                    raise RuntimeError(f'rx lost samples: {RX_ERRORS.get(code, code)} after {got} of {n}')
        finally:
            losses = sender() if sender else {}
        if losses:
            raise RuntimeError(f'tx lost samples during rx: {losses}')
        return out

    def stream(self, block=1 << 16, tx=None):
        """Continuous receive in blocks of `block` samples (and transmit `tx` meanwhile)."""
        return _Stream(self, block, tx)

    def tx(self, waves, secs):
        """Transmit `waves` (one array per transmit channel, repeated) for `secs` seconds."""
        call('usrp_set_time_now', self.h, 0, 0.0, 0)
        stop = self._sender(waves, 0.2)
        threading.Event().wait(secs + 0.2)
        return stop()

    def _sender(self, waves, start):
        """Start sending `waves` from device time `start`; returns stop() -> losses."""
        if waves is None:
            return None
        c = self.config
        load = c['rate'] * BYTES[c['otw']] * (len(c['rx']['channels']) + len(c['tx']['channels']))
        if load > BUS:
            raise ValueError(f"{load / 1e6:.0f} MB/s of receive and transmit data exceeds the "
                             f"{BUS / 1e6:.0f} MB/s FX3 bus: use otw sc12 or sc8, a lower rate or fewer channels")
        waves = [np.ascontiguousarray(w, np.int16 if self.cpu == 'sc16' else np.complex64) for w in waves]
        reps = -(-(1 << 16) // len(waves[0]))     # at least 64 k samples per call
        waves = [np.ascontiguousarray(np.concatenate([w] * reps)) for w in waves]
        ptrs = (P * len(waves))(*[w.ctypes.data for w in waves])
        halt, losses = threading.Event(), {}

        def run():
            md, amd, sent, valid, code = P(), P(), S(), B(), I()
            call('async_metadata_make', C.byref(amd))
            call('tx_metadata_make', C.byref(md), True, 0, start, True, False)
            while not halt.is_set():
                call('tx_streamer_send', self.txs, ptrs, len(waves[0]), C.byref(md), 1.0, C.byref(sent))
                call('tx_metadata_free', C.byref(md))
                call('tx_metadata_make', C.byref(md), False, 0, 0.0, False, False)
                while True:                        # what the FPGA reported, without waiting
                    call('tx_streamer_recv_async_msg', self.txs, C.byref(amd), 0.0, C.byref(valid))
                    if not valid.value:
                        break
                    call('async_metadata_event_code', amd, C.byref(code))
                    if code.value in TX_LOSS:
                        losses[TX_LOSS[code.value]] = losses.get(TX_LOSS[code.value], 0) + 1
            call('tx_metadata_free', C.byref(md))
            call('tx_metadata_make', C.byref(md), False, 0, 0.0, False, True)
            call('tx_streamer_send', self.txs, ptrs, 0, C.byref(md), 1.0, C.byref(sent))   # end of burst
            call('tx_metadata_free', C.byref(md))
            call('async_metadata_free', C.byref(amd))

        thread = threading.Thread(target=run)
        thread.start()

        def stop():
            halt.set()
            thread.join()
            return losses
        return stop

    def close(self):
        if self.h:
            for name, h in (('rx_metadata_free', self.md), ('rx_streamer_free', self.rxs),
                            ('tx_streamer_free', self.txs), ('usrp_free', self.h)):
                if h:
                    getattr(lib(), 'uhd_' + name)(C.byref(h))
            self.h = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class _Stream:
    """Iterator of Blocks; counts samples lost across overflows from the timestamps."""

    def __init__(self, sdr, block, tx):
        self.sdr, self.block, self.tx, self.lost = sdr, block, tx, 0

    def __enter__(self):
        sdr = self.sdr
        call('usrp_set_time_now', sdr.h, 0, 0.0, 0)
        self.stop_tx = sdr._sender(self.tx, 0.2)
        call('rx_streamer_issue_stream_cmd', sdr.rxs, C.byref(StreamCmd(97, 0, False, 0, 0.3)))
        self.next_time = None
        return self

    def __iter__(self):
        return self

    def __next__(self):
        out, got, first, lost = self.sdr._buffer(self.block), 0, None, 0
        while got < self.block:
            step, code, t = self.sdr._recv(out, got, self.block - got)
            if code and code != 0x8:
                raise RuntimeError(f'stream: {RX_ERRORS.get(code, code)}')
            if step:
                if self.next_time is not None:
                    lost += max(0, round((t - self.next_time) * self.sdr.rate))
                first = t if first is None else first
                self.next_time = t + step / self.sdr.rate
            got += step
        self.lost += lost
        return Block(out, first, lost)

    def __exit__(self, *exc):
        call('rx_streamer_issue_stream_cmd', self.sdr.rxs, C.byref(StreamCmd(111, 0, True, 0, 0.0)))
        out = self.sdr._buffer(self.block)
        while self.sdr._recv(out, 0, self.block, timeout=0.1)[0]:
            pass                                   # drain what was in flight
        if self.stop_tx:
            self.tx_losses = self.stop_tx()


def tones(freqs, rate, amplitude=0.5, sc16=False):
    """One block per frequency holding whole periods, to be sent over and over
    (sc16: int16 I, Q rounded half away from zero, as C's lround)."""
    n = 8192
    while any(abs(f * n / rate - round(f * n / rate)) > 1e-9 for f in freqs):
        n += 1
        if n > 1 << 20:
            raise ValueError('no block of whole periods for these tones at this rate')
    t = np.arange(n) / rate
    if sc16:
        rnd = lambda v: np.trunc(v + np.copysign(0.5, v)).astype(np.int16)  # noqa: E731
        return [np.stack([rnd(32768 * amplitude * np.cos(2 * np.pi * f * t)),
                          rnd(32768 * amplitude * np.sin(2 * np.pi * f * t))], -1) for f in freqs]
    return [(amplitude * np.exp(2j * np.pi * f * t)).astype(np.complex64) for f in freqs]
