//! Transmit a complex tone through the RF TX port and measure what the RX
//! antenna receives, at each rx gain: the one stage the digital loopback
//! (`b210 loop-test`) does not reach.
//!
//! What it proves, and what it needs:
//! - The TX chain (FPGA → AD9361 DAC → RF) actually radiates: with the two
//!   ports coupled (one antenna on TX/RX, or a cable), the tone appears on rx
//!   at the transmitted frequency.
//! - The rx gain index moves a *known* signal: the level steps with the gain,
//!   unlike an empty channel, whose floor hides gains below about 45 dB
//!   (docs/DESIGN.md, "the receiver's own floor").
//! - The two LOs agree: the tone's frequency offset from nominal is their
//!   difference (same 40 MHz reference, so it is small).
//!
//! Usage: rf_tone CONFIG.toml [gains]   (default gains 20,30,40,50,60,70)
//! The config needs one rx channel (ch0) and one tx channel (ch0); the burst
//! is -10 dBFS at +1 MHz, so it is 1 MHz away from DC and inside the band.
//! The transmitter runs at whatever attenuation the config's tx gain sets:
//! the example config's 60 dB is 29.75 dB of attenuation, about -25 dBm.

use anyhow::{bail, Context, Result};
use b210::config::Config;
use b210::device::Device;
use b210::dsp::TestTone;
use b210::proto::Format;
use b210::quality;
use b210::regs::{self, rx_source};
use b210::stream::{self, Check, Shape};
use b210::usb::{self, Usb, DEPTH_MS_DEFAULT};
use std::time::{Duration, Instant};

/// The complex amplitude of a tone at `f` in interleaved I/Q samples, in
/// codes: |sum x[n] e^(-j2 pi f n / rate)| / n. A complex exponential of
/// amplitude A gives A, so the level is 20 log10(A / 2048) dBFS, whether or
/// not the tone stands 30 dB above the floor (quality::analyze's criterion
/// for calling it a tone at all).
fn amplitude(iq: &[i16], rate: f64, f: f64) -> f64 {
    let (mut re, mut im) = (0.0f64, 0.0f64);
    let dphi = -2.0 * std::f64::consts::PI * f / rate;
    let (mut c, mut s) = (1.0f64, 0.0f64);
    for p in iq.as_chunks::<2>().0 {
        let (i, q) = (p[0] as f64, p[1] as f64);
        re += i * c - q * s;
        im += i * s + q * c;
        let (c2, s2) = (c * dphi.cos() - s * dphi.sin(), c * dphi.sin() + s * dphi.cos());
        c = c2 / (c2 * c2 + s2 * s2).sqrt(); // renormalise against drift
        s = s2 / (c2 * c2 + s2 * s2).sqrt();
    }
    (re * re + im * im).sqrt() / (iq.len() / 2) as f64
}

/// Seconds of rx per gain; the tx burst and the lead the rx waits after it is
/// scheduled, so the tone is already flowing when the capture starts: a burst
/// that starts inside the capture would make the coherent level depend on
/// where it landed.
const CAPTURE_S: f64 = 0.2;
const BURST_S: f64 = CAPTURE_S + 1.0;
/// Long enough that the FPGA's tx ring is full when the burst's first tick
/// comes: a shorter lead lets the stream underflow at the start, which puts a
/// gap in the tone the correlator then averages over.
const LEAD: f64 = 0.3;
/// The tone: 1 MHz from DC, 10 dB below full scale at the DAC.
const TONE_HZ: f64 = 1e6;
const TONE_DBFS: f64 = -10.0;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().context("usage: rf_tone CONFIG.toml [gains]")?;
    let gains: Vec<f64> = match args.next() {
        Some(list) => list.split(',').map(|g| g.trim().parse().with_context(|| format!("gain {g}"))).collect::<Result<_>>()?,
        None => vec![20.0, 30.0, 40.0, 50.0, 60.0, 70.0],
    };
    let text = std::fs::read_to_string(&path).with_context(|| path.clone())?;
    let base = Config::parse(&text).with_context(|| path.clone())?;
    match (&base.rx.as_ref().and_then(|r| r.ch0.as_ref()), &base.tx.as_ref().and_then(|t| t.ch0.as_ref())) {
        (Some(_), Some(t)) if base.rx.as_ref().is_some_and(|r| r.ch1.is_none()) && base.tx.as_ref().is_some_and(|t| t.ch1.is_none()) => {
            if base.tx.as_ref().is_some_and(|t| t.lo_hz != base.rx.as_ref().map_or(f64::NAN, |r| r.lo_hz)) {
                println!("note: rx and tx LO differ, so the tone appears at +{:.3} MHz + (rx LO - tx LO)",
                         TONE_HZ / 1e6);
            }
            println!("tx gain {:.2} dB (attenuation {:.2} dB)", t.gain_db, 89.75 - t.gain_db);
        }
        _ => bail!("the config needs exactly one rx channel (ch0) and one tx channel (ch0)"),
    }

    let mut usb = Usb::open(DEPTH_MS_DEFAULT)?;
    let s = Shape { format: Format::Sc12, mask: 0b01 };
    println!("{:>6}  {:>10}  {:>9}  {:>7}   {:>9}  {:>9}", "rx dB", "+1MHz dBFS", "rms dBFS",
             "clipped", "peak dBFS", "peak MHz");
    let mut tone_db: Vec<(f64, f64)> = Vec::new();
    for g in gains {
        let mut cfg = base.clone();
        if let Some(ch) = cfg.rx.as_mut().and_then(|r| r.ch0.as_mut()) { ch.gain_db = g; }
        {
            let mut dev = Device::bring_up(&mut usb.ctrl).map_err(|(e, _)| e)?;
            dev.apply(&cfg)?;
        }
        let rate = regs::sample_rate(&mut usb.ctrl)?;
        s.check_bus_full_duplex(rate)?;
        regs::setup(&mut usb.ctrl, rx_source::RADIO)?;
        let at = regs::now(&mut usb.ctrl)? + (LEAD * rate) as u64;
        let n = (BURST_S * rate) as u64;
        let before = regs::counters(&mut usb.ctrl)?;
        let tone = TestTone::new(TONE_HZ, rate, TONE_DBFS);
        let Usb { ctrl, tx, rx, depth } = &mut usb;
        let depth = *depth;
        let mut check = Check::default();
        check.check_values = false;
        let mut iq = Vec::with_capacity((CAPTURE_S * rate * 2.0) as usize);
        let begin = Instant::now();
        let (rx_result, tx_result) = std::thread::scope(|scope| {
            let sender = scope.spawn(move || {
                usb::set_realtime_priority();
                stream::send(tx, stream::burst(s, at, n, |i, k| tone.value(i, k)), depth,
                             Duration::from_secs_f64(LEAD))
            });
            // the burst is scheduled LEAD ahead: wait until it is flowing, so
            // the whole capture holds the tone
            std::thread::sleep(Duration::from_secs_f64(LEAD + 0.15));
            let r = stream::rx_stream(rx, ctrl, s, depth, &mut check, &|_t| [0i16; 4], |packet, _| {
                if let Some((_, v)) = packet { iq.extend_from_slice(v); }
                Ok(begin.elapsed().as_secs_f64() >= CAPTURE_S)
            });
            (r, sender.join().expect("tx thread"))
        });
        rx_result?;
        let packets = tx_result?;
        let after = regs::counters(ctrl)?;
        let moved: Vec<String> = b210::regs::COUNTER_NAMES.iter().zip(before.iter().zip(after.iter()))
            .filter(|(_, (a, b))| a != b).map(|(n, (a, b))| format!("{n} +{}", b.wrapping_sub(*a))).collect();
        if !moved.is_empty() { println!("  counters moved: {}", moved.join(", ")); }
        let r = quality::analyze(&iq, rate, 16_384).context("empty capture")?;
        let l = &r.level;
        let tone = b210::dsp::dbfs(amplitude(&iq, rate, TONE_HZ).powi(2));
        let peak = r.tone.as_ref().map_or((f64::NAN, f64::NAN), |t| (t.freq, t.dbfs));
        println!("{:>6.0}  {:>10.2}  {:>9.2}  {:>7.4}%   {:>9.2}  {:>+9.3}",
                 g, tone, l.rms_dbfs, 100.0 * l.clipped_fraction, peak.1, peak.0 / 1e6);
        if !check.clean() {
            println!("  the rx stream was not clean: lost {}, bad values {}, bad headers {}",
                     check.lost, check.bad_values, check.bad_headers);
        }
        println!("  {packets} tx packets, {:.0} ms", 1e3 * begin.elapsed().as_secs_f64());
        tone_db.push((g, tone));
    }
    // A known tone steps with the gain (about 1 dB per dB, the gain table's
    // calibration); a flat column means the tone never reached the ADC (no
    // coupling, wrong port, or TX off). Only levels above -100 dBFS are the
    // tone: below that the correlator measures the receiver's own floor.
    let seen: Vec<(f64, f64)> = tone_db.iter().copied().filter(|(_, v)| v.is_finite() && *v > -100.0).collect();
    match (seen.first(), seen.last()) {
        (Some(&(g0, l0)), Some(&(g1, l1))) if seen.len() >= 2 => println!(
            "tone {l0:.2} dBFS at {g0:.0} dB and {l1:.2} dBFS at {g1:.0} dB: {:.2} dB per dB of gain",
            (l1 - l0) / (g1 - g0)),
        _ => println!("no tone above -100 dBFS at any gain: nothing coupled from TX to RX"),
    }
    Ok(())
}
