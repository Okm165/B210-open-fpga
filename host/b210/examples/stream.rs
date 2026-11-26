//! A minimal end-to-end client: open the board, bring the AD9361 up, apply
//! a configuration, stream the antenna for N seconds, and print the level
//! and the stream's audit. It makes the same calls as the `b210` binary,
//! in the order the hardware requires:
//!
//!   Usb::open            one handle for the interface
//!   Device::bring_up     RESETB pulse, product id, every AD9361 calibration
//!   Device::apply        only the differences from the chip's state
//!   regs::setup          rx source = the radio, counters cleared
//!   stream::rx_stream    transfers, packet checks, the callback
//!
//! Run it from `host/` (the first argument is a config, the second the
//! seconds to stream):
//!
//!   cargo run --release --example stream -- b210/examples/config.toml 5
//!
//! The callback receives each packet's interleaved I/Q (I0 Q0, or
//! I0 Q0 I1 Q1 per sample time), 12-bit codes in i16. `Check` is the audit
//! every tool prints: packets, sample times, lost, bad values, bad headers,
//! overflow flags; `clean()` is the gate.

use anyhow::{bail, Context, Result};
use b210::config::Config;
use b210::device::Device;
use b210::proto::Format;
use b210::regs::{self, rx_source};
use b210::stream::{self, Check, Shape};
use b210::usb::{Usb, DEPTH_MS_DEFAULT};
use std::time::Instant;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let config = args.next().unwrap_or_else(|| "b210/examples/config.toml".into());
    let seconds: f64 = match args.next() {
        Some(s) => s.parse().with_context(|| format!("seconds {s}"))?,
        None => 3.0,
    };
    let text = std::fs::read_to_string(&config).with_context(|| config.clone())?;
    let cfg = Config::parse(&text).with_context(|| config)?;

    let mut usb = Usb::open(DEPTH_MS_DEFAULT)?;
    let mut dev = Device::bring_up(&mut usb.ctrl).map_err(|(e, _)| e)?;
    dev.apply(&cfg)?;

    // the stream's shape: sc12, the channels the applied direction enables
    // (one channel is channel 0), then the same checks every command makes
    let s = Shape { format: Format::Sc12, mask: match cfg.chains().rx_count() { 2 => 0b11, _ => 0b01 } };
    let rate = regs::sample_rate(&mut usb.ctrl)?;
    s.check_bus(rate)?;
    regs::setup(&mut usb.ctrl, rx_source::RADIO)?;
    println!("{:.3} MS/s, {} channel(s), {seconds} s", rate / 1e6, s.count());

    let nv = 2 * s.count();
    let (mut sum, mut peak) = (vec![0f64; s.count()], vec![0f64; s.count()]);
    let mut check = Check::default();
    check.check_values = false; // the radio has no closed form to compare against
    let begin = Instant::now();
    let expect = |_t: u64| [0i16; 4];
    let streamed = stream::rx_stream(
        &mut usb.rx, &mut usb.ctrl, s, usb.depth, &mut check, &expect,
        |packet, _| {
            if let Some((_, v)) = packet {
                for frame in v.chunks(nv) {
                    for (ch, p) in frame.as_chunks::<2>().0.iter().enumerate() {
                        let (i, q) = (p[0] as f64, p[1] as f64);
                        sum[ch] += i * i + q * q;
                        peak[ch] = peak[ch].max((i * i + q * q).sqrt());
                    }
                }
            }
            Ok(begin.elapsed().as_secs_f64() >= seconds)
        },
    )?;

    let frames = check.samples.max(1) as f64;
    for ch in 0..s.count() {
        let rms = (sum[ch] / frames).sqrt().max(1e-12);
        println!("ch{ch}: rms {:.1} dBFS, peak {:.1} dBFS",
                 20.0 * (rms / 2048.0).log10(), 20.0 * (peak[ch] / 2048.0).log10());
    }
    println!("{} sample times in {streamed:.2} s; lost {}, bad values {}, bad headers {}, overflow flags {}",
             check.samples, check.lost, check.bad_values, check.bad_headers, check.overflow_flags);
    if !check.clean() {
        bail!("the stream was not clean");
    }
    Ok(())
}
