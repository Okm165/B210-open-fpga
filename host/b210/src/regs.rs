// SPDX-License-Identifier: GPL-3.0-or-later

//! Register addresses (docs/PROTOCOL.md section 6, fpga/rtl/regs.v).
//!
//! The map is complete, not just the part the commands drive: SCRATCH is
//! for `b210 read/write` sanity checks, and the timed-start registers
//! (time_set_lo/hi, time_ctrl, rx_at_lo/hi) are implemented by the image
//! but no command sets them - a stream starts when START is written. They
//! are here so the map matches the RTL and PROTOCOL.md; none is a hint that
//! the CLI has a timed mode.

pub const ID: u16 = 0x000;
pub const VERSION: u16 = 0x001;
pub const BUILD: u16 = 0x002;
pub const SCRATCH: u16 = 0x003;
pub const STATUS: u16 = 0x004;
/// Sample strobes counted in the last 1 ms of the bus clock: the sample
/// rate in kS/s.
pub const SAMPLE_RATE: u16 = 0x005;
pub const TIME_LO: u16 = 0x010;
pub const TIME_HI: u16 = 0x011;
pub const TIME_SET_LO: u16 = 0x012;
pub const TIME_SET_HI: u16 = 0x013;
pub const TIME_CTRL: u16 = 0x014;
pub const RX_CTRL: u16 = 0x020;
pub const RX_COUNT: u16 = 0x021;
pub const RX_AT_LO: u16 = 0x022;
pub const RX_AT_HI: u16 = 0x023;
pub const RX_SPP: u16 = 0x024;
/// Radio control: bit 0 drives the AD9361 RESETB pin, 0 = held in reset
/// (the value after the FPGA loads), 1 = released.
pub const RADIO: u16 = 0x030;
/// The front end's band-select switches (`bands`). Not in FPGA images up
/// to build 8, which ignore a write to it and read 0.
pub const BANDS: u16 = 0x031;
/// Event counter of code k (PROTOCOL.md 5) at EVENTS + k - 1.
pub const EVENTS: u16 = 0x080;
/// Sample times lost crossing from the sample clock to the bus clock (a
/// design error if ever nonzero); also counted in event 1, OVERFLOW.
pub const RX_CDC_LOST: u16 = 0x086;
pub const CMD_DROPPED: u16 = 0x087;
/// Words (4 bytes) in the rx ring now, and the most since the last clear
/// (write any value). Depth 2^17 words = 512 KiB.
pub const RX_USED: u16 = 0x088;
pub const RX_HWM: u16 = 0x089;
/// The same for the tx ring, depth 2^16 words = 256 KiB.
pub const TX_USED: u16 = 0x08A;
pub const TX_HWM: u16 = 0x08B;
pub const RX_RING_WORDS: u32 = 1 << 17;
pub const TX_RING_WORDS: u32 = 1 << 16;
pub const RX_SOURCE: u16 = 0x0F0;

/// `id`: "B210".
pub const ID_VALUE: u32 = 0x4232_3130;

/// rx_ctrl bits.
pub mod rx {
    pub const START: u32 = 1 << 0;
    pub const STOP: u32 = 1 << 1;
    pub const TIMED: u32 = 1 << 3;
    /// The configuration word: format (its wire code, 1 sc16, 2 sc12) and
    /// channel mask.
    pub fn config(format: crate::proto::Format, mask: u8) -> u32 {
        (format as u32) << 4 | (mask as u32) << 8
    }
}

/// `BANDS` bits, and the bits for an LO: UHD b200_impl.cpp update_bandsel
/// (from the LO the AD9361 reached). rx: C below 2.2 GHz, B below 4 GHz, A
/// up to 6 GHz; tx: B below 2.5 GHz, A from there. The same edges as the
/// AD9361's own input and output port selection (ad9361 RX_PORT_*_FROM,
/// TX_PORT_A_FROM).
pub mod bands {
    pub const RX_A: u32 = 1 << 0;
    pub const RX_B: u32 = 1 << 1;
    pub const RX_C: u32 = 1 << 2;
    pub const TX_A: u32 = 1 << 3;
    pub const TX_B: u32 = 1 << 4;
    pub const RX: u32 = RX_A | RX_B | RX_C;
    pub const TX: u32 = TX_A | TX_B;

    /// The rx bits for rx LO `hz`.
    pub fn rx(hz: f64) -> u32 {
        if hz < 2.2e9 {
            RX_C
        } else if hz < 4e9 {
            RX_B
        } else {
            RX_A
        }
    }

    /// The tx bits for tx LO `hz`.
    pub fn tx(hz: f64) -> u32 {
        if hz < 2.5e9 { TX_B } else { TX_A }
    }
}

/// rx_source: what the rx stream carries.
pub mod rx_source {
    pub const RADIO: u32 = 0;
    pub const PATTERN: u32 = 1;
    pub const LOOPBACK: u32 = 2;

    /// The pattern value k (I0, Q0, I1, Q1) of sample time t, as a 12-bit
    /// two's-complement code: I0 = t, Q0 = !t, I1 = 7 t, Q1 = 13 t + 5,
    /// each modulo 2^12 (fpga/rtl/sample_domain.v).
    pub fn pattern(t: u64, k: usize) -> i16 {
        let v = match k {
            0 => t,
            1 => !t,
            2 => t.wrapping_mul(7),
            _ => t.wrapping_mul(13).wrapping_add(5),
        } as u16;
        crate::proto::sext12(v)
    }
}

// -- typed reads ------------------------------------------------------------------

use crate::usb::{Ctrl, Error, Result};

/// The event counters by code 1 .. 6 (index code - 1), then rx_cdc_lost.
pub type Counters = [u32; 7];
pub const COUNTER_NAMES: [&str; 7] = ["OVERFLOW", "UNDERFLOW", "LATE", "SEQ_ERROR", "BURST_ACK", "BAD_PACKET", "rx_cdc_lost"];

/// The time now (reading time_lo latches time_hi: both in one command).
pub fn now(ctrl: &mut Ctrl) -> Result<u64> {
    let r = ctrl.read_all(&[TIME_LO, TIME_HI])?;
    Ok(r[0] as u64 | (r[1] as u64) << 32)
}

pub fn counters(ctrl: &mut Ctrl) -> Result<Counters> {
    let r = ctrl.read_all(&[EVENTS, EVENTS + 1, EVENTS + 2, EVENTS + 3, EVENTS + 4, EVENTS + 5, RX_CDC_LOST])?;
    Ok(std::array::from_fn(|i| r[i]))
}

/// The sample rate the sample domain sees, from the bus side's count of
/// data-clock edges (0x005, kS/s). A stopped sample clock is an error: the
/// AD9361 must be running before any stream.
pub fn sample_rate(ctrl: &mut Ctrl) -> Result<f64> {
    let ksps = ctrl.read(SAMPLE_RATE)?;
    if ksps == 0 {
        return Err(Error::NoSampleClock);
    }
    Ok(ksps as f64 * 1e3)
}

/// Prepare a test stream: rx stopped, `source` (an `rx_source` value) on
/// it; the counters before it.
pub fn setup(ctrl: &mut Ctrl, source: u32) -> Result<Counters> {
    ctrl.write(RX_CTRL, rx::STOP)?;
    ctrl.write(RX_SOURCE, source)?;
    counters(ctrl)
}

/// One reading of the board's health, every register in one command
/// packet, so they describe the same moment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Health {
    pub status: u32,
    pub rx_running: bool,
    pub sample_ksps: u32,
    /// Event codes 1 .. 6, rx_cdc_lost, cmd_dropped.
    pub counts: [u32; 8],
    pub rx_used: u32,
    pub rx_hwm: u32,
    pub tx_used: u32,
    pub tx_hwm: u32,
    pub time: u64,
}

pub fn health(ctrl: &mut Ctrl) -> Result<Health> {
    let r = ctrl.read_all(&[
        STATUS, RX_CTRL, SAMPLE_RATE, EVENTS, EVENTS + 1, EVENTS + 2, EVENTS + 3, EVENTS + 4, EVENTS + 5, RX_CDC_LOST,
        CMD_DROPPED, RX_USED, RX_HWM, TX_USED, TX_HWM, TIME_LO, TIME_HI,
    ])?;
    Ok(Health {
        status: r[0],
        rx_running: r[1] & rx::START != 0,
        sample_ksps: r[2],
        counts: std::array::from_fn(|i| r[3 + i]),
        rx_used: r[11],
        rx_hwm: r[12],
        tx_used: r[13],
        tx_hwm: r[14],
        time: r[15] as u64 | (r[16] as u64) << 32,
    })
}

#[cfg(test)]
mod tests {
    use super::rx_source::pattern;

    #[test]
    fn bands_follow_uhds_update_bandsel_at_the_edges() {
        use super::bands::*;
        for (hz, want) in [(70e6, RX_C), (2.2e9 - 1.0, RX_C), (2.2e9, RX_B), (4e9 - 1.0, RX_B), (4e9, RX_A), (6e9, RX_A)] {
            assert_eq!(rx(hz), want, "rx {hz}");
        }
        for (hz, want) in [(70e6, TX_B), (2.5e9 - 1.0, TX_B), (2.5e9, TX_A), (6e9, TX_A)] {
            assert_eq!(tx(hz), want, "tx {hz}");
        }
        // one switch per direction, and the directions apart
        assert_eq!(RX & TX, 0);
        assert_eq!((RX_A | RX_B | RX_C | TX_A | TX_B).count_ones(), 5);
    }

    #[test]
    fn pattern_is_sample_domain_s() {
        // computed independently (12-bit arithmetic, two's complement)
        assert_eq!([0, 1, 2, 3].map(|k| pattern(0x123, k)), [291, -292, 2037, -308]);
        assert_eq!([0, 1, 2, 3].map(|k| pattern((1 << 40) + 4095, k)), [-1, 0, -7, -8]);
    }
}
