//! b210 - board access and the step-1 measurements.
//!
//!   b210 load IMAGE.bin            load the FPGA, start the bus
//!   b210 read ADDR | write ADDR VALUE
//!   b210 rx-test [options]         stream the FPGA's pattern; check every
//!                                  sample and time; report rate and losses

use anyhow::{bail, Context, Result};
use b210::proto::{self, flag, Format, Header, Kind};
use b210::regs::{self, rx, test};
use b210::usb::Usb;
use clap::{Parser, Subcommand};
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
    /// Read a register (hex or decimal address)
    Read { addr: String },
    /// Write a register
    Write { addr: String, value: String },
    /// Stream the pattern f(t); every sample and timestamp checked
    RxTest {
        #[arg(long, default_value_t = 10.0)]
        seconds: f64,
        /// sc16 or sc12
        #[arg(long, default_value = "sc16")]
        format: String,
        /// 1 or 2
        #[arg(long, default_value_t = 1)]
        channels: u32,
        /// a sample strobe every DIV + 1 cycles of the 61.54 MHz test clock
        #[arg(long, default_value_t = 0)]
        div: u32,
        /// sample times per packet (0: a full packet)
        #[arg(long, default_value_t = 0)]
        spp: u32,
        /// transfers in flight
        #[arg(long, default_value_t = 64)]
        depth: usize,
    },
}

fn number(s: &str) -> Result<u32> {
    Ok(match s.strip_prefix("0x") {
        Some(h) => u32::from_str_radix(h, 16)?,
        None => s.parse()?,
    })
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let mut usb = Usb::open()?;
    match cli.cmd {
        Cmd::Load { image } => {
            let bytes = std::fs::read(&image).with_context(|| format!("{}", image.display()))?;
            let start = Instant::now();
            usb.load_fpga(&bytes)?;
            let id = usb.read(regs::ID)?;
            println!("loaded {} ({} bytes) in {:.1} s; id {id:08x}, version {:08x}, build {:08x}",
                     image.display(), bytes.len(), start.elapsed().as_secs_f64(),
                     usb.read(regs::VERSION)?, usb.read(regs::BUILD)?);
            if id != regs::ID_VALUE {
                bail!("id {id:08x}, expected {:08x}", regs::ID_VALUE);
            }
        }
        Cmd::Read { addr } => println!("{:08x}", usb.read(number(&addr)? as u16)?),
        Cmd::Write { addr, value } => usb.write(number(&addr)? as u16, number(&value)?)?,
        Cmd::RxTest { seconds, format, channels, div, spp, depth } => {
            rx_test(&mut usb, seconds, &format, channels, div, spp, depth)?
        }
    }
    Ok(())
}

/// What an rx stream showed.
#[derive(Default)]
struct Tally {
    packets: u64,
    samples: u64,
    lost: u64,          // sample times missing between packets
    overflow_flags: u64,
    bad_values: u64,
    bad_headers: u64,
    ended: bool,
}

fn rx_test(usb: &mut Usb, seconds: f64, format: &str, channels: u32, div: u32, spp: u32, depth: usize) -> Result<()> {
    let (fmt, code) = match format {
        "sc16" => (Format::Sc16, 1),
        "sc12" => (Format::Sc12, 2),
        _ => bail!("format: sc16 or sc12"),
    };
    let mask = match channels { 1 => 0b01, 2 => 0b11, _ => bail!("channels: 1 or 2") };
    let nch = channels as usize;
    let full = fmt.times_per_packet(nch) as u32;
    let rate = 1200e6 / 19.5 / (div as f64 + 1.0);
    println!("rx {format} x{channels}: {:.3} MS/s, {:.1} MB/s, {} sample times per packet",
             rate / 1e6, rate * fmt.bytes_per_time(nch) as f64 / 1e6, if spp == 0 { full } else { spp });

    usb.write(regs::RX_CTRL, rx::STOP)?;
    let before: Vec<u32> = (0..6).map(|k| usb.read(regs::EVENTS + k)).collect::<Result<_, _>>()?;
    usb.write(regs::TEST, test::PATTERN)?;
    usb.write(regs::TEST_DIV, div)?;
    usb.write(regs::RX_SPP, if spp == 0 { full } else { spp })?;
    usb.write(regs::RX_COUNT, 0)?;
    for _ in 0..depth {
        let buf = usb.rx.allocate(proto::DATA_BUFFER);
        usb.rx.submit(buf);
    }
    usb.write(regs::RX_CTRL, rx::START | rx::config(code, mask))?;

    let mut tally = Tally::default();
    let mut next: Option<(u64, u16)> = None;    // expected time and sequence
    let mut values = vec![0i16; 2 * 2 * 8192];
    let start = Instant::now();
    let mut stopping = false;
    while !tally.ended {
        if !stopping && start.elapsed().as_secs_f64() >= seconds {
            usb.write(regs::RX_CTRL, rx::STOP)?;
            stopping = true;
        }
        let c = usb.rx.wait_next_complete(Duration::from_secs(2))
            .context("no rx packet for 2 s")?;
        let n = c.actual_len;
        let buf = c.into_result()?;
        check_packet(&buf[..n], fmt, nch, mask as u8, &mut next, &mut values, &mut tally);
        usb.rx.submit(buf);
    }
    let elapsed = start.elapsed().as_secs_f64();
    usb.rx.cancel_all();
    while usb.rx.pending() > 0 {
        usb.rx.wait_next_complete(Duration::from_secs(1));
    }
    let after: Vec<u32> = (0..6).map(|k| usb.read(regs::EVENTS + k)).collect::<Result<_, _>>()?;
    let rx_lost = usb.read(regs::RX_LOST)?;
    println!("{} packets, {} sample times in {:.2} s = {:.3} MS/s", tally.packets, tally.samples, elapsed,
             tally.samples as f64 / elapsed / 1e6);
    println!("lost {} sample times ({} packets flagged OVERFLOW); bad values {}, bad headers {}",
             tally.lost, tally.overflow_flags, tally.bad_values, tally.bad_headers);
    println!("FPGA: overflow +{}, rx_lost {}", after[0].wrapping_sub(before[0]), rx_lost);
    if tally.lost != 0 || tally.bad_values != 0 || tally.bad_headers != 0 || rx_lost != 0 {
        bail!("rx test FAILED");
    }
    println!("rx test PASSED: every sample checked, none lost");
    Ok(())
}

fn check_packet(p: &[u8], fmt: Format, nch: usize, mask: u8, next: &mut Option<(u64, u16)>,
                values: &mut [i16], t: &mut Tally) {
    let h = match Header::decode(p) {
        Ok(h) if h.kind == Kind::Rx && h.format == fmt && h.channels == mask && h.flags & flag::HAS_TIME != 0 => h,
        _ => { t.bad_headers += 1; return; }
    };
    let bpt = fmt.bytes_per_time(nch);
    let payload = h.length as usize - proto::HEADER;
    if !payload.is_multiple_of(bpt) || p.len() < h.length as usize {
        t.bad_headers += 1;
        return;
    }
    let n = payload / bpt;
    if let Some((time, seq)) = *next {
        if h.sequence != seq {
            t.bad_headers += 1;
        }
        let gap = proto::lost(time, 0, h.time);
        if gap > 0 {
            t.lost += gap as u64;
        } else if gap < 0 {
            t.bad_headers += 1;
        }
        if (gap > 0) != (h.flags & flag::OVERFLOW != 0) {
            t.bad_headers += 1;
        }
    }
    if h.flags & flag::OVERFLOW != 0 {
        t.overflow_flags += 1;
    }
    let body = &p[proto::HEADER..proto::HEADER + payload];
    let nv = 2 * nch;
    match fmt {
        Format::Sc16 => proto::unpack_sc16(body, &mut values[..n * nv]),
        _ => proto::unpack_sc12(body, &mut values[..n * nv]),
    }
    let first = if mask == 0b10 { 2 } else { 0 };
    for k in 0..n {
        let time = h.time + k as u64;
        for v in 0..nv {
            if values[k * nv + v] != test::pattern(time, first + v) {
                if t.bad_values < 5 {
                    eprintln!("time {time} value {v}: {}, expected {}", values[k * nv + v], test::pattern(time, first + v));
                }
                t.bad_values += 1;
            }
        }
    }
    t.packets += 1;
    t.samples += n as u64;
    *next = Some((h.time + n as u64, h.sequence.wrapping_add(1)));
    if h.flags & flag::END_OF_BURST != 0 {
        t.ended = true;
    }
}
