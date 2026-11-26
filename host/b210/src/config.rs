//! The radio's configuration: one declarative TOML file holding the whole
//! radio state (docs/DESIGN.md: applied whole, only differences written),
//! its validation against the hardware's limits, and the minimal ordered
//! list of operations that takes the radio from one state to another.
//! Example, every key used: host/b210/examples/config.toml.
//!
//! # Schema
//!
//! | Key | Unit, range | Meaning |
//! | --- | --- | --- |
//! | `rate_hz` | Hz, 520834 ..= 61.44e6 (30.72e6 with 2 channels in a direction) | sample rate of every channel |
//! | `reference` | `"internal"` (default); `"external"` is rejected: not built yet | the 40 MHz TCXO free-running (external: locked by the ADF4001 to 10 MHz at REF) |
//! | `[rx]`, `[tx]` | present = in use | a direction; absent = both its channels off |
//! | `lo_hz` | Hz, 70e6 ..= 6e9 | the direction's one synthesizer |
//! | `bandwidth_hz` | Hz, rx 800e3 ..= 56e6, tx 1.08e6 ..= 40e6, and <= `rate_hz` | the direction's one analog filter setting |
//! | `ch0`, `ch1` | present = enabled | a channel (bit c of PROTOCOL.md's channel mask); rx and tx
//! may differ (2 rx + 1 tx measured on the board: 2R2T, the single channel uses channel 0, so
//! ch1 alone is rejected) |
//! | `rx.chC.gain_db` | dB, 0 ..= 76 in 1 dB steps | rx gain index of the AD9361 gain table |
//! | `tx.chC.gain_db` | dB, 0 ..= 89.75 in 0.25 dB steps | attenuation = 89.75 dB - gain_db |
//!
//! # Shape, and why
//!
//! - What the AD9361 has once is written once: one sample rate (one
//!   baseband PLL, one data port), and per direction one LO synthesizer
//!   and one analog filter setting, shared by both channels; gains are per
//!   channel.
//! - A channel is enabled by being present, a direction by its section:
//!   a disabled channel has no settings, so no key in a file is without
//!   effect (DESIGN.md: nothing kept "for later"). For the same reason a
//!   section without a channel is rejected.
//! - A stream's wire format (sc12/sc16), channel mask and packet size are
//!   not radio state: they travel with every stream (`b210 --format`,
//!   `--channels`; a full packet), so the file has no key for them. The bus
//!   limit follows: it is checked when a stream starts against the rate the
//!   board reports (proto::BUS_BYTES_PER_SEC), not at apply time.
//! - Defaults only where the board has a natural state: reference internal
//!   (needs no cable). Everything else must be written. AGC is out of
//!   scope: gains are manual only.
//! - Only what this FPGA image can run: no register drives ref_sel and the
//!   ADF4001 yet, so `reference = "external"` is rejected; nor the antenna
//!   switches, so there is no antenna key (the port the switches' reset
//!   state selects is the one used).
//!
//! # Limits
//!
//! The chip's limits are `ad9361`'s constants (one source, their reasons
//! there), the bus's and the packet's are `proto`'s. With n = the larger
//! number of enabled channels in a direction and b(k) = bytes per sample
//! time of k channels (sc16: 4 k, sc12: 3 k):
//!
//! - 520834 <= rate_hz <= 61.44e6 / (1 if n <= 1 else 2). Lower: the
//!   AD9361's least ADC clock (ADI: 25 MHz) over its largest decimation 48
//!   (`ad9361::MIN_RATE`). Upper: the
//!   AD9361's data clock is at most 61.44 MHz and carries the two channels
//!   of a direction interleaved (UHD b200_impl.cpp enforce_tick_rate_limits,
//!   AD9361_MAX_CLOCK_RATE).
//! - 70e6 <= lo_hz <= 6e9.
//! - bandwidth_hz within what every analog filter of the direction is set
//!   to exactly (each clamps its one-sided bandwidth to its own range):
//!   rx 800e3 ..= 56e6, tx 1.08e6 ..= 40e6 (`ad9361::MIN_RX_BANDWIDTH` ..);
//!   and bandwidth_hz <= rate_hz: UHD's filter calibration clips the
//!   baseband bandwidth to the sample rate (ad9361_device.cpp
//!   _calibrate_baseband_rx_analog_filter). Together: an rx section needs
//!   rate_hz >= 800e3, a tx section rate_hz >= 1.08e6; below that no filter
//!   setting would be what the file says.
//! - rx gain_db in 0 ..= 76, integral: the gain table index (UHD
//!   get_gain_range: step 1.0; set_gain truncates to an integer index).
//!   No gain protects the receiver: the RX inputs' absolute maximum is
//!   +2.5 dBm peak (AD9361 data sheet Rev. F, p. 15, absolute maximum
//!   ratings), whatever the gain; a stronger signal at the port must be
//!   attenuated before it, which software cannot do.
//! - tx gain_db in 0 ..= 89.75, a multiple of 0.25: the attenuation word
//!   counts 0.25 dB (UHD set_gain, AD9361_MAX_GAIN = 89.75).
//!
//! # The plan
//!
//! `Config::changes(old, new)` returns the operations (`Change`) that take
//! a radio configured as `old` (or in an unknown state: `None`) to `new`;
//! `device::Device` runs them on the chip. The radio state a configuration
//! means is `State::of`: every value it sets, a tx chain that is off at
//! gain 0 dB (maximum attenuation), everything else unknown. The plan
//! writes a value only where it differs from what the radio already
//! holds, and only the values `new` sets.
//!
//! It relies on what each operation does (`State::apply`, which the device
//! keeps): it changes only what it names, except a rate change, after which
//! both bandwidths are unknown.
//! (UHD's set_clock_rate recalibrates the filters to the new rate, and
//! retunes the stored LOs, reprograms the stored gains and restores the
//! enabled chains.)
//!
//! Order, each step skipped when nothing in it differs:
//!
//! 1. **Mute**: every tx gain to 0 dB (89.75 dB attenuation) when the plan
//!    holds an operation that could make a tx chain emit something other
//!    than its samples at its gain (below); otherwise only the tx chains
//!    about to be switched off. Reason: TX attenuation at maximum before
//!    anything that could transmit.
//! 2. **Chains off**: enabled := old AND new, switching off only. Reason:
//!    a chain going away does not run through the calibrations below; and
//!    the channel count only falls before the rate changes and only rises
//!    after, so every intermediate state keeps the 2-channel rate limit
//!    (old and new each do).
//! 3. **Reference**. Reason: every clock below derives from it.
//! 4. **Rate**. Reason: the filter calibrations depend on it (UHD:
//!    "must be re-done after any change to the sample rate").
//! 5. **Bandwidth**, rx then tx (UHD's set_clock_rate order). Reason: the
//!    calibrations an LO change runs (DC offset, quadrature) use the
//!    current filters.
//! 6. **LO**, rx then tx (UHD's set_clock_rate order). Reason: the gain
//!    table follows the LO band (UHD _tune_helper reprograms it).
//! 7. **Chains on**: enabled := new. Reason: a chain is switched on into
//!    a finished path, a tx chain at maximum attenuation. With tx and rx
//!    both on this step runs the TX quadrature calibration, which turns RX
//!    IQ tracking off (0x169 = 0xC0); the plan re-enables it right after
//!    (0xCF), the step UHD's tune() performs in its order (chains before
//!    tune). Measured: IRR 49.3 dB without it, 78.9 .. 93.2 dB with it.
//! 8. **Gains**, rx then tx. Reason: tx gain last, so that nothing above
//!    runs while a tx chain is loud.
//!
//! The wire format and packet size are stream settings, not radio
//! operations: they go with every stream (rx_ctrl's START word and
//! rx_spp, every tx header), so the plan has no step for them and the file
//! has no key.
//!
//! Operations that could transmit (step 1 mutes for them), with reason:
//! reference (the synthesizers relock, LOs move meanwhile); rate (UHD's
//! set_clock_rate switches every chain on, both tx chains included, and
//! calibrates with TX on); tx bandwidth (the tx filters are recalibrated
//! while a chain may carry signal); rx LO (UHD's rx quadrature calibration
//! moves the tx LO into the rx band); tx LO (the tx synthesizer relocks;
//! a jump over 100 MHz runs the tx quadrature calibration); a chains
//! change that leaves any tx chain on, even one that changes only rx chains
//! (the driver's set_channels runs the tx quadrature calibration whenever
//! a tx chain is on); the data port changing between 1 and 2 channels at step 2
//! or 7 (the tx samples are undefined while it switches; 1 rx + 2 tx to
//! 2 rx + 1 tx is 2-channel at both ends but 1-channel between). An rx bandwidth change only
//! recalibrates rx filters and does not mute.

use serde::Deserialize;

use crate::ad9361::{
    Dir, MAX_LO, MAX_RATE, MAX_RATE_2CH, MAX_RX_BANDWIDTH, MAX_RX_GAIN, MAX_TX_BANDWIDTH, MAX_TX_GAIN, MIN_LO, MIN_RATE,
    MIN_RX_BANDWIDTH, MIN_TX_BANDWIDTH, RX_GAIN_STEP, TX_GAIN_STEP,
};

// -- the file ---------------------------------------------------------------

/// The whole radio state; module doc for every key.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Sample rate of every channel, Hz.
    pub rate_hz: f64,
    #[serde(default)]
    pub reference: Reference,
    pub rx: Option<Rx>,
    pub tx: Option<Tx>,
}

/// The source of the AD9361's 40 MHz reference.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Reference {
    /// The 40 MHz TCXO, free-running (the ADF4001's charge pump off).
    #[default]
    Internal,
    /// The TCXO locked by the ADF4001 to 10 MHz at the REF input
    /// (R = 1, N = 4: UHD adf4001_ctrl.cpp). Not built yet: rejected by
    /// `validate`.
    External,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rx {
    /// The rx synthesizer, both channels, Hz.
    pub lo_hz: f64,
    /// The rx analog filter, both channels, Hz.
    pub bandwidth_hz: f64,
    pub ch0: Option<RxChannel>,
    pub ch1: Option<RxChannel>,
}

#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RxChannel {
    /// Gain table index, dB.
    pub gain_db: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tx {
    /// The tx synthesizer, both channels, Hz.
    pub lo_hz: f64,
    /// The tx analog filter, both channels, Hz.
    pub bandwidth_hz: f64,
    pub ch0: Option<TxChannel>,
    pub ch1: Option<TxChannel>,
}

#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TxChannel {
    /// 89.75 dB minus the attenuation, dB.
    pub gain_db: f64,
}

impl Rx {
    pub fn channels(&self) -> [Option<&RxChannel>; 2] {
        [self.ch0.as_ref(), self.ch1.as_ref()]
    }
}

impl Tx {
    pub fn channels(&self) -> [Option<&TxChannel>; 2] {
        [self.ch0.as_ref(), self.ch1.as_ref()]
    }
}

/// Which chains are on: a channel mask per direction (bit c: channel c).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chains {
    pub rx: u8,
    pub tx: u8,
}

impl Chains {
    pub const NONE: Chains = Chains { rx: 0, tx: 0 };

    fn and(self, o: Chains) -> Chains {
        Chains { rx: self.rx & o.rx, tx: self.tx & o.tx }
    }

    pub fn rx_count(self) -> usize {
        self.rx.count_ones() as usize
    }

    pub fn tx_count(self) -> usize {
        self.tx.count_ones() as usize
    }

    /// Whether tx channel `c` is on.
    pub fn tx_on(self, c: usize) -> bool {
        self.tx >> c & 1 != 0
    }

    /// The data port carries two channels of a direction.
    pub fn dual(self) -> bool {
        self.rx_count() == 2 || self.tx_count() == 2
    }

    /// The highest sample rate these chains allow, Hz.
    pub fn max_rate_hz(self) -> f64 {
        if self.dual() { MAX_RATE_2CH } else { MAX_RATE }
    }
}

/// The channel mask of the present channels.
fn mask<T>(channels: [Option<&T>; 2]) -> u8 {
    channels[0].is_some() as u8 | (channels[1].is_some() as u8) << 1
}

// -- validation ---------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, thiserror::Error)]
pub enum Error {
    /// Not TOML, or not this schema (unknown key, wrong type, missing key).
    #[error("configuration: {0}")]
    Toml(String),
    /// `key` = `value` lies outside `min ..= max`, in `unit`.
    #[error("{key} = {value}: outside {min} ..= {max} {unit}")]
    Range { key: String, value: f64, min: f64, max: f64, unit: &'static str },
    /// `key` = `value` dB is not a multiple of `step` dB.
    #[error("{key} = {value}: not a multiple of {step} dB")]
    Step { key: String, value: f64, step: f64 },
    /// rate_hz above what `channels` channels in a direction allow.
    #[error(
        "rate_hz = {rate_hz}: above {max_hz} Hz, the most with two channels in a direction \
         (one data port carries both)"
    )]
    RateForChannels { rate_hz: f64, max_hz: f64 },
    /// `key` (a bandwidth) above rate_hz.
    #[error("{key} = {bandwidth_hz}: above rate_hz = {rate_hz}; the AD9361's filter is clipped to the sample rate")]
    BandwidthAboveRate { key: &'static str, bandwidth_hz: f64, rate_hz: f64 },
    /// A section with no channel.
    #[error("[{0}] has no channel: add ch0 and/or ch1, or remove the section")]
    NoChannel(&'static str),
    /// ch1 alone: a one-channel direction carries channel 0.
    #[error("[{0}] enables only ch1, but a one-channel direction carries channel 0: use ch0, or ch0 and ch1")]
    OnlyChannel1(&'static str),
    /// `key` = `value` names something this FPGA image cannot do yet.
    #[error("{key} = \"{value}\": not built yet ({why})")]
    NotBuilt { key: &'static str, value: &'static str, why: &'static str },
}

fn range(key: &str, value: f64, min: f64, max: f64, unit: &'static str) -> Result<(), Error> {
    // written so that NaN fails
    if min <= value && value <= max {
        Ok(())
    } else {
        Err(Error::Range { key: key.into(), value, min, max, unit })
    }
}

fn step(key: &str, value: f64, step: f64) -> Result<(), Error> {
    // exact: every multiple of 0.25 below 2^50 is an f64, so is value / step
    if (value / step).fract() == 0.0 { Ok(()) } else { Err(Error::Step { key: key.into(), value, step }) }
}

impl Config {
    /// A configuration from TOML text, validated.
    pub fn parse(text: &str) -> Result<Config, Error> {
        let c: Config = toml::from_str(text).map_err(|e| Error::Toml(e.to_string()))?;
        c.validate()?;
        Ok(c)
    }

    /// The limits of the module doc; the first one broken.
    pub fn validate(&self) -> Result<(), Error> {
        range("rate_hz", self.rate_hz, MIN_RATE, MAX_RATE, "Hz")?;
        if self.reference == Reference::External {
            return Err(Error::NotBuilt {
                key: "reference",
                value: "external",
                why: "no FPGA register drives ref_sel or the ADF4001 in this image",
            });
        }
        let chains = self.chains();
        if self.rate_hz > chains.max_rate_hz() {
            return Err(Error::RateForChannels { rate_hz: self.rate_hz, max_hz: chains.max_rate_hz() });
        }
        let bandwidth = |key: &'static str, hz: f64, (min, max): (f64, f64)| {
            range(key, hz, min, max, "Hz")?;
            if hz > self.rate_hz {
                return Err(Error::BandwidthAboveRate { key, bandwidth_hz: hz, rate_hz: self.rate_hz });
            }
            Ok(())
        };
        if let Some(rx) = &self.rx {
            if chains.rx_count() == 0 {
                return Err(Error::NoChannel("rx"));
            }
            if rx.ch0.is_none() && rx.ch1.is_some() {
                return Err(Error::OnlyChannel1("rx"));
            }
            range("rx.lo_hz", rx.lo_hz, MIN_LO, MAX_LO, "Hz")?;
            bandwidth("rx.bandwidth_hz", rx.bandwidth_hz, (MIN_RX_BANDWIDTH, MAX_RX_BANDWIDTH))?;
            for (c, ch) in rx.channels().into_iter().enumerate() {
                if let Some(ch) = ch {
                    let key = format!("rx.ch{c}.gain_db");
                    range(&key, ch.gain_db, 0.0, MAX_RX_GAIN, "dB")?;
                    step(&key, ch.gain_db, RX_GAIN_STEP)?;
                }
            }
        }
        if let Some(tx) = &self.tx {
            if chains.tx_count() == 0 {
                return Err(Error::NoChannel("tx"));
            }
            if tx.ch0.is_none() && tx.ch1.is_some() {
                return Err(Error::OnlyChannel1("tx"));
            }
            range("tx.lo_hz", tx.lo_hz, MIN_LO, MAX_LO, "Hz")?;
            bandwidth("tx.bandwidth_hz", tx.bandwidth_hz, (MIN_TX_BANDWIDTH, MAX_TX_BANDWIDTH))?;
            for (c, ch) in tx.channels().into_iter().enumerate() {
                if let Some(ch) = ch {
                    let key = format!("tx.ch{c}.gain_db");
                    range(&key, ch.gain_db, 0.0, MAX_TX_GAIN, "dB")?;
                    step(&key, ch.gain_db, TX_GAIN_STEP)?;
                }
            }
        }
        Ok(())
    }

    pub fn chains(&self) -> Chains {
        let rx = self.rx.as_ref().map_or(0, |r| mask(r.channels()));
        let tx = self.tx.as_ref().map_or(0, |t| mask(t.channels()));
        Chains { rx, tx }
    }

    /// The operations that take a radio configured as `old` (None: in an
    /// unknown state) to `new`, in the order of the module doc. Both must
    /// be valid.
    pub fn changes(old: Option<&Config>, new: &Config) -> Vec<Change> {
        let want = State::of(new);
        let mut p = Plan { now: old.map_or_else(State::default, State::of), changes: Vec::new() };
        let new_chains = new.chains();
        let now_chains = p.now.chains;
        let on = |c: Option<Chains>, tx: usize| c.is_some_and(|c| c.tx_on(tx));
        // the chains between steps 2 and 7
        let kept = now_chains.map_or(Chains::NONE, |n| n.and(new_chains));

        // whether steps 2 and 7 switch chains
        let chains_off = now_chains != Some(kept);
        let chains_on = kept != new_chains;

        // 1. mute; the port's mode may change at step 2 or 7 (1 rx + 2 tx
        // to 2 rx + 1 tx passes through 1 + 1); a chains change with a tx
        // chain on runs the tx quadrature calibration
        let could_transmit = differs(p.now.reference, want.reference).is_some()
            || differs(p.now.rate_hz, want.rate_hz).is_some()
            || differs(p.now.bandwidth_hz[Dir::Tx as usize], want.bandwidth_hz[Dir::Tx as usize]).is_some()
            || (0..2).any(|d| differs(p.now.lo_hz[d], want.lo_hz[d]).is_some())
            || (chains_off && kept.tx != 0)
            || (chains_on && new_chains.tx != 0)
            || now_chains.is_none_or(|n| n.dual() != kept.dual() || kept.dual() != new_chains.dual());
        for c in 0..2 {
            let switched_off = on(now_chains, c) && !new_chains.tx_on(c);
            if (could_transmit || switched_off) && p.now.tx_gain_db[c] != Some(0.0) {
                p.emit(Change::Gain { direction: Dir::Tx, channel: c, db: 0.0 });
            }
        }
        // 2. chains off
        if chains_off {
            p.emit(Change::Chains(kept));
        }
        // 3, 4. reference, rate
        if let Some(r) = differs(p.now.reference, want.reference) {
            p.emit(Change::Reference(r));
        }
        if let Some(hz) = differs(p.now.rate_hz, want.rate_hz) {
            p.emit(Change::Rate { hz });
        }
        // 5, 6. bandwidth, LO
        for direction in [Dir::Rx, Dir::Tx] {
            if let Some(hz) = differs(p.now.bandwidth_hz[direction as usize], want.bandwidth_hz[direction as usize]) {
                p.emit(Change::Bandwidth { direction, hz });
            }
        }
        for direction in [Dir::Rx, Dir::Tx] {
            if let Some(hz) = differs(p.now.lo_hz[direction as usize], want.lo_hz[direction as usize]) {
                p.emit(Change::Lo { direction, hz });
            }
        }
        // 7. chains on
        if chains_on {
            p.emit(Change::Chains(new_chains));
        }
        // 8. gains, tx last
        for channel in 0..2 {
            if let Some(db) = differs(p.now.rx_gain_db[channel], want.rx_gain_db[channel]) {
                p.emit(Change::Gain { direction: Dir::Rx, channel, db });
            }
        }
        for channel in 0..2 {
            if let Some(db) = differs(p.now.tx_gain_db[channel], want.tx_gain_db[channel]) {
                p.emit(Change::Gain { direction: Dir::Tx, channel, db });
            }
        }
        p.changes
    }
}

// -- the plan -----------------------------------------------------------------

/// One operation on the radio.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Change {
    Reference(Reference),
    /// Sample rate, Hz.
    Rate { hz: f64 },
    /// A direction's analog filter, Hz.
    Bandwidth { direction: Dir, hz: f64 },
    /// A direction's synthesizer, Hz.
    Lo { direction: Dir, hz: f64 },
    /// Which chains are on (the data port's channel count follows).
    Chains(Chains),
    /// A channel's gain, dB (tx: 89.75 dB minus the attenuation).
    Gain { direction: Dir, channel: usize, db: f64 },
}

/// What the radio holds; None: unknown (or, for a target, left as it is).
#[derive(Clone, Debug, Default, PartialEq)]
struct State {
    reference: Option<Reference>,
    rate_hz: Option<f64>,
    /// Index: Dir.
    bandwidth_hz: [Option<f64>; 2],
    lo_hz: [Option<f64>; 2],
    chains: Option<Chains>,
    rx_gain_db: [Option<f64>; 2],
    tx_gain_db: [Option<f64>; 2],
}

impl State {
    /// The state `c` means: what it sets, a tx chain that is off at 0 dB.
    fn of(c: &Config) -> State {
        let mut s = State {
            reference: Some(c.reference),
            rate_hz: Some(c.rate_hz),
            chains: Some(c.chains()),
            tx_gain_db: [Some(0.0); 2],
            ..State::default()
        };
        if let Some(rx) = &c.rx {
            s.bandwidth_hz[Dir::Rx as usize] = Some(rx.bandwidth_hz);
            s.lo_hz[Dir::Rx as usize] = Some(rx.lo_hz);
            for (k, ch) in rx.channels().into_iter().enumerate() {
                s.rx_gain_db[k] = ch.map(|ch| ch.gain_db);
            }
        }
        if let Some(tx) = &c.tx {
            s.bandwidth_hz[Dir::Tx as usize] = Some(tx.bandwidth_hz);
            s.lo_hz[Dir::Tx as usize] = Some(tx.lo_hz);
            for (k, ch) in tx.channels().into_iter().enumerate() {
                if let Some(ch) = ch {
                    s.tx_gain_db[k] = Some(ch.gain_db);
                }
            }
        }
        s
    }

    /// What a change does to the radio (module doc, the plan): only what
    /// it names, except a rate change, after which both bandwidths are
    /// unknown.
    fn apply(&mut self, change: &Change) {
        match *change {
            Change::Reference(r) => self.reference = Some(r),
            Change::Rate { hz } => {
                self.rate_hz = Some(hz);
                self.bandwidth_hz = [None; 2];
            }
            Change::Bandwidth { direction, hz } => self.bandwidth_hz[direction as usize] = Some(hz),
            Change::Lo { direction, hz } => self.lo_hz[direction as usize] = Some(hz),
            Change::Chains(c) => self.chains = Some(c),
            Change::Gain { direction: Dir::Rx, channel, db } => self.rx_gain_db[channel] = Some(db),
            Change::Gain { direction: Dir::Tx, channel, db } => self.tx_gain_db[channel] = Some(db),
        }
    }
}

/// The target value when it is set and the radio holds another.
fn differs<T: PartialEq + Copy>(now: Option<T>, want: Option<T>) -> Option<T> {
    want.filter(|w| now != Some(*w))
}

struct Plan {
    now: State,
    changes: Vec<Change>,
}

impl Plan {
    fn emit(&mut self, c: Change) {
        self.now.apply(&c);
        self.changes.push(c);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Dir::{Rx as DRx, Tx as DTx};

    const EXAMPLE: &str = include_str!("../examples/config.toml");
    const MINIMAL: &str = "rate_hz = 1e6\n\
                           [rx]\nlo_hz = 100e6\nbandwidth_hz = 1e6\nch0 = { gain_db = 30 }\n";

    fn example() -> Config {
        Config::parse(EXAMPLE).unwrap()
    }

    /// 1 rx + 1 tx channel, sc12, 10 MS/s: inside every limit, so that a
    /// test moves one value to its boundary.
    fn base() -> Config {
        Config::parse(
            "rate_hz = 10e6\n\
             [rx]\nlo_hz = 1e9\nbandwidth_hz = 5e6\nch0 = { gain_db = 30 }\n\
             [tx]\nlo_hz = 1e9\nbandwidth_hz = 5e6\nch0 = { gain_db = 30 }\n",
        )
        .unwrap()
    }

    fn with(f: impl FnOnce(&mut Config)) -> Result<(), Error> {
        let mut c = base();
        f(&mut c);
        c.validate()
    }

    fn rx(c: &mut Config) -> &mut Rx {
        c.rx.as_mut().unwrap()
    }

    fn tx(c: &mut Config) -> &mut Tx {
        c.tx.as_mut().unwrap()
    }

    /// The Range error's key and value, or a panic.
    fn range_of(r: Result<(), Error>) -> (String, f64) {
        match r {
            Err(Error::Range { key, value, .. }) => (key, value),
            other => panic!("expected a range error, got {other:?}"),
        }
    }

    // -- parsing ----------------------------------------------------------------

    #[test]
    fn parses_the_example() {
        let c = example();
        assert_eq!((c.rate_hz, c.reference), (30.72e6, Reference::Internal));
        let r = c.rx.as_ref().unwrap();
        assert_eq!((r.lo_hz, r.bandwidth_hz), (2.45e9, 20e6));
        assert_eq!(r.ch0, Some(RxChannel { gain_db: 60.0 }));
        assert_eq!(r.ch1, Some(RxChannel { gain_db: 55.0 }));
        let t = c.tx.as_ref().unwrap();
        assert_eq!((t.lo_hz, t.bandwidth_hz), (2.45e9, 20e6));
        assert_eq!((t.ch0, t.ch1), (Some(TxChannel { gain_db: 60.0 }), Some(TxChannel { gain_db: 55.5 })));
        assert_eq!(c.chains(), Chains { rx: 0b11, tx: 0b11 });
    }

    #[test]
    fn parses_the_minimal_with_its_defaults() {
        let c = Config::parse(MINIMAL).unwrap();
        assert_eq!(c.reference, Reference::Internal);
        assert_eq!(c.tx, None);
        assert_eq!(c.chains(), Chains { rx: 0b01, tx: 0 });
    }

    #[test]
    fn what_this_image_cannot_run_is_rejected() {
        let external = MINIMAL.replace("rate_hz = 1e6", "rate_hz = 1e6\nreference = \"external\"");
        let e = Config::parse(&external).unwrap_err();
        assert!(matches!(e, Error::NotBuilt { key: "reference", value: "external", .. }), "{e:?}");
        assert_eq!(e.to_string(),
                   "reference = \"external\": not built yet (no FPGA register drives ref_sel or the ADF4001 in this image)");
        // negative control: internal, written out, is fine
        assert!(Config::parse(&MINIMAL.replace("rate_hz = 1e6", "rate_hz = 1e6\nreference = \"internal\"")).is_ok());
        // no antenna key: the switches are not driven
        match Config::parse(&MINIMAL.replace("gain_db = 30", "gain_db = 30, antenna = \"RX2\"")) {
            Err(Error::Toml(m)) => assert!(m.contains("unknown field `antenna`"), "{m}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn rejects_unknown_misspelled_and_missing_keys() {
        let cases = [
            (MINIMAL.replace("rate_hz = 1e6", "rate_hz = 1e6\ngain = 3"), "unknown field `gain`"),
            (MINIMAL.replace("bandwidth_hz", "agc = false\nbandwidth_hz"), "unknown field `agc`"),
            (MINIMAL.replace("gain_db = 30", "gain_db = 30, agc = true"), "unknown field `agc`"),
            (MINIMAL.replace("ch0", "ch2"), "unknown field `ch2`"),
            (MINIMAL.replace("lo_hz", "freq"), "unknown field `freq`"),
            (format!("{MINIMAL}[tx]\nlo_hz = 1e9\nbandwidth_hz = 1e6\nch0 = {{ gain_db = 1, antenna = \"TX/RX\" }}\n"),
             "unknown field `antenna`"),
            (MINIMAL.replace("gain_db = 30", ""), "missing field `gain_db`"),
            (MINIMAL.replace("rate_hz = 1e6", "rate_hz = 1e6\nreference = \"gpsdo\""), "gpsdo"),
        ];
        for (text, needle) in cases {
            match Config::parse(&text) {
                Err(Error::Toml(m)) => assert!(m.contains(needle), "{needle:?} not in {m:?}"),
                other => panic!("{text}\n-> {other:?}"),
            }
        }
    }

    // -- limits, each at its boundary ---------------------------------------

    #[test]
    fn rate_limits() {
        // 1 channel per direction: 61.44 MS/s (sc12: 61.44e6 x 6 = 369 MB/s)
        assert_eq!(with(|c| c.rate_hz = 61.44e6), Ok(()));
        assert_eq!(range_of(with(|c| c.rate_hz = 61_440_001.0)), ("rate_hz".into(), 61_440_001.0));
        // the lowest rate, without sections (their filters need more)
        let low = |c: &mut Config, hz| {
            c.rate_hz = hz;
            c.rx = None;
            c.tx = None;
        };
        assert_eq!(with(|c| low(c, MIN_RATE)), Ok(()));
        assert_eq!(range_of(with(|c| low(c, MIN_RATE - 1.0))), ("rate_hz".into(), MIN_RATE - 1.0));
        assert!(range_of(with(|c| c.rate_hz = f64::NAN)).1.is_nan());
        // 2 channels in either direction: 30.72 MS/s
        let two_rx = |c: &mut Config| rx(c).ch1 = Some(RxChannel { gain_db: 0.0 });
        let two_tx = |c: &mut Config| tx(c).ch1 = Some(TxChannel { gain_db: 0.0 });
        for two in [two_rx as fn(&mut Config), two_tx] {
            assert_eq!(with(|c| { two(c); c.rate_hz = 30.72e6 }), Ok(()));
            assert_eq!(
                with(|c| { two(c); c.rate_hz = 30_720_001.0 }),
                Err(Error::RateForChannels { rate_hz: 30_720_001.0, max_hz: 30.72e6 })
            );
        }
    }

    #[test]
    fn lo_limits() {
        for (key, set) in [
            ("rx.lo_hz", (|c: &mut Config, hz| rx(c).lo_hz = hz) as fn(&mut Config, f64)),
            ("tx.lo_hz", |c, hz| tx(c).lo_hz = hz),
        ] {
            assert_eq!(with(|c| set(c, 70e6)), Ok(()));
            assert_eq!(with(|c| set(c, 6e9)), Ok(()));
            assert_eq!(range_of(with(|c| set(c, 69_999_999.0))), (key.into(), 69_999_999.0));
            assert_eq!(range_of(with(|c| set(c, 6_000_000_001.0))), (key.into(), 6_000_000_001.0));
        }
    }

    #[test]
    fn bandwidth_limits_are_what_the_filters_reach() {
        for (key, set, min, max) in [
            ("rx.bandwidth_hz", (|c: &mut Config, hz| rx(c).bandwidth_hz = hz) as fn(&mut Config, f64), 800e3, 56e6),
            ("tx.bandwidth_hz", |c, hz| tx(c).bandwidth_hz = hz, 1.08e6, 40e6),
        ] {
            assert_eq!(with(|c| set(c, min)), Ok(()));
            assert_eq!(range_of(with(|c| set(c, min - 1.0))), (key.into(), min - 1.0));
            assert_eq!(with(|c| { c.rate_hz = 61.44e6; set(c, max) }), Ok(()));
            assert_eq!(range_of(with(|c| { c.rate_hz = 61.44e6; set(c, max + 1.0) })), (key.into(), max + 1.0));
            // the old limits (UHD's 200e3 ..= 56e6) are not all reachable
            assert!(with(|c| set(c, 200e3)).is_err());
            // no wider than the rate (10 MS/s in base)
            assert_eq!(with(|c| set(c, 10e6)), Ok(()));
            assert_eq!(
                with(|c| set(c, 10_000_001.0)),
                Err(Error::BandwidthAboveRate { key, bandwidth_hz: 10_000_001.0, rate_hz: 10e6 })
            );
        }
        // the tx maximum below the rx one: 41 MHz is rx-only
        assert_eq!(with(|c| { c.rate_hz = 61.44e6; rx(c).bandwidth_hz = 41e6 }), Ok(()));
    }

    #[test]
    fn rx_gain_limits_and_step() {
        let set = |db| move |c: &mut Config| rx(c).ch0.as_mut().unwrap().gain_db = db;
        for db in [0.0, 1.0, 75.0, 76.0] {
            assert_eq!(with(set(db)), Ok(()), "{db}");
        }
        for db in [-1.0, 77.0] {
            assert_eq!(range_of(with(set(db))), ("rx.ch0.gain_db".into(), db));
        }
        for db in [30.5, 0.25, 75.75] {
            assert_eq!(with(set(db)), Err(Error::Step { key: "rx.ch0.gain_db".into(), value: db, step: 1.0 }));
        }
        // the key names the channel
        let ch1 = with(|c| rx(c).ch1 = Some(RxChannel { gain_db: 77.0 }));
        assert_eq!(range_of(ch1).0, "rx.ch1.gain_db");
    }

    #[test]
    fn tx_gain_limits_and_step() {
        let set = |db| move |c: &mut Config| tx(c).ch0.as_mut().unwrap().gain_db = db;
        for db in [0.0, 0.25, 89.5, 89.75] {
            assert_eq!(with(set(db)), Ok(()), "{db}");
        }
        for db in [-0.25, 90.0] {
            assert_eq!(range_of(with(set(db))), ("tx.ch0.gain_db".into(), db));
        }
        for db in [0.1, 30.3, 89.7] {
            assert_eq!(with(set(db)), Err(Error::Step { key: "tx.ch0.gain_db".into(), value: db, step: 0.25 }));
        }
    }

    #[test]
    fn a_section_needs_a_channel_and_a_one_channel_direction_is_channel_0() {
        assert_eq!(with(|c| rx(c).ch0 = None), Err(Error::NoChannel("rx")));
        assert_eq!(with(|c| tx(c).ch0 = None), Err(Error::NoChannel("tx")));
        assert_eq!(with(|c| c.tx = None), Ok(())); // the whole section away: tx off
        // ch1 alone would run as a one-channel port carrying channel 0
        assert_eq!(with(|c| { let ch0 = rx(c).ch0.take(); rx(c).ch1 = ch0; }), Err(Error::OnlyChannel1("rx")));
        assert_eq!(with(|c| { let ch0 = tx(c).ch0.take(); tx(c).ch1 = ch0; }), Err(Error::OnlyChannel1("tx")));
        // ch0 alone, or both, are the one- and two-channel cases
        assert_eq!(with(|c| rx(c).ch1 = None), Ok(()));
        assert_eq!(with(|c| { rx(c).ch1 = Some(RxChannel { gain_db: 0.0 }); }), Ok(()));
    }

    #[test]
    fn messages_name_the_key_the_value_and_the_way_out() {
        let text = |r: Result<(), Error>| r.unwrap_err().to_string();
        assert_eq!(text(with(|c| rx(c).lo_hz = 6_000_000_001.0)), "rx.lo_hz = 6000000001: outside 70000000 ..= 6000000000 Hz");
        assert_eq!(text(with(|c| tx(c).ch0.as_mut().unwrap().gain_db = 0.1)), "tx.ch0.gain_db = 0.1: not a multiple of 0.25 dB");
        assert_eq!(text(with(|c| rx(c).ch0 = None)), "[rx] has no channel: add ch0 and/or ch1, or remove the section");
    }

    // -- the plan: exact plans --------------------------------------------------

    use super::Change as C;

    fn mute(c: usize) -> Change {
        C::Gain { direction: DTx, channel: c, db: 0.0 }
    }

    #[test]
    fn from_unknown_everything_in_order() {
        let all = Chains { rx: 0b11, tx: 0b11 };
        assert_eq!(Config::changes(None, &example()), [
            mute(0), mute(1), C::Chains(Chains::NONE),
            C::Reference(Reference::Internal), C::Rate { hz: 30.72e6 },
            C::Bandwidth { direction: DRx, hz: 20e6 }, C::Bandwidth { direction: DTx, hz: 20e6 },
            C::Lo { direction: DRx, hz: 2.45e9 }, C::Lo { direction: DTx, hz: 2.45e9 },
            C::Chains(all),
            C::Gain { direction: DRx, channel: 0, db: 60.0 }, C::Gain { direction: DRx, channel: 1, db: 55.0 },
            C::Gain { direction: DTx, channel: 0, db: 60.0 }, C::Gain { direction: DTx, channel: 1, db: 55.5 },
        ]);
    }

    #[test]
    fn identical_configs_need_nothing() {
        for text in [EXAMPLE, MINIMAL] {
            let c = Config::parse(text).unwrap();
            assert_eq!(Config::changes(Some(&c), &c), []);
        }
    }

    #[test]
    fn one_value_one_change() {
        let old = example();
        let one = |f: fn(&mut Config), want: Change| {
            let mut new = old.clone();
            f(&mut new);
            new.validate().unwrap();
            assert_eq!(Config::changes(Some(&old), &new), [want]);
        };
        one(|c| rx(c).ch1.as_mut().unwrap().gain_db = 36.0, C::Gain { direction: DRx, channel: 1, db: 36.0 });
        one(|c| tx(c).ch0.as_mut().unwrap().gain_db = 61.25, C::Gain { direction: DTx, channel: 0, db: 61.25 });
        // an rx filter change does not transmit: no mute
        one(|c| rx(c).bandwidth_hz = 10e6, C::Bandwidth { direction: DRx, hz: 10e6 });
    }

    #[test]
    fn transmit_risks_are_muted_and_gains_restored_last() {
        let old = example();
        let unmute = [C::Gain { direction: DTx, channel: 0, db: 60.0 }, C::Gain { direction: DTx, channel: 1, db: 55.5 }];
        // an rx LO change moves the tx LO during calibration
        let mut new = old.clone();
        rx(&mut new).lo_hz = 915e6;
        assert_eq!(Config::changes(Some(&old), &new), [mute(0), mute(1), C::Lo { direction: DRx, hz: 915e6 }, unmute[0], unmute[1]]);
        // a rate change recalibrates; both filters are set again
        let mut new = old.clone();
        new.rate_hz = 25e6;
        assert_eq!(Config::changes(Some(&old), &new), [
            mute(0), mute(1), C::Rate { hz: 25e6 },
            C::Bandwidth { direction: DRx, hz: 20e6 }, C::Bandwidth { direction: DTx, hz: 20e6 },
            unmute[0], unmute[1],
        ]);
        // without tx there is nothing to mute
        let old = Config::parse(MINIMAL).unwrap();
        let mut new = old.clone();
        rx(&mut new).lo_hz = 433e6;
        assert_eq!(Config::changes(Some(&old), &new), [C::Lo { direction: DRx, hz: 433e6 }]);
    }

    #[test]
    fn tx_chains_off_muted_first_on_at_maximum_attenuation() {
        let both = example();
        let mut one = both.clone();
        tx(&mut one).ch1 = None;
        let rx2_tx1 = Chains { rx: 0b11, tx: 0b01 };
        // off: tx 0 stays on, so set_channels calibrates it: both muted
        assert_eq!(Config::changes(Some(&both), &one), [
            mute(0), mute(1), C::Chains(rx2_tx1), C::Gain { direction: DTx, channel: 0, db: 60.0 },
        ]);
        // with no tx chain left on, only the one switched off is muted
        let mut rx_only = both.clone();
        rx_only.tx = None;
        let mut one_tx = rx_only.clone();
        one_tx.tx = Some(Tx { lo_hz: 2.45e9, bandwidth_hz: 20e6, ch0: Some(TxChannel { gain_db: 60.0 }), ch1: None });
        assert_eq!(Config::changes(Some(&one_tx), &rx_only), [mute(0), C::Chains(Chains { rx: 0b11, tx: 0 })]);
        // on: a new transmitter mutes the running one; gains last
        assert_eq!(Config::changes(Some(&one), &both), [
            mute(0), C::Chains(Chains { rx: 0b11, tx: 0b11 }),
            C::Gain { direction: DTx, channel: 0, db: 60.0 }, C::Gain { direction: DTx, channel: 1, db: 55.5 },
        ]);
    }

    #[test]
    fn channel_count_falls_before_a_rate_rise_and_rises_after_a_rate_fall() {
        // 2 rx at 30.72 MS/s <-> 1 rx at 61.44 MS/s (sc12, rx only)
        let two = Config::parse("rate_hz = 30.72e6\n[rx]\nlo_hz = 1e9\nbandwidth_hz = 20e6\n\
                                 ch0 = { gain_db = 10 }\nch1 = { gain_db = 10 }\n").unwrap();
        let mut one = two.clone();
        one.rate_hz = 61.44e6;
        rx(&mut one).ch1 = None;
        let rx0 = Chains { rx: 0b01, tx: 0 };
        let rx01 = Chains { rx: 0b11, tx: 0 };
        assert_eq!(Config::changes(Some(&two), &one), [
            C::Chains(rx0), C::Rate { hz: 61.44e6 }, C::Bandwidth { direction: DRx, hz: 20e6 },
        ]);
        assert_eq!(Config::changes(Some(&one), &two), [
            C::Rate { hz: 30.72e6 }, C::Bandwidth { direction: DRx, hz: 20e6 }, C::Chains(rx01),
            // a channel switched on gets every setting
            C::Gain { direction: DRx, channel: 1, db: 10.0 },
        ]);
    }

    #[test]
    fn a_port_mode_dip_between_the_ends_is_muted() {
        // 1 rx + 2 tx -> 2 rx + 1 tx: 2-channel at both ends, 1 + 1 after
        // step 2 (found by the generated pairs)
        let old = Config::parse("rate_hz = 25e6\n[rx]\nlo_hz = 1e9\nbandwidth_hz = 1e6\n\
                                 ch0 = { gain_db = 0 }\n[tx]\nlo_hz = 1e9\nbandwidth_hz = 2e6\n\
                                 ch0 = { gain_db = 40 }\nch1 = { gain_db = 40 }\n").unwrap();
        let mut new = old.clone();
        rx(&mut new).ch1 = Some(RxChannel { gain_db: 0.0 });
        tx(&mut new).ch1 = None;
        assert_eq!(Config::changes(Some(&old), &new), [
            mute(0), mute(1),
            C::Chains(Chains { rx: 0b01, tx: 0b01 }),
            C::Chains(Chains { rx: 0b11, tx: 0b01 }),
            C::Gain { direction: DRx, channel: 1, db: 0.0 },
            C::Gain { direction: DTx, channel: 0, db: 40.0 },
        ]);
    }

    #[test]
    fn an_rx_chain_change_with_tx_on_is_muted() {
        // set_channels runs the tx quadrature calibration whenever a tx
        // chain is on, so dropping an rx channel under a running tx mutes it
        let old = example();
        let mut new = old.clone();
        rx(&mut new).ch1 = None;
        let rx1_tx2 = C::Chains(Chains { rx: 0b01, tx: 0b11 });
        let plan = Config::changes(Some(&old), &new);
        assert_eq!(plan, [
            mute(0), mute(1), rx1_tx2,
            C::Gain { direction: DTx, channel: 0, db: 60.0 }, C::Gain { direction: DTx, channel: 1, db: 55.5 },
        ]);
        assert!(check_plan(Some(&old), &new, &plan).is_ok());
        // negative control: the plan without the mute is caught by the model
        let e = check_plan(Some(&old), &new, &[rx1_tx2]).unwrap_err();
        assert!(e.starts_with("chains with tx gains"), "{e}");
        // and without tx the same rx change needs no mute
        let (mut old, mut new) = (old, new);
        old.tx = None;
        new.tx = None;
        assert_eq!(Config::changes(Some(&old), &new), [C::Chains(Chains { rx: 0b01, tx: 0 })]);
    }

    // -- the plan: properties over generated pairs --------------------------------

    /// A radio that holds what it was told and checks, independently of
    /// `changes`, the rules a plan must keep: TX muted before anything that
    /// could transmit, a tx chain off only at 0 dB, the filters after the
    /// rate, the rate limit in every intermediate state, no write of a
    /// value already held.
    #[derive(Clone, Debug, Default)]
    struct Model {
        reference: Option<Reference>,
        rate_hz: Option<f64>,
        bandwidth_hz: [Option<f64>; 2],
        lo_hz: [Option<f64>; 2],
        chains: Option<Chains>,
        rx_gain_db: [Option<f64>; 2],
        tx_gain_db: [Option<f64>; 2],
    }

    fn put<T: PartialEq + Copy + std::fmt::Debug>(slot: &mut Option<T>, v: T, what: &str) -> Result<(), String> {
        if *slot == Some(v) {
            return Err(format!("{what} := {v:?}: the value already held"));
        }
        *slot = Some(v);
        Ok(())
    }

    fn dual(c: Chains) -> bool {
        c.rx == 0b11 || c.tx == 0b11
    }

    impl Model {
        fn muted(&self, what: &str) -> Result<(), String> {
            if self.tx_gain_db == [Some(0.0); 2] { Ok(()) } else { Err(format!("{what} with tx gains {:?}", self.tx_gain_db)) }
        }

        fn rate_fits(&self) -> Result<(), String> {
            if let (Some(r), Some(c)) = (self.rate_hz, self.chains) {
                let max = if dual(c) { 30.72e6 } else { 61.44e6 };
                if r > max {
                    return Err(format!("rate {r} with chains {c:?}"));
                }
            }
            Ok(())
        }

        fn apply(&mut self, change: &Change) -> Result<(), String> {
            match *change {
                C::Reference(r) => {
                    self.muted("reference")?;
                    put(&mut self.reference, r, "reference")
                }
                C::Rate { hz } => {
                    self.muted("rate")?;
                    if self.chains.is_none() {
                        return Err("rate with unknown chains".into());
                    }
                    put(&mut self.rate_hz, hz, "rate")?;
                    self.bandwidth_hz = [None; 2]; // what a rate change does
                    self.rate_fits()
                }
                C::Bandwidth { direction, hz } => {
                    if direction == DTx {
                        self.muted("tx bandwidth")?;
                    }
                    match self.rate_hz {
                        None => return Err("bandwidth before rate".into()),
                        Some(r) if hz > r => return Err(format!("bandwidth {hz} above rate {r}")),
                        _ => {}
                    }
                    put(&mut self.bandwidth_hz[direction as usize], hz, "bandwidth")
                }
                C::Lo { direction, hz } => {
                    self.muted("lo")?;
                    put(&mut self.lo_hz[direction as usize], hz, "lo")
                }
                C::Chains(c) => {
                    let old = self.chains;
                    // any tx chain on: set_channels calibrates it
                    if c.tx != 0 || old.is_none_or(|o| dual(o) != dual(c)) {
                        self.muted("chains")?;
                    }
                    for k in 0..2 {
                        if !c.tx_on(k) && self.tx_gain_db[k] != Some(0.0) {
                            return Err(format!("tx chain {k} off at gain {:?}", self.tx_gain_db[k]));
                        }
                    }
                    put(&mut self.chains, c, "chains")?;
                    self.rate_fits()
                }
                C::Gain { direction: DRx, channel, db } => put(&mut self.rx_gain_db[channel], db, "rx gain"),
                C::Gain { direction: DTx, channel, db } => {
                    if db != 0.0 && !self.chains.is_some_and(|c| c.tx_on(channel)) {
                        return Err(format!("tx gain {db} on tx chain {channel}, which is off"));
                    }
                    put(&mut self.tx_gain_db[channel], db, "tx gain")
                }
            }
        }
    }

    /// The model holds what `c` says, read from `c` directly.
    fn holds(m: &Model, c: &Config) -> Result<(), String> {
        let mut bad = Vec::new();
        let mut check = |ok: bool, what: &str| if !ok { bad.push(what.to_string()) };
        check(m.reference == Some(c.reference), "reference");
        check(m.rate_hz == Some(c.rate_hz), "rate");
        let present = |a: bool, b: bool| a as u8 | (b as u8) << 1;
        let rx_on = c.rx.as_ref().map_or(0, |r| present(r.ch0.is_some(), r.ch1.is_some()));
        let tx_on = c.tx.as_ref().map_or(0, |t| present(t.ch0.is_some(), t.ch1.is_some()));
        check(m.chains == Some(Chains { rx: rx_on, tx: tx_on }), "chains");
        if let Some(r) = &c.rx {
            check(m.bandwidth_hz[0] == Some(r.bandwidth_hz), "rx bandwidth");
            check(m.lo_hz[0] == Some(r.lo_hz), "rx lo");
            for (k, ch) in [r.ch0, r.ch1].into_iter().enumerate() {
                if let Some(ch) = ch {
                    check(m.rx_gain_db[k] == Some(ch.gain_db), "rx gain");
                }
            }
        }
        if let Some(t) = &c.tx {
            check(m.bandwidth_hz[1] == Some(t.bandwidth_hz), "tx bandwidth");
            check(m.lo_hz[1] == Some(t.lo_hz), "tx lo");
        }
        let tx = c.tx.as_ref();
        for (k, ch) in [tx.and_then(|t| t.ch0), tx.and_then(|t| t.ch1)].into_iter().enumerate() {
            check(m.tx_gain_db[k] == Some(ch.map_or(0.0, |ch| ch.gain_db)), "tx gain (0 when off)");
        }
        if bad.is_empty() { Ok(()) } else { Err(format!("model differs in {bad:?}: {m:?}")) }
    }

    /// What a plan did, for the coverage check.
    #[derive(Debug, Default)]
    struct Seen {
        mute: bool,
        chains_off: bool,
        chains_on: bool,
        reference: bool,
        rate: bool,
        bandwidth: bool,
        lo: bool,
        gain: bool,
    }

    /// Runs `plan` on a model configured as `old` (by the plan from
    /// unknown) and checks every rule: the model's, the order of the module
    /// doc, each value written at most once (a tx gain: mute, then its
    /// value), a mute only when the plan could transmit or switches that
    /// chain off, and the model holding `new` at the end.
    fn check_plan(old: Option<&Config>, new: &Config, plan: &[Change]) -> Result<Seen, String> {
        let mut m = Model::default();
        if let Some(old) = old {
            for ch in Config::changes(None, old) {
                m.apply(&ch).map_err(|e| format!("configuring old: {e}"))?;
            }
            holds(&m, old)?;
        }
        let mut seen = Seen::default();
        let (mut last, mut prefix, mut could_transmit) = (-1, true, false);
        let mut muted = [false; 2];
        let mut switched_off = [false; 2];
        let mut writes = std::collections::HashMap::new();
        for ch in plan {
            let before = m.chains;
            let class = match *ch {
                C::Gain { direction: DTx, channel, db } if prefix && db == 0.0 => {
                    muted[channel] = true;
                    seen.mute = true;
                    -1
                }
                C::Chains(c) => {
                    let sub = |a: u8, b: u8| a & !b == 0;
                    let off = before.is_none_or(|o| sub(c.rx, o.rx) && sub(c.tx, o.tx));
                    let on = before.is_some_and(|o| sub(o.rx, c.rx) && sub(o.tx, c.tx));
                    if c.tx != 0 || before.is_none_or(|o| dual(o) != dual(c))
                    {
                        could_transmit = true;
                    }
                    for (k, off) in switched_off.iter_mut().enumerate() {
                        *off |= !c.tx_on(k) && before.is_none_or(|o| o.tx_on(k));
                    }
                    if off {
                        seen.chains_off = true;
                        0
                    } else if on {
                        seen.chains_on = true;
                        7
                    } else {
                        return Err(format!("{ch:?} switches chains both on and off"));
                    }
                }
                C::Reference(_) => { could_transmit = true; seen.reference = true; 1 }
                C::Rate { .. } => { could_transmit = true; seen.rate = true; 2 }
                C::Bandwidth { direction: DRx, .. } => { seen.bandwidth = true; 3 }
                C::Bandwidth { direction: DTx, .. } => { could_transmit = true; seen.bandwidth = true; 4 }
                C::Lo { direction, .. } => { could_transmit = true; seen.lo = true; 5 + direction as i32 }
                C::Gain { direction, .. } => { seen.gain = true; 8 + direction as i32 }
            };
            if class != -1 {
                prefix = false;
            }
            if class < last {
                return Err(format!("{ch:?} after an operation of a later step"));
            }
            last = class;
            let key = match *ch {
                C::Gain { direction, channel, .. } => format!("gain {direction:?} {channel}"),
                C::Bandwidth { direction, .. } => format!("bandwidth {direction:?}"),
                C::Lo { direction, .. } => format!("lo {direction:?}"),
                C::Chains(_) => format!("chains {class}"),
                _ => format!("{:?}", std::mem::discriminant(ch)),
            };
            let n = writes.entry(key.clone()).or_insert(0);
            *n += 1;
            if *n > if key.starts_with("gain Tx") { 2 } else { 1 } {
                return Err(format!("{key} written {n} times"));
            }
            m.apply(ch)?;
        }
        // a mute is a 0 dB written first and undone later (a single 0 dB is
        // just the gain new asks for)
        for k in 0..2 {
            let undone = writes.get(&format!("gain Tx {k}")) == Some(&2);
            if muted[k] && undone && !could_transmit && !switched_off[k] {
                return Err(format!("tx {k} muted without a reason"));
            }
        }
        holds(&m, new)?;
        Ok(seen)
    }

    /// xorshift64*: deterministic, so a failure reproduces.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }
        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
        fn pick<T: Copy>(&mut self, xs: &[T]) -> T {
            xs[self.below(xs.len())]
        }
        fn coin(&mut self) -> bool {
            self.below(2) == 0
        }
    }

    // Few values per key, the limits among them, so that generated
    // configurations often share values and differ in few.
    const RATES: [f64; 6] = [MIN_RATE, 1e6, 10e6, 25e6, 30.72e6, 61.44e6];
    const LOS: [f64; 4] = [70e6, 915e6, 2.45e9, 6e9];
    const RX_BANDWIDTHS: [f64; 4] = [800e3, 1e6, 20e6, 56e6];
    const TX_BANDWIDTHS: [f64; 4] = [1.08e6, 2e6, 20e6, 40e6];
    const RX_GAINS: [f64; 3] = [0.0, 31.0, 76.0];
    const TX_GAINS: [f64; 3] = [0.0, 40.25, 89.75];

    fn rx_channel(r: &mut Rng) -> Option<RxChannel> {
        r.coin().then(|| RxChannel { gain_db: r.pick(&RX_GAINS) })
    }

    fn tx_channel(r: &mut Rng) -> Option<TxChannel> {
        r.coin().then(|| TxChannel { gain_db: r.pick(&TX_GAINS) })
    }

    fn random_rx(r: &mut Rng) -> Rx {
        Rx { lo_hz: r.pick(&LOS), bandwidth_hz: r.pick(&RX_BANDWIDTHS), ch0: rx_channel(r), ch1: rx_channel(r) }
    }

    fn random_tx(r: &mut Rng) -> Tx {
        Tx { lo_hz: r.pick(&LOS), bandwidth_hz: r.pick(&TX_BANDWIDTHS), ch0: tx_channel(r), ch1: tx_channel(r) }
    }

    fn random_config(r: &mut Rng) -> Config {
        loop {
            let c = Config {
                rate_hz: r.pick(&RATES),
                reference: Reference::Internal,
                rx: (r.below(5) != 0).then(|| random_rx(r)),
                tx: (r.below(3) != 0).then(|| random_tx(r)),
            };
            if c.validate().is_ok() {
                return c;
            }
        }
    }

    /// `c` with one to three keys changed, valid.
    fn mutate(r: &mut Rng, c: &Config) -> Config {
        loop {
            let mut m = c.clone();
            for _ in 0..1 + r.below(3) {
                match r.below(10) {
                    0 => m.rate_hz = r.pick(&RATES),
                    1 => {}
                    2 => m.rx = if m.rx.is_some() { None } else { Some(random_rx(r)) },
                    3 => m.tx = if m.tx.is_some() { None } else { Some(random_tx(r)) },
                    4 => if let Some(x) = &mut m.rx { x.lo_hz = r.pick(&LOS) },
                    5 => if let Some(x) = &mut m.tx { x.lo_hz = r.pick(&LOS) },
                    6 => if let Some(x) = &mut m.rx { x.bandwidth_hz = r.pick(&RX_BANDWIDTHS) },
                    7 => if let Some(x) = &mut m.tx { x.bandwidth_hz = r.pick(&TX_BANDWIDTHS) },
                    8 => if let Some(x) = &mut m.rx {
                        if r.coin() { x.ch0 = rx_channel(r) } else { x.ch1 = rx_channel(r) }
                    },
                    _ => if let Some(x) = &mut m.tx {
                        if r.coin() { x.ch0 = tx_channel(r) } else { x.ch1 = tx_channel(r) }
                    },
                }
            }
            if m.validate().is_ok() {
                return m;
            }
        }
    }

    #[test]
    fn plans_keep_every_rule_over_generated_pairs() {
        const PAIRS: usize = 5000;
        let mut r = Rng(0x9E37_79B9_7F4A_7C15);
        let mut counts = [0usize; 8];
        let (mut empty, mut identical) = (0, 0);
        for i in 0..PAIRS {
            let a = random_config(&mut r);
            let b = if r.coin() { mutate(&mut r, &a) } else { random_config(&mut r) };
            for old in [Some(&a), None] {
                let plan = Config::changes(old, &b);
                let seen = check_plan(old, &b, &plan)
                    .unwrap_or_else(|e| panic!("pair {i}: {e}\nold {old:?}\nnew {b:?}\nplan {plan:?}"));
                let flags = [seen.mute, seen.chains_off, seen.chains_on, seen.reference, seen.rate,
                             seen.bandwidth, seen.lo, seen.gain];
                for (n, f) in counts.iter_mut().zip(flags) {
                    *n += f as usize;
                }
                if old.is_some() && plan.is_empty() {
                    empty += 1;
                }
            }
            if a == b {
                identical += 1;
                assert_eq!(Config::changes(Some(&a), &b), [], "pair {i}");
            }
            assert_eq!(Config::changes(Some(&b), &b), [], "pair {i}");
        }
        // coverage: every kind of step occurred often, so no rule held vacuously
        assert!(counts.iter().all(|&n| n > PAIRS / 20), "{counts:?}");
        assert!(identical > 0 && empty >= identical, "{identical} identical, {empty} empty plans");
    }

    #[test]
    fn the_checker_rejects_broken_plans() {
        let old = example();
        let mut new = old.clone();
        new.rate_hz = 25e6;
        rx(&mut new).bandwidth_hz = 10e6;
        tx(&mut new).ch0.as_mut().unwrap().gain_db = 61.0;
        let good = Config::changes(Some(&old), &new);
        assert_eq!(good, [
            mute(0), mute(1), C::Rate { hz: 25e6 },
            C::Bandwidth { direction: DRx, hz: 10e6 }, C::Bandwidth { direction: DTx, hz: 20e6 },
            C::Gain { direction: DTx, channel: 0, db: 61.0 }, C::Gain { direction: DTx, channel: 1, db: 55.5 },
        ]);
        assert!(check_plan(Some(&old), &new, &good).is_ok());
        let broken = |f: &dyn Fn(&mut Vec<Change>)| {
            let mut p = good.clone();
            f(&mut p);
            check_plan(Some(&old), &new, &p).unwrap_err()
        };
        // no mute before the rate change
        assert!(broken(&|p| { p.drain(..2); }).starts_with("rate with tx gains"));
        // a gain first
        assert!(broken(&|p| { let g = p.pop().unwrap(); p.insert(2, g) }).contains("later step"));
        // a filter before the rate (rate known from old: caught by order)
        assert!(broken(&|p| p.swap(2, 3)).contains("later step"));
        // a value written twice
        assert!(broken(&|p| p.insert(3, C::Rate { hz: 25e6 })).contains("written 2 times"));
        // an operation missing: the model does not reach new
        assert!(broken(&|p| { p.remove(4); }).contains("model differs"));
        // a value written that the radio already holds
        let mut g = old.clone();
        rx(&mut g).ch0.as_mut().unwrap().gain_db = 41.0;
        let one = Config::changes(Some(&old), &g);
        assert_eq!(one, [C::Gain { direction: DRx, channel: 0, db: 41.0 }]);
        let mut p = one.clone();
        p.push(C::Gain { direction: DRx, channel: 1, db: 55.0 });
        assert!(check_plan(Some(&old), &g, &p).unwrap_err().contains("already held"));
        // a mute without a reason
        let mut p = one.clone();
        p.insert(0, mute(0));
        p.push(C::Gain { direction: DTx, channel: 0, db: 60.0 });
        assert!(check_plan(Some(&old), &g, &p).unwrap_err().contains("without a reason"));
    }
}
