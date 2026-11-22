# USB bring-up checklist (empirical, terminal-only, no LEDs)

Run after any power cycle of the board.  Each step has a pass/fail
criterion; stop at the first failure - it locates the fault layer.

0. Enumeration: `lsusb | grep 2500:0020`
   PASS: device listed.  FAIL: FX3 not booting (power/hardware).
1. Responsiveness: `python3 -c "import usb.core;d=usb.core.find(idVendor=0x2500,idProduct=0x0020);d.set_configuration();print(bytes(d.ctrl_transfer(0xC0,0x83,0,0,1,2000)).hex())"`
   PASS: one status byte (5 = UNCONFIGURED expected).  FAIL: EPIPE = FX3
   firmware wedged (power cycle again).
2. FX3 boot log: ctrl 0xC0/0x23 (512 B) - must contain "b200_fw_start",
   "[DMA] ..." lines.  Absent lines = firmware fault layer.
3. Clean config: `python3 scripts/hw_load_direct.py <image>`
   PASS: "state before: UNCONFIGURED" -> "after data: RUNNING".
   FAIL at "ready" = FPGA not asserting READY; FAIL at RUNNING = DONE low.
4. Control path: `timeout 200 uhd_usrp_probe --args="type=b200,serial=31B92DD,fpga=<image>"`
   PASS: "FPGA Version: 16.0" + two "loopback test passed".
   FAIL (wait_for_ack timeout) = FPGA configures but control path dead.
5. Data path: `scripts/rx_capture.py --rate 61.44e6 --chans 1 --secs 0.25`
   then `--rate 30.72e6 --chans 2` -> FFT/quality PNGs, overflow counts.

Images (in test order):
  /tmp/opencode/ours_repack.bin      ours, per-frame FAR packaging
  /tmp/opencode/vendor_ourspack.bin  vendor content, our packaging
  /tmp/opencode/vendor_fpga/usrp_b210_fpga.bin  vendor original (control)
