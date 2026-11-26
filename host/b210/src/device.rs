//! The AD9361 on the board: the driver's [`Bus`] carried by the FPGA's
//! command operations (docs/PROTOCOL.md section 4), the bring-up from the
//! RESETB pin, and [`Device::apply`], which takes the chip from the
//! configuration it holds to a new one (`config::Config::changes`).
//!
//! # The bus
//!
//! [`Spi`] binds [`Bus`] on [`Exec`] (`usb::Ctrl::exec`) as the driver's
//! `Bus` doc prescribes:
//! - `write(reg, v)`: `Op::Spi { device: SPI_AD9361, word: ad9361::spi_write(reg, v) }`
//!   (24-bit frame: bit 23 write, bits 17:8 address, bits 7:0 data);
//! - `wait(us)`: `Op::Wait { us }`;
//! - `poll(reg, m, w, ms)`: `Op::Spi { word: ad9361::spi_read(reg) }`, then
//!   `Op::Poll { mask: m, value: w, ms }`; ms = 0 is one try; above 255 ms
//!   (the operation's 8-bit `arg`) consecutive POLLs of at most 255 ms, the
//!   last taking the remainder, each repeating the same SPI read
//!   (PROTOCOL.md: POLL repeats the last READ or SPI executed, in this packet
//!   or an earlier one, so a chain may cross a packet boundary). The outcome
//!   is the last POLL's status; its timeout becomes [`ad9361::Error::Poll`]
//!   with the value it read last (the POLL's result data). The earlier
//!   POLLs' timeouts are no outcome: they only mean "not yet";
//! - `read(regs)`: one SPI read per register after the queue, the low 8 bits
//!   of their results;
//! - the queue is executed as one command packet when it holds
//!   `proto::MAX_OPS` (126) operations and another is queued, and by `read`
//!   and `flush`.
//!
//! A POLL timeout does not stop the FPGA (the packet runs on); the first one
//! is kept and returned by the next `read` or `flush`, which is where the
//! driver expects it. Any other non-zero status (unknown opcode: the rest
//! of the packet was skipped) is a bus error at once.

use crate::ad9361::{self, Ad9361, Bus, Dir};
use crate::config::{self, Change, Config};
use crate::proto::{self, Op, Reply, Status, SPI_AD9361};
use crate::regs;
use crate::usb;
use std::time::{Duration, Instant};

/// regs::RADIO bit 0: the AD9361 RESETB pin, 0 = held in reset.
pub const RESETB: u32 = 1 << 0;
/// regs::RADIO bit 1: the data port carries two channels, a sample time
/// every two DATA_CLK periods. It must match the AD9361's data port, which
/// this driver always sets to 2R2T (0x010 = 0xC8, a 50 % frame pulse), and
/// may change only while no stream runs.
pub const TWO_R2T: u32 = 1 << 1;
/// The AD9361 out of reset with its data port as configured: the value
/// every release from reset writes.
pub const RUN: u32 = RESETB | TWO_R2T;

/// The AD9361 product id register and the value this board reads and the
/// driver's `mock::settled` rule answers: product 0x08 (bits 7:3),
/// revision 2 (bits 2:0) (v1 measurement, docs/STATUS.md at tag
/// v1-ettus-uhd).
pub const PRODUCT_ID: u16 = 0x037;
pub const PRODUCT_ID_VALUE: u8 = 0x0A;

/// RESETB low time and the wait after its release, us: ADI's, low 1 ms,
/// then 1 ms before the first SPI access (no-OS ad9361.c `ad9361_reset`,
/// mdelay(1) on each side of the GPIO edge). ADI resets by this pin
/// whenever there is one: its SPI soft reset "was removed from the register
/// map, since it doesn't work reliably". UHD (b200_impl.cpp `reset_codec`)
/// toggles the pin with two back-to-back register writes and relies on the
/// soft reset and 20 ms wait that `Ad9361::init` keeps.
pub const RESET_LOW_US: u32 = 1_000;
pub const RESET_RECOVERY_US: u32 = 1_000;

/// POLL's time limit is the operation's 8-bit `arg`, ms.
const POLL_MAX_MS: u32 = 255;

/// The transport: one command packet of at most `proto::MAX_OPS`
/// operations; its results in order (count checked, statuses not).
pub trait Exec {
    fn exec(&mut self, ops: &[Op]) -> usb::Result<Vec<Reply>>;
}

impl Exec for usb::Ctrl {
    fn exec(&mut self, ops: &[Op]) -> usb::Result<Vec<Reply>> {
        usb::Ctrl::exec(self, ops)
    }
}

impl<E: Exec + ?Sized> Exec for &mut E {
    fn exec(&mut self, ops: &[Op]) -> usb::Result<Vec<Reply>> {
        (**self).exec(ops)
    }
}

/// What a queued operation is, for reading its result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tag {
    /// A write, a wait, the SPI read that starts a poll: status must be ok.
    Plain,
    /// A POLL before the last of its chain: its timeout is no outcome.
    PollMid,
    /// The last POLL of a chain: its status is the poll's outcome.
    PollEnd { reg: u16, mask: u8, want: u8, ms: u32 },
    /// An SPI read whose value `read` returns.
    Read,
}

/// One driver poll as the FPGA answered it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PollRecord {
    pub reg: u16,
    pub mask: u8,
    pub want: u8,
    /// The limit, ms (0: one try).
    pub ms: u32,
    /// The last value read.
    pub value: u8,
    pub ok: bool,
}

/// Bus traffic, cumulative.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub packets: usize,
    pub ops: usize,
}

/// [`Bus`] on the FPGA's command operations (module doc), owning the
/// transport.
pub struct Spi<E: Exec = usb::Ctrl> {
    ctrl: E,
    queue: Vec<(Op, Tag)>,
    /// The results of `Tag::Read` operations since `read` began.
    values: Vec<u8>,
    /// The first POLL timeout not yet reported.
    failed: Option<ad9361::Error>,
    /// Every poll's outcome, in order; the owner drains it.
    pub polls: Vec<PollRecord>,
    pub stats: Stats,
}

fn bus_error(e: impl std::error::Error + Send + Sync + 'static) -> ad9361::Error {
    ad9361::Error::Bus(Box::new(e))
}

fn status_error(r: &Reply) -> usb::Error {
    usb::Error::Status { opcode: r.opcode, addr: r.addr, status: r.status }
}

impl<E: Exec> Spi<E> {
    pub fn new(ctrl: E) -> Self {
        Spi { ctrl, queue: Vec::with_capacity(proto::MAX_OPS), values: Vec::new(), failed: None, polls: Vec::new(), stats: Stats::default() }
    }

    /// The transport back. Operations still queued are dropped: `flush` first.
    pub fn into_ctrl(self) -> E {
        self.ctrl
    }

    /// The transport, for operations outside the AD9361 (FPGA registers);
    /// `flush` first to keep the order.
    pub fn ctrl(&mut self) -> &mut E {
        &mut self.ctrl
    }

    fn push(&mut self, op: Op, tag: Tag) -> ad9361::Result<()> {
        if self.queue.len() == proto::MAX_OPS {
            self.run()?;
        }
        self.queue.push((op, tag));
        Ok(())
    }

    /// Execute the queue as one command packet and sort its results.
    fn run(&mut self) -> ad9361::Result<()> {
        if self.queue.is_empty() {
            return Ok(());
        }
        let ops: Vec<Op> = self.queue.iter().map(|&(op, _)| op).collect();
        let replies = self.ctrl.exec(&ops).map_err(bus_error)?;
        self.stats.packets += 1;
        self.stats.ops += ops.len();
        for (r, (_, tag)) in replies.iter().zip(self.queue.drain(..)) {
            match (tag, r.status) {
                (Tag::PollEnd { reg, mask, want, ms }, s @ (Status::Ok | Status::Timeout)) => {
                    let (value, ok) = (r.data as u8, s == Status::Ok);
                    self.polls.push(PollRecord { reg, mask, want, ms, value, ok });
                    if !ok && self.failed.is_none() {
                        self.failed = Some(ad9361::Error::Poll { reg, mask, want, value });
                    }
                }
                (Tag::PollMid, Status::Ok | Status::Timeout) | (Tag::Plain, Status::Ok) => {}
                (Tag::Read, Status::Ok) => self.values.push(r.data as u8),
                _ => return Err(bus_error(status_error(r))),
            }
        }
        Ok(())
    }

    /// Run the queue; the first POLL timeout not yet reported.
    fn run_checked(&mut self) -> ad9361::Result<()> {
        self.run()?;
        self.failed.take().map_or(Ok(()), Err)
    }
}

impl<E: Exec> Bus for Spi<E> {
    fn write(&mut self, reg: u16, value: u8) -> ad9361::Result<()> {
        self.push(Op::Spi { device: SPI_AD9361, word: ad9361::spi_write(reg, value) }, Tag::Plain)
    }

    fn wait(&mut self, us: u32) -> ad9361::Result<()> {
        self.push(Op::Wait { us }, Tag::Plain)
    }

    fn poll(&mut self, reg: u16, mask: u8, want: u8, ms: u32) -> ad9361::Result<()> {
        self.push(Op::Spi { device: SPI_AD9361, word: ad9361::spi_read(reg) }, Tag::Plain)?;
        // ms = 0: one POLL of one try; else ceil(ms / 255) POLLs
        let n = ms.div_ceil(POLL_MAX_MS).max(1);
        for k in 0..n {
            let this = (ms - k * POLL_MAX_MS).min(POLL_MAX_MS);
            let op = Op::Poll { mask: mask as u16, value: want as u16, ms: this as u8 };
            let tag = if k + 1 == n { Tag::PollEnd { reg, mask, want, ms } } else { Tag::PollMid };
            self.push(op, tag)?;
        }
        Ok(())
    }

    fn read<const N: usize>(&mut self, regs: [u16; N]) -> ad9361::Result<[u8; N]> {
        self.values.clear();
        for reg in regs {
            self.push(Op::Spi { device: SPI_AD9361, word: ad9361::spi_read(reg) }, Tag::Read)?;
        }
        self.run_checked()?;
        // the reads are the last N `Read` results, whichever packets they rode
        let v = &self.values[self.values.len() - N..];
        Ok(std::array::from_fn(|k| v[k]))
    }

    fn flush(&mut self) -> ad9361::Result<()> {
        self.run_checked()
    }
}

// -- reset ----------------------------------------------------------------------

fn check_all(replies: &[Reply]) -> usb::Result<()> {
    replies.iter().find(|r| !r.status.is_ok()).map_or(Ok(()), |r| Err(status_error(r)))
}

/// Pulse RESETB (low `RESET_LOW_US`, then released `RESET_RECOVERY_US`) and
/// read the product id, in one command packet; the id read.
pub fn reset<E: Exec>(ctrl: &mut E) -> usb::Result<u8> {
    let r = ctrl.exec(&[
        Op::Write { addr: regs::RADIO, data: 0 },
        Op::Wait { us: RESET_LOW_US },
        Op::Write { addr: regs::RADIO, data: RUN },
        Op::Wait { us: RESET_RECOVERY_US },
        Op::Spi { device: SPI_AD9361, word: ad9361::spi_read(PRODUCT_ID) },
    ])?;
    check_all(&r)?;
    Ok(r[4].data as u8)
}

/// Hold the AD9361 in reset (regs::RADIO = 0).
pub fn hold_reset<E: Exec>(ctrl: &mut E) -> usb::Result<()> {
    check_all(&ctrl.exec(&[Op::Write { addr: regs::RADIO, data: 0 }])?)
}

// -- the device -----------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Usb(#[from] usb::Error),
    #[error("{0}")]
    Ad9361(#[from] ad9361::Error),
    #[error("{0}")]
    Config(#[from] config::Error),
    #[error("AD9361 product id register {PRODUCT_ID:#05x} = {0:#04x} after reset, expected {PRODUCT_ID_VALUE:#04x}")]
    ProductId(u8),
}

/// A failed bring-up: the error, and the transport back.
pub type BringUpError<E> = (Error, E);

/// The configured radio: the chip, and the configuration it holds (None:
/// unknown, as after bring-up or after a change that failed).
pub struct Device<E: Exec = usb::Ctrl> {
    pub ad: Ad9361<Spi<E>>,
    config: Option<Config>,
    /// What `regs::BANDS` was last set to: the band-select switches for
    /// the LOs the chip runs.
    bands: u32,
    /// What `regs::RADIO` was last set to.
    radio: u32,
}

impl<E: Exec> Device<E> {
    /// Reset the chip, require its product id, run `Ad9361::init` (UHD
    /// initialize(): every calibration, FDD, TX1 on at maximum attenuation).
    /// On an error the transport comes back with it.
    pub fn bring_up(mut ctrl: E) -> Result<Self, BringUpError<E>> {
        match reset(&mut ctrl) {
            Ok(PRODUCT_ID_VALUE) => {}
            Ok(id) => return Err((Error::ProductId(id), ctrl)),
            Err(e) => return Err((e.into(), ctrl)),
        }
        let ad = match Ad9361::try_init(Spi::new(ctrl)) {
            Ok(ad) => ad,
            Err((e, spi)) => return Err((e.into(), spi.into_ctrl())),
        };
        // the switches for the LOs init tuned (UHD sets them at open)
        let mut d = Device { ad, config: None, bands: 0, radio: RUN };
        let bands = regs::bands::rx(d.ad.lo(Dir::Rx)) | regs::bands::tx(d.ad.lo(Dir::Tx));
        match d.set_bands(bands) {
            Ok(()) => Ok(d),
            Err(e) => Err((e, d.into_ctrl())),
        }
    }

    /// The data port's mode from the channels a direction carries: two
    /// channels alternate on one DATA_CLK (2R2T), one needs every period
    /// (1R1T). The AD9361's own data port needs no write: 0x010 = 0xC8
    /// serves both (UHD writes the same for 1R1T and 2R2T on this CMOS
    /// part); the frame it toggles is what marks channel 0. Only while no
    /// stream runs (PROTOCOL.md 6, radio bit 1).
    fn set_data_port(&mut self, chains: config::Chains) -> Result<(), Error> {
        // all chains off is the mute step of a plan, not a port mode: keep it
        if chains.rx == 0 && chains.tx == 0 {
            return Ok(());
        }
        let two = chains.rx.count_ones() > 1 || chains.tx.count_ones() > 1;
        let radio = RESETB | if two { TWO_R2T } else { 0 };
        if radio == self.radio {
            return Ok(());
        }
        let spi = self.ad.bus();
        spi.flush()?;
        check_all(&spi.ctrl().exec(&[Op::Write { addr: regs::RADIO, data: radio }])?)?;
        self.radio = radio;
        Ok(())
    }

    /// Write the band-select switches (`regs::BANDS`), after the queue.
    fn set_bands(&mut self, bands: u32) -> Result<(), Error> {
        let spi = self.ad.bus();
        spi.flush()?;
        check_all(&spi.ctrl().exec(&[Op::Write { addr: regs::BANDS, data: bands }])?)?;
        self.bands = bands;
        Ok(())
    }

    /// The transport back (every public call leaves nothing queued).
    pub fn into_ctrl(self) -> E {
        self.ad.into_bus().into_ctrl()
    }

    /// The configuration the chip holds, if known.
    pub fn config(&self) -> Option<&Config> {
        self.config.as_ref()
    }

    /// Take the chip from the configuration it holds to `new`.
    pub fn apply(&mut self, new: &Config) -> Result<(), Error> {
        self.apply_with(new, |_, _, _| {})
    }

    /// `apply`, calling `after` with each change, its duration and the
    /// driver once it has run.
    pub fn apply_with(&mut self, new: &Config, mut after: impl FnMut(&Change, Duration, &mut Ad9361<Spi<E>>)) -> Result<(), Error> {
        new.validate()?;
        let plan = Config::changes(self.config.as_ref(), new);
        // a change that fails leaves the chip between the two
        self.config = None;
        for c in &plan {
            let t = Instant::now();
            self.change(c)?;
            after(c, t.elapsed(), &mut self.ad);
        }
        self.config = Some(new.clone());
        Ok(())
    }

    fn change(&mut self, c: &Change) -> Result<(), Error> {
        let ad = &mut self.ad;
        Ok(match *c {
            // ref_sel and the ADF4001 are not driven by this FPGA image: the
            // TCXO runs free. The code that drives them reads the reference
            // from `config()`.
            Change::Reference(_) => Ok(()),
            // UHD set_clock_rate: the stored LOs retuned, the stored gains
            // reprogrammed, both filters set to the rate, every calibration
            // run, the enabled chains restored (what `changes` assumes)
            Change::Rate { hz } => ad.set_rate(hz).map(drop),
            Change::Bandwidth { direction, hz } => ad.set_bandwidth(direction, hz).map(drop),
            // the front end's band-select switches follow the LO reached
            // (UHD update_bandsel)
            Change::Lo { direction, hz } => {
                let lo = ad.set_lo(direction, hz)?;
                let bands = match direction {
                    Dir::Rx => self.bands & !regs::bands::RX | regs::bands::rx(lo),
                    Dir::Tx => self.bands & !regs::bands::TX | regs::bands::tx(lo),
                };
                return self.set_bands(bands);
            }
            Change::Chains(ch) => {
                ad.set_channels(ch.rx, ch.tx)?;
                // a chains change with a tx chain on runs the TX quadrature
                // calibration, which turns RX IQ tracking off (0x169=0xC0);
                // UHD re-enables it in tune(), which its runtime calls after
                // the chains are set - this plan sets them after the LOs, so
                // that step is here. Measured: IRR 49.3 dB off, 78.9 dB on
                if ch.tx != 0 && ch.rx != 0 {
                    ad.enable_rx_iq_tracking()?;
                }
                return self.set_data_port(ch);
            }
            // rx: gain index (dB); tx: 89.75 dB - attenuation, the driver's gain
            Change::Gain { direction, channel, db } => ad.set_gain(direction, channel, db).map(drop),
        }?)
    }

    /// Hold the chip in reset (regs::RADIO = 0); the configuration is lost.
    pub fn hold_reset(&mut self) -> Result<(), Error> {
        self.config = None;
        let spi = self.ad.bus();
        spi.flush()?;
        Ok(hold_reset(spi.ctrl())?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ad9361::{mock, Dir};
    use crate::config::Chains;

    /// A fake FPGA: an AD9361 register file answering by a rule
    /// (`mock::settled`), POLL executed as PROTOCOL.md says (repeat the last
    /// SPI read), every packet recorded.
    #[derive(Debug)]
    struct Fpga {
        regs: [u8; 1024],
        rule: fn(u16, &[u8; 1024]) -> u8,
        packets: Vec<Vec<Op>>,
        last_read: Option<u16>,
        radio: u32,
        bands: u32,
    }

    impl Fpga {
        fn new(rule: fn(u16, &[u8; 1024]) -> u8) -> Fpga {
            let mut regs = [0; 1024];
            regs[0x0A3] = 0x4A; // as mock::Mock
            Fpga { regs, rule, packets: Vec::new(), last_read: None, radio: 0, bands: 0 }
        }

        fn ops(&self) -> Vec<Op> {
            self.packets.concat()
        }

        fn sizes(&self) -> Vec<usize> {
            self.packets.iter().map(Vec::len).collect()
        }
    }

    impl Exec for Fpga {
        fn exec(&mut self, ops: &[Op]) -> usb::Result<Vec<Reply>> {
            assert!(ops.len() <= proto::MAX_OPS, "{} operations in one packet", ops.len());
            self.packets.push(ops.to_vec());
            let mut out = Vec::new();
            for &op in ops {
                let reply = |opcode, status, data| Reply { opcode, status, addr: 0, data };
                out.push(match op {
                    Op::Spi { device: 0, word } => {
                        let reg = (word >> 8 & 0x3FF) as u16;
                        self.last_read = Some(reg);
                        if word & 0x80_0000 != 0 {
                            self.regs[reg as usize] = word as u8;
                        }
                        reply(3, Status::Ok, (self.rule)(reg, &self.regs) as u32)
                    }
                    Op::Poll { mask, value, ms: _ } => {
                        let v = (self.rule)(self.last_read.expect("POLL after SPI"), &self.regs) as u16;
                        reply(5, if v & mask == value { Status::Ok } else { Status::Timeout }, v as u32)
                    }
                    Op::Write { addr, data } => {
                        match addr {
                            regs::RADIO => self.radio = data,
                            regs::BANDS => self.bands = data,
                            _ => {}
                        }
                        reply(1, Status::Ok, 0)
                    }
                    Op::Wait { .. } => reply(4, Status::Ok, 0),
                    _ => reply(0, Status::UnknownOp, 0),
                });
            }
            Ok(out)
        }
    }

    fn cal_stuck(reg: u16, regs: &[u8; 1024]) -> u8 {
        if reg == 0x016 { 0x02 } else { mock::settled(reg, regs) }
    }

    #[test]
    fn spi_words_and_operations() {
        let mut f = Fpga::new(mock::settled);
        let mut b = Spi::new(&mut f);
        b.write(0x3F4, 0x1B).unwrap();
        b.wait(20_000).unwrap();
        b.poll(0x016, 0x80, 0x00, 0).unwrap();
        b.flush().unwrap();
        assert_eq!(f.ops(), [
            Op::Spi { device: 0, word: 0x80_0000 | 0x3F4 << 8 | 0x1B },
            Op::Wait { us: 20_000 },
            Op::Spi { device: 0, word: 0x00_1600 },
            Op::Poll { mask: 0x80, value: 0x00, ms: 0 },
        ]);
    }

    #[test]
    fn queue_splits_at_126_operations() {
        let mut f = Fpga::new(mock::settled);
        let mut b = Spi::new(&mut f);
        for k in 0..300u16 {
            b.write(0x200 + k % 40, k as u8).unwrap();
        }
        assert_eq!(b.stats.packets, 2); // 252 run, 48 queued
        b.flush().unwrap();
        b.flush().unwrap(); // nothing queued: no packet
        assert_eq!(b.stats, Stats { packets: 3, ops: 300 });
        assert_eq!(f.sizes(), [126, 126, 48]);
    }

    #[test]
    fn long_polls_chain_255_ms_polls() {
        let mut f = Fpga::new(mock::settled);
        let mut b = Spi::new(&mut f);
        // 10050 ms (UHD's RF DC limit) = 39 x 255 + 105; 255: one; 256: 255 + 1
        for ms in [10_050, 255, 256, 1] {
            b.poll(0x016, 0x02, 0x00, ms).unwrap();
        }
        b.flush().unwrap();
        assert_eq!(b.polls.iter().map(|p| (p.ms, p.ok)).collect::<Vec<_>>(), [(10_050, true), (255, true), (256, true), (1, true)]);
        let ops = f.ops();
        let polls: Vec<u8> = ops.iter().filter_map(|o| if let Op::Poll { ms, .. } = *o { Some(ms) } else { None }).collect();
        let mut want = vec![255; 39];
        want.extend([105, 255, 255, 1, 1]);
        assert_eq!(polls, want);
        // one SPI read before each chain
        let spi: Vec<usize> = ops.iter().enumerate().filter(|(_, o)| matches!(o, Op::Spi { .. })).map(|(k, _)| k).collect();
        assert_eq!(spi, [0, 41, 43, 46]);
    }

    #[test]
    fn a_chain_split_across_packets_times_out_by_its_last_poll() {
        // 120 writes, then a 10-POLL chain: 6 POLLs in the first packet, 4 in
        // the second; every POLL times out, only the last one is the outcome
        let mut f = Fpga::new(cal_stuck);
        let mut b = Spi::new(&mut f);
        for _ in 0..120 {
            b.write(0x000, 0).unwrap();
        }
        b.poll(0x016, 0x02, 0x00, 10 * 255).unwrap();
        let e = b.flush().unwrap_err();
        assert!(matches!(e, ad9361::Error::Poll { reg: 0x016, mask: 0x02, want: 0, value: 0x02 }), "{e}");
        assert_eq!(b.polls, [PollRecord { reg: 0x016, mask: 2, want: 0, ms: 2550, value: 2, ok: false }]);
        assert_eq!(f.sizes(), [126, 5]);
    }

    #[test]
    fn a_chain_whose_early_polls_time_out_succeeds_by_its_last() {
        // the earlier POLLs' timeouts are "not yet": the fake answers
        // timeout for the first 3 POLLs of the chain, then ok
        struct Slow(Fpga, usize);
        impl Exec for Slow {
            fn exec(&mut self, ops: &[Op]) -> usb::Result<Vec<Reply>> {
                let mut r = self.0.exec(ops)?;
                for (op, reply) in ops.iter().zip(&mut r) {
                    if matches!(op, Op::Poll { .. }) && self.1 > 0 {
                        self.1 -= 1;
                        reply.status = Status::Timeout;
                    }
                }
                Ok(r)
            }
        }
        let mut b = Spi::new(Slow(Fpga::new(mock::settled), 3));
        b.poll(0x05E, 0x80, 0x80, 2002).unwrap(); // 8 POLLs
        b.flush().unwrap();
        assert!(b.polls[0].ok);
        assert_eq!(b.into_ctrl().0.ops().len(), 1 + 8);
    }

    #[test]
    fn reads_route_their_values_after_the_queue_and_a_split() {
        let mut f = Fpga::new(mock::settled);
        let mut b = Spi::new(&mut f);
        b.write(0x1FB, 5).unwrap();
        b.write(0x1FC, 0x83).unwrap();
        b.poll(0x05E, 0x80, 0x80, 2002).unwrap();
        // settled: 0x1EB = (5 x 3 + 1) & 0x3F, 0x1EC = 0x83 & 0x7F, 0x037 = 0x0A
        assert_eq!(b.read([0x1EB, 0x1EC, 0x037]).unwrap(), [16, 0x03, 0x0A]);
        assert_eq!(b.stats.packets, 1);
        // 125 writes + 3 reads: the first read in the full packet, two after
        for _ in 0..125 {
            b.write(0x3F4, 0x77).unwrap();
        }
        assert_eq!(b.read([0x3F4, 0x037, 0x0A3]).unwrap(), [0x77, 0x0A, 0x4A]);
        // 3 writes before: 2 + (1 + 8) + 3 = 14
        assert_eq!(f.sizes(), [14, 126, 2]);
    }

    #[test]
    fn poll_timeout_is_one_poll_error_reported_once() {
        let mut f = Fpga::new(|reg, regs| if reg == 0x247 { 0x00 } else { mock::settled(reg, regs) });
        let mut b = Spi::new(&mut f);
        b.poll(0x247, 0x02, 0x02, 0).unwrap();
        b.poll(0x287, 0x02, 0x02, 0).unwrap();
        b.write(0x3F4, 1).unwrap(); // runs anyway, as on the FPGA
        let e = b.read([0x3F4]).unwrap_err();
        assert!(matches!(e, ad9361::Error::Poll { reg: 0x247, mask: 2, want: 2, value: 0 }), "{e}");
        assert_eq!(b.polls.iter().map(|p| (p.reg, p.ok)).collect::<Vec<_>>(), [(0x247, false), (0x287, true)]);
        assert_eq!(b.read([0x3F4]).unwrap(), [1]);
    }

    #[test]
    fn other_statuses_are_bus_errors() {
        let mut b = Spi::new(Fpga::new(mock::settled));
        // the fake answers a register read as an unknown opcode
        b.push(Op::Read { addr: 0 }, Tag::Plain).unwrap();
        assert!(matches!(b.flush(), Err(ad9361::Error::Bus(_))));
    }

    #[test]
    fn bring_up_pulses_resetb_and_checks_the_id() {
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        assert!(d.config().is_none());
        assert!(d.ad.bus().polls.iter().all(|p| p.ok));
        d.hold_reset().unwrap();
        drop(d);
        assert_eq!(f.packets[0], [
            Op::Write { addr: regs::RADIO, data: 0 },
            Op::Wait { us: RESET_LOW_US },
            Op::Write { addr: regs::RADIO, data: RUN },
            Op::Wait { us: RESET_RECOVERY_US },
            Op::Spi { device: 0, word: 0x00_3700 },
        ]);
        assert_eq!(f.radio, 0);
        assert_eq!(f.packets.last().unwrap(), &[Op::Write { addr: regs::RADIO, data: 0 }]);
        let mut f = Fpga::new(|reg, regs| if reg == PRODUCT_ID { 0x0B } else { mock::settled(reg, regs) });
        assert!(matches!(Device::bring_up(&mut f), Err((Error::ProductId(0x0B), _))));
        assert_eq!(f.packets.len(), 1);
        // a calibration that never ends fails the bring-up as a poll error,
        // and the transport comes back with it, every packet recorded
        let Err((e, f)) = Device::bring_up(Fpga::new(cal_stuck)) else { panic!("bring-up passed") };
        assert!(matches!(e, Error::Ad9361(ad9361::Error::Poll { reg: 0x016, .. })), "{e}");
        assert!(f.packets.len() > 1);
        // and from a configured device
        let d = Device::bring_up(Fpga::new(mock::settled)).unwrap();
        assert_eq!(d.into_ctrl().radio, RUN);
    }

    fn spi_writes(ops: &[Op], reg: u16) -> Vec<u8> {
        ops.iter()
            .filter_map(|o| match *o {
                Op::Spi { device: 0, word } if word & 0x80_0000 != 0 && (word >> 8 & 0x3FF) as u16 == reg => Some(word as u8),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn apply_runs_the_example_and_then_only_differences() {
        let example = Config::parse(include_str!("../examples/config.toml")).unwrap();
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        let mut steps = Vec::new();
        d.apply_with(&example, |c, _, _| steps.push(*c)).unwrap();
        assert_eq!(steps, Config::changes(None, &example));
        assert_eq!(d.config(), Some(&example));
        // one value: one change, no other write
        let mut new = example.clone();
        new.rx.as_mut().unwrap().ch1.as_mut().unwrap().gain_db = 20.0;
        let before = d.ad.bus().stats.ops;
        d.apply(&new).unwrap();
        assert_eq!(d.ad.bus().stats.ops - before, 1);
        assert!(d.ad.bus().polls.iter().all(|p| p.ok));
        drop(d);
        let ops = f.ops();
        // rx gain index 60, then the one-value change to 20; tx attenuation
        // 4 x (89.75 - 60) = 119, 4 x (89.75 - 55.5) = 137
        assert_eq!(spi_writes(&ops, 0x109).last(), Some(&60));
        let rx2 = spi_writes(&ops, 0x10C);
        assert_eq!(&rx2[rx2.len() - 2..], [55, 20], "the example, then the one change");
        assert_eq!(spi_writes(&ops, 0x073).last(), Some(&119));
        assert_eq!(spi_writes(&ops, 0x075).last(), Some(&137));
        assert_eq!((spi_writes(&ops, 0x074).last(), spi_writes(&ops, 0x076).last()), (Some(&0), Some(&0)));
        // every chain on, FDD at the end, and RX IQ tracking left on (the
        // chains step runs the TX quadrature calibration, which turns it off)
        assert_eq!((f.regs[0x002] & 0xC0, f.regs[0x003] & 0xC0, f.regs[0x014]), (0xC0, 0xC0, 0x21));
        assert_eq!(spi_writes(&ops, 0x169).last(), Some(&0xCF));
        // nothing but SPI, WAIT, POLL and the radio and band registers after
        // the reset packet: the stream settings (format, spp) are no radio
        // operation
        assert!(f.packets[1..].iter().flatten().all(|o| matches!(o,
            Op::Spi { .. } | Op::Wait { .. } | Op::Poll { .. }
                | Op::Write { addr: regs::RADIO | regs::BANDS, .. })));
        // two channels a direction: the data port alternates them
        assert_eq!(f.radio, RUN);
    }

    #[test]
    fn band_switches_follow_the_los() {
        use regs::bands::*;
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        // init's LOs: rx 800 MHz (C), tx 850 MHz (B), in their own packet
        assert_eq!(d.bands, RX_C | TX_B);
        let example = Config::parse(include_str!("../examples/config.toml")).unwrap();
        d.apply(&example).unwrap(); // 2.45 GHz both: rx B, tx B
        assert_eq!(d.bands, RX_B | TX_B);
        let mut high = example.clone();
        high.rx.as_mut().unwrap().lo_hz = 5.8e9;
        high.tx.as_mut().unwrap().lo_hz = 2.5e9;
        d.apply(&high).unwrap();
        assert_eq!(d.bands, RX_A | TX_A);
        // an rx change leaves the tx switch alone
        let mut low_rx = high.clone();
        low_rx.rx.as_mut().unwrap().lo_hz = 433e6;
        d.apply(&low_rx).unwrap();
        assert_eq!(d.bands, RX_C | TX_A);
        drop(d);
        assert_eq!(f.bands, RX_C | TX_A, "what the FPGA was told");
        let writes = f.ops().iter().filter(|o| matches!(o, Op::Write { addr: regs::BANDS, .. })).count();
        assert_eq!(writes, 1 + 2 + 2 + 1, "bring-up, then one per LO change");
    }

    #[test]
    fn the_data_port_mode_follows_the_channel_count() {
        let example = Config::parse(include_str!("../examples/config.toml")).unwrap();
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        d.apply(&example).unwrap();
        assert_eq!(d.radio, RUN, "2 + 2 channels: 2R2T, written with the reset");
        // one channel a direction at 61.44 MS/s: every DATA_CLK is a sample
        let mut one = example.clone();
        one.rate_hz = 61.44e6;
        for r in one.rx.iter_mut() { r.ch1 = None; }
        for t in one.tx.iter_mut() { t.ch1 = None; }
        d.apply(&one).unwrap();
        assert_eq!(d.radio, RESETB, "1 + 1 channels: 1R1T");
        // and back: 2R2T again, ids and version untouched
        d.apply(&example).unwrap();
        assert_eq!(d.radio, RUN);
        drop(d);
        assert_eq!(f.radio, RUN, "what the FPGA was told");
        let writes: Vec<_> = f.ops().iter().filter_map(|o| match o {
            Op::Write { addr: regs::RADIO, data } => Some(*data), _ => None }).collect();
        assert_eq!(writes, [0, RUN, RESETB, RUN], "the reset (hold, release), 1R1T, 2R2T: unchanged settings are not rewritten");
    }

    #[test]
    fn a_failed_apply_leaves_the_configuration_unknown() {
        let example = Config::parse(include_str!("../examples/config.toml")).unwrap();
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        d.apply(&example).unwrap();
        // a rate the driver cannot reach with 2 channels: the plan's own
        // validation rejects it before anything is written
        let mut bad = example.clone();
        bad.rate_hz = 40e6;
        assert!(matches!(d.apply(&bad), Err(Error::Config(_))));
        assert_eq!(d.config(), Some(&example));
        // a change failing on the chip
        let mut other = example.clone();
        other.rx.as_mut().unwrap().lo_hz = 915e6;
        d.ad.bus().ctrl().rule = |reg, regs| if reg == 0x247 { 0 } else { mock::settled(reg, regs) };
        assert!(matches!(d.apply(&other), Err(Error::Ad9361(ad9361::Error::Poll { reg: 0x247, .. }))));
        assert!(d.config().is_none());
    }

    #[test]
    fn a_rate_change_keeps_chains_and_gains() {
        // what `changes` assumes of a rate change: only the bandwidths go
        let mut f = Fpga::new(mock::settled);
        let mut d = Device::bring_up(&mut f).unwrap();
        for c in [
            Change::Rate { hz: 20e6 },
            Change::Chains(Chains { rx: 0b01, tx: 0b01 }),
            Change::Gain { direction: Dir::Rx, channel: 0, db: 30.0 },
            Change::Gain { direction: Dir::Tx, channel: 0, db: 10.0 },
            Change::Rate { hz: 10e6 },
        ] {
            d.change(&c).unwrap();
        }
        drop(d);
        assert_eq!((f.regs[0x002] & 0xC0, f.regs[0x003] & 0xC0), (0x40, 0x40));
        // attenuation 4 x (89.75 - 10) = 319 = 0x13F: 0x073 low byte, 0x074 bit 8
        assert_eq!((f.regs[0x109], f.regs[0x073], f.regs[0x074], f.regs[0x014]), (30, 0x3F, 0x01, 0x21));
    }
}
