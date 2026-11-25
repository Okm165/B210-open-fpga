//! b210 - board access and the step-1 measurements.
//!
//!   b210 load IMAGE.bin            load the FPGA, start the bus
//!   b210 state | read ADDR | write ADDR VALUE
//!   b210 monitor                   live health: status, rate, counters, rings
//!   b210 rx-test [options]         stream the FPGA's pattern f(t)
//!   b210 loop-test [options]       one timed tx burst through the FPGA's
//!                                  loopback, rx running the whole time
//!   b210 capture [options]         one file per channel, then b210-plot
//!
//! Every streaming command checks every sample time that arrives: its
//! values against what that tick must carry, the times contiguous (a gap is
//! counted as lost and must carry OVERFLOW), sequence +1 per packet; and
//! compares the FPGA's event counters before and after.

use anyhow::{bail, Context, Result};
use b210::proto::{self, flag, Format, Header, Kind, Op};
use b210::regs::{self, rx, rx_source};
use b210::usb::{zero_copy, Ctrl, Usb, DEPTH_MS_DEFAULT};
use clap::{Args, Parser, Subcommand};
use nusb::transfer::{Bulk, In, Out};
use nusb::Endpoint;
use std::time::{Duration, Instant};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Load an FPGA image and start the bus
    Load { image: std::path::PathBuf },
    /// The FX3 firmware's state (1 ready for an image, 2 configuring, 4 running)
    State,
    /// Read a register (hex 0x.. or decimal address)
    Read { addr: String },
    /// Write a register
    Write { addr: String, value: String },
    /// Stream the pattern f(t); every sample and timestamp checked
    RxTest(StreamArgs),
    /// One timed tx burst through the FPGA loopback, back on rx at its tick
    LoopTest(StreamArgs),
    /// Live health: status, event counters, USB events, once per interval
    Monitor {
        /// ms between readings
        #[arg(long, default_value_t = 500)]
        interval_ms: u64,
    },
    /// Stream the rx source into one file per channel, every sample checked
    Capture {
        #[command(flatten)]
        stream: StreamArgs,
        #[command(flatten)]
        capture: CaptureArgs,
    },
}

#[derive(Args)]
struct CaptureArgs {
    /// file name prefix: PREFIX_ch0.raw, PREFIX_ch1.raw (+ .toml sidecars)
    #[arg(long, default_value = "capture.raw")]
    out: std::path::PathBuf,
    /// pattern: the FPGA's f(t); tone: a host tone through tx and the loopback
    #[arg(long, default_value = "tone")]
    source: String,
    /// tone frequency, Hz (channel 0 at +f, channel 1 at -f)
    #[arg(long, default_value_t = 1.234_567e6, allow_hyphen_values = true)]
    tone_hz: f64,
    /// tone level, dBFS (0 = full scale)
    #[arg(long, default_value_t = -1.0, allow_hyphen_values = true)]
    tone_dbfs: f64,
}

#[derive(Args)]
struct StreamArgs {
    #[arg(long, default_value_t = 10.0)]
    seconds: f64,
    /// sc16 or sc12
    #[arg(long, default_value = "sc12")]
    format: String,
    /// 1 or 2
    #[arg(long, default_value_t = 2)]
    channels: u32,
    /// a sample strobe every DIV + 1 cycles of the 61.54 MHz test clock
    #[arg(long, default_value_t = 1)]
    div: u32,
    /// host buffering per direction, ms of the 400 MB/s bus limit (1..100)
    #[arg(long, default_value_t = DEPTH_MS_DEFAULT)]
    depth_ms: f64,
}

/// The step-1 test sample clock: 1200 MHz / 19.5 (fpga/rtl/b210.v).
const TEST_CLOCK: f64 = 1200e6 / 19.5;

/// One stream's shape.
#[derive(Clone, Copy)]
struct Shape {
    format: Format,
    code: u32,
    mask: u8,
    nch: usize,
    rate: f64,
}

impl Shape {
    fn new(a: &StreamArgs) -> Result<Shape> {
        let (format, code) = match a.format.as_str() {
            "sc16" => (Format::Sc16, 1),
            "sc12" => (Format::Sc12, 2),
            _ => bail!("format: sc16 or sc12"),
        };
        let mask = match a.channels { 1 => 0b01, 2 => 0b11, _ => bail!("channels: 1 or 2") };
        Ok(Shape { format, code, mask, nch: a.channels as usize, rate: TEST_CLOCK / (a.div as f64 + 1.0) })
    }
    fn per_packet(&self) -> usize {
        self.format.times_per_packet(self.nch)
    }
    fn mbytes(&self) -> f64 {
        self.rate * self.format.bytes_per_time(self.nch) as f64 / 1e6
    }
}

fn number(s: &str) -> Result<u32> {
    Ok(match s.strip_prefix("0x") {
        Some(h) => u32::from_str_radix(h, 16)?,
        None => s.parse()?,
    })
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    // Buffering is planned before the endpoints open; commands that do not
    // stream still use the default so the usbfs check has one plan.
    let depth_ms = match &cli.cmd {
        Cmd::RxTest(a) | Cmd::LoopTest(a) | Cmd::Capture { stream: a, .. } => a.depth_ms,
        _ => DEPTH_MS_DEFAULT,
    };
    let mut usb = Usb::open(depth_ms)?;
    match cli.cmd {
        Cmd::Load { image } => {
            let bytes = std::fs::read(&image).with_context(|| format!("{}", image.display()))?;
            let start = Instant::now();
            usb.ctrl.load_fpga(&bytes)?;
            let id = usb.ctrl.read(regs::ID)?;
            println!("loaded {} ({} bytes) in {:.1} s; id {id:08x}, version {:08x}, build {:08x}",
                     image.display(), bytes.len(), start.elapsed().as_secs_f64(),
                     usb.ctrl.read(regs::VERSION)?, usb.ctrl.read(regs::BUILD)?);
            if id != regs::ID_VALUE {
                bail!("id {id:08x}, expected {:08x}", regs::ID_VALUE);
            }
        }
        Cmd::State => println!("{}", usb.ctrl.fx3_state()?),
        Cmd::Read { addr } => println!("{:08x}", usb.ctrl.read(number(&addr)? as u16)?),
        Cmd::Write { addr, value } => usb.ctrl.write(number(&addr)? as u16, number(&value)?)?,
        Cmd::RxTest(a) => rx_test(&mut usb, &a)?,
        Cmd::LoopTest(a) => loop_test(&mut usb, &a)?,
        Cmd::Monitor { interval_ms } => monitor(&mut usb, interval_ms)?,
        Cmd::Capture { stream, capture: c } => capture(&mut usb, &stream, &c)?,
    }
    Ok(())
}

// -- the FPGA's counters --------------------------------------------------------------------

/// Event counters by code 1 .. 6 (index code - 1), then rx_cdc_lost.
fn counters(ctrl: &mut Ctrl) -> Result<[u32; 7]> {
    let ops: Vec<Op> = (0..6).map(|k| Op::Read { addr: regs::EVENTS + k })
        .chain([Op::Read { addr: regs::RX_CDC_LOST }]).collect();
    let r = ctrl.exec(&ops)?;
    Ok(std::array::from_fn(|i| r[i].data))
}

const CODES: [&str; 6] = ["OVERFLOW", "UNDERFLOW", "LATE", "SEQ_ERROR", "BURST_ACK", "BAD_PACKET"];

/// Every counter rose by exactly what `want` says (BURST_ACK and the rest).
fn check_counters(before: &[u32; 7], after: &[u32; 7], want: [u32; 7]) -> bool {
    let mut ok = true;
    for i in 0..7 {
        let d = after[i].wrapping_sub(before[i]);
        let name = if i < 6 { CODES[i] } else { "rx_cdc_lost" };
        if d != want[i] {
            println!("  FPGA {name}: +{d}, expected +{}", want[i]);
            ok = false;
        }
    }
    ok
}

/// Every counter's increase, pass or fail. No ring-fill register exists in
/// docs/PROTOCOL.md section 6, so there is none to report.
fn report_counters(before: &[u32; 7], after: &[u32; 7]) {
    let d = |i: usize| after[i].wrapping_sub(before[i]);
    println!("counters: {} +{} {} +{} {} +{} {} +{} {} +{} {} +{} rx_cdc_lost +{}",
             CODES[0], d(0), CODES[1], d(1), CODES[2], d(2),
             CODES[3], d(3), CODES[4], d(4), CODES[5], d(5), d(6));
}

/// Events the EP8 reader queued, for information only: every count is also
/// in the registers printed above and accumulating there is lossless.
fn report_events(ctrl: &Ctrl) {
    let n = ctrl.drain_events().len();
    if n > 0 {
        println!("usb events: {n} records (informational; the registers above are authoritative)");
    }
}

/// The time now (time_lo latches time_hi: both read in one command).
fn now(ctrl: &mut Ctrl) -> Result<u64> {
    let r = ctrl.exec(&[Op::Read { addr: regs::TIME_LO }, Op::Read { addr: regs::TIME_HI }])?;
    Ok(r[0].data as u64 | (r[1].data as u64) << 32)
}

// -- rx: one stream loop for every command ---------------------------------------------------

/// What an rx stream showed.
#[derive(Default)]
struct Tally {
    packets: u64,
    samples: u64,
    lost: u64,
    overflow_flags: u64,
    bad_values: u64,
    bad_headers: u64,
    first: Option<u64>,
    /// time and sequence the next packet must carry
    next: Option<(u64, u16)>,
}

impl Tally {
    fn report(&self, seconds: f64) {
        println!("rx: {} packets, {} sample times in {seconds:.2} s = {:.3} MS/s", self.packets, self.samples,
                 self.samples as f64 / seconds / 1e6);
        println!("rx: lost {} sample times ({} packets flagged OVERFLOW); bad values {}, bad headers {}",
                 self.lost, self.overflow_flags, self.bad_values, self.bad_headers);
    }
    fn clean(&self) -> bool {
        self.lost == 0 && self.bad_values == 0 && self.bad_headers == 0 && self.overflow_flags == 0
    }
    /// One data packet's header against the stream so far: kind, format and
    /// channels as configured, HAS_TIME, times contiguous unless OVERFLOW
    /// says samples were dropped (then the gap is counted lost), sequence
    /// +1. Returns false for a header that must not be used.
    fn header(&mut self, h: &Header, s: Shape, n: usize) -> bool {
        if h.format != s.format || h.channels != s.mask || h.flags & flag::HAS_TIME == 0 {
            self.bad_headers += 1;
            return false;
        }
        let overflow = h.flags & flag::OVERFLOW != 0;
        if let Some((time, seq)) = self.next {
            let gap = proto::lost(time, 0, h.time);
            if h.sequence != seq || gap < 0 || (gap > 0) != overflow {
                self.bad_headers += 1;
            }
            self.lost += gap.max(0) as u64;
        }
        self.overflow_flags += overflow as u64;
        self.first.get_or_insert(h.time);
        self.packets += 1;
        self.samples += n as u64;
        self.next = Some((h.time + n as u64, h.sequence.wrapping_add(1)));
        true
    }
}

/// Fetch and discard whatever a previous stream left on the endpoint: a
/// stopped stream's packets (and its END_OF_BURST) sit in the FX3's DMA
/// channel, and the next run must begin with an empty one. 100 ms is ~25
/// packets at the slowest test rate, far more than any leftover; the loop
/// ends at the first transfer that does not complete.
fn flush_rx(rx: &mut Endpoint<Bulk, In>) {
    let deadline = Instant::now() + Duration::from_millis(100);
    rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        if rx.wait_next_complete(left).is_none() { break; }
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    rx.cancel_all();
    while rx.pending() > 0 { rx.wait_next_complete(Duration::from_millis(100)); }
}

/// Run one rx stream: flush the endpoint, start the stream (continuous),
/// hand every data packet's header and unpacked values (I0 Q0 [I1 Q1] per
/// sample time) to `packet`, send STOP once `packet` returns true, and
/// return when the stream's END_OF_BURST has arrived (seconds streamed).
///
/// Packets are walked by their length, not by transfer: a transfer may end
/// inside a packet or hold several (PROTOCOL.md 1, S(L)). An END_OF_BURST
/// before any data packet belongs to a stopped earlier stream and is
/// ignored. A header that cannot be decoded is counted in `t.bad_headers`.
fn rx_stream(rx: &mut Endpoint<Bulk, In>, ctrl: &mut Ctrl, s: Shape, depth: usize, t: &mut Tally,
             mut packet: impl FnMut(&Header, &[i16], &mut Tally) -> Result<bool>) -> Result<f64> {
    let nv = 2 * s.nch;
    let bpt = s.format.bytes_per_time(s.nch);
    ctrl.write(regs::RX_SPP, s.per_packet() as u32)?;
    ctrl.write(regs::RX_COUNT, 0)?;
    flush_rx(rx);
    for _ in 0..depth {
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    ctrl.write(regs::RX_CTRL, rx::START | rx::config(s.code, s.mask as u32))?;
    let start = Instant::now();
    let mut values = vec![0i16; 4 * 8192];
    let mut bytes: Vec<u8> = Vec::with_capacity(2 * proto::DATA_BUFFER);
    let (mut stopping, mut ended, mut data_seen) = (false, false, false);
    while !ended {
        // 2 s without a transfer is a stalled stream, not a slow host: at
        // the slowest test rate a 16 KiB packet takes a few milliseconds
        let c = rx.wait_next_complete(Duration::from_secs(2)).context("no rx transfer for 2 s")?;
        let n = c.actual_len;
        let buf = c.into_result()?;
        bytes.extend_from_slice(&buf[..n]);
        rx.submit(buf);
        let mut at = 0;
        while bytes.len() - at >= proto::HEADER {
            let length = u16::from_le_bytes([bytes[at], bytes[at + 1]]) as usize;
            let size = proto::transfer_size(length, proto::DATA_BUFFER);
            if bytes.len() - at < size { break; }
            let p = &bytes[at..at + size];
            at += size;
            let h = match Header::decode(p) {
                Ok(h) if h.kind == Kind::Rx => h,
                _ => { t.bad_headers += 1; continue; }
            };
            let payload = h.length as usize - proto::HEADER;
            if payload > 0 {
                if !payload.is_multiple_of(bpt) { t.bad_headers += 1; continue; }
                let k = payload / bpt;
                let body = &p[proto::HEADER..proto::HEADER + payload];
                match s.format {
                    Format::Sc16 => proto::unpack_sc16(body, &mut values[..k * nv]),
                    _ => proto::unpack_sc12(body, &mut values[..k * nv]),
                }
                data_seen = true;
                if packet(&h, &values[..k * nv], t)? && !stopping {
                    ctrl.write(regs::RX_CTRL, rx::STOP)?;
                    stopping = true;
                }
            }
            ended |= data_seen && h.flags & flag::END_OF_BURST != 0;
        }
        bytes.drain(..at);
    }
    let seconds = start.elapsed().as_secs_f64();
    rx.cancel_all();
    // cancelled transfers return at once; 1 s bounds a kernel that does not
    while rx.pending() > 0 { rx.wait_next_complete(Duration::from_secs(1)); }
    Ok(seconds)
}

/// Check every sample time of a packet against `expect(t)` (the four values
/// I0 Q0 I1 Q1 tick t must carry); print the first few mismatches.
fn check_values(h: &Header, v: &[i16], s: Shape, expect: &impl Fn(u64) -> [i16; 4], t: &mut Tally) {
    let nv = 2 * s.nch;
    for (k, got) in v.chunks(nv).enumerate() {
        let time = h.time + k as u64;
        let e = expect(time);
        for (j, g) in got.iter().enumerate() {
            if *g != e[j] {
                if t.bad_values < 5 { eprintln!("time {time} value {j}: {g}, expected {}", e[j]); }
                t.bad_values += 1;
            }
        }
    }
}

// -- the tests ----------------------------------------------------------------------------------

fn setup(ctrl: &mut Ctrl, source: u32, div: u32) -> Result<[u32; 7]> {
    ctrl.write(regs::RX_CTRL, rx::STOP)?;
    ctrl.write(regs::RX_SOURCE, source)?;
    ctrl.write(regs::STROBE_DIV, div)?;
    counters(ctrl)
}

fn rx_test(usb: &mut Usb, a: &StreamArgs) -> Result<()> {
    let s = Shape::new(a)?;
    println!("rx-test {} x{}: {:.3} MS/s, {:.1} MB/s", a.format, a.channels, s.rate / 1e6, s.mbytes());
    let before = setup(&mut usb.ctrl, rx_source::PATTERN, a.div)?;
    let pattern = |t: u64| std::array::from_fn(|k| rx_source::pattern(t, k));
    let depth = usb.depth;
    let begin = Instant::now();
    let mut tally = Tally::default();
    let seconds = rx_stream(&mut usb.rx, &mut usb.ctrl, s, depth, &mut tally, |h, v, t| {
        if t.header(h, s, v.len() / (2 * s.nch)) { check_values(h, v, s, &pattern, t); }
        Ok(begin.elapsed().as_secs_f64() >= a.seconds)
    })?;
    tally.report(seconds);
    let after = counters(&mut usb.ctrl)?;
    let counters_ok = check_counters(&before, &after, [0; 7]);
    report_counters(&before, &after);
    report_events(&usb.ctrl);
    if !(counters_ok & tally.clean()) {
        bail!("rx-test FAILED");
    }
    println!("rx-test PASSED: every sample time checked, none lost");
    Ok(())
}

/// The value k (I0 Q0 I1 Q1) of burst sample i: 12 bits of a 64-bit hash,
/// never 0, so a sample missing from the burst cannot pass as idle.
fn burst_value(i: u64, k: usize) -> i16 {
    let x = i.wrapping_add(1).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> (12 * k + 8);
    let v = (x as u16 & 0xFFF).max(1);
    ((v << 4) as i16) >> 4
}

/// Send `n` sample times as one burst starting at tick `at`, value v of
/// sample time i being `value(i, v)` (v: I0 Q0 [I1 Q1]): full packets, the
/// last one shorter; START_OF_BURST + HAS_TIME on the first, END_OF_BURST
/// on the last. Returns the packets sent.
fn tx_burst(tx: &mut Endpoint<Bulk, Out>, s: Shape, at: u64, n: u64, depth: usize, wait: Duration,
            value: impl Fn(u64, usize) -> i16) -> Result<u64> {
    let per = s.per_packet() as u64;
    let packets = n.div_ceil(per);
    let mut scratch = vec![0u8; proto::DATA_BUFFER];
    let mut values = vec![0i16; 4 * per as usize];
    for p in 0..packets {
        let i0 = p * per;
        let m = per.min(n - i0);
        let nv = 2 * s.nch;
        for i in 0..m as usize {
            for v in 0..nv {
                values[i * nv + v] = value(i0 + i as u64, v);
            }
        }
        let mut flags = flag::HAS_TIME;
        if p == 0 { flags |= flag::START_OF_BURST; }
        if p == packets - 1 { flags |= flag::END_OF_BURST; }
        let h = Header { length: 0, kind: Kind::Tx, format: s.format, channels: s.mask,
                         sequence: p as u16, flags, time: at + i0 };
        let size = proto::tx_packet(h, &values[..m as usize * nv], &mut scratch);
        let mut buf = if tx.pending() < depth {
            zero_copy(tx.allocate(proto::DATA_BUFFER))
        } else {
            tx.wait_next_complete(wait).context("tx transfer did not complete")?.into_result()?
        };
        buf.clear();
        buf.extend_from_slice(&scratch[..size]);
        tx.submit(buf);
    }
    while tx.pending() > 0 {
        tx.wait_next_complete(wait).context("tx transfer did not complete")?.into_result()?;
    }
    Ok(packets)
}

fn loop_test(usb: &mut Usb, a: &StreamArgs) -> Result<()> {
    let s = Shape::new(a)?;
    println!("loop-test {} x{}: {:.3} MS/s, {:.1} MB/s each way", a.format, a.channels, s.rate / 1e6, s.mbytes());
    let before = setup(&mut usb.ctrl, rx_source::LOOPBACK, a.div)?;
    let lead = 0.3;                                       // s from now to the burst
    let at = now(&mut usb.ctrl)? + (lead * s.rate) as u64;
    let n = (a.seconds * s.rate) as u64;
    let end = at + n;
    let tail = (0.02 * s.rate) as u64;                    // rx keeps going this long after the burst
    let expect = move |t: u64| -> [i16; 4] {
        if t >= at && t < end { std::array::from_fn(|k| burst_value(t - at, k)) } else { [0; 4] }
    };
    let depth = usb.depth;
    let Usb { ctrl, tx, rx, .. } = usb;
    let mut tally = Tally::default();
    let (rx_result, tx_result) = std::thread::scope(|scope| {
        // The burst starts after `lead`; 5 s on top of it is over 1000
        // 16 KiB packets at the bus rate, so a transfer that has not
        // completed by then is stuck, not merely queued.
        let wait = Duration::from_secs_f64(lead + 5.0);
        let sender = scope.spawn(move || tx_burst(tx, s, at, n, depth, wait, burst_value));
        let r = rx_stream(rx, ctrl, s, depth, &mut tally, |h, v, t| {
            if t.header(h, s, v.len() / (2 * s.nch)) { check_values(h, v, s, &expect, t); }
            Ok(t.next.is_some_and(|(time, _)| time >= end + tail))
        });
        (r, sender.join().expect("tx thread"))
    });
    let seconds = rx_result?;
    let packets = tx_result?;
    tally.report(seconds);
    println!("tx: {n} samples in {packets} packets, burst at tick {at}");
    let covered = tally.first.is_some_and(|f| f <= at) && tally.next.is_some_and(|(t, _)| t >= end);
    if !covered {
        println!("  rx did not cover the whole burst");
    }
    let mut want = [0; 7];
    want[4] = 1;                                          // one BURST_ACK
    let after = counters(ctrl)?;
    let counters_ok = check_counters(&before, &after, want);
    report_counters(&before, &after);
    report_events(ctrl);
    if !(counters_ok & tally.clean() & covered) {
        bail!("loop-test FAILED");
    }
    println!("loop-test PASSED: all {n} tx samples back on rx at exactly their ticks, zeros around them");
    Ok(())
}

// -- live health ---------------------------------------------------------------------------------

/// One reading of the board's health, all registers in one command packet
/// (so they describe the same moment, to within the 13 reads' ~2 us).
struct Health {
    status: u32,
    rx_running: bool,
    sample_ksps: u32,
    /// event codes 1 .. 6, rx_cdc_lost, cmd_dropped
    counts: [u32; 8],
    rx_used: u32,
    rx_hwm: u32,
    tx_used: u32,
    tx_hwm: u32,
    time: u64,
}

fn health(ctrl: &mut Ctrl) -> Result<Health> {
    let addrs = [regs::STATUS, regs::RX_CTRL, regs::SAMPLE_RATE, regs::EVENTS, regs::EVENTS + 1, regs::EVENTS + 2,
                 regs::EVENTS + 3, regs::EVENTS + 4, regs::EVENTS + 5, regs::RX_CDC_LOST, regs::CMD_DROPPED,
                 regs::RX_USED, regs::RX_HWM, regs::TX_USED, regs::TX_HWM, regs::TIME_LO, regs::TIME_HI];
    let r: Vec<u32> = ctrl.exec(&addrs.map(|addr| Op::Read { addr }))?.iter().map(|x| x.data).collect();
    Ok(Health {
        status: r[0], rx_running: r[1] & 1 != 0, sample_ksps: r[2],
        counts: std::array::from_fn(|i| r[3 + i]),
        rx_used: r[11], rx_hwm: r[12], tx_used: r[13], tx_hwm: r[14],
        time: r[15] as u64 | (r[16] as u64) << 32,
    })
}

/// Watch the board until interrupted. Each line: status (clocks locked,
/// sample clock running), the measured sample rate, both rings' fill now
/// and at most since the last line (the marks are cleared after each read),
/// and how much every counter rose. Every counter rising except BURST_ACK
/// is trouble: OVERFLOW = rx samples dropped, UNDERFLOW = tx ran dry in a
/// burst, LATE = a burst came after its time, SEQ_ERR / BAD_PKT = broken tx
/// packets, cdc_lost = a design error, cmd_drop = malformed commands.
fn monitor(usb: &mut Usb, interval_ms: u64) -> Result<()> {
    // fast enough to see a burst or a fault; the 17 reads per line take a
    // few microseconds of the bus, so even 50 ms costs nothing
    let interval = Duration::from_millis(interval_ms.max(50));
    let ring = |used: u32, words: u32| 100.0 * used as f64 / words as f64;
    let mut last = health(&mut usb.ctrl)?;
    usb.ctrl.write(regs::RX_HWM, 0)?;
    usb.ctrl.write(regs::TX_HWM, 0)?;
    println!("lock clk  rate MS/s  rx ring % (max)  tx ring % (max)  OVERFLOW UNDERFLOW LATE SEQ_ERR BURST_ACK BAD_PKT cdc_lost cmd_drop");
    loop {
        std::thread::sleep(interval);
        let h = health(&mut usb.ctrl)?;
        usb.ctrl.write(regs::RX_HWM, 0)?;
        usb.ctrl.write(regs::TX_HWM, 0)?;
        let d: [u32; 8] = std::array::from_fn(|i| h.counts[i].wrapping_sub(last.counts[i]));
        println!("{:>4} {:>3}  {:>9.3}  {:>6.1} ({:>5.1})   {:>6.1} ({:>5.1})   {:>8} {:>9} {:>4} {:>7} {:>9} {:>7} {:>8} {:>8}{}",
                 if h.status & 1 != 0 { "ok" } else { "NO" }, if h.status & 2 != 0 { "ok" } else { "NO" },
                 h.sample_ksps as f64 / 1e3,
                 ring(h.rx_used, regs::RX_RING_WORDS), ring(h.rx_hwm, regs::RX_RING_WORDS),
                 ring(h.tx_used, regs::TX_RING_WORDS), ring(h.tx_hwm, regs::TX_RING_WORDS),
                 d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                 if h.rx_running { "  rx streaming" } else { "" });
        if h.time <= last.time && h.status & 2 != 0 {
            println!("  the sample tick did not advance ({} -> {}) with the clock reported running", last.time, h.time);
        }
        for e in usb.ctrl.drain_events() {
            println!("  event {:?} +{} at tick {}", e.code, e.count, e.time);
        }
        last = h;
    }
}

// -- capture -------------------------------------------------------------------------------------

/// The tone of `capture --source tone`, coherently sampled: its frequency is
/// snapped to f = m rate / L with L = 2^16 and m odd (coprime with L, so the
/// tone passes through all L phases before it repeats), and its L complex
/// values are computed once. Sample time i is then entry (i m) mod L: exact,
/// periodic, and a table lookup - computing cos/sin per value (250 M/s at
/// 2 x 30.72 MS/s) is more than one host core can do, and the stream then
/// underflows. Channel 0 plays +f, channel 1 -f (the conjugate), so a
/// swapped I/Q or a swapped channel shows in the spectrum. Amplitude
/// A = 2048 * 10^(dbfs/20) codes, rounded and held to the 12-bit range.
struct Tone {
    table: Vec<[i16; 2]>,
    m: u64,
}

impl Tone {
    const L: u64 = 1 << 16;
    fn new(f: f64, rate: f64, dbfs: f64) -> Tone {
        // the nearest odd m: 2 round((x - 1) / 2) + 1, at most one step away
        let x = f / rate * Self::L as f64;
        let m = (2 * ((x - 1.0) / 2.0).round() as i64 + 1).rem_euclid(Self::L as i64) as u64;
        let a = b210::iq::FULL_SCALE * 10f64.powf(dbfs / 20.0);
        let code = |x: f64| (a * x).round().clamp(-2048.0, 2047.0) as i16;
        let table = (0..Self::L).map(|k| {
            let p = 2.0 * std::f64::consts::PI * k as f64 / Self::L as f64;
            [code(p.cos()), code(p.sin())]
        }).collect();
        Tone { table, m }
    }
    /// The frequency actually played, Hz, in -rate/2 .. rate/2.
    fn freq(&self, rate: f64) -> f64 {
        let m = if self.m >= Self::L / 2 { self.m as f64 - Self::L as f64 } else { self.m as f64 };
        m * rate / Self::L as f64
    }
    /// Value v (I0 Q0 I1 Q1) of sample time i.
    fn value(&self, i: u64, v: usize) -> i16 {
        let [c, s] = self.table[(i.wrapping_mul(self.m) % Self::L) as usize];
        match v { 0 | 2 => c, 1 => s, _ => s.saturating_neg() }
    }
}

/// Stream the rx source into one file per channel (interleaved i16 I, Q;
/// iq::channel_path names them) with a .toml sidecar each, and print each
/// channel's level and quality.
///
/// pattern: the FPGA's f(t), every value checked.
/// tone:    the host sends a tone burst (`tone_value`) through the FPGA's
///          tx path and loopback; only the burst's sample times are kept,
///          every one checked bit for bit against what was sent, so the
///          files are what the whole digital chain delivered. A perfect
///          chain gives exactly the quantised tone: SNR at the 12-bit limit.
fn capture(usb: &mut Usb, a: &StreamArgs, c: &CaptureArgs) -> Result<()> {
    use b210::{iq, quality};
    use std::io::Write;
    let s = Shape::new(a)?;
    let nv = 2 * s.nch;
    let paths: Vec<_> = (0..s.nch).map(|ch| iq::channel_path(&c.out, ch)).collect();
    if c.source == "tone" && !(c.tone_hz.abs() < s.rate / 2.0 && c.tone_dbfs <= 0.0) {
        bail!("--tone-hz within +-rate/2 ({:.0} Hz), --tone-dbfs <= 0", s.rate / 2.0);
    }
    let src = match c.source.as_str() {
        "pattern" => rx_source::PATTERN,
        "tone" => rx_source::LOOPBACK,
        x => bail!("--source pattern or tone, not {x}"),
    };
    println!("capture {} x{} from {}: {:.3} MS/s -> {}", a.format, a.channels, c.source, s.rate / 1e6,
             paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", "));
    let before = setup(&mut usb.ctrl, src, a.div)?;
    let n = (a.seconds * s.rate) as u64;
    let tone = Tone::new(c.tone_hz, s.rate, c.tone_dbfs);
    if c.source == "tone" {
        println!("tone {:+.6} MHz (snapped to {} / {} of the rate) at {:.1} dBFS; channel 1 at the negative frequency",
                 tone.freq(s.rate) / 1e6, tone.m, Tone::L, c.tone_dbfs);
    }
    let tone = &tone;
    // The sample times kept: all of them for the pattern, the burst's for a
    // tone (set before the stream starts).
    let (from, to, lead) = if src == rx_source::PATTERN { (0, u64::MAX, 0.0) } else {
        let lead = 0.3;                                        // s from now to the burst
        let at = now(&mut usb.ctrl)? + (lead * s.rate) as u64;
        (at, at + n, lead)
    };
    let tail = (0.02 * s.rate) as u64;                         // rx runs this long past the burst
    let expect = move |t: u64| -> [i16; 4] {
        if src == rx_source::PATTERN { std::array::from_fn(|k| rx_source::pattern(t, k)) }
        else if t >= from && t < to { std::array::from_fn(|k| tone.value(t - from, k)) }
        else { [0; 4] }
    };
    let depth = usb.depth;
    let begin = Instant::now();
    let mut tally = Tally::default();
    let Usb { ctrl, tx, rx, .. } = &mut *usb;
    // Three threads: the rx loop only checks and queues packets, a writer
    // splits them into the channel files, and in tone mode a sender feeds
    // the burst. Writing 2 x 123 MB/s on the thread that serves the USB
    // completions stalls it long enough to overflow the FPGA's rx ring.
    // 4096 queued packets = 67 MB, ~130 ms at the highest rate.
    let paths_w = &paths;
    let kept = std::thread::scope(|scope| -> Result<u64> {
        let (queue, packets) = std::sync::mpsc::sync_channel::<(u64, Vec<i16>)>(4096);
        let writer = scope.spawn(move || -> std::io::Result<u64> {
            let mut files = Vec::with_capacity(paths_w.len());
            for p in paths_w { files.push(std::io::BufWriter::with_capacity(1 << 20, std::fs::File::create(p)?)); }
            let mut kept = 0u64;
            let mut raw = Vec::new();
            for (time, v) in packets {
                let k0 = from.saturating_sub(time).min((v.len() / nv) as u64) as usize;
                let k1 = to.saturating_sub(time).min((v.len() / nv) as u64) as usize;
                kept += (k1 - k0) as u64;
                for (ch, file) in files.iter_mut().enumerate() {
                    raw.clear();
                    for frame in v[k0 * nv..k1 * nv].chunks(nv) {
                        raw.extend_from_slice(&frame[2 * ch].to_le_bytes());
                        raw.extend_from_slice(&frame[2 * ch + 1].to_le_bytes());
                    }
                    file.write_all(&raw)?;
                }
            }
            for f in &mut files { f.flush()?; }
            Ok(kept)
        });
        let sender = (src == rx_source::LOOPBACK).then(|| scope.spawn(move || {
            tx_burst(tx, s, from, n, depth, Duration::from_secs_f64(lead + 5.0), |i, v| tone.value(i, v))
        }));
        let streamed = rx_stream(rx, ctrl, s, depth, &mut tally, |h, v, t| {
            if t.header(h, s, v.len() / nv) {
                check_values(h, v, s, &expect, t);
                if queue.send((h.time, v.to_vec())).is_err() { bail!("the file writer stopped"); }
            }
            Ok(if src == rx_source::PATTERN { begin.elapsed().as_secs_f64() >= a.seconds }
               else { t.next.is_some_and(|(time, _)| time >= to + tail) })
        });
        drop(queue);
        let kept = writer.join().expect("writer thread")?;
        if let Some(sender) = sender { sender.join().expect("tx thread")?; }
        streamed?;
        Ok(kept)
    })?;
    let after = counters(ctrl)?;
    let mut want = [0; 7];
    if src == rx_source::LOOPBACK { want[4] = 1; }                 // the burst's BURST_ACK
    let counters_ok = check_counters(&before, &after, want);
    println!("kept {kept} sample times per channel; rx lost {}, bad values {}, bad headers {}",
             tally.lost, tally.bad_values, tally.bad_headers);
    for (ch, path) in paths.iter().enumerate() {
        iq::write_meta(path, &iq::Meta { rate_hz: s.rate, channel: ch, source: c.source.clone() })?;
        let x = iq::read(path)?;
        let Some(r) = quality::analyze(&x, s.rate, 16384) else { continue };
        let l = &r.level;
        print!("  ch{ch} {}: rms {:.1} dBFS, peak {:.1} dBFS, DC {:.1} dBFS", path.display(), l.rms_dbfs, l.peak_dbfs, l.dc_dbfs);
        match &r.tone {
            Some(t) => println!(", tone {:+.4} MHz {:.2} dBFS, SNR {:.1} dB, SFDR {:.1} dBc, ENOB {:.2}",
                                t.freq / 1e6, t.dbfs, t.snr_db, t.sfdr_dbc, t.enob),
            None => println!(", no tone"),
        }
    }
    if !(counters_ok && tally.clean()) { bail!("capture: the stream was not clean (see above)"); }
    println!("every sample time checked against what the source must carry; analyse with: b210-plot {}",
             paths[0].display());
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tone_is_coherent_conjugate_on_channel_1_and_matches_direct_computation() {
        let rate = 30.72e6;
        let t = Tone::new(1.234567e6, rate, -1.0);
        assert_eq!(t.m % 2, 1, "m odd: coprime with L");
        assert!((t.freq(rate) - 1.234567e6).abs() <= rate / Tone::L as f64, "snapped within one step");
        let a = 2048.0 * 10f64.powf(-1.0 / 20.0);
        for i in [0u64, 1, 12345, 1 << 40] {
            let p = 2.0 * std::f64::consts::PI * (t.m * (i % Tone::L) % Tone::L) as f64 / Tone::L as f64;
            assert_eq!(t.value(i, 0), (a * p.cos()).round() as i16, "i={i}");
            assert_eq!(t.value(i, 1), (a * p.sin()).round() as i16, "i={i}");
            assert_eq!((t.value(i, 2), t.value(i, 3)), (t.value(i, 0), -t.value(i, 1)));
        }
        assert!(Tone::new(-2e6, rate, 0.0).freq(rate) < 0.0, "negative frequencies stay negative");
    }
}
