//! b210 - board access and the step-1 measurements.
//!
//!   b210 load IMAGE.bin            load the FPGA, start the bus (from power-up:
//!                                  the FX3 firmware first, --firmware FILE.hex)
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
use b210::dsp::TestTone;
use b210::proto::{self, Format};
use b210::regs::{self, rx_source, Counters, COUNTER_NAMES};
use b210::stream::{self, Check, Shape};
use b210::usb::{self, Board, Ctrl, Usb, DEPTH_MS_DEFAULT};
use clap::{Args, Parser, Subcommand};
use std::time::{Duration, Instant};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Load an FPGA image and start the bus; from the FX3 bootloader (after
    /// power-up), load Ettus's stock FX3 firmware first
    Load {
        image: std::path::PathBuf,
        /// stock FX3 firmware (Intel HEX), checked against the SHA-256 that
        /// scripts/toolchain.sh pins
        #[arg(long, default_value = usb::FIRMWARE_DEFAULT)]
        firmware: std::path::PathBuf,
    },
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
    /// pattern: the FPGA's f(t); tone: a host tone through tx and the loopback;
    /// radio: the AD9361, sample_times kept, not checked against a closed form
    #[arg(long, default_value = "tone")]
    source: String,
    /// radio only: check every word's bit 0 against the AD9361's BIST
    /// pseudo-random sequence (`b210-radio test CONFIG prbs` first) instead
    /// of keeping the sample_times unchecked
    #[arg(long)]
    prbs: bool,
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
    #[arg(long, value_enum, default_value_t = Format::Sc12)]
    format: Format,
    /// 1 or 2
    #[arg(long, default_value_t = 2)]
    channels: u32,
    /// host buffering per direction, ms of the 400 MB/s bus limit (1..100)
    #[arg(long, default_value_t = DEPTH_MS_DEFAULT)]
    depth_ms: f64,
}

/// Seconds from reading the time to a burst's first tick: the tx thread has
/// started and the first transfers are queued well before it.
const LEAD: f64 = 0.3;
/// Seconds rx keeps streaming past a burst's end, so that the zeros after it
/// are checked too.
const TAIL: f64 = 0.02;

/// A stream's shape.
fn shape(a: &StreamArgs) -> Result<Shape> {
    let mask: u8 = match a.channels { 1 => 0b01, 2 => 0b11, _ => bail!("channels: 1 or 2") };
    Ok(Shape { format: a.format, mask })
}

fn mbytes(s: Shape, rate: f64) -> f64 {
    rate * s.bytes_per_time() as f64 / 1e6
}

fn number(s: &str) -> Result<u32> {
    Ok(match s.strip_prefix("0x") {
        Some(h) => u32::from_str_radix(h, 16)?,
        None => s.parse()?,
    })
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    // `load` starts from whatever the FX3 runs, possibly its bootloader, so
    // it opens the board itself once the firmware is up.
    if let Cmd::Load { image, firmware } = &cli.cmd {
        return load(image, firmware);
    }
    // Buffering is planned before the endpoints open; commands that do not
    // stream still use the default so the usbfs check has one plan.
    let depth_ms = match &cli.cmd {
        Cmd::RxTest(a) | Cmd::LoopTest(a) | Cmd::Capture { stream: a, .. } => a.depth_ms,
        _ => DEPTH_MS_DEFAULT,
    };
    let mut usb = Usb::open(depth_ms)?;
    if matches!(cli.cmd, Cmd::RxTest(_) | Cmd::LoopTest(_) | Cmd::Capture { .. }) {
        // this thread runs the rx loop
        usb::set_realtime_priority();
    }
    match cli.cmd {
        Cmd::Load { .. } => unreachable!("handled above"),
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

/// `b210 load`: from the FX3 bootloader or a running firmware to a running
/// FPGA image, each step printed with its duration.
fn load(image: &std::path::Path, firmware: &std::path::Path) -> Result<()> {
    // Read the image first: a wrong path fails before the board is touched.
    let bytes = std::fs::read(image).with_context(|| format!("{}", image.display()))?;
    match usb::board()? {
        Board::Running => println!("FX3 firmware: already running ({:04x}:{:04x})", usb::VID, usb::PID),
        Board::Bootloader => {
            let t = Instant::now();
            let fw = usb::read_firmware(firmware)?;
            println!("FX3 firmware: {} verified (SHA-256 {}), {} bytes in {} writes, entry {:#010x} ({:.3} s)",
                     firmware.display(), usb::FIRMWARE_SHA256, fw.bytes(), fw.chunks.len(), fw.entry,
                     t.elapsed().as_secs_f64());
            let t = Instant::now();
            usb::download_firmware(&fw)?;
            println!("FX3 firmware: written to the bootloader and started ({:.2} s)", t.elapsed().as_secs_f64());
            let t = Instant::now();
            usb::wait_firmware(usb::FIRMWARE_BOOT_WAIT)?;
            println!("FX3 firmware: running as {:04x}:{:04x} ({:.2} s)", usb::VID, usb::PID, t.elapsed().as_secs_f64());
        }
        Board::Absent => bail!(
            "no B210 on USB: neither the firmware ({:04x}:{:04x}) nor the FX3 bootloader ({:04x}:{:04x})",
            usb::VID, usb::PID, usb::BOOT_VID, usb::BOOT_PID
        ),
    }
    let mut usb = Usb::open(DEPTH_MS_DEFAULT)?;
    let start = Instant::now();
    usb.ctrl.load_fpga(&bytes)?;
    let id = usb.ctrl.read(regs::ID)?;
    println!("loaded {} ({} bytes) in {:.1} s; id {id:08x}, version {:08x}, build {:08x}",
             image.display(), bytes.len(), start.elapsed().as_secs_f64(),
             usb.ctrl.read(regs::VERSION)?, usb.ctrl.read(regs::BUILD)?);
    if id != regs::ID_VALUE {
        bail!("id {id:08x}, expected {:08x}", regs::ID_VALUE);
    }
    Ok(())
}

// -- printing ---------------------------------------------------------------------------------

/// Every counter rose by exactly what `want` says (BURST_ACK and the rest).
fn check_counters(before: &Counters, after: &Counters, want: Counters) -> bool {
    let mut ok = true;
    for i in 0..before.len() {
        let d = after[i].wrapping_sub(before[i]);
        if d != want[i] {
            println!("  FPGA {}: +{d}, expected +{}", COUNTER_NAMES[i], want[i]);
            ok = false;
        }
    }
    ok
}

/// Every counter's increase, pass or fail. No ring-fill register exists in
/// docs/PROTOCOL.md section 6, so there is none to report.
fn report_counters(before: &Counters, after: &Counters) {
    let rises: Vec<String> = (0..before.len())
        .map(|i| format!("{} +{}", COUNTER_NAMES[i], after[i].wrapping_sub(before[i])))
        .collect();
    println!("counters: {}", rises.join(" "));
}

/// Events met on the result endpoint, for information only: every count is
/// also in the registers printed above and accumulating there is lossless.
fn report_events(ctrl: &mut Ctrl) {
    let n = ctrl.drain_events().len();
    if n > 0 {
        println!("usb events: {n} records (informational; the registers above are authoritative)");
    }
}

fn report_mismatches(c: &Check) {
    for m in &c.mismatches {
        println!("time {} value {}: {}, expected {}", m.time, m.value, m.got, m.want);
    }
}

fn report_rx(c: &Check, seconds: f64) {
    report_mismatches(c);
    println!("rx: {} packets, {} sample times in {seconds:.2} s = {:.3} MS/s", c.packets, c.sample_times,
             c.sample_times as f64 / seconds / 1e6);
    println!("rx: lost {} sample times ({} packets flagged OVERFLOW); bad values {}, bad headers {}",
             c.lost, c.overflow_flags, c.bad_values, c.bad_headers);
}

// -- the tests ----------------------------------------------------------------------------------

fn rx_test(usb: &mut Usb, a: &StreamArgs) -> Result<()> {
    let s = shape(a)?;
    let before = regs::setup(&mut usb.ctrl, rx_source::PATTERN)?;
    let rate = regs::sample_rate(&mut usb.ctrl)?;
    s.check_bus(rate)?;
    println!("rx-test {} x{}: {:.3} MS/s, {:.1} MB/s", a.format, a.channels, rate / 1e6, mbytes(s, rate));
    let pattern = |t: u64| std::array::from_fn(|k| rx_source::pattern(t, k));
    let begin = Instant::now();
    let mut check = Check::default();
    let seconds = stream::rx_stream(&mut usb.rx, &mut usb.ctrl, s, usb.depth, &mut check, &pattern,
                                    |_, _| Ok(begin.elapsed().as_secs_f64() >= a.seconds))?;
    report_rx(&check, seconds);
    let after = regs::counters(&mut usb.ctrl)?;
    let counters_ok = check_counters(&before, &after, [0; 7]);
    report_counters(&before, &after);
    report_events(&mut usb.ctrl);
    if !(counters_ok & check.clean()) {
        bail!("rx-test FAILED");
    }
    println!("rx-test PASSED: every sample time checked, none lost");
    Ok(())
}

/// The value k (I0 Q0 I1 Q1) of burst sample i: 12 bits of a 64-bit hash,
/// never 0, so a sample missing from the burst cannot pass as idle.
fn burst_value(i: u64, k: usize) -> i16 {
    let x = i.wrapping_add(1).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> (12 * k + 8);
    proto::sext12((x as u16 & 0xFFF).max(1))
}

/// One BURST_ACK, nothing else.
const BURST_COUNTERS: Counters = [0, 0, 0, 0, 1, 0, 0];

fn loop_test(usb: &mut Usb, a: &StreamArgs) -> Result<()> {
    let s = shape(a)?;
    let before = regs::setup(&mut usb.ctrl, rx_source::LOOPBACK)?;
    let rate = regs::sample_rate(&mut usb.ctrl)?;
    s.check_bus_full_duplex(rate)?;
    println!("loop-test {} x{}: {:.3} MS/s, {:.1} MB/s each way", a.format, a.channels, rate / 1e6, mbytes(s, rate));
    let at = regs::now(&mut usb.ctrl)? + (LEAD * rate) as u64;
    let n = (a.seconds * rate) as u64;
    let end = at + n;
    let tail = (TAIL * rate) as u64;
    let expect = move |t: u64| -> [i16; 4] {
        if t >= at && t < end { std::array::from_fn(|k| burst_value(t - at, k)) } else { [0; 4] }
    };
    let Usb { ctrl, tx, rx, depth } = usb;
    let depth = *depth;
    let mut check = Check::default();
    let (rx_result, tx_result) = std::thread::scope(|scope| {
        let sender = scope.spawn(move || {
            usb::set_realtime_priority();
            stream::send(tx, stream::burst(s, at, n, burst_value), depth, Duration::from_secs_f64(LEAD))
        });
        let r = stream::rx_stream(rx, ctrl, s, depth, &mut check, &expect,
                                  |_, c| Ok(c.next.is_some_and(|(time, _)| time >= end + tail)));
        (r, sender.join().expect("tx thread"))
    });
    let seconds = rx_result?;
    let packets = tx_result?;
    report_rx(&check, seconds);
    println!("tx: {n} sample_times in {packets} packets, burst at tick {at}");
    let covered = check.first.is_some_and(|f| f <= at) && check.next.is_some_and(|(t, _)| t >= end);
    if !covered {
        println!("  rx did not cover the whole burst");
    }
    let after = regs::counters(ctrl)?;
    let counters_ok = check_counters(&before, &after, BURST_COUNTERS);
    report_counters(&before, &after);
    report_events(ctrl);
    if !(counters_ok & check.clean() & covered) {
        bail!("loop-test FAILED");
    }
    println!("loop-test PASSED: all {n} tx sample_times back on rx at exactly their ticks, zeros around them");
    Ok(())
}

// -- live health ---------------------------------------------------------------------------------

/// Watch the board until interrupted. Each line: status (clocks locked,
/// sample clock running), the measured sample rate, both rings' fill now
/// and at most since the last line (the marks are cleared after each read),
/// and how much every counter rose. Every counter rising except BURST_ACK
/// is trouble: OVERFLOW = rx sample_times dropped, UNDERFLOW = tx ran dry in a
/// burst, LATE = a burst came after its time, SEQ_ERR / BAD_PKT = broken tx
/// packets, cdc_lost = a design error, cmd_drop = malformed commands.
fn monitor(usb: &mut Usb, interval_ms: u64) -> Result<()> {
    // fast enough to see a burst or a fault; the 17 reads per line take a
    // few microseconds of the bus, so even 50 ms costs nothing
    let interval = Duration::from_millis(interval_ms.max(50));
    let ring = |used: u32, words: u32| 100.0 * used as f64 / words as f64;
    let mut last = regs::health(&mut usb.ctrl)?;
    usb.ctrl.write(regs::RX_HWM, 0)?;
    usb.ctrl.write(regs::TX_HWM, 0)?;
    println!("lock clk  rate MS/s  rx ring % (max)  tx ring % (max)  OVERFLOW UNDERFLOW LATE SEQ_ERR BURST_ACK BAD_PKT cdc_lost cmd_drop");
    loop {
        std::thread::sleep(interval);
        let h = regs::health(&mut usb.ctrl)?;
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

/// Packets the rx loop may queue for the file writer: 4096 packets = 67 MB,
/// ~130 ms at the highest rate.
const WRITE_QUEUE: usize = 4096;

/// FFT points of the per-channel summary: 16 384 bins at 30.72 MS/s is
/// 1.875 kHz, fine enough to separate close carriers in one line. The plot
/// view defaults to 4096 (a wider lobe, fewer bins); each prints its size,
/// since SFDR and the strongest bin depend on it.
const SUMMARY_FFT: usize = 16_384;

/// Stream the rx source into one file per channel (interleaved i16 I, Q;
/// capture::channel_path names them) with a .toml sidecar each, and print each
/// channel's level and quality.
///
/// pattern: the FPGA's f(t), every value checked.
/// tone:    the host sends a tone burst (`dsp::TestTone`) through the FPGA's
///          tx path and loopback; only the burst's sample times are kept,
///          every one checked bit for bit against what was sent, so the
///          files are what the whole digital chain delivered. A perfect
///          chain gives exactly the quantised tone: SNR at the 12-bit limit.
/// radio:   the AD9361's output; its values have no closed form.
///
/// Both digital sources span the code range by construction, so their CLIPPING
/// note reports the rails without refusing; only the radio's saturation
/// refuses a capture, because only there is the data a measurement of an input.
/// A stream that lost sample times is not analysed at all: the file is a
/// splice, and its sidecar says so for `b210-plot`.
fn capture(usb: &mut Usb, a: &StreamArgs, c: &CaptureArgs) -> Result<()> {
    use b210::{capture, quality};
    use std::io::Write;
    let s = shape(a)?;
    let nv = 2 * s.count();
    let paths: Vec<_> = (0..s.count()).map(|ch| capture::channel_path(&c.out, ch)).collect();
    let src = match c.source.as_str() {
        "pattern" => rx_source::PATTERN,
        "tone" => rx_source::LOOPBACK,
        "radio" => rx_source::RADIO,
        x => bail!("--source pattern, tone or radio, not {x}"),
    };
    let before = regs::setup(&mut usb.ctrl, src)?;
    let rate = regs::sample_rate(&mut usb.ctrl)?;
    s.check_bus(rate)?;
    if c.source == "tone" && !(c.tone_hz.abs() < rate / 2.0 && c.tone_dbfs <= 0.0) {
        bail!("--tone-hz within +-rate/2 ({:.0} Hz), --tone-dbfs <= 0", rate / 2.0);
    }
    println!("capture {} x{} from {}: {:.3} MS/s -> {}", a.format, a.channels, c.source, rate / 1e6,
             paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", "));
    let n = (a.seconds * rate) as u64;
    let tone = TestTone::new(c.tone_hz, rate, c.tone_dbfs);
    if c.source == "tone" {
        println!("tone {:+.6} MHz (snapped to {} / {} of the rate) at {:.1} dBFS; channel 1 at the negative frequency",
                 tone.freq(rate) / 1e6, tone.m, TestTone::L, c.tone_dbfs);
    }
    let tone = &tone;
    // The sample times kept: all of them for the pattern, the burst's for a
    // tone (set before the stream starts).
    let (from, to) = if src != rx_source::LOOPBACK { (0, u64::MAX) } else {
        let at = regs::now(&mut usb.ctrl)? + (LEAD * rate) as u64;
        (at, at + n)
    };
    let tail = (TAIL * rate) as u64;
    let expect = move |t: u64| -> [i16; 4] {
        if src == rx_source::PATTERN { std::array::from_fn(|k| rx_source::pattern(t, k)) }
        else if t >= from && t < to { std::array::from_fn(|k| tone.value(t - from, k)) }
        else { [0; 4] }
    };
    let begin = Instant::now();
    let mut check = Check::default();
    check.check_values = src != rx_source::RADIO;
    if c.prbs {
        if src != rx_source::RADIO {
            bail!("--prbs is for --source radio (the AD9361's BIST)");
        }
        check.prbs = Some(b210::prbs::Checker::default());
    }
    let Usb { ctrl, tx, rx, depth } = &mut *usb;
    let depth = *depth;
    // Three threads: the rx loop only checks and queues packets, a writer
    // splits them into the channel files, and in tone mode a sender feeds
    // the burst. Writing 2 x 123 MB/s on the thread that serves the USB
    // completions stalls it long enough to overflow the FPGA's rx ring.
    let paths_w = &paths;
    let kept = std::thread::scope(|scope| -> Result<u64> {
        let (queue, packets) = std::sync::mpsc::sync_channel::<(u64, Vec<i16>)>(WRITE_QUEUE);
        let writer = scope.spawn(move || -> std::io::Result<u64> {
            let mut files = Vec::with_capacity(paths_w.len());
            for p in paths_w { files.push(std::io::BufWriter::with_capacity(1 << 20, std::fs::File::create(p)?)); }
            let mut kept = 0u64;
            let mut raw = Vec::new();
            for (time, v) in packets {
                let k = stream::within(time, v.len() / nv, from, to);
                kept += k.len() as u64;
                for (ch, file) in files.iter_mut().enumerate() {
                    raw.clear();
                    for frame in v[k.start * nv..k.end * nv].chunks(nv) {
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
            usb::set_realtime_priority();
            stream::send(tx, stream::burst(s, from, n, |i, v| tone.value(i, v)), depth, Duration::from_secs_f64(LEAD))
        }));
        let streamed = stream::rx_stream(rx, ctrl, s, depth, &mut check, &expect, |data, c| {
            if let Some((h, v)) = data
                && queue.send((h.time, v.to_vec())).is_err()
            {
                return Err(stream::Error::Sink("the file writer stopped"));
            }
            Ok(if src != rx_source::LOOPBACK { begin.elapsed().as_secs_f64() >= a.seconds }
               else { c.next.is_some_and(|(time, _)| time >= to + tail) })
        });
        drop(queue);
        let kept = writer.join().expect("writer thread")?;
        if let Some(sender) = sender { sender.join().expect("tx thread")?; }
        streamed?;
        Ok(kept)
    })?;
    let after = regs::counters(ctrl)?;
    let want = if src == rx_source::LOOPBACK { BURST_COUNTERS } else { [0; 7] };
    let counters_ok = check_counters(&before, &after, want);
    report_mismatches(&check);
    println!("kept {kept} sample times per channel; rx lost {}, bad values {}, bad headers {}",
             check.lost, check.bad_values, check.bad_headers);
    if check.lost > 0 {
        // The protocol makes the two origins distinguishable, and they are
        // opposite diagnoses: OVERFLOW is the FPGA saying it dropped sample
        // times because the host did not read them fast enough; a gap with no
        // flag is the data path losing them silently.
        println!("  {}", if check.overflow_flags > 0 {
            format!("the FPGA announced the drop in {} OVERFLOW header(s): the host did not keep up \
                     (writes and builds compete with {:.0} MB/s)", check.overflow_flags,
                     rate * s.bytes_per_time() as f64 / 1e6)
        } else {
            "no OVERFLOW header announced the gap: the data path lost sample times, not the host".to_string()
        });
    }
    // The sidecar is written before the verdict so a file that fails below can
    // still be read (and marked) by b210-plot.
    for (ch, path) in paths.iter().enumerate() {
        capture::write_meta(path, &capture::Meta { rate_hz: rate, channel: ch, source: c.source.clone(),
                                                   lost: check.lost })?;
    }
    if !check.clean() {
        bail!("capture: the stream was not clean - the files are a splice, not a continuous record; \
               b210-plot marks them, so their spectra are a diagnostic, not a measurement");
    }
    let mut reports: Vec<(usize, quality::Report)> = Vec::new();
    println!("analysis: {SUMMARY_FFT}-point spectrum per channel (b210-plot defaults to 4096)");
    for (ch, path) in paths.iter().enumerate() {
        let Some(r) = quality::analyze_file(path, rate, SUMMARY_FFT)? else { continue };
        reports.push((ch, r));
        let r = &reports.last().unwrap().1;
        let l = &r.level;
        print!("  ch{ch} {}: rms {:.1} dBFS, peak {:.1} dBFS, DC {:.1} dBFS", path.display(), l.rms_dbfs, l.peak_dbfs, l.dc_dbfs);
        match &r.tone {
            Some(t) => {
                print!(", tone {:+.4} MHz {:.2} dBFS, SNR {:.1} dB, SFDR {:.1} dBc, ENOB {:.2}",
                       t.freq / 1e6, t.dbfs, t.snr_db, t.sfdr_dbc, t.enob);
                if t.share < 0.9 {
                    print!(" [largest of several components, {:.0}% of the power; SNR/SFDR/ENOB describe it only - \
                            b210-plot's report has the findings]", 100.0 * t.share);
                }
                println!();
            }
            None => println!(", no tone"),
        }
    }
    if let Some(p) = &check.prbs {
        println!("PRBS: {} bits, {} mismatches, {:.1}% ones", p.bits(), p.mismatches(), 100.0 * p.ones());
    }
    // The first finding per channel (findings are ordered most serious
    // first): the same words b210-plot would give, so a capture's own summary
    // never leaves its biggest anomaly unnamed - a 42 dB-crest window is not
    // just "no tone".
    for (ch, r) in &reports {
        if let Some(note) = quality::findings(r).first() { println!("  ch{ch}: {note}"); }
    }
    if !counters_ok { bail!("capture: an event counter moved during the stream - the samples may be sound, \
                              the run is not (see above)"); }
    // Only an ADC's values can be helped by a gain: a digital source
    // (pattern, tone) spans the codes by construction, so its rails are a
    // fact to report, not a saturation to refuse.
    let refused = reports.iter().filter(|(_, r)| c.source == "radio" && quality::clipping_refuses(&r.level)).count();
    if refused > 0 { bail!("capture: the ADC saturated on {refused} channel(s) - the sample_times are not the input (see above)"); }
    println!("{}; analyse with: b210-plot {}", if check.prbs.is_some() {
        "every header and the BIST pseudo-random sequence checked"
    } else if check.check_values {
        "every sample time checked against what the source must carry"
    } else {
        "every header and the timing checked; the sample_times are the radio's"
    }, paths[0].display());
    Ok(())
}
