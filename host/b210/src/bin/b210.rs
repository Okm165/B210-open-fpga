//! b210 - board access and the step-1 measurements.
//!
//!   b210 load IMAGE.bin            load the FPGA, start the bus
//!   b210 read ADDR | write ADDR VALUE
//!   b210 rx-test [options]         stream the FPGA's pattern f(t)
//!   b210 loop-test [options]       one timed tx burst through the FPGA's
//!                                  loopback, rx running the whole time
//!
//! Both tests check every sample time that arrives: its values against
//! what that tick must carry, the times contiguous (a gap is counted as
//! lost and must carry OVERFLOW), sequence +1 per packet; and compare the
//! FPGA's event counters before and after.

use anyhow::{bail, Context, Result};
use b210::proto::{self, flag, Format, Header, Kind, Op};
use b210::regs::{self, rx, test};
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
    /// Stream the rx source to a raw file (interleaved i16, I0 Q0 [I1 Q1])
    Capture {
        #[arg(long, default_value_t = 1.0)]
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
        /// output file
        #[arg(long, default_value = "capture.raw")]
        out: std::path::PathBuf,
        /// the source: pattern f(t) or the tx loopback
        #[arg(long, default_value = "pattern")]
        source: String,
    },
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
        Cmd::RxTest(a) | Cmd::LoopTest(a) => a.depth_ms,
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
        Cmd::Capture { seconds, format, channels, div, depth_ms, out, source } => {
            let a = StreamArgs { seconds, format, channels, div, depth_ms };
            capture(&mut usb, &a, &source, &out)?
        }
    }
    Ok(())
}

// -- the FPGA's counters --------------------------------------------------------------------

/// Event counters by code 1 .. 6 (index code - 1), then rx_lost.
fn counters(ctrl: &mut Ctrl) -> Result<[u32; 7]> {
    let ops: Vec<Op> = (0..6).map(|k| Op::Read { addr: regs::EVENTS + k })
        .chain([Op::Read { addr: regs::RX_LOST }]).collect();
    let r = ctrl.exec(&ops)?;
    Ok(std::array::from_fn(|i| r[i].data))
}

const CODES: [&str; 6] = ["OVERFLOW", "UNDERFLOW", "LATE", "SEQ_ERROR", "BURST_ACK", "BAD_PACKET"];

/// Every counter rose by exactly what `want` says (BURST_ACK and the rest).
fn check_counters(before: &[u32; 7], after: &[u32; 7], want: [u32; 7]) -> bool {
    let mut ok = true;
    for i in 0..7 {
        let d = after[i].wrapping_sub(before[i]);
        let name = if i < 6 { CODES[i] } else { "rx_lost" };
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
    println!("counters: {} +{} {} +{} {} +{} {} +{} {} +{} {} +{} rx_lost +{}",
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

// -- rx: every packet checked ----------------------------------------------------------------

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
    ended: bool,
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
}

/// Run the rx stream until it ends (`stop` says when to ask it to): check
/// each packet against `expect(t)` = the four values (I0 Q0 I1 Q1) tick t
/// must carry.
fn rx_run(rx: &mut Endpoint<Bulk, In>, ctrl: &mut Ctrl, s: Shape, depth: usize,
          expect: impl Fn(u64) -> [i16; 4], mut stop: impl FnMut(&Tally, f64) -> bool) -> Result<(Tally, f64)> {
    for _ in 0..depth {
        let buf = zero_copy(rx.allocate(proto::DATA_BUFFER));
        rx.submit(buf);
    }
    ctrl.write(regs::RX_SPP, s.per_packet() as u32)?;
    ctrl.write(regs::RX_COUNT, 0)?;
    // whatever a previous stream left in the endpoint must not mix with this
    // stream's packets (its END_OF_BURST would end the run before it begins)
    flush_rx(rx);
    ctrl.write(regs::RX_CTRL, rx::START | rx::config(s.code, s.mask as u32))?;
    let mut t = Tally::default();
    let mut values = vec![0i16; 4 * 8192];
    let start = Instant::now();
    let mut stopping = false;
    while !t.ended {
        if !stopping && stop(&t, start.elapsed().as_secs_f64()) {
            ctrl.write(regs::RX_CTRL, rx::STOP)?;
            stopping = true;
        }
        // 2 s without a 16 KiB packet is a stalled stream, not a slow host:
        // at the slowest test rate one packet is a few milliseconds.
        let c = rx.wait_next_complete(Duration::from_secs(2)).context("no rx packet for 2 s")?;
        let n = c.actual_len;
        let buf = c.into_result()?;
        check_packet(&buf[..n], s, &expect, &mut values, &mut t);
        rx.submit(buf);
    }
    let seconds = start.elapsed().as_secs_f64();
    rx.cancel_all();
    while rx.pending() > 0 {
        // Cancelled transfers return at once; 1 s bounds a kernel that does
        // not, and the loop exits after at most `depth` of them.
        rx.wait_next_complete(Duration::from_secs(1));
    }
    Ok((t, seconds))
}

fn check_packet(p: &[u8], s: Shape, expect: &impl Fn(u64) -> [i16; 4], values: &mut [i16], t: &mut Tally) {
    let h = match Header::decode(p) {
        Ok(h) if h.kind == Kind::Rx && h.format == s.format && h.channels == s.mask
            && h.flags & flag::HAS_TIME != 0 && p.len() >= h.length as usize => h,
        _ => { t.bad_headers += 1; return; }
    };
    let bpt = s.format.bytes_per_time(s.nch);
    let payload = h.length as usize - proto::HEADER;
    if !payload.is_multiple_of(bpt) {
        t.bad_headers += 1;
        return;
    }
    let n = payload / bpt;
    let overflow = h.flags & flag::OVERFLOW != 0;
    if let Some((time, seq)) = t.next {
        let gap = proto::lost(time, 0, h.time);
        if h.sequence != seq || gap < 0 || (gap > 0) != overflow {
            t.bad_headers += 1;
        }
        t.lost += gap.max(0) as u64;
    }
    t.overflow_flags += overflow as u64;
    let nv = 2 * s.nch;
    let body = &p[proto::HEADER..proto::HEADER + payload];
    match s.format {
        Format::Sc16 => proto::unpack_sc16(body, &mut values[..n * nv]),
        _ => proto::unpack_sc12(body, &mut values[..n * nv]),
    }
    let first = if s.mask == 0b10 { 2 } else { 0 };
    for k in 0..n {
        let time = h.time + k as u64;
        let e = expect(time);
        for v in 0..nv {
            if values[k * nv + v] != e[first + v] {
                if t.bad_values == 0 {
                    // the first bad packet, raw: header and the first payload words
                    let words: Vec<String> = p[..p.len().min(proto::HEADER + 48)].as_chunks::<4>().0.iter()
                        .map(|w| format!("{:08x}", u32::from_le_bytes(*w))).collect();
                    eprintln!("first bad packet ({} bytes): {}", p.len(), words.join(" "));
                    if let Ok(path) = std::env::var("B210_DUMP") {
                        let _ = std::fs::write(path, p);
                    }
                }
                if t.bad_values < 5 {
                    eprintln!("time {time} value {v}: {}, expected {}", values[k * nv + v], e[first + v]);
                }
                t.bad_values += 1;
            }
        }
    }
    t.first.get_or_insert(h.time);
    t.packets += 1;
    t.samples += n as u64;
    t.next = Some((h.time + n as u64, h.sequence.wrapping_add(1)));
    t.ended |= h.flags & flag::END_OF_BURST != 0;
}

/// Fetch and discard whatever a previous stream left on the endpoint. A
/// stopped stream's packets (and its END_OF_BURST) sit in the FX3's DMA
/// channel; the next run must begin with an empty one. Bounded: 100 ms is
/// ~25 packets at the slowest test rate and far more than any leftover,
/// and the loop exits at once when nothing arrives.
fn flush_rx(rx: &mut Endpoint<Bulk, In>) {
    let deadline = Instant::now() + Duration::from_millis(100);
    rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() { break; }
        let Some(c) = rx.wait_next_complete(left) else { break };
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    rx.cancel_all();
    while rx.pending() > 0 { rx.wait_next_complete(Duration::from_millis(100)); }
}

// -- the tests ----------------------------------------------------------------------------------

fn setup(ctrl: &mut Ctrl, source: u32, div: u32) -> Result<[u32; 7]> {
    ctrl.write(regs::RX_CTRL, rx::STOP)?;
    ctrl.write(regs::TEST, source)?;
    ctrl.write(regs::TEST_DIV, div)?;
    counters(ctrl)
}

fn rx_test(usb: &mut Usb, a: &StreamArgs) -> Result<()> {
    let s = Shape::new(a)?;
    println!("rx-test {} x{}: {:.3} MS/s, {:.1} MB/s", a.format, a.channels, s.rate / 1e6, s.mbytes());
    let before = setup(&mut usb.ctrl, test::PATTERN, a.div)?;
    let pattern = |t: u64| std::array::from_fn(|k| test::pattern(t, k));
    let depth = usb.depth;
    let (tally, seconds) = rx_run(&mut usb.rx, &mut usb.ctrl, s, depth, pattern,
                                  |_, elapsed| elapsed >= a.seconds)?;
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

/// Send `n` samples as one burst starting at tick `at`: full packets, the
/// last one shorter; START_OF_BURST + HAS_TIME on the first, END_OF_BURST
/// on the last. Returns the packets sent.
fn tx_burst(tx: &mut Endpoint<Bulk, Out>, s: Shape, at: u64, n: u64, depth: usize, wait: Duration) -> Result<u64> {
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
                values[i * nv + v] = burst_value(i0 + i as u64, v);
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
    let before = setup(&mut usb.ctrl, test::LOOPBACK, a.div)?;
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
    let (rx_result, tx_result) = std::thread::scope(|scope| {
        // The burst starts after `lead`; 5 s on top of it is over 1000
        // 16 KiB packets at the bus rate, so a transfer that has not
        // completed by then is stuck, not merely queued.
        let wait = Duration::from_secs_f64(lead + 5.0);
        let sender = scope.spawn(move || tx_burst(tx, s, at, n, depth, wait));
        let r = rx_run(rx, ctrl, s, depth, expect,
                       |t, _| t.next.is_some_and(|(time, _)| time >= end + tail));
        (r, sender.join().expect("tx thread"))
    });
    let (tally, seconds) = rx_result?;
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

/// One reading of the FPGA's state, as one command packet.
fn health(ctrl: &mut Ctrl) -> Result<([u32; 7], u32, u64, u32)> {
    let ops: Vec<Op> = [Op::Read { addr: regs::STATUS }, Op::Read { addr: regs::RX_CTRL }]
        .into_iter().chain((0..6).map(|k| Op::Read { addr: regs::EVENTS + k }))
        .chain([Op::Read { addr: regs::RX_LOST }, Op::Read { addr: regs::TIME_LO },
                Op::Read { addr: regs::TIME_HI }]).collect();
    let r = ctrl.exec(&ops)?;
    let status = r[0].data;
    let counters = std::array::from_fn(|i| r[2 + i].data);
    let time = r[8].data as u64 | (r[9].data as u64) << 32;
    Ok((counters, status, time, r[1].data))
}

/// Watch the board until interrupted: status bits, the event counters' rise
/// per interval (500 ms default: every event code that rises is trouble
/// except BURST_ACK), the sample clock's tick, and the USB event packets.
fn monitor(usb: &mut Usb, interval_ms: u64) -> Result<()> {
    // 500 ms: fast enough to see a burst or a fault, slow enough that the
    // register reads (10 in one command packet, ~1 us each on the bus)
    // never load the command FIFO.
    let interval = Duration::from_millis(interval_ms.max(50));
    println!("status: bit0 clocks locked, bit1 sample clock running; rx_ctrl bit0 a stream runs");
    let (c, _, t, _) = health(&mut usb.ctrl)?;
    println!("{:>8} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}  status  tick",
             "OVERFLOW", "UNDERFLOW", "LATE", "SEQ_ERR", "BURST_ACK", "BAD_PKT", "rx_lost", "cmd_drop");
    let mut last = (c, t);
    loop {
        std::thread::sleep(interval);
        let (c, status, t, rx_ctrl) = health(&mut usb.ctrl)?;
        let d = |a: u32, b: u32| a.wrapping_sub(b);
        let per = |i: usize, pc: &[u32; 7], c: &[u32; 7]| if i < 6 { d(c[i], pc[i]) } else { d(c[6], pc[6]) };
        println!("{:>8} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}  {:04b}  {}{}",
                 per(0, &last.0, &c), per(1, &last.0, &c), per(2, &last.0, &c), per(3, &last.0, &c),
                 per(4, &last.0, &c), per(5, &last.0, &c), per(6, &last.0, &c), 0,
                 status & 3, t, if rx_ctrl & 1 != 0 { " rx-running" } else { "" });
        for e in usb.ctrl.drain_events() {
            println!("  event {:?} count +{} at tick {}", e.code, e.count, e.time);
        }
        last = (c, t);
    }
}

// -- capture -------------------------------------------------------------------------------------

/// Stream the rx source to `out` as interleaved i16 (I0 Q0 [I1 Q1]), print
/// signal statistics, and stop after `seconds`. The step-1 sources are the
/// FPGA's pattern and the tx loopback; the radio needs the step-2 image.
fn capture(usb: &mut Usb, a: &StreamArgs, source: &str, out: &std::path::Path) -> Result<()> {
    use b210::iq;
    use std::io::Write;
    let src = match source { "pattern" => test::PATTERN, "loopback" => test::LOOPBACK,
                             _ => bail!("source: pattern or loopback") };
    let s = Shape::new(a)?;
    let nch = s.nch;
    let nv = 2 * nch;
    // one file per channel, so every later tool reads one channel without
    // knowing the mask (iq::channel_path owns the naming)
    let paths: Vec<_> = (0..nch).map(|c| iq::channel_path(out, c)).collect();
    println!("capture {} x{} from {:?}: {:.3} MS/s -> {}", a.format, a.channels, source, s.rate / 1e6,
             paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", "));
    let before = setup(&mut usb.ctrl, src, a.div)?;
    let depth = usb.depth;
    let mut files = Vec::with_capacity(nch);
    for p in &paths {
        let f = std::fs::File::create(p).with_context(|| p.display().to_string())?;
        files.push(std::io::BufWriter::new(f));
    }
    // level per channel, accumulated as it streams: (min, max, sum of squares,
    // values), so the statistics never re-read or hold the capture
    let mut acc = vec![(i16::MAX, i16::MIN, 0f64, 0u64); nch];
    ctrl_stream(&mut usb.rx, &mut usb.ctrl, s, depth, |vals| {
        let frames = vals.len() / nv;          // sample times in this packet
        for (c, acc) in acc.iter_mut().enumerate() {
            // one write per channel per packet: the whole packet's I/Q pairs
            let mut raw = Vec::with_capacity(4 * frames);
            for k in 0..frames {
                let i = vals[k * nv + 2 * c];
                let q = vals[k * nv + 2 * c + 1];
                raw.extend_from_slice(&i.to_le_bytes());
                raw.extend_from_slice(&q.to_le_bytes());
                acc.0 = acc.0.min(i).min(q);
                acc.1 = acc.1.max(i).max(q);
                acc.2 += (i as f64).powi(2) + (q as f64).powi(2);
                acc.3 += 2;                     // I and Q are two values per time
            }
            files[c].write_all(&raw)?;
        }
        Ok(())
    }, |_, elapsed| elapsed >= a.seconds)?;
    for f in &mut files { f.flush()?; }
    drop(files);
    let after = counters(&mut usb.ctrl)?;
    // capture sends no burst, so no counter may rise in either source
    let counters_ok = check_counters(&before, &after, [0; 7]);
    for (c, &(lo, hi, sum, n)) in acc.iter().enumerate() {
        let st = iq::Stats { min: lo, max: hi, rms: if n > 0 { (sum / n as f64).sqrt() } else { 0.0 } };
        let frames = n / 2;
        println!("  ch{c}: {frames} times, {}: min {} max {} rms {:.1}{}",
                 paths[c].display(), st.min, st.max, st.rms,
                 if st.clipped(2048.0) { " (at full scale)" } else { "" });
    }
    if !counters_ok { bail!("capture: a counter rose that should not"); }
    println!("plot one channel with: b210-plot {} --rate {:.6}", paths[0].display(), s.rate);
    Ok(())
}

/// The rx stream loop, handing the unpacked values of every packet to
/// `sink`. Shared by the checking tests and the raw capture.
fn ctrl_stream(rx: &mut Endpoint<Bulk, In>, ctrl: &mut Ctrl, s: Shape, depth: usize,
               mut sink: impl FnMut(&[i16]) -> std::io::Result<()>,
               mut stop: impl FnMut(&Tally, f64) -> bool) -> Result<()> {
    let nv = 2 * s.nch;
    ctrl.write(regs::RX_SPP, s.per_packet() as u32)?;
    ctrl.write(regs::RX_COUNT, 0)?;
    flush_rx(rx);
    ctrl.write(regs::RX_CTRL, rx::START | rx::config(s.code, s.mask as u32))?;
    let mut t = Tally::default();
    let mut values = vec![0i16; 4 * 8192];
    let t0 = Instant::now();
    for _ in 0..depth {
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    if std::env::var("B210_DEBUG").is_ok() { eprintln!("submitted {depth} at {:.3}s", t0.elapsed().as_secs_f64()); }
    let mut pending = Vec::new();        // bytes of a packet split over transfers
    let start = Instant::now();
    let mut stopping = false;
    while !t.ended {
        if !stopping && stop(&t, start.elapsed().as_secs_f64()) {
            if std::env::var("B210_DEBUG").is_ok() { eprintln!("{:.6}s stop", start.elapsed().as_secs_f64()); }
            ctrl.write(regs::RX_CTRL, rx::STOP)?;
            stopping = true;
        }
        let c = rx.wait_next_complete(Duration::from_secs(2)).context("no rx packet for 2 s")?;
        let n = c.actual_len;
        let buf = c.into_result()?;
        if std::env::var("B210_DEBUG").is_ok() { eprintln!("{:.3}s transfer {n} bytes, pending {}", start.elapsed().as_secs_f64(), rx.pending()); }
        // Packets may split across transfers and several may share one, so
        // accumulate bytes and walk whole packets: the wire size of a packet
        // follows from its 16-bit length (PROTOCOL.md 1).
        let mut bytes = std::mem::take(&mut pending);
        bytes.extend_from_slice(&buf[..n]);
        let mut at = 0;
        while bytes.len() - at >= proto::HEADER {
            let length = u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap()) as usize;
            let size = proto::transfer_size(length, proto::DATA_BUFFER);
            if bytes.len() - at < size { break }
            let p = &bytes[at..at + size];
            let h = match Header::decode(p) {
                Ok(h) if h.kind == Kind::Rx && h.length as usize == length => h,
                e => {
                    t.bad_headers += 1;
                    if std::env::var("B210_DEBUG").is_ok() {
                        eprintln!("bad header at {}, length {}: {:?} {:02x?}", at, length, e, &p[..16.min(p.len())]);
                    }
                    at += size.max(1); continue
                }
            };
            let payload = h.length as usize - proto::HEADER;
            let bpt = s.format.bytes_per_time(s.nch);
            if payload == 0 {
                // header-only END_OF_BURST: marks the end, carries no sample
            } else if payload.is_multiple_of(bpt) {
                let n = payload / bpt;
                let body = &p[proto::HEADER..proto::HEADER + payload];
                if s.format == Format::Sc16 { proto::unpack_sc16(body, &mut values[..n * nv]); }
                else { proto::unpack_sc12(body, &mut values[..n * nv]); }
                sink(&values[..n * nv])?;
                t.packets += 1; t.samples += n as u64;
            } else {
                t.bad_headers += 1;
            }
            // an END_OF_BURST before any data is a stopped stream's leftover,
            // never this stream's end
            if std::env::var("B210_DEBUG").is_ok() { eprintln!("  pkt t {} len {} flags {:04x}", h.time, h.length, h.flags); }
            if t.packets > 0 && h.flags & flag::END_OF_BURST != 0 {
                if std::env::var("B210_DEBUG").is_ok() { eprintln!("  end at {} after {} packets", h.time, t.packets); }
                t.ended = true;
            }
            at += size;
        }
        pending = bytes.split_off(at);
        rx.submit(buf);
    }
    rx.cancel_all();
    while rx.pending() > 0 { rx.wait_next_complete(Duration::from_secs(1)); }
    if std::env::var("B210_DEBUG").is_ok() { eprintln!("done: {} packets, {} times, {} bad", t.packets, t.samples, t.bad_headers); }
    if t.bad_headers > 0 { bail!("capture: {} bad headers", t.bad_headers) }
    Ok(())
}
