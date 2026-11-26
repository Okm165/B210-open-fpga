//! The AD9361 from a configuration file: reset and identify it, or bring it
//! up and apply a configuration (host/b210/examples/config.toml), step by
//! step with each step's time, the driver's polls and the PLL lock bits.

use anyhow::{Context, Result, bail};
use b210::ad9361::{self, Bus, Test};
use b210::config::Config;
use b210::device::{self, Device, Exec, PollRecord, Spi};
use b210::usb::{Usb, DEPTH_MS_DEFAULT};
use b210::stream::{self, Check};
use b210::prbs::Checker;
use b210::proto::Format;
use b210::regs;
use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Parser)]
#[command(about = "Configure the B210's AD9361")]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Reset the AD9361 (RESETB pulse) and read its product id; leaves it
    /// out of reset, unconfigured.
    Id,
    /// Bring the AD9361 up (reset, id, initialization with every
    /// calibration) and apply CONFIG. With --from, OLD is applied first and
    /// then only the differences to CONFIG (the chip's state does not
    /// outlive this process, so OLD has to be put on it first).
    Apply {
        config: PathBuf,
        #[arg(long)]
        from: Option<PathBuf>,
    },
    /// Read AD9361 registers over SPI as they are (no reset), hex addresses.
    Peek { regs: Vec<String> },
    /// Hold the AD9361 in reset (radio register 0x030 = 0).
    Reset,
    /// Bring the chip up, apply CONFIG, then select a digital test mode at
    /// its data port: `tone` (fs/32, -6 dBFS), `prbs` (its pseudo-random
    /// sequence), `loopback` (the tx port onto the rx port) or `none`.
    /// The mode stays until the chip is reset (any `apply`).
    Test {
        config: PathBuf,
        #[arg(value_parser = ["none", "tone", "prbs", "loopback"])]
        mode: String,
    },
    /// The rx data-port eye: the BIST PRBS at every clock and data delay of
    /// the chip (0x006), `seconds` of streaming per point; the delays that
    /// still give zero errors are the timing margin.
    Scan {
        config: PathBuf,
        #[arg(long, default_value_t = 0.05)]
        seconds: f64,
    },
}

fn main() -> Result<()> {
    let args = Args::parse();
    // one handle: only the scan needs the data endpoints, and a second
    // open of the interface is refused by the kernel (EBUSY)
    let mut usb = Usb::open(DEPTH_MS_DEFAULT)?;
    let version = usb.ctrl.read(regs::VERSION)?;
    println!("FPGA protocol {} build {}", version >> 16, version & 0xFFFF);
    match args.cmd {
        Cmd::Id => {
            let t = Instant::now();
            let id = device::reset(&mut usb.ctrl)?;
            println!("reset + read: {:.3} ms", ms(t));
            println!("AD9361 product id {PRODUCT:#05x} = {id:#04x} (product {:#04x}, revision {})", id & 0xF8, id & 7,
                     PRODUCT = device::PRODUCT_ID);
            println!("radio register {:#05x} = {:#x}", regs::RADIO, usb.ctrl.read(regs::RADIO)?);
            if id != device::PRODUCT_ID_VALUE {
                bail!("expected {:#04x}", device::PRODUCT_ID_VALUE);
            }
        }
        Cmd::Peek { regs } => {
            let mut spi = Spi::new(&mut usb.ctrl);
            for r in regs {
                let reg = u16::from_str_radix(r.trim_start_matches("0x"), 16).with_context(|| format!("register {r}"))?;
                println!("{reg:#05x} = {:#04x}", spi.read([reg])?[0]);
            }
        }
        Cmd::Reset => {
            device::hold_reset(&mut usb.ctrl)?;
            println!("radio register {:#05x} = {:#x}: AD9361 held in reset", regs::RADIO, usb.ctrl.read(regs::RADIO)?);
        }
        Cmd::Apply { config, from } => {
            let new = load(&config)?;
            let old = from.as_deref().map(load).transpose()?;
            apply(&mut usb.ctrl, old.as_ref(), &new)?;
        }
        Cmd::Scan { config, seconds } => {
            let cfg = load(&config)?;
            let depth = usb.depth;
            let mut dev = apply(&mut usb.ctrl, None, &cfg)?;
            dev.ad.set_test(Test::Prbs)?;
            // the port's mode follows the configuration's rx channels
            // a valid config has one channel (ch0) or two
            let mask = match cfg.chains().rx_count() {
                2 => 0b11,
                1 => 0b01,
                _ => bail!("scan needs a [rx] section with channels"),
            };
            let s = stream::Shape { format: Format::Sc16, mask };
            let expect = |_t: u64| [0i16; 4];
            // one PRBS bit per 16-bit word per data line: I and Q of every
            // channel, so 2 x count words per sample time
            let bits = (seconds * cfg.rate_hz * (2 * s.count()) as f64).round() as u64;
            println!("scanning rx clock 0..15 x data 0..15, {seconds:.3} s each ({bits} PRBS bits a point); o = 0 errors");
            let mut pass = [[false; 16]; 16];
            for clock in 0..16u8 {
                for data in 0..16u8 {
                    dev.ad.set_delays(clock << 4 | data, ad9361::TX_DELAYS)?;
                    let mut check = Check::default();
                    check.check_values = false;
                    check.prbs = Some(Checker::default());
                    let begin = Instant::now();
                    let ctrl = &mut **dev.ad.bus().ctrl();
                    stream::rx_stream(&mut usb.rx, ctrl, s, depth, &mut check, &expect,
                                      |_, _| Ok(begin.elapsed().as_secs_f64() >= seconds))
                        .with_context(|| format!("clock {clock}, data {data}"))?;
                    pass[clock as usize][data as usize] =
                        check.prbs.as_ref().is_some_and(|p| p.ok());
                }
                print!("  {clock:2} ");
                for ok in &pass[clock as usize] { print!("{}", if *ok { 'o' } else { '.' }); }
                println!();
            }
            println!("     0123456789abcdef");
            dev.ad.set_delays(ad9361::RX_DELAYS, ad9361::TX_DELAYS)?;
            dev.ad.set_test(Test::None)?;
            let ok = pass.iter().flatten().filter(|p| **p).count();
            println!("{ok} of 256 points pass ({bits} bits each; a point at the window edge can pass or fail \
                      between runs); the chip's delays restored to {:#04x}", ad9361::RX_DELAYS);
            if ok == 0 { bail!("no delay pair carries the PRBS: the port is not working"); }
        }
        Cmd::Test { config, mode } => {
            let test = match mode.as_str() {
                "none" => Test::None,
                "tone" => Test::Tone,
                "prbs" => Test::Prbs,
                _ => Test::Loopback,
            };
            let mut dev = apply(&mut usb.ctrl, None, &load(&config)?)?;
            dev.ad.set_test(test)?;
            println!("digital test mode {mode}: the AD9361 now drives its data port with it");
            println!("capture it with: b210 capture --source radio ...; any `apply` clears it");
        }
    }
    Ok(())
}

fn load(path: &Path) -> Result<Config> {
    let text = std::fs::read_to_string(path).with_context(|| format!("{}", path.display()))?;
    Config::parse(&text).with_context(|| format!("{}", path.display()))
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1e3
}

/// BBPLL lock (0x05E bit 7), rx and tx RF PLL lock (0x247, 0x287 bit 1),
/// ENSM state (0x017 bits 3:0), calibrations running (0x016).
const STATUS_REGS: [u16; 5] = [0x05E, 0x247, 0x287, 0x017, 0x016];

/// The chip as it is after an error, for diagnosis.
fn print_status_after_error<E: Exec>(spi: &mut Spi<E>) {
    if let Ok(v) = spi.read(STATUS_REGS) {
        println!("after the error: {}", status_line(v));
    }
}

fn status_line([bb, rx, tx, ensm, cal]: [u8; 5]) -> String {
    let lock = |v: u8, bit: u8| if v & bit != 0 { "locked" } else { "UNLOCKED" };
    format!(
        "BBPLL {} ({bb:#04x}), rx PLL {} ({rx:#04x}), tx PLL {} ({tx:#04x}), ENSM {:#x}, cal {cal:#04x}",
        lock(bb, 0x80), lock(rx, 0x02), lock(tx, 0x02), ensm & 0x0F
    )
}

/// What a driver poll waits for.
fn poll_name(p: &PollRecord) -> String {
    let cal = |m: u8| match m {
        0x01 => "BB DC offset cal",
        0x02 => "RF DC offset cal",
        0x10 => "TX quadrature cal",
        0x20 => "RX quadrature cal",
        0x40 => "TX BB filter cal",
        0x80 => "RX BB filter cal",
        _ => "cal",
    };
    match p.reg {
        0x05E => "BBPLL lock".into(),
        0x244 => "rx charge pump cal".into(),
        0x284 => "tx charge pump cal".into(),
        0x247 => "rx RF PLL lock".into(),
        0x287 => "tx RF PLL lock".into(),
        0x016 => cal(p.mask).into(),
        0x017 => format!("ENSM state {:#x}", p.want),
        r => format!("reg {r:#05x}"),
    }
}

fn print_polls(polls: &mut Vec<PollRecord>) {
    for p in polls.drain(..) {
        println!(
            "    poll {:<20} {:#05x} & {:#04x} == {:#04x} within {:>5} ms: {} (read {:#04x})",
            poll_name(&p), p.reg, p.mask, p.want, p.ms, if p.ok { "ok" } else { "TIMEOUT" }, p.value
        );
    }
}

fn apply<E: Exec>(ctrl: E, old: Option<&Config>, new: &Config) -> Result<Device<E>> {
    let mut configs = Vec::new();
    if let Some(old) = old {
        configs.push(("from", old));
    }
    configs.push(("to", new));
    let mut before = None;
    for (name, c) in &configs {
        println!("plan {name}:");
        for (k, change) in Config::changes(before, c).iter().enumerate() {
            println!("  {:>2}. {change:?}", k + 1);
        }
        before = Some(*c);
    }

    println!("bring-up (RESETB pulse, product id, Ad9361::init):");
    let t = Instant::now();
    let mut dev = match Device::bring_up(ctrl) {
        Ok(dev) => dev,
        Err((e, ctrl)) => {
            print_status_after_error(&mut Spi::new(ctrl));
            return Err(e.into());
        }
    };
    let elapsed = ms(t);
    let stats = dev.ad.bus().stats;
    print_polls(&mut dev.ad.bus().polls);
    let status = dev.ad.bus().read(STATUS_REGS)?;
    println!("  {elapsed:.1} ms, {} packets, {} operations; {}", stats.packets, stats.ops, status_line(status));

    for (name, c) in configs {
        println!("apply {name}:");
        let mut k = 0;
        let mut last = dev.ad.bus().stats;
        let mut failed = None;
        let r = dev.apply_with(c, |change, took, ad| {
            k += 1;
            let bus = ad.bus();
            let s = bus.stats;
            println!("  {k:>2}. {change:?}: {:.1} ms, {} packets, {} operations", took.as_secs_f64() * 1e3,
                     s.packets - last.packets, s.ops - last.ops);
            print_polls(&mut bus.polls);
            match bus.read(STATUS_REGS) {
                Ok(v) => println!("      {}", status_line(v)),
                Err(e) => failed = Some(e),
            }
            last = bus.stats;
        });
        if let Err(e) = r {
            println!("  {:>2}. failed: {e}", k + 1);
            print_polls(&mut dev.ad.bus().polls);
            print_status_after_error(dev.ad.bus());
            return Err(e.into());
        }
        if let Some(e) = failed {
            return Err(e.into());
        }
    }
    let polls_ok = dev.ad.bus().polls.iter().all(|p| p.ok);
    println!("done: every poll {}", if polls_ok { "succeeded" } else { "did not succeed" });
    Ok(dev)
}
