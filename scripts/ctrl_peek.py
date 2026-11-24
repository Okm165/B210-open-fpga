#!/usr/bin/env python3
"""ctrl_peek2 - resilient raw VRT peek with retries + EP flush; dumps raws."""
import sys, time, struct, usb.core, usb.util

SID, SR_READBACK, PTYPE = 0x40, 32, 2

dev = usb.core.find(idVendor=0x2500, idProduct=0x0020)
try: dev.reset()
except Exception: pass
time.sleep(0.3)
dev.set_configuration()
for itf in range(5):
    try: usb.util.claim_interface(dev, itf)
    except Exception: pass

def hdr(seq, nw):
    return ((PTYPE & 7) << 29) | 0x10000000 | ((seq & 0xf) << 16) | (nw & 0xffff)

def tx(seq):
    pkt = struct.pack('<4I', hdr(seq,4), SID, SR_READBACK, 0)  # peek64 of reg pair 0
    dev.write(4, pkt, 500)

def rx():
    return bytes(dev.read(0x88, 512, 300))

def flush():
    for _ in range(3):
        try: rx()
        except Exception: return

seq = 0
raws = []
for i in range(int(sys.argv[1]) if len(sys.argv)>1 else 20):
    for attempt in range(4):
        try: tx(seq)
        except Exception as e: print('tx-err', e); flush(); continue
        try:
            d = rx()
        except Exception:
            flush(); continue
        if d:
            raws.append(d)
            seq = (seq+1) & 0xf
            break
    else:
        pass
print('responses:', len(raws))
for d in raws[:6]:
    print(len(d), d.hex())
