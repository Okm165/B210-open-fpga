// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright 2014 Ettus Research
// Copyright 2018 Ettus Research, a National Instruments Company
//
// Derived from UHD's ad9361_driver (ad9361_device.cpp, ad9361_device.h,
// ad9361_client.h), UHD 3.15 as patched and run by v1 of this project
// (.tools/src/uhd/host/lib/usrp/common/ad9361_driver/), with the B210's
// client settings from b200_impl.cpp and the SPI word of ad9361_ctrl.cpp.
// Rewritten for the B210 alone; the SPI sequence is UHD's, write for write,
// except the one documented change (maximum TX attenuation before FDD).
// tests/ad9361_golden.rs proves it against traces of UHD's own C++.

//! AD9361 configuration: bring-up, rate, LO frequencies, gains, analog
//! bandwidths, calibrations and the digital test modes, for the B210.
//!
//! The driver knows nothing about USB: it talks to the chip through a [`Bus`]
//! whose operations are those of docs/PROTOCOL.md section 4 (SPI, WAIT,
//! POLL). Writes, waits and polls are queued; the queue runs when the driver
//! needs a value read back to decide what to write next, and at the end of
//! every public call. Calibrations wait in POLL operations on the FPGA, not
//! in host round trips.
//!
//! # Units
//!
//! Frequencies, rates and bandwidths in Hz (f64), gains in dB, waits in us,
//! poll limits in ms. "bandwidth" is the RF (two-sided) bandwidth UHD takes;
//! the analog filters are set from the baseband (one-sided) bandwidth
//! bbbw = bandwidth / 2.
//!
//! # Clocks and rate
//!
//! The chip's baseband PLL (BBPLL) runs from the 40 MHz reference:
//!
//!   f_bbpll = 40 MHz x (N_int + N_frac / 2 088 960),  N_frac rounded,
//!   715 MHz <= f_bbpll <= 1430 MHz,  f_adc = f_bbpll / 2^k,  k = 1 .. 6.
//!
//! The receive chain decimates the ADC clock by D_rx = (1, 2 or 3) x (1 or 2)
//! x (1 or 2) x (FIR 2 or 4) (stages HB3/DEC3, HB2, HB1, FIR; register 0x003),
//! chosen by rate band, so f_adc = rate x D_rx. The DAC runs at f_adc, or
//! f_adc / 2 above 320 MHz, where the transmit interpolation D_tx is D_rx / 2
//! (register 0x002); both directions run the same rate. The rate set is the
//! one the PLL reaches: f_adc / D_rx (returned by `set_rate`). The bands keep
//! every clock within ADI's limits (no-OS ad9361.h, MIN_BBPLL_FREQ ..
//! MAX_TX_HB1): BBPLL 715 .. 1430 MHz, ADC 25 .. 640 MHz, DAC <= 320 MHz, rx
//! half-band outputs HB3 <= 640, HB2 <= 320, HB1 <= 245.76 MHz, tx half-band
//! inputs HB3 <= 320, HB2 <= 320, HB1 <= 160 MHz (test
//! rate_bands_keep_adis_clock_limits). Every rate in [MIN_RATE, 61.44 MHz]
//! has a k (the [715, 1430] MHz windows of successive k meet).
//!
//! # LO frequencies
//!
//! Each RF synthesizer runs from REFCLK x 2 = 80 MHz:
//!
//!   f_lo = 80 MHz x (N_int + N_frac / 8 388 593) / 2^(k + 1),  N_frac truncated,
//!   6 GHz <= f_vco <= 12 GHz,  k = 0 .. 6,
//!
//! so f_lo in [46.875 MHz, 6 GHz]; the B210 takes [70 MHz, 6 GHz].
//!
//! # Analog filters (UG-570 "baseband filters")
//!
//! With bbbw clamped to rate / 2 and to each filter's range:
//! rx baseband LPF corner 1.4 bbbw, rx TIA 2.5 bbbw, tx baseband LPF 1.6 bbbw,
//! tx secondary LPF 5 bbbw. A filter is tuned by a calibration clocked at
//! f_bbpll / div with div = ceil(f_bbpll ln 2 / (2 pi x corner)), at most 511.
//!
//! # Gains
//!
//! rx: gain index g in 0 .. 76, a row of the band's gain table (about 1 dB
//! per step; the table changes at 1.3 GHz and 4 GHz). tx: attenuation word
//! a = 4 (89.75 - gain) in 0.25 dB steps; gain 0 dB is the maximum
//! attenuation, 89.75 dB.
//!
//! # Invariants
//!
//! - The register shadows (`inputsel`, `rxfilt`, `txfilt`, `vcodivs`,
//!   `bbpll`, `bbftune_*`, `bist`, `loopback`) hold what the chip's registers
//!   hold: only this driver writes them.
//! - Between public calls the chip is in FDD (state 0x0A) with the chains of
//!   `set_channels` enabled, and every queued operation has run.
//! - 2 channels at most 30.72 MS/s: the CMOS dual-port data clock is at most
//!   61.44 MHz with one sample time per clock per channel (I and Q on the two
//!   edges, UG-570 "CMOS dual port full duplex"), and 2R2T takes two clocks.
//!
//! # Changes from UHD
//!
//! tests/ad9361_golden.rs compares this driver with UHD's C++ access for
//! access and allows exactly these differences.
//!
//! *TX attenuation at bring-up.* UHD's initialize() writes TX attenuation
//! 0 dB (registers 0x073 .. 0x076 := 0, under a comment saying 10 dB) and then enters FDD with TX1 on: full
//! output power until the first gain is set, and a chip state that
//! contradicts the driver's own "tx gain 0" (= 89.75 dB attenuation). Here the
//! same four writes carry the maximum attenuation, 4 x 89.75 = 359 = 0x167
//! (0x073 := 0x67, 0x074 := 0x01, 0x075 := 0x67, 0x076 := 0x01), at the same
//! place, before FDD. The TX quadrature calibration that follows in
//! `set_channels` then runs at maximum attenuation, as every later one does
//! in UHD (its tune() rewrites the stored gains, 0 dB by default, first).
//!
//! *Rate bands within ADI's clock limits* (Clocks and rate). UHD's bands
//! run the ADC above ADI's 640 MHz from 40 MS/s (decimation 16 below 41
//! MS/s: 656 MHz; decimation 12 up to 58 MS/s: 696 MHz) and below its
//! 25 MHz under 1.5625 MS/s (16 MHz at 1 MS/s), and UHD's minimum rate
//! 220 kHz needs a BBPLL below ADI's 715 MHz. Here: decimation 48 below
//! 781.25 kS/s, 32 below 1.5625 MS/s, 16 up to 40 MS/s, 12 up to
//! 53.33 MS/s, 8 above; the DAC halves above 320 MHz (UHD: 336 MHz, which
//! no band reaches between 320 and 336 MHz, so no access changes); the
//! minimum rate is 25 MHz / 48 = 520.833 kHz. Rates in [1.5625, 40] and
//! (41, 53.33] and (58, 61.44] MS/s, init's 50 MS/s among them, keep UHD's
//! bands access for access.
//!
//! *RF PLL lock.* UHD waits 2 ms after a synthesizer write and reads the
//! lock bit once; ADI polls it until set (no-OS ad9361_check_cal_done).
//! Here: the same 2 ms wait, then a POLL of the lock bit for up to
//! [`PLL_LOCK_MS`]. A POLL is recorded as its first read, so a chip that is
//! locked at once (the golden traces' `settled` rule) gives UHD's accesses.
//!
//! # Conversions
//!
//! UHD converts doubles to uint8_t/uint16_t with C casts; `c_u8` keeps the
//! C behaviour (truncation toward zero; gcc on x86-64 then keeps the low
//! bits) so that the port stays exact even where a value leaves [0, 256).

mod tables;
pub mod mock;

use std::f64::consts::{LN_2, PI};
use tables::GainTable;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("bus: {0}")]
    Bus(Box<dyn std::error::Error + Send + Sync>),
    #[error("AD9361 register {reg:#05x} = {value:#04x}: (value & {mask:#04x}) != {want:#04x} within the time limit")]
    Poll { reg: u16, mask: u8, want: u8, value: u8 },
    #[error("AD9361 product id register 0x037 & 0xf8 = {0:#04x}, expected product 0x08 in bits 7:3")]
    ProductId(u8),
    #[error("AD9361 state machine in state {0:#x}, expected ALERT (0x5) or FDD (0xa)")]
    State(u8),
    #[error("{what} = {value} outside [{min}, {max}]")]
    Range { what: &'static str, value: f64, min: f64, max: f64 },
    #[error("tx quadrature calibration tone at {tone} Hz beyond the rx filter ({bandwidth} Hz)")]
    CalTone { tone: f64, bandwidth: f64 },
}

/// The AD9361's register bus, as the FPGA's control operations reach it
/// (docs/PROTOCOL.md section 4: SPI to device 0, WAIT, POLL).
///
/// `write`, `wait` and `poll` queue operations; `read` and `flush` run the
/// queue (in order) and report the first POLL that timed out as
/// [`Error::Poll`]. Nothing the driver decides depends on a queued
/// operation's outcome, so a whole configuration step is one command packet
/// or a few.
///
/// A binding on `usb::Ctrl::exec(&[Op]) -> Vec<Reply>`:
/// - `write(reg, v)`: `Op::Spi { device: SPI_AD9361, word: spi_write(reg, v) }`;
/// - `wait(us)`: `Op::Wait { us }`;
/// - `poll(reg, m, w, ms)`: `Op::Spi { word: spi_read(reg) }`, then
///   `Op::Poll { mask: m, value: w, ms }` with ms = 0 a single try; a limit
///   above 255 ms becomes consecutive POLLs of at most 255 ms (each repeats
///   the same read), the outcome being the last one's status;
/// - `read(regs)`: one `Op::Spi { word: spi_read(reg) }` per register after
///   the queue, one `exec`, the low 8 bits of the last N results;
/// - a queue reaching 126 operations (`proto::MAX_OPS`) is executed first.
pub trait Bus {
    /// Queue a write of `value` to register `reg`.
    fn write(&mut self, reg: u16, value: u8) -> Result<()>;
    /// Queue a wait of `us` microseconds.
    fn wait(&mut self, us: u32) -> Result<()>;
    /// Queue a read of `reg` repeated until `value & mask == want`, for at
    /// most `ms` milliseconds (0: one read).
    fn poll(&mut self, reg: u16, mask: u8, want: u8, ms: u32) -> Result<()>;
    /// Run the queue, then read `regs` in order.
    fn read<const N: usize>(&mut self, regs: [u16; N]) -> Result<[u8; N]>;
    /// Run the queue.
    fn flush(&mut self) -> Result<()>;
}

impl<B: Bus> Bus for &mut B {
    fn write(&mut self, reg: u16, value: u8) -> Result<()> {
        (**self).write(reg, value)
    }
    fn wait(&mut self, us: u32) -> Result<()> {
        (**self).wait(us)
    }
    fn poll(&mut self, reg: u16, mask: u8, want: u8, ms: u32) -> Result<()> {
        (**self).poll(reg, mask, want, ms)
    }
    fn read<const N: usize>(&mut self, regs: [u16; N]) -> Result<[u8; N]> {
        (**self).read(regs)
    }
    fn flush(&mut self) -> Result<()> {
        (**self).flush()
    }
}

/// The 24-bit SPI word writing `value` to `reg` (MSB first): bit 23 write,
/// bits 22:20 byte count - 1 = 0, bits 17:8 the 10-bit address, bits 7:0 the
/// data (AD9361 SPI instruction word; UHD ad9361_ctrl.cpp).
pub fn spi_write(reg: u16, value: u8) -> u32 {
    1 << 23 | spi_read(reg) | value as u32
}

/// The 24-bit SPI word reading `reg`: bit 23 clear; the chip returns the
/// value in the last 8 bits shifted.
pub fn spi_read(reg: u16) -> u32 {
    debug_assert!(reg < 0x400);
    (reg as u32 & 0x3FF) << 8
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    Rx = 0,
    Tx = 1,
}

/// Digital test modes for proving the data path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Test {
    None,
    /// BIST tone at fs/32, -6 dBFS, injected at the receive data port.
    Tone,
    /// BIST pseudo-random sequence at the receive data port.
    Prbs,
    /// The transmit data port looped onto the receive data port.
    Loopback,
}

// -- the B210 (b200_impl.cpp b200_ad9361_client_t) -------------------------------

/// Data port delays, (clock delay << 4) | data delay, in the chip's delay
/// steps (0.24 ns on this board): data 15 steps late, clock 0, both
/// directions; UHD's value. At 61.44 MHz the nearest data transition lay
/// 11 steps (2.6 ns, rx eye) and 14 steps (3.4 ns, tx eye) from it on this
/// board, by the chip's digital loopback run over all 31 x 31 clock / data
/// delays (v1 measurement, docs/STATUS.md at tag v1-ettus-uhd).
/// The board's data-port delays, `(clock << 4) | data` in the chip's 0.24 ns
/// steps. Ours, not UHD's 0x0F: the measured eye (`b210-radio scan`, BIST
/// PRBS at every clock/data delay, 0.2 s a point) is data 4 .. 15 at clock 0
/// in both modes, so UHD's 15 sits one step from the failing edge and 9 is
/// the window's midpoint (ADI AN-1441: take the middle of the passing
/// range), 1.44 ns to the near edge and 1.68 ns to the far one.
pub const RX_DELAYS: u8 = 0x09;
pub const TX_DELAYS: u8 = 0x0F;
/// Receive port by LO: C below 2.2 GHz, B below 4 GHz, A up to 6 GHz.
const RX_PORT_B_FROM: f64 = 2.2e9;
const RX_PORT_A_FROM: f64 = 4.0e9;
/// Transmit port: B below 2.5 GHz, A from there.
const TX_PORT_A_FROM: f64 = 2.5e9;

// -- ranges -------------------------------------------------------------------

// The chip's limits, the one source for config.rs's validation too.

/// Rates. Lower: ADI's least ADC clock over the largest decimation, 25 MHz /
/// 48 = 520 833.3 Hz, rounded up (no-OS ad9361.h MIN_ADC_CLK; UHD's
/// AD9361_MIN_CLOCK_RATE 220 kHz runs the ADC at 10.6 MHz). Upper: UHD
/// AD9361_MAX_CLOCK_RATE, ADI MAX_BASEBAND_RATE.
pub const MIN_RATE: f64 = 520_834.0;
pub const MAX_RATE: f64 = 61.44e6;
/// Two channels in a direction: the data port carries both (Invariants).
pub const MAX_RATE_2CH: f64 = MAX_RATE / 2.0;
/// LO frequencies: the AD9361's and the B210's specified tuning range
/// (UHD's get_rf_freq_range accepts down to 50 MHz, unspecified).
pub const MIN_LO: f64 = 70e6;
pub const MAX_LO: f64 = 6e9;
/// Bandwidths `set_bandwidth` takes: UHD AD9361_MIN/MAX_BW (the analog
/// filters' roll-off). Each filter then clamps its one-sided bandwidth to
/// its own range (below), so not every bandwidth in here is set as asked.
pub const MIN_BANDWIDTH: f64 = 200e3;
pub const MAX_BANDWIDTH: f64 = 56e6;
/// The one-sided bandwidth ranges of the analog filters, (min, max) Hz:
/// UHD's clamps, from each filter's corner range over its corner factor
/// (see the calibrate_* functions).
const RX_BB_BBBW: (f64, f64) = (0.143e6, 28e6);
const RX_TIA_BBBW: (f64, f64) = (0.40e6, 28e6);
const TX_BB_BBBW: (f64, f64) = (0.391e6, 20e6);
const TX_SECONDARY_BBBW: (f64, f64) = (0.54e6, 20e6);
/// The RF bandwidths that every filter of a direction is set to exactly:
/// twice the intersection of its filters' one-sided ranges, given a rate
/// of at least the bandwidth (`bbbw` clips to rate / 2). rx: 800 kHz ..=
/// 56 MHz; tx: 1.08 MHz ..= 40 MHz.
pub const MIN_RX_BANDWIDTH: f64 = 2.0 * RX_BB_BBBW.0.max(RX_TIA_BBBW.0);
pub const MAX_RX_BANDWIDTH: f64 = 2.0 * RX_BB_BBBW.1.min(RX_TIA_BBBW.1);
pub const MIN_TX_BANDWIDTH: f64 = 2.0 * TX_BB_BBBW.0.max(TX_SECONDARY_BBBW.0);
pub const MAX_TX_BANDWIDTH: f64 = 2.0 * TX_BB_BBBW.1.min(TX_SECONDARY_BBBW.1);
/// rx gain: the gain table index, 1 dB per step (fractions truncated);
/// tx gain: 89.75 dB minus the attenuation word's 0.25 dB steps.
pub const MAX_RX_GAIN: f64 = 76.0;
pub const RX_GAIN_STEP: f64 = 1.0;
pub const MAX_TX_GAIN: f64 = 89.75;
pub const TX_GAIN_STEP: f64 = 0.25;

// -- clocks ---------------------------------------------------------------------

/// BBPLL: reference (REFCLK / 1, register 0x045 = 0), fractional modulus
/// (UHD _tune_bbvco), VCO range: ADI's MIN_BBPLL_FREQ, MAX_BBPLL_FREQ
/// (no-OS ad9361.h; UHD's minimum is 672 MHz).
const BB_REF: f64 = 40e6;
const BB_MOD: i32 = 2_088_960;
const BB_VCO_MIN: f64 = 715e6;
const BB_VCO_MAX: f64 = 1430e6;
/// ADI's ADC clock range and DAC maximum (no-OS ad9361.h MIN_ADC_CLK,
/// MAX_ADC_CLK, MAX_DAC_CLK).
const MIN_ADC_CLK: f64 = 25e6;
const MAX_ADC_CLK: f64 = 640e6;
const MAX_DAC_CLK: f64 = MAX_ADC_CLK / 2.0;
/// Above this ADC clock the DAC runs at half of it: ADI's DAC maximum
/// (UHD: 336 MHz, above it).
const DAC_MAX: f64 = MAX_DAC_CLK;
/// Limit of the POLL for an RF synthesizer's lock bit, after UHD's 2 ms
/// wait (module header, changes from UHD): 5x that wait, far beyond a
/// lock that takes microseconds once the VCO is calibrated.
const PLL_LOCK_MS: u32 = 10;
/// RF PLLs: reference REFCLK x 2 (registers 0x2AB/0x2AC), modulus, VCO range
/// (UHD _tune_helper).
const RF_REF: f64 = 80e6;
const RF_MOD: i32 = 8_388_593;
const RF_VCO_MIN: f64 = 6e9;
const RF_VCO_MAX: f64 = 12e9;
/// Calibrations are redone after a retune by more than this (UHD
/// AD9361_CAL_VALID_WINDOW).
const CAL_WINDOW: f64 = 100e6;
/// Initial LO frequencies (UHD DEFAULT_RX_FREQ, DEFAULT_TX_FREQ).
const INIT_LO: [f64; 2] = [800e6, 850e6];

// -- registers --------------------------------------------------------------------

/// ENSM state (register 0x017 bits 3:0).
const ENSM_STATE: u16 = 0x017;
const STATE_ALERT: u8 = 0x5;
const STATE_FDD: u8 = 0xA;
const STATE_FLUSH: u8 = 0xB;
/// ENSM control (register 0x014; bits as ADI's driver names them: 0 to
/// ALERT, 2 force ALERT, 5 force TX on, which in FDD mode is the FDD state).
/// UHD's three values: to ALERT; force ALERT | to ALERT; force TX on | to ALERT.
const ENSM_CTRL: u16 = 0x014;
const TO_ALERT: u8 = 0x01;
const FORCE_ALERT: u8 = 0x05;
const TO_FDD: u8 = 0x21;
/// Calibration control (register 0x016): a calibration runs while its bit
/// is set.
const CAL_CTRL: u16 = 0x016;
const CAL_TX_QUAD: u8 = 0x10;
const CAL_RX_QUAD: u8 = 0x20;
const CAL_TX_BB: u8 = 0x40;
const CAL_RX_BB: u8 = 0x80;
const CAL_BB_DC: u8 = 0x01;
const CAL_RF_DC: u8 = 0x02;

/// Filter stage settings of registers 0x002 (tx) and 0x003 (rx): bits 7:6
/// chain 2, chain 1 enabled; bits 5:4 stage 3 (1: HB3 x2, 2: x3); bit 3
/// HB2 x2; bit 2 HB1 x2; bits 1:0 FIR (2: x2, 3: x4).
const CHAIN1: u8 = 1 << 6;
const CHAIN2: u8 = 1 << 7;
const HB3: u8 = 1 << 4;
const X3: u8 = 2 << 4;
const HB2: u8 = 1 << 3;
const HB1: u8 = 1 << 2;
const FIR_X2: u8 = 2;
const FIR_X4: u8 = 3;

/// BIST configuration (register 0x3F4), fields as ADI's driver names them:
/// bit 0 enable, bit 1 tone (else PRBS), bits 3:2 injection point (2: the
/// receive data port), bits 5:4 tone level in -6 dB steps, bits 7:6 tone
/// frequency in fs/32 steps. v1 ran tone 0x1B and PRBS 0x09.
const BIST: u16 = 0x3F4;
const BIST_ENABLE: u8 = 1 << 0;
const BIST_TONE: u8 = 1 << 1;
const BIST_AT_RX_PORT: u8 = 2 << 2;
const BIST_MINUS_6DB: u8 = 1 << 4;
/// Data port loopback (register 0x3F5 bit 0): tx port onto rx port.
const LOOPBACK: u16 = 0x3F5;

/// POLL limit for a UHD wait loop of `checks` failed checks `sleep_ms`
/// apart: UHD gives up when the count exceeds its limit L, after L + 1
/// sleeps, so `checks` = L + 1.
const fn uhd_limit(checks: u32, sleep_ms: u32) -> u32 {
    checks * sleep_ms
}

/// UHD's double -> uint8_t conversion (gcc, x86-64): truncate toward zero to
/// 32 bits, keep the low 8.
fn c_u8(x: f64) -> u8 {
    x as i32 as u8
}

/// UHD's double -> uint16_t conversion, the same way.
fn c_u16(x: f64) -> u16 {
    x as i32 as u16
}

/// UHD freq_is_nearly_equal: requests closer than 1 Hz are the same.
fn nearly_equal(a: f64, b: f64) -> bool {
    (a - b).abs() < 1.0
}

/// Decimation (or interpolation) of a 0x002/0x003 filter setting: the
/// product of the enabled stages.
fn rate_change(filt: u8) -> u32 {
    let stage3 = [1, 2, 3, 1][(filt >> 4 & 3) as usize];
    let hb = |bit: u8| if filt & bit != 0 { 2 } else { 1 };
    let fir = [1, 1, 2, 4][(filt & 3) as usize];
    stage3 * hb(HB2) * hb(HB1) * fir
}

/// The AD9361 of one B210, configured.
pub struct Ad9361<B: Bus> {
    bus: B,
    // register shadows (UHD chip_regs_t), and the test registers
    vcodivs: u8,
    inputsel: u8,
    rxfilt: u8,
    txfilt: u8,
    bbpll: u8,
    bbftune_config: u8,
    bbftune_mode: u8,
    bist: u8,
    loopback: u8,
    /// Per `Dir`: the LO, the last requested LO, the LO at the last
    /// calibration (Hz).
    lo: [f64; 2],
    req_lo: [f64; 2],
    cal_lo: [f64; 2],
    /// Per `Dir`, per channel: the gain last set (dB).
    gain: [[f64; 2]; 2],
    /// Channel masks (bit c: channel c) of `set_channels`, rx and tx.
    mask: [u8; 2],
    /// The rate (UHD _baseband_bw), the last requested rate, the BBPLL and
    /// ADC clocks and the last requested ADC clock (Hz).
    rate: f64,
    req_rate: f64,
    bbpll_freq: f64,
    adc_freq: f64,
    req_adc: f64,
    /// FIR rate change (2 or 4) of the current rate.
    fir_factor: u32,
    /// rx baseband filter: its bandwidth (one-sided, Hz) and tune divider.
    rx_bb_bw: f64,
    rx_tune_div: u16,
    /// The gain table loaded: 0 none, 1 below 1.3 GHz, 2 below 4 GHz, 3 above.
    gain_table: u8,
}

impl<B: Bus> Ad9361<B> {
    /// Reset and bring up the chip (UHD initialize()): rate about 50 MS/s,
    /// rx LO 800 MHz, tx LO 850 MHz, every calibration run, TX1 enabled at
    /// maximum attenuation, FDD.
    pub fn init(bus: B) -> Result<Self> {
        Self::try_init(bus).map_err(|(e, _)| e)
    }

    /// `init`, giving the bus back with the error.
    pub fn try_init(bus: B) -> std::result::Result<Self, (Error, B)> {
        let mut d = Ad9361 {
            bus,
            vcodivs: 0x00,
            inputsel: 0x30,
            rxfilt: 0x00,
            txfilt: 0x00,
            bbpll: 0x02,
            bbftune_config: 0x1E,
            bbftune_mode: 0x1E,
            bist: 0,
            loopback: 0,
            lo: INIT_LO,
            req_lo: [0.0; 2],
            cal_lo: [0.0; 2],
            gain: [[0.0; 2]; 2],
            mask: [0, 0],
            rate: 0.0,
            req_rate: 0.0,
            bbpll_freq: 0.0,
            adc_freq: 0.0,
            req_adc: 0.0,
            fir_factor: 0,
            rx_bb_bw: 0.0,
            rx_tune_div: 0,
            gain_table: 0,
        };
        match d.initialize().and_then(|()| d.bus.flush()) {
            Ok(()) => Ok(d),
            Err(e) => Err((e, d.bus)),
        }
    }

    /// The bus (for its owner: statistics, events, the mock's log).
    pub fn bus(&mut self) -> &mut B {
        &mut self.bus
    }

    /// The LO of `dir` as reached (Hz).
    pub fn lo(&self, dir: Dir) -> f64 {
        self.lo[dir as usize]
    }

    /// The bus back. Every public call ends with the queue run, so nothing
    /// is left queued on it.
    pub fn into_bus(self) -> B {
        self.bus
    }

    /// Set the rate (samples per second per channel); the rate reached.
    /// All calibrations run again (UHD set_clock_rate).
    pub fn set_rate(&mut self, rate: f64) -> Result<f64> {
        let n = self.mask.iter().map(|c| c.count_ones()).max().unwrap_or(1).max(1);
        check("rate", rate, MIN_RATE, MAX_RATE / n as f64)?;
        let r = self.clock_rate(rate)?;
        self.bus.flush()?;
        Ok(r)
    }

    /// Enable the channels in the masks (bit c: channel c), rx and tx, and
    /// run the TX quadrature calibration if a tx channel is on (UHD
    /// set_active_chains). Two channels on a side need rate <= 30.72 MS/s.
    pub fn set_channels(&mut self, rx: u8, tx: u8) -> Result<()> {
        check("rx channel mask", rx as f64, 0.0, 3.0)?;
        check("tx channel mask", tx as f64, 0.0, 3.0)?;
        if rx == 3 || tx == 3 {
            // the rate as requested: the one reached is off by a fraction of a
            // BBPLL step (30.72 MS/s comes out 0.02 Hz high)
            check("rate for 2 channels", self.req_rate, MIN_RATE, MAX_RATE_2CH)?;
        }
        self.chains(rx, tx)?;
        self.bus.flush()
    }

    /// Re-enable the RX IQ tracking that a TX quadrature calibration turns
    /// off (0x169 = 0xC0). UHD does this in tune(), after the recalibration;
    /// our plan switches the chains on after the LOs, so `Device::apply`
    /// calls it where UHD's tune() would have. Measured on the board: off
    /// gave image rejection 49.3 dB where on gave 78.9 dB (same station,
    /// 30.72 MS/s, 50 dB gain).
    pub fn enable_rx_iq_tracking(&mut self) -> Result<()> {
        self.w(0x169, 0xCF)?;
        self.bus.flush()
    }

    /// Tune the rx or tx LO; the frequency reached (UHD tune()).
    pub fn set_lo(&mut self, dir: Dir, lo: f64) -> Result<f64> {
        check(["rx LO", "tx LO"][dir as usize], lo, MIN_LO, MAX_LO)?;
        let f = self.tune(dir, lo)?;
        self.bus.flush()?;
        Ok(f)
    }

    /// Set the gain of a channel: rx the gain index (dB, 0 .. 76, fractions
    /// truncated), tx in dB (0 .. 89.75, 0 = maximum attenuation); the gain
    /// set (UHD set_gain).
    pub fn set_gain(&mut self, dir: Dir, channel: usize, gain: f64) -> Result<f64> {
        check("channel", channel as f64, 0.0, 1.0)?;
        let max = [MAX_RX_GAIN, MAX_TX_GAIN][dir as usize];
        check(["rx gain", "tx gain"][dir as usize], gain, 0.0, max)?;
        let g = self.gain(dir, channel, gain)?;
        self.bus.flush()?;
        Ok(g)
    }

    /// Set the analog filters for an RF bandwidth (UHD set_bw_filter); the
    /// bandwidth taken. Each filter is limited to the rate and its range.
    pub fn set_bandwidth(&mut self, dir: Dir, bandwidth: f64) -> Result<f64> {
        check(["rx bandwidth", "tx bandwidth"][dir as usize], bandwidth, MIN_BANDWIDTH, MAX_BANDWIDTH)?;
        let b = self.bw_filter(dir, bandwidth)?;
        self.bus.flush()?;
        Ok(b)
    }

    /// Select a digital test mode; only registers that change are written.
    pub fn set_test(&mut self, test: Test) -> Result<()> {
        let (bist, loopback) = match test {
            Test::None => (0, 0),
            Test::Tone => (BIST_ENABLE | BIST_TONE | BIST_AT_RX_PORT | BIST_MINUS_6DB, 0),
            Test::Prbs => (BIST_ENABLE | BIST_AT_RX_PORT, 0),
            Test::Loopback => (0, 1),
        };
        if bist != self.bist {
            self.bist = bist;
            self.w(BIST, bist)?;
        }
        if loopback != self.loopback {
            self.loopback = loopback;
            self.w(LOOPBACK, loopback)?;
        }
        self.bus.flush()
    }

    /// Set the data port delays (registers 0x006, 0x007), for an eye scan;
    /// `init` sets the board's (UHD set_interface_delays).
    pub fn set_delays(&mut self, rx: u8, tx: u8) -> Result<()> {
        self.w(0x006, rx)?;
        self.w(0x007, tx)?;
        self.bus.flush()
    }

    // -- the sequence -------------------------------------------------------------

    fn w(&mut self, reg: u16, value: u8) -> Result<()> {
        self.bus.write(reg, value)
    }

    fn writes(&mut self, list: &[(u16, u8)]) -> Result<()> {
        list.iter().try_for_each(|&(reg, value)| self.w(reg, value))
    }

    fn wait_ms(&mut self, ms: u32) -> Result<()> {
        self.bus.wait(ms * 1000)
    }

    /// Fail unless `reg & mask == want` now (a single-try POLL).
    fn check(&mut self, reg: u16, mask: u8, want: u8) -> Result<()> {
        self.bus.poll(reg, mask, want, 0)
    }

    /// Start a calibration and wait for its bit in 0x016 to clear.
    fn calibrate(&mut self, bit: u8, limit_ms: u32) -> Result<()> {
        self.w(CAL_CTRL, bit)?;
        self.bus.poll(CAL_CTRL, bit, 0, limit_ms)
    }

    fn ensm_state(&mut self) -> Result<u8> {
        Ok(self.bus.read([ENSM_STATE])?[0] & 0x0F)
    }

    /// UHD initialize(), from the reset on.
    fn initialize(&mut self) -> Result<()> {
        // soft reset (0x000 bit 0), UHD's; kept for the golden traces, the
        // RESETB pulse before init (device::reset) being the reset that
        // counts: ADI's driver writes 0x81 here (bits 7 and 0, mirrored) and
        // only without a RESETB pin, warning that the SPI soft reset "doesn't
        // work reliably" (no-OS ad9361.c ad9361_reset). Then the product id
        // (0x037 bits 7:3; bits 2:0 are the revision: this board read 0x0A
        // over the FPGA's SPI master, v1 measurement, docs/STATUS.md at tag
        // v1-ettus-uhd)
        self.writes(&[(0x000, 0x01), (0x000, 0x00)])?;
        self.wait_ms(20)?;
        let id = self.bus.read([0x037])?[0] & 0xF8;
        if id != 0x08 {
            return Err(Error::ProductId(id));
        }
        self.writes(&[
            (0x3DF, 0x01), // undocumented; UHD: "There is not a WAT big enough for this."
            (0x2A6, 0x0E), // enable master bias
            (0x2A8, 0x0E), // bandgap trim
            (0x2AB, 0x07), // RF PLL reference = REFCLK x 2
            (0x2AC, 0xFF),
            (0x009, 0x17), // clocks on, external reference on XTAL_N (the B210's)
        ])?;
        self.wait_ms(20)?;
        self.setup_rates(50e6)?;
        // CMOS dual-port full duplex: swap I and Q on tx and rx, toggling
        // frame sync (0x010); 0x012 = 0x02: CMOS, during and after the
        // calibrations (UHD AD9361_DDR_FDD_LVCMOS); the data port delays
        self.writes(&[(0x010, 0xC8), (0x011, 0x00), (0x012, 0x02), (0x006, RX_DELAYS), (0x007, TX_DELAYS)])?;
        // AuxDAC 1/2 words and configuration, manual control, rx/tx delays
        self.writes(&[(0x018, 0x00), (0x019, 0x00), (0x01A, 0x00), (0x01B, 0x00), (0x023, 0xFF), (0x026, 0x00)])?;
        self.writes(&[(0x030, 0x00), (0x031, 0x00), (0x032, 0x00), (0x033, 0x00)])?;
        // LNA bypass polarity inversion off (UHD: measured to align the bypass
        // and LNA phases, against the register map)
        self.w(0x022, 0x0A)?;
        // AuxADC / temperature sensor: offset, window, manual measure,
        // decimation, clock divider, enable
        self.writes(&[(0x00B, 0x00), (0x00C, 0x00), (0x00D, 0x00), (0x00F, 0x04), (0x01C, 0x10), (0x01D, 0x01)])?;
        // control outputs
        self.writes(&[(0x035, 0x01), (0x036, 0xFF)])?;
        // GPO: delay, auto enable, manual / ALERT values, rx delays, tx delays
        self.writes(&[(0x03A, 0x27), (0x020, 0x00), (0x027, 0x03)])?;
        self.writes(&[(0x028, 0x00), (0x029, 0x00), (0x02A, 0x00), (0x02B, 0x00)])?;
        self.writes(&[(0x02C, 0x00), (0x02D, 0x00), (0x02E, 0x00), (0x02F, 0x00)])?;
        // synthesizers, rx then tx: LO power, VCO LDO on, calibration Tcf
        // powered down, VCO calibration length, charge pump MSB, prescaler
        // bias, half VCO calibration clock off
        self.writes(&[(0x261, 0x00), (0x2A1, 0x00), (0x248, 0x0B), (0x288, 0x0B), (0x246, 0x02), (0x286, 0x02)])?;
        self.writes(&[(0x249, 0x8E), (0x289, 0x8E), (0x23B, 0x80), (0x27B, 0x80), (0x243, 0x0D), (0x283, 0x0D)])?;
        self.writes(&[(0x23D, 0x00), (0x27D, 0x00)])?;
        // UHD: "The order of the following process is EXTREMELY important."
        self.enter_alert()?;
        self.calibrate_charge_pumps()?;
        self.tune_lo(Dir::Rx, self.lo[0])?;
        self.tune_lo(Dir::Tx, self.lo[1])?;
        self.program_mixer_gm()?;
        self.program_gain_table()?;
        self.setup_gain_control()?;
        self.bw_filter(Dir::Rx, self.rate)?;
        self.bw_filter(Dir::Tx, self.rate)?;
        self.setup_adc()?;
        self.calibrate_bb_dc()?;
        self.calibrate_rf_dc()?;
        self.calibrate_rx_quadrature()?;
        self.after_calibrations()?;
        // the change from UHD (module header): maximum attenuation, not 0 dB
        let a = atten_word(0.0);
        self.writes(&[(0x073, a as u8), (0x074, (a >> 8) as u8 & 1), (0x075, a as u8), (0x076, (a >> 8) as u8 & 1)])?;
        // RSSI: measurement durations, weighted multipliers, delay, wait,
        // mode, power measurement duration
        self.writes(&[(0x150, 0x0E), (0x151, 0x00), (0x152, 0xFF), (0x153, 0x00), (0x154, 0x00), (0x155, 0x00)])?;
        self.writes(&[(0x156, 0x00), (0x157, 0x00), (0x158, 0x0D), (0x15C, 0x67)])?;
        // TX1 on (UHD set_active_chains(true, false, false, false)), FDD
        self.chains(0, 1)?;
        self.w(ENSM_CTRL, TO_FDD)
    }

    /// Dual synthesizer mode with synthesizer enable control (0x015), the
    /// ENSM forced to ALERT with TX on (0x014), the ENSM enabled in FDD mode
    /// (0x013), 1 ms to settle.
    fn enter_alert(&mut self) -> Result<()> {
        self.writes(&[(0x015, 0x04), (ENSM_CTRL, FORCE_ALERT), (0x013, 0x01)])?;
        self.wait_ms(1)
    }

    /// The end of every full calibration: rx DC offset (0x18B) and IQ
    /// (0x169) tracking on, calibration points noted, the port in CMOS
    /// (0x012), FDD mode (0x013), dual synthesizers (0x015).
    fn after_calibrations(&mut self) -> Result<()> {
        self.w(0x18B, 0xAD)?;
        self.w(0x169, 0xCF)?;
        self.cal_lo = self.lo;
        self.writes(&[(0x012, 0x02), (0x013, 0x01), (0x015, 0x04)])
    }

    /// UHD set_clock_rate(), past its range check.
    fn clock_rate(&mut self, rate: f64) -> Result<f64> {
        if nearly_equal(rate, self.req_rate) {
            return Ok(self.rate);
        }
        // to SLEEP/WAIT (0x014 = 0) for the BBPLL change
        let state = self.ensm_state()?;
        match state {
            STATE_ALERT => {
                self.w(ENSM_CTRL, TO_FDD)?;
                self.wait_ms(5)?;
                self.w(ENSM_CTRL, 0x00)?;
            }
            STATE_FDD => self.w(ENSM_CTRL, 0x00)?,
            s => return Err(Error::State(s)),
        }
        let chains = (self.txfilt & 0xC0, self.rxfilt & 0xC0);
        self.setup_rates(rate)?;
        self.enter_alert()?;
        self.calibrate_charge_pumps()?;
        self.tune_lo(Dir::Rx, self.lo[0])?;
        self.tune_lo(Dir::Tx, self.lo[1])?;
        self.program_mixer_gm()?;
        self.program_gain_table()?;
        self.setup_gain_control()?;
        self.reprogram_gains()?;
        self.bw_filter(Dir::Rx, self.rate)?;
        self.bw_filter(Dir::Tx, self.rate)?;
        self.setup_adc()?;
        self.calibrate_bb_dc()?;
        self.calibrate_rf_dc()?;
        self.calibrate_rx_quadrature()?;
        self.after_calibrations()?;
        if state == STATE_FDD {
            // back to FDD with the chains as they were (setup_rates enabled all)
            self.txfilt = self.txfilt & 0x3F | chains.0;
            self.rxfilt = self.rxfilt & 0x3F | chains.1;
            self.writes(&[(0x002, self.txfilt), (0x003, self.rxfilt), (ENSM_CTRL, TO_FDD)])?;
        }
        Ok(self.rate)
    }

    /// UHD set_active_chains(tx1, tx2, rx1, rx2).
    fn chains(&mut self, rx: u8, tx: u8) -> Result<()> {
        self.mask = [rx, tx];
        let bits = |mask: u8| if mask & 1 != 0 { CHAIN1 } else { 0 } | if mask & 2 != 0 { CHAIN2 } else { 0 };
        self.txfilt = self.txfilt & 0x3F | bits(tx);
        self.rxfilt = self.rxfilt & 0x3F | bits(rx);
        let state = self.ensm_state()?;
        if state == STATE_FDD {
            self.w(ENSM_CTRL, TO_ALERT)?; // through the FDD flush state
        }
        if state == STATE_FDD || state == STATE_FLUSH {
            // UHD waits without a limit; the flush takes six ADC_CLK / 64
            // periods (UG-570 as UHD's ad936x_manager quotes it), under 40 us
            // at the slowest ADC clock (10.56 MHz)
            self.bus.poll(ENSM_STATE, 0x0F, STATE_ALERT, 1)?;
        }
        self.w(0x002, self.txfilt)?;
        self.w(0x003, self.rxfilt)?;
        if tx != 0 {
            self.calibrate_tx_quadrature()?;
        }
        if state == STATE_FDD {
            self.w(ENSM_CTRL, TO_FDD)?;
        }
        Ok(())
    }

    /// UHD tune().
    fn tune(&mut self, dir: Dir, value: f64) -> Result<f64> {
        let d = dir as usize;
        if nearly_equal(value, self.req_lo[d]) {
            return Ok(self.lo[d]);
        }
        let last_cal = self.cal_lo[d];
        let not_in_alert = self.ensm_state()? != STATE_ALERT;
        if not_in_alert {
            self.w(ENSM_CTRL, TO_ALERT)?;
        }
        let f = self.tune_lo(dir, value)?;
        if dir == Dir::Rx {
            self.program_gain_table()?;
        }
        self.reprogram_gains()?;
        if (last_cal - f).abs() > CAL_WINDOW {
            match dir {
                Dir::Rx => {
                    // the single-shot rx quadrature calibration is left out
                    // while IQ tracking runs (always, here)
                    self.calibrate_rf_dc()?;
                    self.w(0x18B, 0xAD)?; // rx BB DC tracking on
                }
                Dir::Tx => self.calibrate_tx_quadrature()?,
            }
            self.cal_lo[d] = f;
            self.w(0x169, 0xCF)?; // rx IQ tracking on
        }
        if not_in_alert {
            self.w(ENSM_CTRL, TO_FDD)?;
        }
        Ok(self.lo[d])
    }

    /// UHD set_gain().
    fn gain(&mut self, dir: Dir, channel: usize, value: f64) -> Result<f64> {
        self.gain[dir as usize][channel] = value;
        match dir {
            Dir::Rx => {
                let index = (value as i32).clamp(0, MAX_RX_GAIN as i32);
                self.w([0x109, 0x10C][channel], index as u8)?;
                Ok(index as f64)
            }
            Dir::Tx => {
                // bit 6 of 0x077 / 0x07C: the attenuation word takes effect at once
                self.writes(&[(0x077, 0x40), (0x07C, 0x40)])?;
                let a = atten_word(value);
                let reg = [0x073, 0x075][channel];
                self.writes(&[(reg, a as u8), (reg + 1, (a >> 8) as u8 & 1)])?;
                Ok(MAX_TX_GAIN - a as f64 / 4.0)
            }
        }
    }

    /// The stored gains again (the gain table may have changed).
    fn reprogram_gains(&mut self) -> Result<()> {
        for (dir, ch) in [(Dir::Rx, 0), (Dir::Rx, 1), (Dir::Tx, 0), (Dir::Tx, 1)] {
            self.gain(dir, ch, self.gain[dir as usize][ch])?;
        }
        Ok(())
    }

    /// UHD set_bw_filter(), the bandwidth clamped to its range.
    fn bw_filter(&mut self, dir: Dir, rf_bw: f64) -> Result<f64> {
        let bw = rf_bw.clamp(MIN_BANDWIDTH, MAX_BANDWIDTH);
        match dir {
            Dir::Rx => {
                self.rx_bb_bw = self.calibrate_rx_bb_filter(bw)?;
                self.calibrate_rx_tia(bw)?;
            }
            Dir::Tx => {
                self.calibrate_tx_bb_filter(bw)?;
                self.calibrate_tx_secondary_filter(bw)?;
            }
        }
        Ok(bw)
    }

    /// The one-sided bandwidth of a filter for the RF bandwidth `rf_bw`: half
    /// of it, at most rate / 2, in [min, max] (each filter's range).
    fn bbbw(&self, rf_bw: f64, (min, max): (f64, f64)) -> f64 {
        (rf_bw / 2.0).min(self.rate / 2.0).clamp(min, max)
    }

    // -- clocks and rates ---------------------------------------------------------

    /// UHD _setup_rates(): the filter stages for the rate band, the BBPLL for
    /// f_adc = rate x D_rx, the DAC divider, the FIRs.
    fn setup_rates(&mut self, rate: f64) -> Result<()> {
        self.req_rate = rate;
        let all = CHAIN1 | CHAIN2; // every chain on for the calibrations
        let (rx, tx, fir) = filters(rate);
        (self.rxfilt, self.txfilt, self.fir_factor) = (all | rx, all | tx, fir);
        let d_rx = rate_change(rx) as f64;
        let adc = self.adc_clock(rate * d_rx)?;
        let dac = if adc > DAC_MAX {
            self.bbpll |= 0x08; // DAC clock = ADC clock / 2
            adc / 2.0
        } else {
            self.bbpll &= 0xF7;
            adc
        };
        self.writes(&[(0x002, self.txfilt), (0x003, self.rxfilt), (0x004, self.inputsel), (0x00A, self.bbpll)])?;
        self.rate = adc / d_rx;
        // the FIRs compute 16 taps per clock: 16 x (clock / rate) taps, at most
        // 128 (UG-671); the tx FIR's 64-tap limit applies at x1, never used
        let tx_taps = num_taps(16 * (dac / rate + 0.5) as usize);
        let rx_taps = num_taps(16 * (adc / rate + 0.5) as usize);
        self.program_fir(Dir::Tx, tx_taps)?;
        self.program_fir(Dir::Rx, rx_taps)
    }

    /// UHD _tune_bbvco(): the BBPLL for ADC clock `f`; the ADC clock reached.
    fn adc_clock(&mut self, f: f64) -> Result<f64> {
        if nearly_equal(f, self.req_adc) {
            return Ok(self.adc_freq);
        }
        self.req_adc = f;
        let range = Error::Range { what: "ADC clock", value: f, min: BB_VCO_MIN / 64.0, max: BB_VCO_MAX / 2.0 };
        let k = (1..=6).find(|&k| (BB_VCO_MIN..=BB_VCO_MAX).contains(&(f * (1 << k) as f64))).ok_or(range)?;
        let vco = f * (1 << k) as f64;
        let nint = (vco / BB_REF) as i32;
        let nfrac = ((vco / BB_REF - nint as f64) * BB_MOD as f64).round() as i32;
        let actual = BB_REF * (nint as f64 + nfrac as f64 / BB_MOD as f64);
        // charge pump current 150 uA at 1280 MHz, proportional to the VCO;
        // register: 25 uA steps from 25 uA
        let icp = 150e-6 * (actual / 1280e6);
        let icp_reg = (icp / 25e-6) as i32 - 1;
        self.writes(&[
            (0x045, 0x00), // REFCLK / 1 to the BBPLL
            (0x046, icp_reg as u8 & 0x3F),
            (0x048, 0xE8), // loop filter (UHD's values)
            (0x049, 0x5B),
            (0x04A, 0x35),
            (0x04B, 0xE0),
            (0x04E, 0x10), // maximum accuracy
            (0x043, nfrac as u8),
            (0x042, (nfrac >> 8) as u8),
            (0x041, (nfrac >> 16) as u8),
            (0x044, nint as u8),
        ])?;
        // calibrate (0x03F bit 2 starts it), raise the KV and phase margin,
        // wait for lock (0x05E bit 7): UHD checks 1001 times, 2 ms apart
        self.writes(&[(0x03F, 0x05), (0x03F, 0x01), (0x04C, 0x86), (0x04D, 0x01), (0x04D, 0x05)])?;
        self.bus.poll(0x05E, 0x80, 0x80, uhd_limit(1001, 2))?;
        self.bbpll = self.bbpll & 0xF8 | k as u8;
        self.bbpll_freq = actual;
        self.adc_freq = actual / (1 << k) as f64;
        Ok(self.adc_freq)
    }

    /// UHD _program_fir_filter() for both chains of `dir`, with the
    /// coefficients for `taps` and the current FIR factor (UG-671 "FIR",
    /// the indirect programming ADI recommends).
    fn program_fir(&mut self, dir: Dir, taps: usize) -> Result<()> {
        let coeffs = tables::fir(taps, self.fir_factor).expect("setup_rates reaches 64, 96 or 128 taps (test rates_reach_valid_firs)");
        let base = [0x0F0, 0x060][dir as usize];
        // base + 5: bits 7:5 taps / 16 - 1, bits 4:3 chains (3: both), bit 2
        // write, bit 1 clock on; base + 0 address, base + 1/2 coefficient low
        // and high byte, base + 4 strobed twice to store it
        let cfg = ((taps / 16 - 1) as u8 & 7) << 5 | 3 << 3;
        let (clock, write) = (1 << 1, 1 << 2);
        self.w(base + 5, cfg | clock)?;
        self.wait_ms(1)?;
        // the unused taps first (zeroed, "in case they have stale data")
        let taps_written = (taps..128).map(|a| (a, 0)).chain(coeffs.iter().enumerate().map(|(a, &c)| (a, c as u16)));
        for (addr, c) in taps_written {
            self.writes(&[
                (base, addr as u8),
                (base + 1, c as u8),
                (base + 2, (c >> 8) as u8),
                (base + 5, cfg | clock | write),
                (base + 4, 0),
                (base + 4, 0),
            ])?;
        }
        // write bit off with the clock on, then the clock off (UG-671 p. 25)
        self.w(base + 5, cfg | clock)?;
        self.w(base + 5, cfg)?;
        if dir == Dir::Rx {
            // rx FIR gain -6 dB against overflow (0x0F6: 0 +6, 1 0, 2 -6, 3 -12 dB)
            self.w(base + 6, 0x02)?;
        }
        Ok(())
    }

    // -- synthesizers --------------------------------------------------------------

    /// UHD _tune_helper(): the rx or tx synthesizer for the LO `value`; the LO
    /// reached.
    fn tune_lo(&mut self, dir: Dir, value: f64) -> Result<f64> {
        let what = ["rx LO", "tx LO"][dir as usize];
        let range = Error::Range { what, value, min: RF_VCO_MIN / 128.0, max: MAX_LO };
        let k = (0..=6).find(|&k| (RF_VCO_MIN..=RF_VCO_MAX).contains(&(value * (2 << k) as f64))).ok_or(range)?;
        let div = (2 << k) as f64;
        let vco = value * div;
        let nint = (vco / RF_REF) as i32;
        let nfrac = ((vco / RF_REF - nint as f64) * RF_MOD as f64) as i32;
        let actual_vco = RF_REF * (nint as f64 + nfrac as f64 / RF_MOD as f64);
        let lo = actual_vco / div;
        // the tx registers are the rx ones + 0x40
        let o = 0x40 * dir as u16;
        self.req_lo[dir as usize] = value;
        match dir {
            Dir::Rx => {
                // input port (0x004 bits 5:0): C 0x30, B 0x0C, A 0x03, balanced
                let port = if value < RX_PORT_B_FROM {
                    0x30
                } else if value < RX_PORT_A_FROM {
                    0x0C
                } else {
                    0x03
                };
                self.inputsel = self.inputsel & 0xC0 | port;
                self.vcodivs = self.vcodivs & 0xF0 | k;
            }
            Dir::Tx => {
                // output port (0x004 bit 6): 1 B, 0 A
                self.inputsel = if value < TX_PORT_A_FROM { self.inputsel | 0x40 } else { self.inputsel & 0xBF };
                self.vcodivs = self.vcodivs & 0x0F | k << 4;
            }
        }
        self.w(0x004, self.inputsel)?;
        self.setup_synth(o, actual_vco)?;
        self.writes(&[
            (0x233 + o, nfrac as u8),
            (0x234 + o, (nfrac >> 8) as u8),
            (0x235 + o, (nfrac >> 16) as u8),
            (0x232 + o, (nint >> 8) as u8),
            (0x231 + o, nint as u8),
            (0x005, self.vcodivs), // VCO dividers 2^(k + 1): rx bits 3:0, tx 7:4
        ])?;
        // 2 ms to lock (UHD), then the lock bit (0x247 bit 1), polled (ADI)
        self.wait_ms(2)?;
        self.bus.poll(0x247 + o, 0x02, 0x02, PLL_LOCK_MS)?;
        self.lo[dir as usize] = lo;
        Ok(lo)
    }

    /// UHD _setup_synth(): VCO and loop filter settings for the VCO band of
    /// `vco` (rx registers + `o`); the fixed upper bits are UHD's.
    fn setup_synth(&mut self, o: u16, vco: f64) -> Result<()> {
        let band = tables::VCO_BAND.iter().position(|&edge| vco > edge).unwrap_or(tables::VCO_BAND.len() - 1);
        let [level, varactor, bias_ref, bias_tcf, cal_offset, varactor_ref, icp, c2, c1, r1, c3, r3] = tables::SYNTH[band];
        self.writes(&[
            (0x23A + o, 0x40 | level),
            (0x239 + o, 0xC0 | varactor),
            (0x242 + o, bias_ref | bias_tcf << 3),
            (0x238 + o, cal_offset << 3),
            (0x245 + o, 0x00),
            (0x251 + o, varactor_ref),
            (0x250 + o, 0x70),
            (0x23B + o, 0x80 | icp),
            (0x23E + o, c1 | c2 << 4),
            (0x23F + o, c3 | r1 << 4),
            (0x240 + o, r3),
        ])
    }

    /// UHD _calibrate_synth_charge_pumps(), in ALERT: rx, then tx; UHD checks
    /// the done bit (0x244 / 0x284 bit 7) 6 times, 1 ms apart.
    fn calibrate_charge_pumps(&mut self) -> Result<()> {
        self.check(ENSM_STATE, 0x0F, STATE_ALERT)?;
        for o in [0, 0x40] {
            self.w(0x23D + o, 0x04)?;
            self.bus.poll(0x244 + o, 0x80, 0x80, uhd_limit(6, 1))?;
            self.w(0x23D + o, 0x00)?;
        }
        Ok(())
    }

    // -- gain ----------------------------------------------------------------------

    /// UHD _program_mixer_gm_subtable().
    fn program_mixer_gm(&mut self) -> Result<()> {
        self.w(0x13F, 0x02)?; // table clock on
        for (index, &(gain, gm)) in (0..16u8).rev().zip(&tables::MIXER_GM) {
            // index, gain, 0, GM, clock + write, two strobes
            self.writes(&[(0x138, index), (0x139, gain), (0x13A, 0x00), (0x13B, gm), (0x13F, 0x06), (0x13C, 0x00), (0x13C, 0x00)])?;
        }
        // write bit off, strobes, clock off
        self.writes(&[(0x13F, 0x02), (0x13C, 0x00), (0x13C, 0x00), (0x13F, 0x00)])
    }

    /// UHD _program_gain_table(): the rx LO's band's table, if not loaded;
    /// rows 77 .. 90 zero.
    fn program_gain_table(&mut self) -> Result<()> {
        let rx = self.lo[0];
        let (n, table): (u8, &GainTable) = if rx < 1300e6 {
            (1, &tables::GAIN_SUB_1300MHZ)
        } else if rx < 4e9 {
            (2, &tables::GAIN_1300MHZ_TO_4000MHZ)
        } else {
            (3, &tables::GAIN_4000MHZ_TO_6000MHZ)
        };
        if self.gain_table == n {
            return Ok(());
        }
        self.gain_table = n;
        self.w(0x137, 0x1A)?; // table clock on
        for index in 0..91u8 {
            let [a, b, c] = table.get(index as usize).copied().unwrap_or([0; 3]);
            // index, the three words, clock + write, two strobes
            self.writes(&[(0x130, index), (0x131, a), (0x132, b), (0x133, c), (0x137, 0x1E), (0x134, 0x00), (0x134, 0x00)])?;
        }
        self.writes(&[(0x137, 0x1A), (0x134, 0x00), (0x134, 0x00), (0x137, 0x00)])
    }

    /// UHD _setup_gain_control(false): manual gain, both channels.
    fn setup_gain_control(&mut self) -> Result<()> {
        self.writes(&[
            (0x0FA, 0xE0), // gain control mode: manual
            (0x0FB, 0x08), // table, digital gain, manual gain control
            (0x0FC, 0x23), // increment step, ADC overrange size
            (0x0FD, 0x4C), // maximum full/LMT table index
            (0x0FE, 0x44), // decrement step, peak overload time
            (0x100, 0x6F), // maximum digital gain
            (0x104, 0x2F), // ADC small overload threshold
            (0x105, 0x3A), // ADC large overload threshold
            (0x107, 0x31), // large LMT overload threshold
            (0x108, 0x39), // small LMT overload threshold
            (0x109, 0x23), // rx1 full/LMT gain index
            (0x10A, 0x58), // rx1 LPF gain index
            (0x10B, 0x00), // rx1 digital gain index
            (0x10C, 0x23), // rx2 full/LMT gain index
            (0x10D, 0x18), // rx2 LPF gain index
            (0x10E, 0x00), // rx2 digital gain index
            (0x114, 0x30), // low power threshold
            (0x11A, 0x27), // initial LMT gain limit
            (0x081, 0x00), // tx symbol gain control
        ])
    }

    // -- analog filters ----------------------------------------------------------------

    /// UHD _calibrate_baseband_rx_analog_filter(): corner 1.4 bbbw, bbbw in
    /// [143 kHz, 28 MHz] (the filter's 200 kHz .. 39.2 MHz / 1.4); the bbbw.
    fn calibrate_rx_bb_filter(&mut self, rf_bw: f64) -> Result<f64> {
        let bbbw = self.bbbw(rf_bw, RX_BB_BBBW);
        let tune_clk = 1.4 * bbbw * 2.0 * PI / LN_2;
        self.rx_tune_div = c_u16((self.bbpll_freq / tune_clk).ceil()).min(511);
        self.bbftune_config = self.bbftune_config & 0xFE | (self.rx_tune_div >> 8) as u8 & 1;
        // bbbw in whole MHz (0x1FB) and the fraction in 7.8125 kHz steps (0x1FC)
        let mhz = bbbw / 1e6;
        let frac = (mhz - mhz.floor()) * 1000.0 / 7.8125;
        let khz = c_u8((frac + 0.5).floor()).min(127);
        self.writes(&[
            (0x1FB, c_u8(mhz)),
            (0x1FC, khz),
            (0x1F8, self.rx_tune_div as u8), // tune divider bits 7:0; bit 8 in 0x1F9 bit 0
            (0x1F9, self.bbftune_config),
            (0x1D5, 0x3F), // rx mix voltage (UHD: "only change with apps engineer help")
            (0x1C0, 0x03),
            (0x1E2, 0x02), // rx1, rx2 filter tuners on
            (0x1E3, 0x02),
        ])?;
        // UHD checks 101 times, 1 ms apart
        self.calibrate(CAL_RX_BB, uhd_limit(101, 1))?;
        self.writes(&[(0x1E2, 0x03), (0x1E3, 0x03)])?;
        Ok(bbbw)
    }

    /// UHD _calibrate_rx_TIAs(): the TIA capacitor from the calibrated rx
    /// filter's R and C, so that its corner is at 2.5 bbbw where the filter's
    /// is at 1.4 bbbw; bbbw in [400 kHz, 28 MHz] (1 .. 70 MHz / 2.5).
    fn calibrate_rx_tia(&mut self, rf_bw: f64) -> Result<()> {
        let [c3_msb, c3_lsb, r2346] = self.bus.read([0x1EB, 0x1EC, 0x1E6])?;
        let bbbw = self.bbbw(rf_bw, RX_TIA_BBBW);
        let ceil_mhz = (bbbw / 1e6).ceil();
        // filter C in fF: 160 fF x msb + 10 fF x lsb + 140 fF; R in ohms: 18.3 k x code
        let c_bbf = (c3_msb & 0x3F) as i32 * 160 + (c3_lsb & 0x7F) as i32 * 10 + 140;
        let r_bbf = 18300 * (r2346 & 0x07) as i32;
        // C_TIA x 3500 ohm = C_bbf x R_bbf x 1.4 / 2.5 (0.56)
        let c_tia = (c_bbf * r_bbf) as f64 * 0.56 / 3500.0;
        let reg1db = if ceil_mhz <= 3.0 {
            0xE0
        } else if ceil_mhz <= 10.0 {
            0x60
        } else {
            0x20
        };
        // above 2920 fF: coarse steps of 320 fF over 400 fF (0x1DD/0x1DF),
        // fine part 0x40; else fine steps of 40 fF over 400 fF, | 0x40
        let (fine, coarse) = if c_tia > 2920.0 {
            (0x40, c_u8((0.5 + (c_tia - 400.0) / 320.0).floor()).min(127))
        } else {
            (c_u8((0.5 + (c_tia - 400.0) / 40.0).floor() + 64.0), 0)
        };
        self.writes(&[(0x1DB, reg1db), (0x1DD, coarse), (0x1DF, coarse), (0x1DC, fine), (0x1DE, fine)])
    }

    /// UHD _calibrate_baseband_tx_analog_filter(): corner 1.6 bbbw, bbbw in
    /// [391 kHz, 20 MHz] (625 kHz .. 32 MHz / 1.6).
    fn calibrate_tx_bb_filter(&mut self, rf_bw: f64) -> Result<()> {
        let bbbw = self.bbbw(rf_bw, TX_BB_BBBW);
        let tune_clk = 1.6 * bbbw * 2.0 * PI / LN_2;
        let div = c_u16((self.bbpll_freq / tune_clk).ceil()).min(511);
        self.bbftune_mode = self.bbftune_mode & 0xFE | (div >> 8) as u8 & 1;
        // divider bits 7:0 (0x0D6), bit 8 (0x0D7 bit 0); tuner on (0x0CA)
        self.writes(&[(0x0D6, div as u8), (0x0D7, self.bbftune_mode), (0x0CA, 0x22)])?;
        self.calibrate(CAL_TX_BB, uhd_limit(101, 1))?;
        self.w(0x0CA, 0x26) // tuner off
    }

    /// UHD _calibrate_secondary_tx_filter(): corner 5 bbbw, bbbw in
    /// [540 kHz, 20 MHz] (2.7 .. 100 MHz / 5). The RC: R from 100 ohms
    /// doubling until C = 1 / (2 pi corner R) fits the 12 .. 75 pF array
    /// (code C / 1 pF - 12, at most 63).
    fn calibrate_tx_secondary_filter(&mut self, rf_bw: f64) -> Result<()> {
        let bbbw = self.bbbw(rf_bw, TX_SECONDARY_BBBW);
        let mhz = bbbw / 1e6;
        let corner = 5.0 * mhz * 2.0 * PI; // rad/us
        let mut res = 100;
        let mut cap = 0;
        for _ in 0..=3 {
            cap = (0.5 + (1.0 / (corner * res as f64 * 1e6)) * 1e12).floor() as i32 - 12;
            if cap <= 63 {
                break;
            }
            res *= 2;
        }
        let cap = cap.min(63);
        let reg0d0 = if mhz * 2.0 <= 9.0 {
            0x59
        } else if mhz * 2.0 <= 24.0 {
            0x56
        } else {
            0x57
        };
        let reg0d1 = match res {
            200 => 0x04,
            400 => 0x03,
            800 => 0x01,
            _ => 0x0C, // 100 ohms (and UHD's fallback)
        };
        self.writes(&[(0x0D2, cap as u8), (0x0D1, reg0d1), (0x0D0, reg0d0)])
    }

    /// UHD _setup_adc(): the 40 ADC settings (0x200 .. 0x227), from the ADC
    /// clock and the rx filter's bandwidth and R, C. UHD: "DO NOT TOUCH THIS
    /// UNLESS YOU KNOW EXACTLY WHAT YOU ARE DOING"; the formulas are ADI's,
    /// kept operation for operation.
    fn setup_adc(&mut self) -> Result<()> {
        // the rx filter's bandwidth as tuned: f_bbpll / div x ln 2 / (1.4 x 2 pi), MHz
        let bbbw_mhz = ((self.bbpll_freq / 1e6) / self.rx_tune_div as f64 * LN_2 / (1.4 * 2.0 * PI)).clamp(0.20, 28.0);
        let [c3_msb, c3_lsb, r2346] = self.bus.read([0x1EB, 0x1EC, 0x1E6])?;
        let (c3_msb, c3_lsb, r2346) = ((c3_msb & 0x3F) as f64, (c3_lsb & 0x7F) as f64, r2346 & 0x07);
        let fsadc = self.adc_freq / 1e6;
        // 1 / (2 pi x 1.4 bbbw x R x C), the filter's RC against the corner,
        // derated by 1 % per MHz above 18 MHz
        let r = (18300 * r2346 as i32) as f64;
        let c = 160e-15 * c3_msb + 10e-15 * c3_lsb + 140e-15;
        let rc = if bbbw_mhz < 18.0 {
            1.0 / (1.4 * 2.0 * PI * r * c * (bbbw_mhz * 1e6))
        } else {
            1.0 / (1.4 * 2.0 * PI * r * c * (bbbw_mhz * 1e6) * (1.0 + 0.01 * (bbbw_mhz - 18.0)))
        };
        let scale_res = (1.0 / rc).sqrt();
        let scale_cap = (1.0 / rc).sqrt();
        let scale_snr = if self.adc_freq < 80e6 { 1.0 } else { 1.584893192 }; // +2 dB = 10^0.2
        let maxsnr = 4.0; // 640 / 160 (an integer division in UHD)
        let s = (maxsnr * fsadc / 640.0).sqrt().min(1.0);
        let slope = 0.98 + 0.02 * ((640.0 / fsadc) / maxsnr).max(1.0);
        let mut d = [0u8; 40];
        d[3] = 0x24;
        d[4] = 0x24;
        d[7] = c_u8((-0.5 + 80.0 * scale_snr * scale_res * s).floor()).min(124);
        let d7 = d[7] as f64;
        d[8] = c_u8((0.5 + 20.0 * (640.0 / fsadc) * (d7 / 80.0) / (scale_res * scale_cap)).floor());
        d[10] = c_u8((-0.5 + 77.0 * scale_res * s).floor()).min(127);
        let d10 = d[10] as f64;
        d[9] = c_u8((0.8 * d10).floor()).min(127);
        d[11] = c_u8((0.5 + 20.0 * (640.0 / fsadc) * ((d10 / 77.0) / (scale_res * scale_cap))).floor());
        d[12] = c_u8((-0.5 + 80.0 * scale_res * s).floor()).min(127);
        let d12 = d[12] as f64;
        d[13] = c_u8((-1.5 + 20.0 * (640.0 / fsadc) * ((d12 / 80.0) / (scale_res * scale_cap))).floor());
        d[14] = (21 * c_u8((0.1 * 640.0 / fsadc).floor()) as u32) as u8;
        d[15] = c_u8(1.025 * d7).min(127);
        d[16] = c_u8((d[15] as f64 * slope).floor()).min(127);
        d[17] = d[15];
        d[18] = c_u8(0.975 * d10).min(127);
        d[19] = c_u8((d[18] as f64 * slope).floor()).min(127);
        d[20] = d[18];
        d[21] = c_u8(0.975 * d12).min(127);
        d[22] = c_u8((d[21] as f64 * slope).floor()).min(127);
        d[23] = d[21];
        d[24] = 0x2E;
        for k in [25, 28, 31] {
            d[k] = c_u8((128.0 + (63.0 * (fsadc / 640.0)).min(63.0)).floor());
            d[k + 1] = c_u8((63.0 * (fsadc / 640.0) * (0.92 + 0.08 * (640.0 / fsadc))).min(63.0).floor());
        }
        d[27] = c_u8((32.0 * (fsadc / 640.0).sqrt()).min(63.0).floor());
        d[30] = d[27];
        d[33] = c_u8((63.0 * (fsadc / 640.0).sqrt()).min(63.0).floor());
        d[34] = c_u8((64.0 * (fsadc / 640.0).sqrt()).floor()).min(127);
        d[35] = 0x40;
        d[36] = 0x40;
        d[37] = 0x2C;
        for (i, &v) in d.iter().enumerate() {
            self.w(0x200 + i as u16, v)?;
        }
        Ok(())
    }

    // -- calibrations ----------------------------------------------------------------

    /// UHD _calibrate_baseband_dc_offset(): RF DC tracking flag reset (0x18B),
    /// settings, tracking coefficient; UHD checks 101 times, 5 ms apart.
    fn calibrate_bb_dc(&mut self) -> Result<()> {
        self.writes(&[(0x18B, 0x83), (0x193, 0x3F), (0x190, 0x0F), (0x194, 0x01)])?;
        self.calibrate(CAL_BB_DC, uhd_limit(101, 5))
    }

    /// UHD _calibrate_rf_dc_offset(): counts by band (below / from 4 GHz),
    /// wait count, tracking off; UHD checks 201 times, 50 ms apart; then RF DC
    /// tracking on.
    fn calibrate_rf_dc(&mut self) -> Result<()> {
        let counts = if self.lo[0] < 4e9 { [0x32, 0x24, 0x05] } else { [0x28, 0x34, 0x06] };
        self.writes(&[(0x186, counts[0]), (0x187, counts[1]), (0x188, counts[2])])?;
        self.writes(&[(0x185, 0x20), (0x18B, 0x83), (0x189, 0x30)])?;
        self.calibrate(CAL_RF_DC, uhd_limit(201, 50))?;
        self.w(0x18B, 0x8D)
    }

    /// UHD _calibrate_rx_quadrature(): tone level, gain index, Kexp phase and
    /// amplitude, tx mixer down (0x057), tracking off; the tx LO moved into
    /// the rx passband (rx LO + rx filter bandwidth / 2) for the calibration;
    /// UHD checks 1001 times, 5 ms apart.
    fn calibrate_rx_quadrature(&mut self) -> Result<()> {
        self.writes(&[(0x168, 0x03), (0x16E, 0x25), (0x16A, 0x75), (0x16B, 0x95), (0x057, 0x33), (0x169, 0xC0)])?;
        let tx = self.lo[1];
        self.tune_lo(Dir::Tx, self.lo[0] + self.rx_bb_bw / 2.0)?;
        self.calibrate(CAL_RX_QUAD, uhd_limit(1001, 5))?;
        self.w(0x057, 0x30)?; // tx mixers on
        self.tune_lo(Dir::Tx, tx)?;
        Ok(())
    }

    /// UHD _calibrate_tx_quadrature(), in ALERT: tracking off, then TX A and
    /// TX B (0x004 bit 6) each calibrated, the port restored.
    fn calibrate_tx_quadrature(&mut self) -> Result<()> {
        self.check(ENSM_STATE, 0x0F, STATE_ALERT)?;
        self.w(0x169, 0xC0)?;
        let inputsel = self.inputsel;
        for port in [self.inputsel & 0xBF, self.inputsel | 0x40] {
            self.inputsel = port;
            self.w(0x004, port)?;
            self.tx_quadrature_routine()?;
        }
        self.inputsel = inputsel;
        self.w(0x004, inputsel)
    }

    /// UHD _tx_quadrature_cal_routine(): the calibrated NCO frequency bits
    /// (0x0A3 bits 7:6) copied to the rx NCO (0x0A0) and back into 0x0A3,
    /// the two calibration tones checked against the rx filter, settings,
    /// the calibration (UHD checks 101 times, 10 ms apart).
    fn tx_quadrature_routine(&mut self) -> Result<()> {
        let nco = self.bus.read([0x0A3])?[0] & 0xC0;
        self.w(0x0A0, 0x15 | nco >> 1)?;
        let reg0a3 = self.bus.read([0x0A3])?[0];
        self.w(0x0A3, reg0a3 & 0x3F | nco)?;
        // tone = rate x FIR factor x (NCO + 1) / 32 x 2; the rx filter
        // passes rate / 2, within [200 kHz, 28 MHz]
        let tone = self.rate * self.fir_factor as f64 * ((nco >> 6) + 1) as f64 / 32.0 * 2.0;
        let bandwidth = (self.rate / 2.0).clamp(0.20e6, 28e6);
        if tone > bandwidth {
            return Err(Error::CalTone { tone, bandwidth });
        }
        self.writes(&[
            (0x0A1, 0x7B), // tracking coefficient
            (0x0A9, 0xFF), // count
            (0x0A2, 0x7F), // Kexp
            (0x0A5, 0x01), // magnitude thresholds
            (0x0A6, 0x01),
            // gain table index giving TIA index 1, LPF index 0 in the band's table
            (0x0AA, if self.lo[0] < 1300e6 { 0x22 } else { 0x25 }),
            (0x0A4, 0xF0), // setting count
            (0x0AE, 0x00), // LPF gain index (split mode)
        ])?;
        self.calibrate(CAL_TX_QUAD, uhd_limit(101, 10))
    }
}

/// The filter stages (rx 0x003, tx 0x002, without the chain bits) and the
/// FIR factor for `rate`: UHD's _setup_rates bands, with their edges where
/// ADI's clock limits put them (module header, changes from UHD). Each
/// edge is the rate at which the band's ADC (or DAC) clock reaches a limit.
fn filters(rate: f64) -> (u8, u8, u32) {
    match rate {
        // D 48: ADC 25 .. 37.5 MHz
        r if r < MIN_ADC_CLK / 32.0 => (X3 | HB2 | HB1 | FIR_X4, X3 | HB2 | HB1 | FIR_X4, 4),
        // D 32: ADC 25 .. 50 MHz
        r if r < MIN_ADC_CLK / 16.0 => (HB3 | HB2 | HB1 | FIR_X4, HB3 | HB2 | HB1 | FIR_X4, 4),
        // D 16, the DAC at the ADC clock: up to 320 MHz
        r if r <= MAX_DAC_CLK / 16.0 => (HB3 | HB2 | HB1 | FIR_X2, HB3 | HB2 | HB1 | FIR_X2, 2),
        // D 24, the DAC at half: UHD's band
        r if r < 23e6 => (X3 | HB2 | HB1 | FIR_X2, X3 | HB1 | FIR_X2, 2),
        // D 16: ADC up to 640 MHz
        r if r <= MAX_ADC_CLK / 16.0 => (HB3 | HB2 | HB1 | FIR_X2, HB2 | HB1 | FIR_X2, 2),
        // D 12: ADC up to 640 MHz
        r if r <= MAX_ADC_CLK / 12.0 => (X3 | HB1 | FIR_X2, X3 | FIR_X2, 2),
        // D 8: ADC up to 491.52 MHz
        _ => (HB2 | HB1 | FIR_X2, HB3 | FIR_X2, 2),
    }
}

/// The tx attenuation word for a gain (dB): 4 x (89.75 - gain), 0.25 dB steps.
fn atten_word(gain: f64) -> u32 {
    ((MAX_TX_GAIN - gain) * 4.0) as u32
}

/// UHD get_num_taps(): the largest multiple of 16 not above `max`, at most
/// 128 (for max >= 16).
fn num_taps(max: usize) -> usize {
    (max / 16).clamp(1, 8) * 16
}

fn check(what: &'static str, value: f64, min: f64, max: f64) -> Result<()> {
    if (min..=max).contains(&value) {
        Ok(())
    } else {
        Err(Error::Range { what, value, min, max })
    }
}

#[cfg(test)]
mod tests {
    use super::mock::{Access, Mock};
    use super::*;

    #[test]
    fn spi_words_are_uhds() {
        // UHD: write 0x800000 | reg << 8 & 0x3FFF00 | value; read reg << 8
        assert_eq!(spi_write(0x3F4, 0x1B), 0x80_0000 | 0x3F4 << 8 | 0x1B);
        assert_eq!(spi_read(0x037), 0x00_3700);
    }

    /// Every band edge, and next to it.
    const RATE_EDGES: [f64; 16] = [MIN_RATE, 781_250.0 - 1.0, 781_250.0, 1.5625e6 - 1.0, 1.5625e6, 20e6, 20e6 + 1.0,
                                   23e6 - 1.0, 23e6, 40e6, 40e6 + 1.0, 53_333_333.0, 53_333_334.0, 58e6, 58e6 + 1.0, MAX_RATE];

    /// The clocks of a rate band against ADI's limits (module header): the
    /// broken ones, named. `rxfilt`, `txfilt` are 0x003 and 0x002, `adc` the
    /// ADC clock, `half` whether the DAC runs at half of it.
    fn clock_violations(bbpll: f64, adc: f64, half: bool, rxfilt: u8, txfilt: u8) -> Vec<String> {
        let stage3 = |f: u8| [1.0, 2.0, 3.0, 1.0][(f >> 4 & 3) as usize];
        let hb = |f: u8, bit: u8| if f & bit != 0 { 2.0 } else { 1.0 };
        let dac = if half { adc / 2.0 } else { adc };
        // rx: the outputs of HB3/DEC3, HB2, HB1; tx: the inputs of HB3, HB2, HB1
        let r2 = adc / stage3(rxfilt);
        let r1 = r2 / hb(rxfilt, HB2);
        let clkrf = r1 / hb(rxfilt, HB1);
        let t2 = dac / stage3(txfilt);
        let t1 = t2 / hb(txfilt, HB2);
        let clktf = t1 / hb(txfilt, HB1);
        [
            ("BBPLL low", bbpll >= 715e6 - 71_500.0), // ADI: 715 MHz - 100 ppm
            ("BBPLL high", bbpll <= 1430e6 + 143_000.0),
            ("ADC low", adc >= 25e6),
            ("ADC high", adc <= 640e6),
            ("DAC high", dac <= 320e6),
            ("rx HB3", r2 <= 640e6),
            ("rx HB2", r1 <= 320e6),
            ("rx HB1", clkrf <= 245.76e6),
            ("tx HB3", t2 <= 320e6),
            ("tx HB2", t1 <= 320e6),
            ("tx HB1", clktf <= 160e6),
        ]
        .iter()
        .filter(|(_, ok)| !ok)
        .map(|(what, _)| what.to_string())
        .collect()
    }

    #[test]
    fn rate_bands_keep_adis_clock_limits() {
        let mut d = Ad9361::init(Mock::settled()).unwrap();
        let mut rates: Vec<f64> = RATE_EDGES.to_vec();
        let mut r = MIN_RATE;
        while r <= MAX_RATE {
            rates.push(r);
            r *= 1.003;
        }
        for &rate in &rates {
            d.setup_rates(rate).unwrap();
            let v = clock_violations(d.bbpll_freq, d.adc_freq, d.bbpll & 0x08 != 0, d.rxfilt, d.txfilt);
            assert!(v.is_empty(), "{rate}: {v:?}");
        }
        // negative control: UHD's bands (and its 336 MHz DAC switch) break
        // the limits, at the rates the module header names
        let uhd = |rate: f64| -> (u8, u8) {
            match rate {
                r if r < 0.33e6 => (X3 | HB2 | HB1 | FIR_X4, X3 | HB2 | HB1 | FIR_X4),
                r if r < 0.66e6 => (HB3 | HB2 | HB1 | FIR_X4, HB3 | HB2 | HB1 | FIR_X4),
                r if r <= 20e6 => (HB3 | HB2 | HB1 | FIR_X2, HB3 | HB2 | HB1 | FIR_X2),
                r if r < 23e6 => (X3 | HB2 | HB1 | FIR_X2, X3 | HB1 | FIR_X2),
                r if r < 41e6 => (HB3 | HB2 | HB1 | FIR_X2, HB2 | HB1 | FIR_X2),
                r if r <= 58e6 => (X3 | HB1 | FIR_X2, X3 | FIR_X2),
                _ => (HB2 | HB1 | FIR_X2, HB3 | FIR_X2),
            }
        };
        for (rate, broken) in [(220e3, "BBPLL low"), (1e6, "ADC low"), (40.5e6, "ADC high"), (56e6, "ADC high")] {
            let (rx, tx) = uhd(rate);
            let adc = rate * rate_change(rx) as f64;
            let k = (1..=6).find(|&k| (672e6..=1430e6).contains(&(adc * (1 << k) as f64))).unwrap();
            let v = clock_violations(adc * (1 << k) as f64, adc, adc > 336e6, rx, tx);
            assert!(v.contains(&broken.to_string()), "{rate}: {v:?}");
        }
    }

    #[test]
    fn rate_bands_keep_tx_and_rx_rates_equal() {
        // for every band: D_rx as UHD's divfactor, and D_tx = D_rx with the DAC
        // at the ADC clock, D_rx / 2 with the DAC at half of it
        let mut rate = MIN_RATE;
        while rate <= MAX_RATE {
            let mut d = Ad9361::init(Mock::settled()).unwrap();
            d.setup_rates(rate).unwrap();
            let (d_rx, d_tx) = (rate_change(d.rxfilt), rate_change(d.txfilt));
            let half = d.bbpll & 0x08 != 0;
            assert_eq!(half, d.adc_freq > DAC_MAX, "{rate}");
            assert_eq!(d_tx * if half { 2 } else { 1 }, d_rx, "{rate}");
            // within half a BBPLL step: 40 MHz / 2088960 / 2^k / 2
            let step = BB_REF / BB_MOD as f64 / (1 << (d.bbpll & 7)) as f64;
            assert!((d.adc_freq - rate * d_rx as f64).abs() <= step / 2.0, "{rate}");
            assert!((d.rate - rate).abs() <= step / 2.0 / d_rx as f64, "{rate}: {}", d.rate);
            rate *= 1.07;
        }
        for rate in RATE_EDGES {
            let mut d = Ad9361::init(Mock::settled()).unwrap();
            d.setup_rates(rate).unwrap();
            let half = d.bbpll & 0x08 != 0;
            assert_eq!(rate_change(d.txfilt) * if half { 2 } else { 1 }, rate_change(d.rxfilt), "{rate}");
        }
    }

    #[test]
    fn rf_pll_lock_is_polled() {
        // UHD's 2 ms wait, then the lock bit polled for up to PLL_LOCK_MS
        let mut m = Mock::settled();
        let mut d = Ad9361::init(&mut m).unwrap();
        d.bus().log.clear();
        d.set_lo(Dir::Tx, 2.4e9).unwrap();
        let log = &d.bus().log;
        let at = log.iter().position(|a| *a == Access::Read { reg: 0x287, value: 0x02 }).unwrap();
        assert_eq!(log[at - 1], Access::Wait { us: 2000 });
        assert_eq!(log[at + 1], Access::Poll { mask: 0x02, want: 0x02, ms: PLL_LOCK_MS, ok: true });
    }

    #[test]
    fn realisable_bandwidths_reach_every_filter_exactly() {
        assert_eq!((MIN_RX_BANDWIDTH, MAX_RX_BANDWIDTH, MIN_TX_BANDWIDTH, MAX_TX_BANDWIDTH), (0.8e6, 56e6, 1.08e6, 40e6));
        let mut d = Ad9361::init(Mock::settled()).unwrap();
        d.set_rate(MAX_RATE).unwrap();
        let filters = [[RX_BB_BBBW, RX_TIA_BBBW], [TX_BB_BBBW, TX_SECONDARY_BBBW]];
        let limits = [(MIN_RX_BANDWIDTH, MAX_RX_BANDWIDTH), (MIN_TX_BANDWIDTH, MAX_TX_BANDWIDTH)];
        for (filters, (min, max)) in filters.into_iter().zip(limits) {
            for bw in [min, (min + max) / 2.0, max] {
                assert!(filters.iter().all(|&f| d.bbbw(bw, f) == bw / 2.0), "{bw}");
            }
            // negative control: just outside, some filter is clamped
            for bw in [min - 1.0, max + 1.0] {
                assert!(filters.iter().any(|&f| d.bbbw(bw, f) != bw / 2.0), "{bw}");
            }
        }
        // and the rate clips: a bandwidth above it is not set as asked
        d.set_rate(10e6).unwrap();
        assert_eq!(d.bbbw(10e6, RX_TIA_BBBW), 5e6);
        assert_ne!(d.bbbw(10e6 + 2.0, RX_TIA_BBBW), (10e6 + 2.0) / 2.0);
    }

    #[test]
    fn rates_reach_valid_firs() {
        // every rate band, at and next to its edges, programs a FIR set
        for rate in RATE_EDGES {
            let mut d = Ad9361::init(Mock::settled()).unwrap();
            d.setup_rates(rate).unwrap();
        }
    }

    #[test]
    fn lo_formula_lands_within_one_step() {
        // f_lo within one fractional step of the request: 80 MHz / 8388593 / div
        let mut d = Ad9361::init(Mock::settled()).unwrap();
        for f in [MIN_LO, 100e6, 433.92e6, 2.4e9, 5.8e9, MAX_LO] {
            let lo = d.tune_lo(Dir::Rx, f).unwrap();
            assert!(lo <= f && f - lo < RF_REF / RF_MOD as f64, "{f}: {lo}");
        }
        assert!(matches!(d.tune_lo(Dir::Rx, 6.001e9), Err(Error::Range { .. })));
    }

    #[test]
    fn init_ends_in_fdd_at_maximum_attenuation() {
        let mut m = Mock::settled();
        Ad9361::init(&mut m).unwrap();
        assert_eq!(m.regs[0x014], TO_FDD);
        // 359 = 4 x 89.75, set before the FDD write
        assert_eq!([m.regs[0x073], m.regs[0x074], m.regs[0x075], m.regs[0x076]], [0x67, 0x01, 0x67, 0x01]);
        let fdd = m.log.iter().position(|a| *a == Access::Write { reg: 0x014, value: TO_FDD }).unwrap();
        let atten = m.log.iter().position(|a| *a == Access::Write { reg: 0x073, value: 0x67 }).unwrap();
        assert!(atten < fdd);
        // and nothing writes 0 dB attenuation
        assert!(!m.log.iter().any(|a| matches!(a, Access::Write { reg: 0x073..=0x076, value: 0 })));
    }

    #[test]
    fn a_chain_set_runs_the_tx_calibration_and_leaves_tracking_to_the_plan() {
        // the driver stays UHD's: the calibration turns RX IQ tracking off
        // (0x169 = 0xC0) and the chains function does not turn it back on;
        // the plan does, after this (Device::apply, measured 49 vs 79 dB IRR)
        let mut m = Mock::settled();
        let before;
        {
            let mut d = Ad9361::init(&mut m).unwrap();
            d.set_rate(30.72e6).unwrap();
            before = d.bus().log.len();
            d.set_channels(3, 3).unwrap();
        }
        let wrote: Vec<u8> = m.log[before..].iter().filter_map(|a| match a {
            Access::Write { reg: 0x169, value } => Some(*value),
            _ => None,
        }).collect();
        assert!(wrote.contains(&0xC0), "the calibration disabled tracking: {wrote:?}");
        assert_ne!(wrote.last(), Some(&0xCF), "the chains function must not re-enable it: {wrote:?}");

        // and the explicit step does
        let mut m = Mock::settled();
        {
            let mut d = Ad9361::init(&mut m).unwrap();
            d.enable_rx_iq_tracking().unwrap();
        }
        assert_eq!(m.regs[0x169], 0xCF);
    }

    #[test]
    fn range_errors() {
        let mut d = Ad9361::init(Mock::settled()).unwrap();
        assert!(matches!(d.set_rate(MAX_RATE + 1.0), Err(Error::Range { .. })));
        assert!(matches!(d.set_rate(MIN_RATE - 1.0), Err(Error::Range { .. })));
        assert!(matches!(d.set_lo(Dir::Rx, 69e6), Err(Error::Range { .. })));
        assert!(matches!(d.set_gain(Dir::Tx, 0, 90.0), Err(Error::Range { .. })));
        assert!(matches!(d.set_gain(Dir::Rx, 2, 10.0), Err(Error::Range { .. })));
        assert!(matches!(d.set_bandwidth(Dir::Rx, 57e6), Err(Error::Range { .. })));
        // two channels: at most 30.72 MS/s, from either side
        d.set_rate(61.44e6).unwrap();
        assert!(matches!(d.set_channels(3, 1), Err(Error::Range { .. })));
        d.set_rate(30.72e6).unwrap();
        d.set_channels(3, 3).unwrap();
        assert!(matches!(d.set_rate(40e6), Err(Error::Range { .. })));
    }

    #[test]
    fn test_modes_write_only_changes() {
        let mut m = Mock::settled();
        let mut d = Ad9361::init(&mut m).unwrap();
        let writes = |d: &mut Ad9361<&mut Mock>, t| {
            d.bus().log.clear();
            d.set_test(t).unwrap();
            d.bus().log.iter().filter_map(|a| if let Access::Write { reg, value } = *a { Some((reg, value)) } else { None }).collect::<Vec<_>>()
        };
        assert_eq!(writes(&mut d, Test::Tone), [(0x3F4, 0x1B)]);
        assert_eq!(writes(&mut d, Test::Tone), []);
        assert_eq!(writes(&mut d, Test::Prbs), [(0x3F4, 0x09)]);
        assert_eq!(writes(&mut d, Test::Loopback), [(0x3F4, 0x00), (0x3F5, 0x01)]);
        assert_eq!(writes(&mut d, Test::None), [(0x3F5, 0x00)]);
    }

    #[test]
    fn poll_timeouts_are_errors() {
        // a calibration that never finishes, a PLL that never locks, a wrong id
        let mut m = Mock::new(|reg, regs| if reg == CAL_CTRL { regs[CAL_CTRL as usize] } else { mock::settled(reg, regs) });
        assert!(matches!(Ad9361::init(&mut m), Err(Error::Poll { reg: CAL_CTRL, .. })));
        let mut m = Mock::new(|reg, regs| if reg == 0x247 { 0 } else { mock::settled(reg, regs) });
        assert!(matches!(Ad9361::init(&mut m), Err(Error::Poll { reg: 0x247, mask: 0x02, want: 0x02, value: 0 })));
        let mut m = Mock::new(|reg, regs| if reg == 0x037 { 0x10 } else { mock::settled(reg, regs) });
        assert!(matches!(Ad9361::init(&mut m), Err(Error::ProductId(0x10))));
    }

    #[test]
    fn batches_flush_only_for_reads() {
        // init: one round trip per value read back, plus the final flush
        let mut m = Mock::settled();
        Ad9361::init(&mut m).unwrap();
        let reads = m.log.iter().filter(|a| matches!(a, Access::Read { .. })).count();
        let polls = m.log.iter().filter(|a| matches!(a, Access::Poll { .. })).count();
        // reads that decide: id, 2 x 3 filter values, 4 x 0x0A3, ENSM state
        assert_eq!(m.round_trips, 1 + 2 + 4 + 1 + 1);
        assert_eq!(reads, (1 + 6 + 4 + 1) + polls);
    }
}
