#!/usr/bin/env python3
"""fx3_raw_load.py - load FX3 firmware + FPGA bitstream with no UHD involvement.

1. reset FX3 into its USB bootloader (VREQ 0x99) if running
2. download usrp_b200_fw.hex record-by-record via the FX3 boot protocol
   (bmRequestType=0x40, bRequest=0xA0, wValue=addr_lo, wIndex=addr_hi)
3. load a FPGA bitstream via the stock firmware's vendor requests
4. drain-test the data OUT endpoint

usage: fx3_raw_load.py <fpga.bin> [fw.hex]
"""
import sys,time,usb.core,usb.util
sys.path.insert(0,__file__.rsplit("/",1)[0])
from gpif_rig import load,GPIF_RESET,VOUT
VID,PID=0x2500,0x0020
def find():
    return usb.core.find(idVendor=VID,idProduct=PID)
def to_bootloader():
    d=find()
    if d:
        try: p=usb.util.get_string(d,d.iProduct)
        except Exception: p='?'
        if 'West' not in p and 'Cypress' not in p:
            d.set_configuration(); d.ctrl_transfer(0x40,0x99,0,0,b'\x00',5000)
    for _ in range(20):
        time.sleep(0.5); d=find()
        if d:
            try: p=usb.util.get_string(d,d.iProduct)
            except Exception: continue
            if 'West' in p or 'Cypress' in p: return d
    raise SystemExit('bootloader not found')
def load_fw(bl,path):
    ext=0
    for line in open(path):
        line=line.strip()
        if not line.startswith(':'): continue
        b=bytes.fromhex(line[1:])
        ln=b[0]; addr=(b[1]<<8)|b[2]; typ=b[3]; data=b[4:4+ln]
        if typ==4: ext=int.from_bytes(b[4:6],'big')
        elif typ==2: ext=int.from_bytes(b[4:6],'big')<<4
        elif typ==0:
            a32=(ext<<16)|addr
            bl.ctrl_transfer(0x40,0xA0,a32&0xFFFF,(a32>>16)&0xFFFF,data,5000)
        elif typ==1: break
    try: bl.ctrl_transfer(0x40,0xA0,0,0,b'',5000)
    except Exception: pass
    for _ in range(40):
        time.sleep(0.5); d=find()
        if d:
            try: p=usb.util.get_string(d,d.iProduct)
            except Exception: continue
            if 'USRP' in p or 'B200' in p: return d
    raise SystemExit('firmware did not boot')
if __name__=='__main__':
    fpga=sys.argv[1]; fw=sys.argv[2] if len(sys.argv)>2 else '/usr/share/uhd/images/usrp_b200_fw.hex'
    bl=to_bootloader(); bl.set_configuration()
    dev=load_fw(bl,fw); dev.set_configuration()
    for itf in (1,2,3,4):
        try: usb.util.claim_interface(dev,itf)
        except Exception: pass
    load(dev,fpga)
    dev.ctrl_transfer(VOUT,GPIF_RESET,0,0,b'\x00',5000); time.sleep(0.05)
    frame=bytes(512); sent=0; stalls=0; t0=time.time()
    while sent<8*1024*1024 and stalls<3:
        try: sent+=dev.write(0x02,frame,200)
        except usb.core.USBError: stalls+=1
    dt=time.time()-t0
    print(f'{sent} B in {dt:.2f}s ({sent/dt/1e6:.2f} MB/s)')
