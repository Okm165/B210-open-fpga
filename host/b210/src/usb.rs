//! The board on USB: the stock FX3 firmware's vendor requests (FPGA load,
//! GPIF reset) and the four bulk endpoints of docs/PROTOCOL.md section 1.
//!
//! Each endpoint is alone on its interface (1 tx, 2 rx, 3 command, 4
//! result/event). One thread owns EP8 IN for the life of the device: it
//! keeps [`RESULT_TRANSFERS`] 1024-byte transfers in flight, splits the byte
//! stream into packets by the S(L) rule of docs/PROTOCOL.md section 1 (a
//! transfer may begin or end in the middle of a packet, and may hold several
//! short packets), sends a result to the command waiting for its sequence
//! number and queues an event for the CLI. Commands are sent on EP4 by the
//! calling thread; it then blocks on a channel until the reader delivers the
//! result, so there is no polling anywhere on the result path.
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
use nusb::transfer::{Buffer, Bulk, ControlIn, ControlOut, ControlType, In, Out, Recipient, TransferError};
use nusb::{Endpoint, MaybeFuture};
use std::collections::HashMap;
use std::ops::Range;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard, Once};
use std::thread::{self, JoinHandle};
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

/// The bus's data ceiling (docs/PROTOCOL.md section 3: rate x bytes per
/// sample time, both directions summed, must stay below 400 MB/s). Buffering
/// is planned at this rate because it is the worst case any legal stream can
/// ask of one direction.
pub const BUS_BYTES_PER_SEC: f64 = 400e6;

/// Host buffering per direction, in milliseconds of `BUS_BYTES_PER_SEC`.
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

/// Result transfers in flight on EP8. Two is the FX3 DMA channel's own
/// depth (PROTOCOL.md section 1); three means one completes while two are
/// queued for the kernel and the FX3 can fill the next, without the gaps a
/// just-completed transfer would otherwise leave. Four would add memory and
/// latency for no result the protocol needs.
const RESULT_TRANSFERS: usize = 3;

/// How long a single `wait_next_complete` wait may last before the reader
/// re-checks the stop flag. This only bounds shutdown latency; completions
/// themselves wake the wait through the kernel's event, so it is not a poll
/// interval for results.
const WAIT_TICK: Duration = Duration::from_millis(100);

/// Drop waits this long for the reader: one `WAIT_TICK` to notice the flag,
/// one more to cancel and drain `RESULT_TRANSFERS` transfers, and 3x the
/// total as slack for a loaded host (100 + 100 + 300 ms).
const SHUTDOWN_WAIT: Duration = Duration::from_millis(500);

/// Limit for one 1024-byte command packet to leave the host. At the 400 MB/s
/// bus ceiling that packet takes 2.6 us; 1 s is 390 000x that, enough for
/// usbfs scheduling behind other transfers. A command that has not left in
/// 1 s is a stuck endpoint, not a wait.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(1);

/// Event packets the reader may queue before dropping new ones. One packet
/// is at most 112 bytes, so 64 packets is ~7 KiB. Dropping is safe: the same
/// increases accumulate in the FPGA's event-counter registers
/// (docs/PROTOCOL.md sections 5 and 6), which the CLI reads directly.
const EVENT_QUEUE: usize = 64;

/// SCHED_FIFO priority of the reader thread. Linux real-time priorities run
/// 1 .. 99; 50 is above every ordinary (SCHED_OTHER) thread while leaving the
/// upper half for kernel threads that must preempt it. The reader is not
/// pinned to a CPU: pinning the streaming process to the USB interrupt's CPU
/// made loss worse at 2 RX x 30.72 MS/s on this board (v1 measurement,
/// docs/STATUS.md at tag v1-ettus-uhd).
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
    #[error("USB thread: {0}")]
    Io(#[from] std::io::Error),
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
    #[error("the EP8 reader stopped")]
    ReaderStopped,
    #[error(
        "USB buffering needs {need_bytes} bytes ({need_mb} MiB), more than {file} = {have_mb} MB; \
         raise the limit with `sudo modprobe usbcore usbfs_memory_mb={need_mb}` \
         (or write {need_mb} to {file})"
    )]
    Usbfs { need_bytes: usize, need_mb: u64, have_mb: u64, file: &'static str },
}

pub type Result<T> = std::result::Result<T, Error>;

impl Status {
    /// Status 0 only. Status 1 is a legitimate result of a POLL (the value
    /// never matched within the time limit), which `exec` exposes to the
    /// caller; only `read` and `write`, whose operations have no timeout
    /// result, turn any non-zero status into an error.
    pub fn is_ok(self) -> bool {
        matches!(self, Status::Ok)
    }
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Status::Ok => f.write_str("ok"),
            Status::Timeout => f.write_str("timeout (poll)"),
            Status::Late => f.write_str("late (at)"),
            Status::UnknownOp => f.write_str("unknown opcode/argument"),
            Status::Other(code) => write!(f, "unknown status {code}"),
        }
    }
}

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
/// result/event reader thread.
pub struct Ctrl {
    device: nusb::Device,
    cmd: Endpoint<Bulk, Out>,
    /// The one command buffer, allocated zero-copy on first use and reused.
    cmd_buf: Option<Buffer>,
    sequence: u16,
    shared: Arc<Shared>,
    /// Event packets the reader has queued; counters are authoritative.
    events: Receiver<Vec<Event>>,
    /// The reader signals this channel just before it returns.
    done: Receiver<()>,
    reader: Option<JoinHandle<()>>,
}

/// Everything the command thread and the EP8 reader share.
struct Shared {
    /// Sequence -> the channel of the command waiting for it. A result is
    /// removed from the map as it is delivered, so a duplicate has nowhere
    /// to go (it is counted in `late`).
    waiters: Mutex<HashMap<u16, mpsc::Sender<Vec<Reply>>>>,
    events: SyncSender<Vec<Event>>,
    stop: AtomicBool,
    /// Result packets with no waiter: a late answer to a timed-out command,
    /// or a duplicate.
    late: AtomicU64,
    /// Transfers whose packet stream did not parse.
    protocol_errors: AtomicU64,
    /// Whether the reader has already warned about a transfer error.
    reader_warned: AtomicBool,
}

impl Usb {
    /// Open the board and start the EP8 reader. `depth_ms` is clamped to
    /// [`DEPTH_MS_MIN`] .. [`DEPTH_MS_MAX`] and converted to a transfer
    /// count by [`depth_transfers`]; the planned usbfs memory is checked
    /// before any buffer is allocated.
    pub fn open(depth_ms: f64) -> Result<Usb> {
        let depth = depth_transfers(depth_ms, BUS_BYTES_PER_SEC);
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
        )?;
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
    fn start(device: nusb::Device, cmd: Endpoint<Bulk, Out>, rsp: Endpoint<Bulk, In>) -> Result<Ctrl> {
        let (event_tx, events) = mpsc::sync_channel(EVENT_QUEUE);
        let (done_tx, done) = mpsc::channel();
        let shared = Arc::new(Shared {
            waiters: Mutex::new(HashMap::new()),
            events: event_tx,
            stop: AtomicBool::new(false),
            late: AtomicU64::new(0),
            protocol_errors: AtomicU64::new(0),
            reader_warned: AtomicBool::new(false),
        });
        let thread_shared = Arc::clone(&shared);
        let reader = thread::Builder::new()
            .name("b210-ep8".to_string())
            .spawn(move || {
                read_loop(rsp, thread_shared);
                let _ = done_tx.send(());
            })?;
        Ok(Ctrl {
            device,
            cmd,
            cmd_buf: None,
            sequence: 0,
            shared,
            events,
            done,
            reader: Some(reader),
        })
    }

    /// Event records the reader has queued since the last call. Losing an
    /// event record here is never a correctness problem: the event counters
    /// are registers (`regs::EVENTS + k`) and the FPGA adds increases to them
    /// until they can be reported, so the registers — not this queue — are
    /// the authoritative count.
    pub fn drain_events(&self) -> Vec<Event> {
        let mut out = Vec::new();
        while let Ok(packet) = self.events.try_recv() {
            out.extend(packet);
        }
        out
    }

    /// One vendor control transfer carries at most 512 bytes (< 2 us at the
    /// 400 MB/s bus ceiling). 5 s is the same order as the firmware's own
    /// state-change limit below, and covers a request queued behind the
    /// FX3's busy control thread; past that the firmware is not answering.
    fn vendor_out(&self, request: u8, data: &[u8]) -> Result<()> {
        let c = ControlOut { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, data };
        Ok(self.device.control_out(c, Duration::from_secs(5)).wait()?)
    }

    fn vendor_in(&self, request: u8, length: u16) -> Result<Vec<u8>> {
        let c = ControlIn { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, length };
        Ok(self.device.control_in(c, Duration::from_secs(5)).wait()?)
    }

    /// The firmware's state (1 ready for an image, 2 configuring, 4 running).
    pub fn fx3_state(&self) -> Result<u8> {
        Ok(self.vendor_in(VREQ_GET_STATUS, 1)?.first().copied().unwrap_or(0))
    }

    /// Poll the firmware state every 10 ms (1/500 of the shortest limit
    /// below, so at most 500 one-byte reads) until it reaches `want`.
    /// The limits are firmware work, not data: 5 s to accept an image and to
    /// start running, 10 s to configure, the longest because it writes the
    /// whole image in 512-byte requests.
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
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Load an FPGA image (the .bin the build writes) and start the bus.
    pub fn load_fpga(&mut self, image: &[u8]) -> Result<()> {
        self.vendor_out(VREQ_FPGA_CONFIG, &[0])?;
        self.wait_state(STATE_FPGA_READY, Duration::from_secs(5))?;
        self.vendor_out(VREQ_FPGA_START, &[0])?;
        self.wait_state(STATE_CONFIGURING, Duration::from_secs(10))?;
        for chunk in image.chunks(VREQ_CHUNK) {
            self.vendor_out(VREQ_FPGA_DATA, chunk)?;
        }
        self.wait_state(STATE_RUNNING, Duration::from_secs(5))?;
        self.gpif_reset()?;
        // The FPGA answers once its clocks have locked and left reset; a
        // command sent earlier is lost. Ask every 100 ms, for up to 2 s:
        // 100 ms is 50 000 command packets at the bus rate, so each probe is
        // far longer than a healthy answer, and 20 probes cover clock lock
        // (the gate measures lock in milliseconds).
        for _ in 0..20 {
            match self.run_within(&[Op::Read { addr: crate::regs::ID }], Duration::from_millis(100)) {
                Err(Error::Timeout(..)) => continue,
                r => return r.map(|_| ()),
            }
        }
        Err(Error::Timeout(self.sequence, Duration::from_secs(2)))
    }

    /// Restart the firmware's GPIF state machine (needed after every load).
    pub fn gpif_reset(&self) -> Result<()> {
        self.vendor_out(VREQ_GPIF_RESET, &[0; 4])
    }

    /// Run operations in one command packet; their results, in order.
    ///
    /// The deadline is [`CONTROL_TIMEOUT`] for the result to come back plus
    /// the operations' own WAIT/POLL time: a command packet is at most 1024
    /// bytes (2.6 us at the 400 MB/s ceiling), and the result is the same
    /// size, so the same one-second allowance covers both; anything the FPGA
    /// is told to wait or poll is added to it.
    pub fn exec(&mut self, ops: &[Op]) -> Result<Vec<Reply>> {
        // AT is deliberately not included: its delay is a tick count, and
        // this layer does not know the sample rate, so it cannot derive the
        // time. No command in this driver issues AT; a future caller must
        // resolve the time against the clock and use a deadline that covers
        // it.
        let extra: Duration = ops
            .iter()
            .map(|op| match *op {
                Op::Wait { us } => Duration::from_micros(us as u64),
                Op::Poll { ms, .. } => Duration::from_millis(ms as u64),
                Op::At { .. } | Op::Write { .. } | Op::Read { .. } | Op::Spi { .. } => Duration::ZERO,
            })
            .sum();
        self.run_within(ops, CONTROL_TIMEOUT.saturating_add(extra))
    }

    /// `exec` with an explicit result deadline, still checking the reply
    /// count. `load_fpga`'s readiness probe uses the shorter deadline.
    fn run_within(&mut self, ops: &[Op], limit: Duration) -> Result<Vec<Reply>> {
        let sequence = self.sequence;
        exact_count(self.exec_within(ops, limit)?, ops.len(), sequence)
    }

    /// Send one command packet and wait at most `limit` for its result.
    fn exec_within(&mut self, ops: &[Op], limit: Duration) -> Result<Vec<Reply>> {
        let sequence = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);
        let packet = proto::command(sequence, ops).map_err(Error::Proto)?;
        let (tx, rx) = mpsc::channel();
        lock(&self.shared.waiters).insert(sequence, tx);
        // The command buffer is one 1024-byte transfer, reused for every
        // command: zero-copy like the streaming buffers, and no mmap per
        // command during an AD9361 bring-up.
        let mut buf = self.cmd_buf.take().unwrap_or_else(|| {
            zero_copy(self.cmd.allocate(proto::CONTROL_BUFFER))
        });
        buf.clear();
        buf.extend_from_slice(&packet);
        let c = self.cmd.transfer_blocking(buf, CONTROL_TIMEOUT);
        let (buf, status) = (c.buffer, c.status);
        self.cmd_buf = Some(buf);
        if let Err(e) = status {
            self.shared.cancel(sequence);
            return Err(e.into());
        }
        match rx.recv_timeout(limit) {
            Ok(replies) => Ok(replies),
            Err(RecvTimeoutError::Timeout) => {
                self.shared.cancel(sequence);
                // If this command's result arrives after the deadline, the
                // reader finds no waiter and drops it. That is intentional:
                // it answers a command already reported as timed out, and no
                // later command reuses the sequence until 2^16 more have run.
                Err(Error::Timeout(sequence, limit))
            }
            Err(RecvTimeoutError::Disconnected) => {
                self.shared.cancel(sequence);
                Err(Error::ReaderStopped)
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
}

impl Drop for Ctrl {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        let Some(handle) = self.reader.take() else { return };
        match self.done.recv_timeout(SHUTDOWN_WAIT) {
            Ok(()) | Err(RecvTimeoutError::Disconnected) => {
                let _ = handle.join();
            }
            Err(RecvTimeoutError::Timeout) => {
                // Never hang in Drop. The reader owns its endpoint and shares
                // only Arcs with Ctrl, so detaching it (dropping the handle,
                // which does not join) is safe; it sees the stop flag within
                // one WAIT_TICK anyway.
                eprintln!("b210: warning: EP8 reader did not stop within {SHUTDOWN_WAIT:?}; detaching");
                drop(handle);
            }
        }
    }
}

impl Shared {
    fn cancel(&self, sequence: u16) {
        lock(&self.waiters).remove(&sequence);
    }

    /// Give `replies` to the command waiting for `sequence`. `false` means
    /// there was no waiter: a duplicate result, or a late one whose command
    /// already timed out.
    fn deliver(&self, sequence: u16, replies: Vec<Reply>) -> bool {
        let tx = lock(&self.waiters).remove(&sequence);
        match tx {
            Some(tx) => tx.send(replies).is_ok(),
            None => {
                self.late.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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

/// The reader thread: owns EP8 IN until `stop` is set.
fn read_loop(mut rsp: Endpoint<Bulk, In>, shared: Arc<Shared>) {
    set_realtime_priority();
    for _ in 0..RESULT_TRANSFERS {
        let b = zero_copy(rsp.allocate(proto::CONTROL_BUFFER));
        rsp.submit(b);
    }
    let mut pending = Vec::new();
    while !shared.stop.load(Ordering::Relaxed) {
        let Some(c) = rsp.wait_next_complete(WAIT_TICK) else { continue };
        let stopped = shared.stop.load(Ordering::Relaxed);
        let n = c.actual_len;
        // A cancelled transfer can still report the bytes it had; they are
        // part of the stream, so parse them before acting on the status.
        if n > 0 {
            pending.extend_from_slice(&c.buffer[..n]);
            ingest(&mut pending, &shared);
        }
        let buf = c.buffer;
        match c.status {
            Ok(()) => {
                if !stopped {
                    rsp.submit(buf);
                }
            }
            Err(TransferError::Cancelled) => {
                // Only shutdown cancels; the buffer is done.
                if !stopped {
                    warn_reader(&shared, "a transfer was cancelled unexpectedly");
                    rsp.submit(buf);
                }
            }
            Err(TransferError::Disconnected) => {
                warn_reader(&shared, "the board disconnected");
                break;
            }
            Err(e) => {
                if stopped {
                    break;
                }
                warn_reader(&shared, &format!("{e}"));
                if matches!(e, TransferError::Stall) {
                    // Clear the halt and refill; pending transfers will come
                    // back as errors and be replaced by the loop.
                    let _ = rsp.clear_halt().wait();
                }
                rsp.submit(buf);
                // Do not spin on a persistent fault: one retry per WAIT_TICK.
                thread::sleep(WAIT_TICK);
            }
        }
    }
    // Leave no transfer queued on an endpoint about to be dropped; bounded
    // because cancellation is asynchronous.
    rsp.cancel_all();
    let deadline = Instant::now() + SHUTDOWN_WAIT;
    while rsp.pending() > 0 && Instant::now() < deadline {
        // A cancelled transfer is returned at once; 50 ms is only the bound
        // for one that is not, half the shutdown budget per attempt.
        if rsp.wait_next_complete(Duration::from_millis(50)).is_none() {
            break;
        }
    }
}

/// One line for the first EP8 transfer error; a persistent fault must not
/// fill the terminal while the reader backs off.
fn warn_reader(shared: &Shared, message: &str) {
    if !shared.reader_warned.swap(true, Ordering::Relaxed) {
        eprintln!("b210: EP8 reader: {message}");
    }
}

/// Append `frame`'s contents to the register/event queues.
fn dispatch(frame: &[u8], shared: &Shared) {
    // `frame_ranges` has already validated the header.
    let Ok(h) = Header::decode(frame) else { return };
    let body = &frame[proto::HEADER..h.length as usize];
    match h.kind {
        Kind::Result => {
            shared.deliver(h.sequence, proto::replies(body));
        }
        Kind::Event => {
            let events = proto::events(body);
            // Full queue: the counters in `regs::EVENTS` still hold the
            // increases, so dropping the packet loses no information.
            let _ = shared.events.try_send(events);
        }
        // Data and command packets never arrive on EP8.
        Kind::Rx | Kind::Tx | Kind::Command => {}
    }
}

/// The complete packets in `stream`: ranges of their wire bytes, where a
/// packet's size comes from its header's length L and the S(L) rule
/// (docs/PROTOCOL.md section 1). Everything after the last range is an
/// incomplete packet for the next transfer. Pure: the result depends only on
/// the concatenated stream, not on how it was split into transfers.
fn frame_ranges(stream: &[u8], buffer: usize) -> std::result::Result<Vec<Range<usize>>, proto::Error> {
    let mut frames = Vec::new();
    let mut at = 0;
    while stream.len() - at >= proto::HEADER {
        let h = Header::decode(&stream[at..at + proto::HEADER])?;
        let size = proto::transfer_size(h.length as usize, buffer);
        if size > buffer {
            // A length just below the buffer that rounds up to a multiple of
            // 1024 is padded by 4 and no longer fits the buffer; no control
            // packet can have such a length.
            return Err(proto::Error::Length(h.length));
        }
        if at + size > stream.len() {
            break;
        }
        frames.push(at..at + size);
        at += size;
    }
    Ok(frames)
}

/// Consume every complete packet in `pending`, keeping the tail for the next
/// transfer. An unparseable stream is dropped as a whole (counted once):
/// there is no length to resynchronise on.
fn ingest(pending: &mut Vec<u8>, shared: &Shared) {
    match frame_ranges(pending, proto::CONTROL_BUFFER) {
        Ok(frames) => {
            let used = frames.last().map_or(0, |r| r.end);
            for r in frames {
                dispatch(&pending[r], shared);
            }
            pending.drain(..used);
        }
        Err(e) => {
            if shared.protocol_errors.fetch_add(1, Ordering::Relaxed) == 0 {
                eprintln!("b210: EP8: bad packet stream ({e:?}); dropping {} buffered bytes", pending.len());
            }
            pending.clear();
        }
    }
}

/// Put this thread in SCHED_FIFO at [`RT_PRIORITY`]. Never fatal: without
/// RLIMIT_RTPRIO >= the priority (or root) the kernel refuses, and a normal
/// thread is still correct, only more likely to lose a completion to
/// scheduling delay.
#[cfg(target_os = "linux")]
fn set_realtime_priority() {
    let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
    // SAFETY: getrlimit writes one `rlimit` through the pointer on success;
    // it is only assumed initialised in that branch.
    let limit = unsafe {
        if libc::getrlimit(libc::RLIMIT_RTPRIO, limit.as_mut_ptr()) == 0 {
            Some(limit.assume_init())
        } else {
            None
        }
    };
    let param = libc::sched_param { sched_priority: RT_PRIORITY };
    // SAFETY: pid 0 is this thread and `param` is a valid sched_param for
    // the duration of the call.
    let rc = unsafe { libc::sched_setscheduler(0, libc::SCHED_FIFO, &param) };
    if rc != 0 {
        let err = std::io::Error::last_os_error();
        match limit {
            Some(l) => {
                let (cur, max) = (l.rlim_cur, l.rlim_max);
                eprintln!(
                    "b210: warning: EP8 reader stays a normal thread ({err}); \
                     RLIMIT_RTPRIO is {cur} of {max}, raise it with `ulimit -r {RT_PRIORITY}`"
                )
            }
            None => eprintln!("b210: warning: EP8 reader stays a normal thread ({err})"),
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn set_realtime_priority() {}

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

/// One 0xA0 write moves at most 4 KiB; the bootloader runs at USB 2 high
/// speed (64-byte control packets, 64 of them at 480 Mb/s, well under a
/// millisecond). 1 s is 1000x that and only bounds a ROM that stopped
/// answering.
const BOOT_WRITE_TIMEOUT: Duration = Duration::from_secs(1);

/// From the jump to a usable 2500:0020. UHD allows 1 s for the firmware to
/// settle (b200_iface.cpp `load_firmware`) and then 3 s to find the
/// re-enumerated device (b200_impl.cpp REENUMERATION_TIMEOUT_MS): 4 s. 10 s
/// is 2.5x UHD's budget, slack for udev applying the device's permissions.
pub const FIRMWARE_BOOT_WAIT: Duration = Duration::from_secs(10);
/// 1/10 of UHD's 1 s settle time: at most 100 sysfs enumerations in
/// [`FIRMWARE_BOOT_WAIT`], and the device is used within 100 ms of being ready.
const FIRMWARE_POLL: Duration = Duration::from_millis(100);

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
    use crate::proto::{flag, Format};

    fn header(length: u16, kind: Kind, sequence: u16) -> Header {
        Header {
            length,
            kind,
            format: Format::None,
            channels: 0,
            sequence,
            flags: if kind == Kind::Event { flag::HAS_TIME } else { 0 },
            time: 0,
        }
    }

    /// A packet padded to its wire size S(L).
    fn packet(length: usize, kind: Kind, sequence: u16) -> Vec<u8> {
        let size = proto::transfer_size(length, proto::CONTROL_BUFFER);
        let mut p = vec![0u8; size];
        p[..proto::HEADER].copy_from_slice(&header(length as u16, kind, sequence).encode());
        p
    }

    /// Feed `chunks` the way the reader does and return the packets it saw.
    fn split_chunks(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        let mut pending = Vec::new();
        let mut out = Vec::new();
        for chunk in chunks {
            pending.extend_from_slice(chunk);
            match frame_ranges(&pending, proto::CONTROL_BUFFER) {
                Ok(frames) => {
                    let used = frames.last().map_or(0, |r| r.end);
                    for r in frames {
                        out.push(pending[r].to_vec());
                    }
                    pending.drain(..used);
                }
                Err(e) => panic!("{e:?}"),
            }
        }
        out
    }

    #[test]
    fn splitter_keeps_awkward_sizes_across_transfer_boundaries() {
        // A table with full 1024-byte packets, packets whose pad is 4 (none:
        // 1021..1023 are invalid on a control endpoint), header-only packets
        // and lengths on both sides of 1024.
        let lengths = [16usize, 20, 24, 1008, 1016, 1024, 16, 1024, 1008, 24];
        let mut stream = Vec::new();
        for (i, &len) in lengths.iter().enumerate() {
            let kind = if i % 2 == 0 { Kind::Result } else { Kind::Event };
            stream.extend_from_slice(&packet(len, kind, i as u16));
        }
        let all: Vec<Vec<u8>> = lengths
            .iter()
            .enumerate()
            .map(|(i, &len)| packet(len, if i % 2 == 0 { Kind::Result } else { Kind::Event }, i as u16))
            .collect();

        // The same stream cut in awkward places: an 8-byte and a 15-byte
        // first chunk split the first header in two; cuts at 1023/1024/1025
        // straddle a full packet; one byte at a time proves the leftover.
        let cuts: &[&[usize]] = &[
            &[8, 20, stream.len()],
            &[15, 16, stream.len()],
            &[0, 1, 1023, 1024, 1025, stream.len()],
            &[1024, 2048, 3 * 1024, stream.len()],
            &[16],
        ];
        for cuts in cuts {
            let mut chunks = Vec::new();
            let mut at = 0;
            for &cut in *cuts {
                chunks.push(&stream[at..cut]);
                at = cut;
            }
            if at < stream.len() {
                chunks.push(&stream[at..]);
            }
            assert_eq!(split_chunks(&chunks), all, "cuts {cuts:?}");
        }
        assert_eq!(split_chunks(&[&stream]), all);
    }

    #[test]
    fn splitter_waits_for_a_whole_header_and_a_whole_packet() {
        let p = packet(24, Kind::Result, 7);
        // A header split in two: 8 bytes, then the rest.
        assert!(split_chunks(&[&p[..8]]).is_empty());
        assert!(split_chunks(&[&p[..15]]).is_empty());
        assert_eq!(split_chunks(&[&p[..8], &p[8..]]), vec![p.clone()]);
        // 16 bytes is a whole header but not a whole packet.
        assert!(split_chunks(&[&p[..16]]).is_empty());
        // One byte short of the wire size: still pending, not a packet.
        assert!(split_chunks(&[&p[..p.len() - 1]]).is_empty());
        assert_eq!(split_chunks(&[&p[..p.len() - 1], &p[p.len() - 1..]]), vec![p]);
    }

    #[test]
    fn splitter_rejects_a_length_that_cannot_fit_the_control_buffer() {
        // L = 1021 rounds to 1024 and the rule adds 4, so S(L) = 1028 > 1024.
        let mut buf = vec![0u8; 1028];
        buf[..proto::HEADER].copy_from_slice(&header(1021, Kind::Result, 1).encode());
        assert_eq!(frame_ranges(&buf, proto::CONTROL_BUFFER), Err(proto::Error::Length(1021)));
        // Negative control: the largest valid non-full length is 1016.
        let mut ok = vec![0u8; 1016];
        ok[..proto::HEADER].copy_from_slice(&header(1016, Kind::Result, 1).encode());
        assert_eq!(frame_ranges(&ok, proto::CONTROL_BUFFER).unwrap().len(), 1);
    }

    fn reply(status: Status, data: u32) -> Reply {
        Reply { opcode: 2, status, addr: 3, data }
    }

    #[test]
    fn results_route_by_sequence_out_of_order_and_duplicates_are_dropped() {
        let shared = Shared {
            waiters: Mutex::new(HashMap::new()),
            events: mpsc::sync_channel(1).0,
            stop: AtomicBool::new(false),
            late: AtomicU64::new(0),
            protocol_errors: AtomicU64::new(0),
            reader_warned: AtomicBool::new(false),
        };
        let (tx10, rx10) = mpsc::channel();
        let (tx11, rx11) = mpsc::channel();
        lock(&shared.waiters).insert(10, tx10);
        lock(&shared.waiters).insert(11, tx11);

        // Out of order: 11 before 10.
        assert!(shared.deliver(11, vec![reply(Status::Ok, 11)]));
        assert!(shared.deliver(10, vec![reply(Status::Ok, 10)]));
        assert_eq!(rx10.recv().unwrap()[0].data, 10);
        assert_eq!(rx11.recv().unwrap()[0].data, 11);

        // A duplicate of 10 has no waiter left, and is not appended to 11.
        assert!(!shared.deliver(10, vec![reply(Status::Ok, 99)]));
        assert!(rx10.try_recv().is_err());
        assert_eq!(shared.late.load(Ordering::Relaxed), 1);

        // A sequence nobody waits for is dropped too (negative control).
        assert!(!shared.deliver(12, vec![reply(Status::Ok, 12)]));
        assert_eq!(shared.late.load(Ordering::Relaxed), 2);

        // A timed-out command's waiter is removed, so its late reply is
        // dropped rather than delivered to a later command.
        let (tx13, rx13) = mpsc::channel();
        lock(&shared.waiters).insert(13, tx13);
        shared.cancel(13);
        assert!(!shared.deliver(13, vec![reply(Status::Ok, 13)]));
        assert!(rx13.try_recv().is_err());
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
    fn status_mapping_is_protocol_section_4() {
        // One result per status code, decoded through proto::replies, the one
        // place that maps wire codes to Status.
        let mut payload = Vec::new();
        for (status, data) in [(0u8, 0x11u32), (1, 0x22), (2, 0x33), (3, 0x44), (7, 0x55)] {
            let a = 2u32 << 24 | (status as u32) << 16 | 3;
            payload.extend_from_slice(&a.to_le_bytes());
            payload.extend_from_slice(&data.to_le_bytes());
        }
        let r = proto::replies(&payload);
        assert_eq!(r[0].status, Status::Ok);
        assert!(r[0].status.is_ok());
        assert_eq!(r[2].status, Status::Late);
        assert_eq!(r[3].status, Status::UnknownOp);
        assert_eq!(r[4].status, Status::Other(7));
        assert_eq!(r[1].status, Status::Timeout);
        assert!(!r[1].status.is_ok(), "a POLL timeout is a legitimate non-ok reply");
        assert_eq!(r[1].status.to_string(), "timeout (poll)");
        assert_eq!(r[3].status.to_string(), "unknown opcode/argument");
        // Negative control: only status 0 counts as ok.
        assert!(r[1..].iter().all(|r| !r.status.is_ok()));
    }

    #[test]
    fn read_and_write_reject_non_ok_results_but_poll_timeout_stays_visible() {
        let ok = check_reply(reply(Status::Ok, 7)).unwrap();
        assert_eq!(ok.data, 7);
        let err = check_reply(reply(Status::Timeout, 0)).unwrap_err();
        assert!(matches!(err, Error::Status { status: Status::Timeout, .. }));
        assert_eq!(err.to_string(), "opcode 2 at 0x0003: timeout (poll)");
        // `exec` itself does not reject it: that is how a POLL timeout is
        // reported to its caller.
        let replies = vec![reply(Status::Timeout, 0)];
        assert_eq!(exact_count(replies.clone(), 1, 0).unwrap(), replies);
    }

    #[test]
    fn depth_ms_to_transfer_count_boundaries() {
        let total = |ms: f64| depth_transfers(ms, BUS_BYTES_PER_SEC);
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
        // Negative control: flooring instead of rounding up would
        // under-allocate; also never plan less than the requested time.
        assert_ne!(total(1.0), 24);
        for ms in [1.0, 2.0, 8.0, 33.0, 100.0] {
            let n = total(ms);
            let bytes = BUS_BYTES_PER_SEC * ms / 1000.0;
            assert!((n * proto::DATA_BUFFER) as f64 >= bytes, "{ms} ms");
            assert!(n >= 1);
        }
        // The transfer size stays a whole number of max packets.
        assert_eq!(proto::DATA_BUFFER % MAX_PACKET, 0);
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
