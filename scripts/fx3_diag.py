#!/usr/bin/env python3
"""fx3_diag.py - read the stock B200 FX3 firmware's own diagnostics.

No firmware modification: uses the vendor requests the stock firmware already
serves (b200_main.c):
  0x23 GET_LOG       text log; every PIB/GPIF error interrupt is logged here
                     (CYU3P_PIB_ERR_THR<n>_RD_UNDERRUN, GPIF_ERR_DATA_READ_ERR..)
  0x24 GET_COUNTERS  struct Counters (57 x int32, layout below)

Why this matters: the FX3's GPIF state machine is clocked by PCLK, which the
FPGA supplies.  A PIB/GPIF error can only be raised by a state machine that
is being clocked, so ANY such log line proves PCLK edges and the FPGA's
strobes reach the FX3.  Conversely the DMA counters show whether the P-port
ever consumed a host buffer (dma_from_host.CONS_EVENT).

Deliberately does NOT call set_configuration(): that makes the firmware run
b200_fw_stop/start and bump the 'ABORTED' DMA counters, which is what the
old "liveness counter" (byte 24) was actually measuring.

usage: fx3_diag.py [--clear]
"""
import struct, sys, usb.core

DMA = ['XFER_CPLT', 'SEND_CPLT', 'RECV_CPLT', 'PROD_EVENT', 'CONS_EVENT',
       'ABORTED', 'ERROR', 'PROD_SUSP', 'CONS_SUSP', 'BUFFER_MARKER',
       'BUFFER_EOP', 'BUFFER_ERROR', 'BUFFER_OCCUPIED', 'last_count',
       'last_size', 'last_sid', 'bad_sid_count']
USBERR = ['phy_error_count', 'link_error_count', 'PHY_LOCK_EV',
          'TRAINING_ERROR_EV', 'RX_ERROR_CRC32_EV', 'RX_ERROR_CRC16_EV',
          'RX_ERROR_CRC5_EV', 'PHY_ERROR_DISPARITY_EV', 'PHY_ERROR_EB_UND_EV',
          'PHY_ERROR_EB_OVR_EV', 'PHY_ERROR_DECODE_EV']
FIELDS = (['magic'] + ['to_host.' + f for f in DMA] + ['from_host.' + f for f in DMA]
          + ['log_overrun_count', 'usb_error_update_count']
          + ['usberr.' + f for f in USBERR]
          + ['usb_ep_underrun_count', 'heap_size', 'resume_count',
             'state_transition_count', 'invalid_gpif_state']
          + [f'pib{i}.socket_inactive' for i in range(4)])


def dev():
    d = usb.core.find(idVendor=0x2500, idProduct=0x0020)
    if d is None:
        raise SystemExit('no B210')
    return d


def counters(d):
    raw = bytes(d.ctrl_transfer(0xC0, 0x24, 0, 0, 4 * len(FIELDS), 2000))
    vals = struct.unpack('<%di' % (len(raw) // 4), raw[:len(raw) // 4 * 4])
    return dict(zip(FIELDS, vals))


def log(d):
    out = []
    for _ in range(64):
        raw = bytes(d.ctrl_transfer(0xC0, 0x23, 0, 0, 4096, 2000))
        if not raw or raw[0] == 0:
            break
        out += [s.decode('ascii', 'replace') for s in raw.split(b'\0') if s]
    return out


def main():
    d = dev()
    if '--clear' in sys.argv:
        d.ctrl_transfer(0x40, 0x25, 0, 0, b'\x00', 2000)
        log(d)
        print('cleared')
        return
    lines = log(d)
    c = counters(d)
    gpif = [l for l in lines if 'PIB_ERR' in l or 'GPIF_ERR' in l]
    print(f'log lines: {len(lines)}   PIB/GPIF error lines: {len(gpif)}')
    kinds = {}
    for l in gpif:
        k = l.split(' ', 2)[-1]
        kinds[k] = kinds.get(k, 0) + 1
    for k, n in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print(f'   {n:5d} x {k}')
    if '-v' in sys.argv:
        for l in lines:
            print('   |', l)
    keys = ['from_host.PROD_EVENT', 'from_host.CONS_EVENT', 'from_host.ABORTED',
            'from_host.ERROR', 'to_host.PROD_EVENT', 'to_host.CONS_EVENT',
            'log_overrun_count', 'invalid_gpif_state', 'state_transition_count',
            'pib1.socket_inactive']
    print('counters: ' + '  '.join(f'{k}={c.get(k)}' for k in keys))


main()
