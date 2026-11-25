//! The board on USB: the stock FX3 firmware's vendor requests (FPGA load,
//! GPIF reset) and the four bulk endpoints of docs/PROTOCOL.md section 1.
//!
//! Each endpoint is alone on its interface (1 tx, 2 rx, 3 command, 4
//! result/event). Commands are synchronous, one in flight: [`Ctrl::exec`]
//! sends the command packet on EP4, then waits on EP8, where
//! [`RESULT_TRANSFERS`] 1024-byte transfers stay queued for the life of the
//! device, until the result carrying the command's sequence number arrives.
//! The EP8 byte stream is split into packets by the S(L) rule of
//! docs/PROTOCOL.md section 1 (`proto::packets`: a transfer may begin or end
//! in the middle of a packet, and may hold several short packets). Event
//! packets met on the way are kept for [`Ctrl::drain_events`]; a result
//! with another sequence number answers an earlier command that timed out
//! and is discarded. Completions wake the wait through the kernel's event:
//! nothing polls.
//!
//! Before any of that, [`load_firmware`] brings the FX3 from its ROM
//! bootloader to Ettus's stock firmware (section "FX3 boot" below).
//!
//! FPGA load, the sequence of the firmware's vendor requests
//! (b200_main.c, b200_const.h):
//!   0x55 FPGA_CONFIG, wait for state 1 (ready for an image)
//!   0x02 FPGA_START,  wait for state 2 (configuring)
//!   0x12 FPGA_DATA,   the image in pieces of the control buffer (512 bytes)
//!   wait for state 4 (running), then 0x72 GPIF_RESET: the firmware starts
//!   its bus state machine only on that request.

use crate::proto::{self, Event, Header, Kind, Op, Reply, Status};
use nusb::transfer::{
    Buffer, Bulk, ControlIn, ControlOut, ControlType, EndpointDirection, In, Out, Recipient, TransferError,
};
use nusb::{Endpoint, MaybeFuture};
use std::path::Path;
use std::sync::Once;
use std::thread;
use std::time::{Duration, Instant};

pub const VID: u16 = 0x2500;
pub const PID: u16 = 0x0020;

const VREQ_FPGA_START: u8 = 0x02;
const VREQ_FPGA_DATA: u8 = 0x12;
const VREQ_FPGA_CONFIG: u8 = 0x55;
const VREQ_GPIF_RESET: u8 = 0x72;
const VREQ_GET_STATUS: u8 = 0x83;
/// The firmware's control buffer at SuperSpeed.
const VREQ_CHUNK: usize = 512;

const STATE_FPGA_READY: u8 = 1;
const STATE_CONFIGURING: u8 = 2;
const STATE_RUNNING: u8 = 4;

/// SuperSpeed bulk maximum packet size. nusb requires every IN transfer
/// length to be a multiple of this, and `proto::DATA_BUFFER` is 16 x 1024.
const MAX_PACKET: usize = 1024;
const _: () = assert!(proto::DATA_BUFFER.is_multiple_of(MAX_PACKET));
const _: () = assert!(proto::CONTROL_BUFFER.is_multiple_of(MAX_PACKET));

/// Host buffering per direction, in milliseconds of
/// `proto::BUS_BYTES_PER_SEC`: planned at the bus ceiling because that is
/// the worst case any legal stream can ask of one direction.
/// 8 ms is the knee measured on this board streaming 2 RX x 30.72 MS/s
/// (245 MB/s) through UHD with receive queues of 16 360-byte frames: 32
/// frames (2.1 ms) lost samples in 7 of 15 runs, 128 (8.5 ms) in 1 of 15,
/// and 512 (34 ms) did no better (v1 measurement, docs/STATUS.md at tag
/// v1-ettus-uhd). 1 ms is below one scheduler slice and would hold
/// fewer than 25 transfers; 100 ms caps the plan (80 MB for both
/// directions) so the usbfs message stays actionable.
pub const DEPTH_MS_DEFAULT: f64 = 8.0;
pub const DEPTH_MS_MIN: f64 = 1.0;
pub const DEPTH_MS_MAX: f64 = 100.0;

/// Result transfers queued on EP8. Two is the FX3 DMA channel's own
/// depth (PROTOCOL.md section 1); three means one completes while two are
/// queued for the kernel and the FX3 can fill the next, without the gaps a
/// just-completed transfer would otherwise leave. Four would add memory and
/// latency for no result the protocol needs.
const RESULT_TRANSFERS: usize = 3;

/// Event records kept for [`Ctrl::drain_events`] before new ones are
/// dropped: 64 full event packets (7 records each), ~7 KiB. Dropping is
/// safe: the same increases accumulate in the FPGA's event-counter
/// registers (docs/PROTOCOL.md sections 5 and 6), which are authoritative.
const EVENT_LIMIT: usize = 64 * 7;

// -- timeouts, each with its derivation ---------------------------------------------------

/// A command's result: one 1024-byte command packet out and one result
/// packet back. At the 400 MB/s bus ceiling either takes 2.6 us; 1 s is
/// 390 000x that, enough for usbfs scheduling behind other transfers. A
/// result that has not come in 1 s (plus the operations' own WAIT and POLL
/// time, which [`Ctrl::exec`] adds) is a stuck endpoint, not a wait. Also
/// the limit for the command packet to leave the host.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(1);

/// One vendor control transfer carries at most 512 bytes (< 2 us at the
/// 400 MB/s bus ceiling). 5 s is the same order as the firmware's own
/// state-change limits below, and covers a request queued behind the FX3's
/// busy control thread; past that the firmware is not answering.
const VENDOR_TIMEOUT: Duration = Duration::from_secs(5);

/// The firmware's state changes during an FPGA load. These are firmware
/// work, not data: 5 s to accept an image and to start running, 10 s to
/// configure, the longest because it writes the whole image in 512-byte
/// requests.
const FX3_READY_WAIT: Duration = Duration::from_secs(5);
const FX3_CONFIGURE_WAIT: Duration = Duration::from_secs(10);
const FX3_RUN_WAIT: Duration = Duration::from_secs(5);
/// Interval of the state polls: 1/500 of the shortest limit above, so at
/// most 500 one-byte reads.
const FX3_STATE_POLL: Duration = Duration::from_millis(10);

/// After a load the FPGA answers once its clocks have locked and left
/// reset; a command sent earlier is lost. It is asked every 100 ms, up to
/// 20 times (2 s): 100 ms is 50 000 command packets at the bus rate, so each
/// probe is far longer than a healthy answer, and 20 probes cover clock
/// lock (the gate measures lock in milliseconds).
const PROBE_TIMEOUT: Duration = Duration::from_millis(100);
const PROBES: u32 = 20;

/// Per-transfer bound of [`drain`]: a cancelled transfer comes back within
/// microseconds; 100 ms is long enough for a loaded host and short enough
/// that a stuck one ends a drain quickly.
const DRAIN_WAIT: Duration = Duration::from_millis(100);

/// One 0xA0 write to the FX3 ROM bootloader moves at most 4 KiB; the
/// bootloader runs at USB 2 high speed (64-byte control packets, 64 of them
/// at 480 Mb/s, well under a millisecond). 1 s is 1000x that and only
/// bounds a ROM that stopped answering.
const BOOT_WRITE_TIMEOUT: Duration = Duration::from_secs(1);

/// From the jump to a usable 2500:0020. UHD allows 1 s for the firmware to
/// settle (b200_iface.cpp `load_firmware`) and then 3 s to find the
/// re-enumerated device (b200_impl.cpp REENUMERATION_TIMEOUT_MS): 4 s. 10 s
/// is 2.5x UHD's budget, slack for udev applying the device's permissions.
pub const FIRMWARE_BOOT_WAIT: Duration = Duration::from_secs(10);
/// 1/10 of UHD's 1 s settle time: at most 100 sysfs enumerations in
/// [`FIRMWARE_BOOT_WAIT`], and the device is used within 100 ms of being ready.
const FIRMWARE_POLL: Duration = Duration::from_millis(100);

/// SCHED_FIFO priority of [`set_realtime_priority`]. Linux real-time
/// priorities run 1 .. 99; 50 is above every ordinary (SCHED_OTHER) thread
/// while leaving the upper half for kernel threads that must preempt it.
/// The streaming threads are not pinned to a CPU: pinning the streaming
/// process to the USB interrupt's CPU made loss worse at 2 RX x 30.72 MS/s
/// on this board (v1 measurement, docs/STATUS.md at tag v1-ettus-uhd).
const RT_PRIORITY: i32 = 50;

/// `usbfs_memory_mb` is counted in 2^20-byte MiB (drivers/usb/core/devio.c);
/// the parameter's 0 means unlimited.
const USBMEM_FILE: &str = "/sys/module/usbcore/parameters/usbfs_memory_mb";
const MIB: u64 = 1 << 20;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("no B210 ({VID:04x}:{PID:04x}) on USB")]
    NotFound,
    #[error("the FX3 is in its ROM bootloader; `b210 load IMAGE` loads its firmware first")]
    Bootloader,
    #[error("no FX3 bootloader ({BOOT_VID:04x}:{BOOT_PID:04x}) on USB")]
    NoBootloader,
    #[error("firmware {}: {source}", path.display())]
    FirmwareFile { path: std::path::PathBuf, source: std::io::Error },
    #[error("firmware {}: SHA-256 {got}, expected {FIRMWARE_SHA256} (scripts/toolchain.sh uhd)", path.display())]
    FirmwareHash { path: std::path::PathBuf, got: String },
    #[error("firmware HEX: {0}")]
    Hex(#[from] HexError),
    #[error("the firmware did not enumerate as {VID:04x}:{PID:04x} within {0:?}")]
    FirmwareTimeout(Duration),
    #[error("USB: {0}")]
    Usb(#[from] nusb::Error),
    #[error("USB transfer: {0}")]
    Transfer(#[from] TransferError),
    #[error("FX3 firmware state {state} while waiting for {want}")]
    Fx3State { state: u8, want: u8 },
    #[error("protocol: {0:?}")]
    Proto(proto::Error),
    #[error("command {sequence} returned {got} results for {want} operations")]
    ReplyCount { sequence: u16, got: usize, want: usize },
    #[error("opcode {opcode} at {addr:#06x}: {status}")]
    Status { opcode: u8, addr: u16, status: Status },
    #[error("no result for command {0} within {1:?}")]
    Timeout(u16, Duration),
    #[error("no sample clock: the AD9361 is not running (`b210-radio apply CONFIG`)")]
    NoSampleClock,
    #[error(
        "USB buffering needs {need_bytes} bytes ({need_mb} MiB), more than {file} = {have_mb} MB; \
         raise the limit with `sudo modprobe usbcore usbfs_memory_mb={need_mb}` \
         (or write {need_mb} to {file})"
    )]
    Usbfs { need_bytes: usize, need_mb: u64, have_mb: u64, file: &'static str },
}

pub type Result<T> = std::result::Result<T, Error>;

/// The board: control (vendor requests, commands and their results) and
/// the two data endpoints, separate so that each can run on its own thread.
pub struct Usb {
    pub ctrl: Ctrl,
    pub tx: Endpoint<Bulk, Out>,
    pub rx: Endpoint<Bulk, In>,
    /// Transfer buffers planned per direction at open (see
    /// [`depth_transfers`]).
    pub depth: usize,
}

/// The control side: FX3 vendor requests, the command endpoint and the
/// result/event endpoint.
pub struct Ctrl {
    device: nusb::Device,
    cmd: Endpoint<Bulk, Out>,
    /// The one command buffer, allocated zero-copy on first use and reused.
    cmd_buf: Option<Buffer>,
    /// The sequence number of the next command.
    sequence: u16,
    rsp: Endpoint<Bulk, In>,
    /// EP8 bytes not yet split into packets: the start of an incomplete one.
    pending: Vec<u8>,
    /// Event records met on EP8 since the last `drain_events`.
    events: Vec<Event>,
}

impl Usb {
    /// Open the board and queue the EP8 transfers. `depth_ms` is clamped
    /// to [`DEPTH_MS_MIN`] .. [`DEPTH_MS_MAX`] and converted to a transfer
    /// count by [`depth_transfers`]; the planned usbfs memory is checked
    /// before any buffer is allocated.
    pub fn open(depth_ms: f64) -> Result<Usb> {
        let depth = depth_transfers(depth_ms, proto::BUS_BYTES_PER_SEC);
        // Planned usbfs memory: `depth` 16 KiB transfers for the rx and the
        // tx direction (both can be in flight in loopback), the EP8 result
        // transfers, one command packet, and one vendor FPGA-load chunk.
        // Each is allocated once and reused, so this is the peak.
        let plan = 2 * depth * proto::DATA_BUFFER
            + (RESULT_TRANSFERS + 1) * proto::CONTROL_BUFFER
            + VREQ_CHUNK;

        let info = nusb::list_devices()
            .wait()?
            .find(|d| d.vendor_id() == VID && d.product_id() == PID)
            .ok_or(Error::NotFound)?;
        if !firmware_running(&info) {
            return Err(Error::Bootloader);
        }
        let device = info.open().wait()?;
        check_usbfs(plan)?;
        let ep = |n: u8| device.detach_and_claim_interface(n).wait();
        let (i1, i2, i3, i4) = (ep(1)?, ep(2)?, ep(3)?, ep(4)?);
        let ctrl = Ctrl::start(
            device,
            i3.endpoint::<Bulk, Out>(0x04)?,
            i4.endpoint::<Bulk, In>(0x88)?,
        );
        Ok(Usb {
            tx: i1.endpoint::<Bulk, Out>(0x02)?,
            rx: i2.endpoint::<Bulk, In>(0x86)?,
            ctrl,
            depth,
        })
    }
}

/// Transfers per direction that hold `depth_ms` of data at
/// `bytes_per_sec`: `bytes = bytes_per_sec x depth_ms / 1000`, then
/// `total = ceil(bytes / DATA_BUFFER)`, and at least one transfer. The
/// transfer size is `proto::DATA_BUFFER` = 16 KiB = 16 x 1024, a multiple of
/// the SuperSpeed maximum packet size.
pub fn depth_transfers(depth_ms: f64, bytes_per_sec: f64) -> usize {
    let ms = if depth_ms.is_finite() {
        depth_ms.clamp(DEPTH_MS_MIN, DEPTH_MS_MAX)
    } else {
        DEPTH_MS_DEFAULT
    };
    let bytes = bytes_per_sec.max(0.0) * ms / 1000.0;
    ((bytes / proto::DATA_BUFFER as f64).ceil() as usize).max(1)
}

/// The `usbfs_memory_mb` limit in bytes, or `None` if the kernel has no such
/// parameter (then there is nothing to check); 0 means unlimited.
fn usbfs_limit_bytes() -> Option<u64> {
    let text = std::fs::read_to_string(USBMEM_FILE).ok()?;
    let mb: u64 = text.trim().parse().ok()?;
    (mb != 0).then_some(mb * MIB)
}

fn check_usbfs(plan: usize) -> Result<()> {
    let Some(limit) = usbfs_limit_bytes() else { return Ok(()) };
    if plan as u64 <= limit {
        return Ok(());
    }
    let have_mb = limit / MIB;
    let need_mb = (plan as u64).div_ceil(MIB);
    Err(Error::Usbfs { need_bytes: plan, need_mb, have_mb, file: USBMEM_FILE })
}

/// A transfer buffer allocated zero-copy (usbfs mmap) where nusb can. A
/// copying buffer still works, but it makes the kernel copy every transfer
/// and is not what the usbfs plan describes, so say so once instead of
/// accepting it silently.
pub fn zero_copy(buf: Buffer) -> Buffer {
    if !buf.is_zero_copy() {
        static WARNED: Once = Once::new();
        WARNED.call_once(|| {
            eprintln!(
                "b210: warning: USB buffer is not zero-copy \
                 (usbfs mmap failed or is unsupported); transfers will be copied"
            )
        });
    }
    buf
}

impl Ctrl {
    fn start(device: nusb::Device, cmd: Endpoint<Bulk, Out>, mut rsp: Endpoint<Bulk, In>) -> Ctrl {
        for _ in 0..RESULT_TRANSFERS {
            let b = zero_copy(rsp.allocate(proto::CONTROL_BUFFER));
            rsp.submit(b);
        }
        Ctrl { device, cmd, cmd_buf: None, sequence: 0, rsp, pending: Vec::new(), events: Vec::new() }
    }

    /// Event records met on EP8 since the last call, after collecting the
    /// transfers that have already completed. Losing an event record is never
    /// a correctness problem: the event counters are registers
    /// (`regs::EVENTS + k`) and the FPGA adds increases to them until they
    /// can be reported, so the registers, not this list, are the
    /// authoritative count.
    pub fn drain_events(&mut self) -> Vec<Event> {
        // completions that are ready now; a transfer error only ends the
        // collection, the next command reports it
        while let Ok(Some(_)) = self.collect(Duration::ZERO, None) {}
        std::mem::take(&mut self.events)
    }

    fn vendor_out(&self, request: u8, data: &[u8]) -> Result<()> {
        let c = ControlOut { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, data };
        Ok(self.device.control_out(c, VENDOR_TIMEOUT).wait()?)
    }

    fn vendor_in(&self, request: u8, length: u16) -> Result<Vec<u8>> {
        let c = ControlIn { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, length };
        Ok(self.device.control_in(c, VENDOR_TIMEOUT).wait()?)
    }

    /// The firmware's state (1 ready for an image, 2 configuring, 4 running).
    pub fn fx3_state(&self) -> Result<u8> {
        Ok(self.vendor_in(VREQ_GET_STATUS, 1)?.first().copied().unwrap_or(0))
    }

    /// Poll the firmware state every [`FX3_STATE_POLL`] until it reaches
    /// `want`, for at most `limit`.
    fn wait_state(&self, want: u8, limit: Duration) -> Result<()> {
        let start = Instant::now();
        loop {
            let state = self.fx3_state()?;
            if state == want {
                return Ok(());
            }
            if start.elapsed() > limit {
                return Err(Error::Fx3State { state, want });
            }
            thread::sleep(FX3_STATE_POLL);
        }
    }

    /// Load an FPGA image (the .bin the build writes) and start the bus.
    pub fn load_fpga(&mut self, image: &[u8]) -> Result<()> {
        self.vendor_out(VREQ_FPGA_CONFIG, &[0])?;
        self.wait_state(STATE_FPGA_READY, FX3_READY_WAIT)?;
        self.vendor_out(VREQ_FPGA_START, &[0])?;
        self.wait_state(STATE_CONFIGURING, FX3_CONFIGURE_WAIT)?;
        for chunk in image.chunks(VREQ_CHUNK) {
            self.vendor_out(VREQ_FPGA_DATA, chunk)?;
        }
        self.wait_state(STATE_RUNNING, FX3_RUN_WAIT)?;
        self.gpif_reset()?;
        for _ in 0..PROBES {
            match self.run(&[Op::Read { addr: crate::regs::ID }], PROBE_TIMEOUT) {
                Err(Error::Timeout(..)) => continue,
                r => return r.map(|_| ()),
            }
        }
        // the last probe sent, which is the one that went unanswered
        Err(Error::Timeout(self.sequence.wrapping_sub(1), PROBE_TIMEOUT * PROBES))
    }

    /// Restart the firmware's GPIF state machine (needed after every load).
    pub fn gpif_reset(&self) -> Result<()> {
        self.vendor_out(VREQ_GPIF_RESET, &[0; 4])
    }

    /// Run operations in one command packet; their results, in order, one
    /// per operation (statuses not checked: a POLL's timeout is its
    /// caller's to see). The result must arrive within [`CONTROL_TIMEOUT`]
    /// plus the operations' own WAIT and POLL time.
    pub fn exec(&mut self, ops: &[Op]) -> Result<Vec<Reply>> {
        let extra: Duration = ops
            .iter()
            .map(|op| match *op {
                Op::Wait { us } => Duration::from_micros(us as u64),
                Op::Poll { ms, .. } => Duration::from_millis(ms as u64),
                Op::Write { .. } | Op::Read { .. } | Op::Spi { .. } => Duration::ZERO,
            })
            .sum();
        self.run(ops, CONTROL_TIMEOUT.saturating_add(extra))
    }

    /// Send one command packet and wait at most `limit` for its result.
    fn run(&mut self, ops: &[Op], limit: Duration) -> Result<Vec<Reply>> {
        let sequence = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);
        let packet = proto::command(sequence, ops).map_err(Error::Proto)?;
        // The command buffer is one 1024-byte transfer, reused for every
        // command: zero-copy like the streaming buffers, and no mmap per
        // command during an AD9361 bring-up.
        let mut buf = self.cmd_buf.take().unwrap_or_else(|| zero_copy(self.cmd.allocate(proto::CONTROL_BUFFER)));
        buf.clear();
        buf.extend_from_slice(&packet);
        let c = self.cmd.transfer_blocking(buf, CONTROL_TIMEOUT);
        self.cmd_buf = Some(c.buffer);
        c.status?;
        let deadline = Instant::now() + limit;
        loop {
            // A result whose command already timed out (an earlier
            // sequence) is discarded by `collect`: no later command reuses
            // its sequence until 2^16 more have run.
            let left = deadline.saturating_duration_since(Instant::now());
            match self.collect(left, Some(sequence))? {
                Some(Some(replies)) => return exact_count(replies, ops.len(), sequence),
                Some(None) => {}
                None => return Err(Error::Timeout(sequence, limit)),
            }
        }
    }

    /// Wait at most `wait` for one EP8 transfer, append its bytes to the
    /// stream and split it: events are kept, results other than `sequence`'s
    /// discarded. None: no transfer completed; Some(Some(replies)): the
    /// result for `sequence` was in it.
    fn collect(&mut self, wait: Duration, sequence: Option<u16>) -> Result<Option<Option<Vec<Reply>>>> {
        let Some(c) = self.rsp.wait_next_complete(wait) else { return Ok(None) };
        let n = c.actual_len;
        // A cancelled or failed transfer can still report the bytes it had;
        // they are part of the stream, so take them before the status.
        self.pending.extend_from_slice(&c.buffer[..n]);
        let buf = c.buffer;
        match c.status {
            Ok(()) => self.rsp.submit(buf),
            Err(TransferError::Disconnected) => return Err(TransferError::Disconnected.into()),
            Err(e) => {
                // Clear a halt and refill; the command fails, the next one
                // starts afresh (no spinning on a persistent fault).
                if matches!(e, TransferError::Stall) {
                    let _ = self.rsp.clear_halt().wait();
                }
                self.rsp.submit(buf);
                return Err(e.into());
            }
        }
        match take(&mut self.pending, sequence, &mut self.events) {
            Ok(replies) => Ok(Some(replies)),
            Err(e) => {
                // no length to resynchronise on: the buffered bytes go
                self.pending.clear();
                Err(Error::Proto(e))
            }
        }
    }

    pub fn write(&mut self, addr: u16, data: u32) -> Result<()> {
        let r = self.exec(&[Op::Write { addr, data }])?;
        check_reply(r[0]).map(|_| ())
    }

    pub fn read(&mut self, addr: u16) -> Result<u32> {
        let r = self.exec(&[Op::Read { addr }])?;
        Ok(check_reply(r[0])?.data)
    }

    /// Read registers in one command packet, so that they describe the same
    /// moment (a read takes about 100 ns on the FPGA).
    pub fn read_all(&mut self, addrs: &[u16]) -> Result<Vec<u32>> {
        let ops: Vec<Op> = addrs.iter().map(|&addr| Op::Read { addr }).collect();
        self.exec(&ops)?.into_iter().map(|r| check_reply(r).map(|r| r.data)).collect()
    }
}

impl Drop for Ctrl {
    fn drop(&mut self) {
        // leave no transfer queued on an endpoint about to be dropped
        drain(&mut self.rsp);
    }
}

/// Split every complete packet off the front of `stream` (keeping an
/// incomplete one for the next transfer): event records are appended to
/// `events` (beyond [`EVENT_LIMIT`] they are dropped), the replies of the
/// result for `sequence` are returned, every other result is discarded
/// (it answers a command that already timed out), and data or command
/// packets, which never arrive on EP8, are ignored.
fn take(stream: &mut Vec<u8>, sequence: Option<u16>, events: &mut Vec<Event>) -> std::result::Result<Option<Vec<Reply>>, proto::Error> {
    let ranges = proto::packets(stream, proto::CONTROL_BUFFER)?;
    let used = ranges.last().map_or(0, |r| r.end);
    let mut found = None;
    for r in ranges {
        let p = &stream[r];
        let h = Header::decode(p)?;
        let body = &p[proto::HEADER..h.length as usize];
        match h.kind {
            Kind::Result if Some(h.sequence) == sequence => found = Some(proto::replies(body)),
            Kind::Event => {
                let room = EVENT_LIMIT.saturating_sub(events.len());
                events.extend(proto::events(body).into_iter().take(room));
            }
            Kind::Result | Kind::Rx | Kind::Tx | Kind::Command => {}
        }
    }
    stream.drain(..used);
    Ok(found)
}

/// A command's result must have exactly one reply per operation. A short
/// result would shift every later reply onto the wrong operation, so it is
/// an error rather than a shorter list.
fn exact_count(replies: Vec<Reply>, want: usize, sequence: u16) -> Result<Vec<Reply>> {
    if replies.len() == want {
        Ok(replies)
    } else {
        Err(Error::ReplyCount { sequence, got: replies.len(), want })
    }
}

fn check_reply(reply: Reply) -> Result<Reply> {
    if reply.status.is_ok() {
        Ok(reply)
    } else {
        Err(Error::Status { opcode: reply.opcode, addr: reply.addr, status: reply.status })
    }
}

/// Cancel every transfer queued on `ep` and collect them, discarding their
/// data. A cancelled transfer is returned at once; [`DRAIN_WAIT`] only bounds
/// one that is not, and the first wait that runs out ends the drain (the
/// endpoint is then dropped or reused with that transfer still pending,
/// rather than the caller hanging).
pub fn drain<D: EndpointDirection>(ep: &mut Endpoint<Bulk, D>) {
    ep.cancel_all();
    while ep.pending() > 0 {
        if ep.wait_next_complete(DRAIN_WAIT).is_none() {
            break;
        }
    }
}

/// Put the calling thread in SCHED_FIFO at [`RT_PRIORITY`]: for the threads
/// that serve the data endpoints while streaming, so that a loaded host does
/// not starve them of the CPU (the FPGA's rings then overflow or run dry).
/// Never fatal: without RLIMIT_RTPRIO >= the priority (or root) the kernel
/// refuses, and a normal thread is still correct, only more likely to lose
/// a completion to scheduling delay; that is said once per process.
#[cfg(target_os = "linux")]
pub fn set_realtime_priority() {
    let param = libc::sched_param { sched_priority: RT_PRIORITY };
    // SAFETY: pid 0 is this thread and `param` is a valid sched_param for
    // the duration of the call.
    let rc = unsafe { libc::sched_setscheduler(0, libc::SCHED_FIFO, &param) };
    if rc == 0 {
        return;
    }
    let err = std::io::Error::last_os_error();
    static WARNED: Once = Once::new();
    WARNED.call_once(|| {
        let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
        // SAFETY: getrlimit writes one `rlimit` through the pointer on
        // success; it is only assumed initialised in that branch.
        let limit = unsafe {
            if libc::getrlimit(libc::RLIMIT_RTPRIO, limit.as_mut_ptr()) == 0 { Some(limit.assume_init()) } else { None }
        };
        match limit {
            Some(l) => eprintln!(
                "b210: warning: streaming threads stay normal threads ({err}); \
                 RLIMIT_RTPRIO is {} of {}, raise it with `ulimit -r {RT_PRIORITY}`",
                l.rlim_cur, l.rlim_max
            ),
            None => eprintln!("b210: warning: streaming threads stay normal threads ({err})"),
        }
    });
}

#[cfg(not(target_os = "linux"))]
pub fn set_realtime_priority() {}

// -- FX3 boot: the stock firmware from the ROM bootloader -----------------------------------
//
// After power-up the FX3 runs its ROM bootloader. With no boot record in
// the board's EEPROM it enumerates with Cypress's IDs 04b4:00f3; with one it
// enumerates as 2500:0020 and only its manufacturer string tells it apart
// from the firmware (UHD, transport/libusb1_base.cpp `firmware_loaded`:
// "Ettus Research LLC", "National Instruments Corp." or "Free Software
// Folks" means the firmware runs). Both are treated as the bootloader.
//
// The download is the ROM's vendor request 0xA0 (UHD b200_iface.cpp
// FX3_FIRMWARE_LOAD, its Intel HEX reader lib/utils/ihex.cpp): host to
// device, wValue = address bits 15..0, wIndex = address bits 31..16, the data
// written to RAM at that address. A request with no data is the jump: the
// ROM starts the code at that address, which is the HEX file's start linear
// address (record 05). The firmware then re-enumerates as 2500:0020.
//
// UHD sends one request per HEX record (at most 255 bytes). This loader
// joins contiguous records and sends at most 4 KiB per request, the ROM's
// control buffer, on 4-byte-aligned addresses: the same bytes at the same
// addresses in fewer requests.

/// The FX3 ROM bootloader's own IDs (Cypress).
pub const BOOT_VID: u16 = 0x04b4;
pub const BOOT_PID: u16 = 0x00f3;
const VREQ_FX3_BOOT: u8 = 0xA0;
/// Largest 0xA0 write: the ROM bootloader's 4 KiB control buffer.
pub const BOOT_CHUNK: usize = 4096;
/// The manufacturer strings of a running firmware (UHD `firmware_loaded`).
const FIRMWARE_MANUFACTURERS: [&str; 3] = ["Ettus Research LLC", "National Instruments Corp.", "Free Software Folks"];

/// Where `scripts/toolchain.sh uhd` puts Ettus's stock FX3 firmware.
pub const FIRMWARE_DEFAULT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../.tools/uhd315/images/usrp_b200_fw.hex");
/// SHA-256 of that file, the value scripts/toolchain.sh asserts when it
/// extracts it from Ettus's UHD 4.9.0.1 archive. The FX3 executes whatever
/// it is given, so a file that is not this one is never downloaded.
pub const FIRMWARE_SHA256: &str = "cc8e4bc968d91d1a67c63871ce5b2c1613c49676fe363bf2f6e336059899ae5c";

/// What is on the bus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Board {
    /// 2500:0020 with the stock firmware running.
    Running,
    /// The FX3 ROM bootloader, waiting for firmware.
    Bootloader,
    Absent,
}

fn firmware_running(d: &nusb::DeviceInfo) -> bool {
    d.vendor_id() == VID
        && d.product_id() == PID
        && d.manufacturer_string().is_some_and(|m| FIRMWARE_MANUFACTURERS.contains(&m))
}

fn in_bootloader(d: &nusb::DeviceInfo) -> bool {
    (d.vendor_id() == BOOT_VID && d.product_id() == BOOT_PID)
        || (d.vendor_id() == VID && d.product_id() == PID && !firmware_running(d))
}

/// The board's state on USB; a running firmware wins over a bootloader.
pub fn board() -> Result<Board> {
    let mut found = Board::Absent;
    for d in nusb::list_devices().wait()? {
        if firmware_running(&d) {
            return Ok(Board::Running);
        }
        if in_bootloader(&d) {
            found = Board::Bootloader;
        }
    }
    Ok(found)
}

/// A firmware image ready for the bootloader: the writes in order, then the
/// jump to `entry`.
#[derive(Debug, PartialEq, Eq)]
pub struct FirmwareImage {
    /// (address, bytes): each at most [`BOOT_CHUNK`] bytes, each address a
    /// multiple of 4.
    pub chunks: Vec<(u32, Vec<u8>)>,
    pub entry: u32,
}

impl FirmwareImage {
    pub fn bytes(&self) -> usize {
        self.chunks.iter().map(|(_, d)| d.len()).sum()
    }
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum HexError {
    #[error("line {line}: {what}")]
    Line { line: usize, what: String },
    #[error("no end-of-file record")]
    NoEof,
    #[error("no start linear address record (05): nowhere to jump")]
    NoEntry,
}

/// Parse Intel HEX as the FX3 bootloader needs it. Records: 00 data, 01 end
/// of file, 04 extended linear address (bits 31..16 for the data records
/// that follow), 05 start linear address (the entry point). Every record's
/// checksum is verified (all bytes, checksum included, sum to 0 mod 256);
/// any other record type, malformed line, empty data record (a zero-length
/// 0xA0 would be a jump), text after the end-of-file record or data
/// beyond 4 GiB is an error. Contiguous data is joined and split into
/// [`BOOT_CHUNK`]-byte writes; each run of contiguous data must start on a
/// 4-byte boundary, so every write does.
pub fn parse_hex(text: &str) -> std::result::Result<FirmwareImage, HexError> {
    let mut upper: u32 = 0;
    let mut runs: Vec<(u32, Vec<u8>)> = Vec::new();
    let mut entry = None;
    let mut eof = false;
    for (i, raw) in text.lines().enumerate() {
        let line = i + 1;
        let err = |what: String| HexError::Line { line, what };
        let record = raw.trim();
        if record.is_empty() {
            continue;
        }
        if eof {
            return Err(err("text after the end-of-file record".into()));
        }
        let hex = record.strip_prefix(':').ok_or_else(|| err("does not start with ':'".into()))?;
        if !hex.is_ascii() || hex.len() % 2 != 0 || hex.len() < 10 {
            return Err(err("not a record (odd length, too short or not ASCII)".into()));
        }
        let bytes = (0..hex.len())
            .step_by(2)
            .map(|k| u8::from_str_radix(&hex[k..k + 2], 16))
            .collect::<std::result::Result<Vec<u8>, _>>()
            .map_err(|_| err("not hexadecimal".into()))?;
        let count = bytes[0] as usize;
        if bytes.len() != count + 5 {
            return Err(err(format!("length field says {count} data bytes, the record holds {}", bytes.len() - 5)));
        }
        if bytes.iter().fold(0u8, |s, &b| s.wrapping_add(b)) != 0 {
            return Err(err("checksum mismatch".into()));
        }
        let addr = u16::from_be_bytes([bytes[1], bytes[2]]);
        let data = &bytes[4..4 + count];
        match bytes[3] {
            0x00 => {
                if count == 0 {
                    return Err(err("empty data record".into()));
                }
                let at = upper | addr as u32;
                if at as u64 + count as u64 > 1 << 32 {
                    return Err(err(format!("data at {at:#010x} runs past 4 GiB")));
                }
                match runs.last_mut() {
                    Some((start, run)) if *start as u64 + run.len() as u64 == at as u64 => run.extend_from_slice(data),
                    _ => {
                        if !at.is_multiple_of(4) {
                            return Err(err(format!("data at {at:#010x} is not 4-byte aligned")));
                        }
                        runs.push((at, data.to_vec()));
                    }
                }
            }
            0x01 => {
                if addr != 0 || count != 0 {
                    return Err(err("end-of-file record with address or data".into()));
                }
                eof = true;
            }
            0x04 => {
                if addr != 0 || count != 2 {
                    return Err(err("extended linear address record must have address 0 and 2 bytes".into()));
                }
                upper = (u16::from_be_bytes([data[0], data[1]]) as u32) << 16;
            }
            0x05 => {
                if addr != 0 || count != 4 {
                    return Err(err("start linear address record must have address 0 and 4 bytes".into()));
                }
                if entry.is_some() {
                    return Err(err("second start linear address record".into()));
                }
                entry = Some(u32::from_be_bytes([data[0], data[1], data[2], data[3]]));
            }
            kind => return Err(err(format!("unsupported record type {kind:02x}"))),
        }
    }
    if !eof {
        return Err(HexError::NoEof);
    }
    let entry = entry.ok_or(HexError::NoEntry)?;
    let chunks = runs
        .iter()
        .flat_map(|(start, run)| {
            run.chunks(BOOT_CHUNK)
                .enumerate()
                .map(move |(k, c)| (start + (k * BOOT_CHUNK) as u32, c.to_vec()))
        })
        .collect();
    Ok(FirmwareImage { chunks, entry })
}

/// Lowercase hex SHA-256. The `sha2` crate is a dependency for this alone:
/// nothing else in the dependency tree computes SHA-256, the pin in
/// toolchain.sh is a SHA-256 (so a weaker or different hash cannot check
/// it), and a hand-written SHA-256 would be unreviewed crypto code.
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Read the firmware file, check it is the pinned one and parse it.
pub fn read_firmware(hex: &Path) -> Result<FirmwareImage> {
    let path = hex.to_path_buf();
    let bytes = std::fs::read(hex).map_err(|source| Error::FirmwareFile { path: path.clone(), source })?;
    let got = sha256_hex(&bytes);
    if got != FIRMWARE_SHA256 {
        return Err(Error::FirmwareHash { path, got });
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| HexError::Line { line: 0, what: "not text".into() })?;
    Ok(parse_hex(text)?)
}

fn boot_write(device: &nusb::Device, addr: u32, data: &[u8]) -> Result<()> {
    let c = ControlOut {
        control_type: ControlType::Vendor,
        recipient: Recipient::Device,
        request: VREQ_FX3_BOOT,
        value: addr as u16,
        index: (addr >> 16) as u16,
        data,
    };
    Ok(device.control_out(c, BOOT_WRITE_TIMEOUT).wait()?)
}

/// Write `image` into the bootloader's RAM and jump to it. Returns once the
/// jump is sent; the firmware is not up yet (see [`wait_firmware`]).
pub fn download_firmware(image: &FirmwareImage) -> Result<()> {
    let info = nusb::list_devices().wait()?.find(in_bootloader).ok_or(Error::NoBootloader)?;
    let device = info.open().wait()?;
    for (addr, data) in &image.chunks {
        boot_write(&device, *addr, data)?;
    }
    // The ROM leaves the bus as it jumps, so the status stage may fail;
    // UHD ignores this request's result too. Success shows as the firmware
    // enumerating.
    let _ = boot_write(&device, image.entry, &[]);
    Ok(())
}

/// Poll every [`FIRMWARE_POLL`] until 2500:0020 with the firmware is listed
/// and can be opened (udev may apply its permissions a little after the
/// device appears), for at most `limit`.
pub fn wait_firmware(limit: Duration) -> Result<()> {
    let start = Instant::now();
    loop {
        if let Some(info) = nusb::list_devices().wait()?.find(firmware_running)
            && info.open().wait().is_ok()
        {
            return Ok(());
        }
        if start.elapsed() >= limit {
            return Err(Error::FirmwareTimeout(limit));
        }
        thread::sleep(FIRMWARE_POLL);
    }
}

/// Bring the FX3 from its ROM bootloader to the stock firmware: verify and
/// parse `hex`, download it, start it and wait up to
/// [`FIRMWARE_BOOT_WAIT`] for 2500:0020.
pub fn load_firmware(hex: &Path) -> Result<()> {
    let image = read_firmware(hex)?;
    download_firmware(&image)?;
    wait_firmware(FIRMWARE_BOOT_WAIT)
}

#[cfg(test)]
mod tests {
    use super::*;


    fn reply(status: Status, data: u32) -> Reply {
        Reply { opcode: 2, status, addr: 3, data }
    }

    /// A result or event packet of `length` bytes on the wire, padded to S(L).
    fn packet(kind: Kind, sequence: u16, body: &[u8]) -> Vec<u8> {
        let length = proto::HEADER + body.len();
        let flags = if kind == Kind::Event { proto::flag::HAS_TIME } else { 0 };
        let h = Header { length: length as u16, kind, format: None, mask: 0, sequence, flags, time: 0 };
        let mut p = h.encode().to_vec();
        p.extend_from_slice(body);
        p.resize(proto::transfer_size(length, proto::CONTROL_BUFFER), 0);
        p
    }

    /// One result record: opcode 2 (READ), status ok, `data`.
    fn result(data: u32) -> Vec<u8> {
        let mut b = (2u32 << 24 | 3).to_le_bytes().to_vec();
        b.extend_from_slice(&data.to_le_bytes());
        b
    }

    /// One event record: OVERFLOW, `count` samples.
    fn event(count: u32) -> Vec<u8> {
        let mut b = vec![1, 0b01, 0, 0];
        b.extend_from_slice(&count.to_le_bytes());
        b.extend_from_slice(&0u64.to_le_bytes());
        b
    }

    #[test]
    fn take_returns_our_result_keeps_events_and_discards_stale_results() {
        let mut stream = Vec::new();
        stream.extend(packet(Kind::Result, 9, &result(99))); // a timed-out command's late answer
        stream.extend(packet(Kind::Event, 0, &event(5)));
        stream.extend(packet(Kind::Result, 10, &result(10)));
        stream.extend(packet(Kind::Event, 0, &[event(6), event(7)].concat()));
        let tail = packet(Kind::Result, 11, &result(11));
        stream.extend(&tail[..20]); // the start of a packet the next transfer completes
        let mut events = Vec::new();
        let r = take(&mut stream, Some(10), &mut events).unwrap();
        assert_eq!(r.map(|r| r.iter().map(|r| r.data).collect::<Vec<_>>()), Some(vec![10]));
        assert_eq!(events.iter().map(|e| e.count).collect::<Vec<_>>(), [5, 6, 7], "events before and after the result");
        assert_eq!(stream, &tail[..20], "the incomplete packet stays");
        // negative control: the stale sequence alone is not taken for ours
        let mut stale = packet(Kind::Result, 9, &result(99));
        assert_eq!(take(&mut stale, Some(10), &mut events).unwrap(), None);
        assert!(stale.is_empty(), "consumed and discarded");
        // with no command in flight every result is discarded
        let mut any = packet(Kind::Result, 10, &result(10));
        assert_eq!(take(&mut any, None, &mut events).unwrap(), None);
    }

    #[test]
    fn take_caps_the_events_and_rejects_a_bad_stream() {
        let mut events = Vec::new();
        for _ in 0..EVENT_LIMIT / 7 + 2 {
            let mut p = packet(Kind::Event, 0, &[event(1), event(1), event(1), event(1), event(1), event(1), event(1)].concat());
            take(&mut p, None, &mut events).unwrap();
        }
        assert_eq!(events.len(), EVENT_LIMIT);
        let mut bad = packet(Kind::Result, 1, &result(1));
        bad[3] = 0x20 | (bad[3] & 0x0F); // version 2
        assert_eq!(take(&mut bad, Some(1), &mut events), Err(proto::Error::Version(2)));
    }

    #[test]
    fn reply_count_must_match_the_operations() {
        let one = reply(Status::Ok, 1);
        assert_eq!(exact_count(vec![one], 1, 5).unwrap(), vec![one]);
        let err = exact_count(vec![one], 2, 5).unwrap_err();
        assert!(matches!(err, Error::ReplyCount { sequence: 5, got: 1, want: 2 }));
        // Negative control: too many is an error as well, not ignored.
        let err = exact_count(vec![one, one, one], 2, 5).unwrap_err();
        assert!(matches!(err, Error::ReplyCount { got: 3, want: 2, .. }));
    }

    #[test]
    fn read_and_write_reject_non_ok_results() {
        let ok = check_reply(reply(Status::Ok, 7)).unwrap();
        assert_eq!(ok.data, 7);
        let err = check_reply(reply(Status::Timeout, 0)).unwrap_err();
        assert!(matches!(err, Error::Status { status: Status::Timeout, .. }));
        assert_eq!(err.to_string(), "opcode 2 at 0x0003: timeout (poll)");
    }

    #[test]
    fn depth_ms_to_transfer_count_boundaries() {
        let total = |ms: f64| depth_transfers(ms, proto::BUS_BYTES_PER_SEC);
        assert_eq!(total(1.0), 25, "400000 B / 16384 = 24.4 -> 25");
        assert_eq!(total(8.0), 196, "default: 3200000 B / 16384 = 195.3 -> 196");
        assert_eq!(total(100.0), 2442, "40000000 B / 16384 = 2441.4 -> 2442");
        // Clamps: below 1 ms is 1 ms, above 100 ms is 100 ms, NaN is default.
        assert_eq!(total(0.0), total(1.0));
        assert_eq!(total(0.5), total(1.0));
        assert_eq!(total(101.0), total(100.0));
        assert_eq!(total(f64::NAN), total(DEPTH_MS_DEFAULT));
        // Exact boundary: one transfer holds exactly 1 ms at this rate.
        let one = proto::DATA_BUFFER as f64 * 1000.0;
        assert_eq!(depth_transfers(1.0, one), 1);
        assert_eq!(depth_transfers(1.0, one + 1.0), 2);
    }

    // -- Intel HEX ------------------------------------------------------------------------

    /// One record with its checksum (two's complement of the byte sum).
    fn rec(kind: u8, addr: u16, data: &[u8]) -> String {
        let mut bytes = vec![data.len() as u8, (addr >> 8) as u8, addr as u8, kind];
        bytes.extend_from_slice(data);
        let sum = bytes.iter().fold(0u8, |s, &b| s.wrapping_add(b));
        bytes.push(sum.wrapping_neg());
        format!(":{}", bytes.iter().map(|b| format!("{b:02X}")).collect::<String>())
    }

    const EOF: &str = ":00000001FF";
    /// The stock firmware's own start record: entry 0x40019DEC.
    const START: &str = ":0400000540019DEC2D";

    fn line_err(line: usize, what: &str) -> HexError {
        HexError::Line { line, what: what.into() }
    }

    #[test]
    fn hex_record_helper_matches_known_records() {
        assert_eq!(rec(0x01, 0, &[]), EOF);
        assert_eq!(rec(0x05, 0, &[0x40, 0x01, 0x9D, 0xEC]), START);
        assert_eq!(rec(0x00, 0x0010, &[1, 2, 3, 4]), ":0400100001020304E2");
    }

    #[test]
    fn hex_valid_file() {
        // Two contiguous records join into one write; CRLF and blank lines pass.
        let text = format!(":0400100001020304E2\r\n:0400140005060708CE\r\n\r\n{START}\r\n{EOF}\r\n");
        assert_eq!(
            parse_hex(&text),
            Ok(FirmwareImage { chunks: vec![(0x10, vec![1, 2, 3, 4, 5, 6, 7, 8])], entry: 0x4001_9DEC })
        );
    }

    #[test]
    fn hex_bad_checksum() {
        let text = format!(":0400100001020304E2\n:0400140005060708CF\n{START}\n{EOF}\n");
        assert_eq!(parse_hex(&text), Err(line_err(2, "checksum mismatch")));
    }

    #[test]
    fn hex_unknown_record_types() {
        // 02 extended segment address and 03 start segment address are x86
        // real-mode records; the FX3 file has neither.
        for kind in [0x02, 0x03, 0x06, 0xFF] {
            let data: &[u8] = if kind == 0x03 { &[0, 0, 0, 0] } else { &[0, 0] };
            let text = format!("{}\n{START}\n{EOF}\n", rec(kind, 0, data));
            assert_eq!(parse_hex(&text), Err(line_err(1, &format!("unsupported record type {kind:02x}"))));
        }
    }

    #[test]
    fn hex_extended_addresses() {
        // Contiguous across a 64 KiB boundary set by two 04 records: one write.
        // A later run elsewhere: a second write.
        let a: Vec<u8> = (0..16).collect();
        let b: Vec<u8> = (16..32).collect();
        let c: Vec<u8> = vec![0xAA; 8];
        let text = [
            rec(0x04, 0, &[0x40, 0x00]),
            rec(0x00, 0xFFF0, &a),
            rec(0x04, 0, &[0x40, 0x01]),
            rec(0x00, 0x0000, &b),
            rec(0x04, 0, &[0x10, 0x00]),
            rec(0x00, 0x0100, &c),
            START.into(),
            EOF.into(),
        ]
        .join("\n");
        let ab: Vec<u8> = (0..32).collect();
        assert_eq!(
            parse_hex(&text),
            Ok(FirmwareImage { chunks: vec![(0x4000_FFF0, ab), (0x1000_0100, c)], entry: 0x4001_9DEC })
        );
    }

    #[test]
    fn hex_data_split_across_chunks() {
        // 300 records of 16 bytes = 4800 contiguous bytes at 0x40000000:
        // 4096 bytes at 0x40000000, then 704 at 0x40001000.
        let all: Vec<u8> = (0..4800u32).map(|i| (i * 7 + i / 256) as u8).collect();
        let mut lines = vec![rec(0x04, 0, &[0x40, 0x00])];
        for (k, piece) in all.chunks(16).enumerate() {
            lines.push(rec(0x00, (k * 16) as u16, piece));
        }
        lines.push(START.into());
        lines.push(EOF.into());
        let image = parse_hex(&lines.join("\n")).unwrap();
        assert_eq!(
            image,
            FirmwareImage {
                chunks: vec![(0x4000_0000, all[..4096].to_vec()), (0x4000_1000, all[4096..].to_vec())],
                entry: 0x4001_9DEC,
            }
        );
        assert_eq!(image.bytes(), 4800);
    }

    #[test]
    fn hex_rejects_malformed_files() {
        let d = rec(0x00, 0x0010, &[1, 2, 3, 4]);
        let cases: Vec<(String, HexError)> = vec![
            (format!("{d}\n{START}\n"), HexError::NoEof),
            (format!("{d}\n{EOF}\n"), HexError::NoEntry),
            (format!("{d}\n{START}\n{EOF}\n{d}\n"), line_err(4, "text after the end-of-file record")),
            (format!("0400100001020304E2\n{START}\n{EOF}\n"), line_err(1, "does not start with ':'")),
            (format!(":0400100001020304E\n{START}\n{EOF}\n"), line_err(1, "not a record (odd length, too short or not ASCII)")),
            (format!(":04001000010203G4E2\n{START}\n{EOF}\n"), line_err(1, "not hexadecimal")),
            (format!(":05001000010203041D\n{START}\n{EOF}\n"), line_err(1, "length field says 5 data bytes, the record holds 4")),
            (format!("{}\n{START}\n{EOF}\n", rec(0x00, 0x0010, &[])), line_err(1, "empty data record")),
            (format!("{}\n{START}\n{EOF}\n", rec(0x00, 0x0012, &[1, 2])), line_err(1, "data at 0x00000012 is not 4-byte aligned")),
            (
                format!("{}\n{}\n{START}\n{EOF}\n", rec(0x04, 0, &[0xFF, 0xFF]), rec(0x00, 0xFFFC, &[0; 8])),
                line_err(2, "data at 0xfffffffc runs past 4 GiB"),
            ),
            (format!("{d}\n{START}\n{START}\n{EOF}\n"), line_err(3, "second start linear address record")),
            (format!("{}\n{START}\n{EOF}\n", rec(0x04, 0, &[0x40])), line_err(1, "extended linear address record must have address 0 and 2 bytes")),
            (format!("{d}\n{START}\n{}\n", rec(0x01, 1, &[])), line_err(3, "end-of-file record with address or data")),
        ];
        for (text, want) in cases {
            assert_eq!(parse_hex(&text), Err(want), "{text}");
        }
    }

    /// The real firmware, where `scripts/toolchain.sh uhd` has put it: the
    /// pinned hash matches and the image parses into valid writes.
    #[test]
    fn stock_firmware_parses() {
        let path = Path::new(FIRMWARE_DEFAULT);
        if !path.exists() {
            eprintln!("skipped: {FIRMWARE_DEFAULT} not present");
            return;
        }
        let image = read_firmware(path).unwrap();
        assert_eq!(image.entry, 0x4001_9DEC);
        assert!(image.chunks.iter().all(|(a, d)| a.is_multiple_of(4) && !d.is_empty() && d.len() <= BOOT_CHUNK));
    }

    #[test]
    fn firmware_hash_is_checked() {
        let dir = std::env::temp_dir().join(format!("b210-fw-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("fw.hex");
        std::fs::write(&file, format!("{START}\n{EOF}\n")).unwrap();
        let r = read_firmware(&file);
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(matches!(r, Err(Error::FirmwareHash { .. })), "{r:?}");
    }
}
