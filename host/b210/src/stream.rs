//! Streams on the data endpoints (docs/PROTOCOL.md sections 1 to 3): the rx
//! loop every streaming command runs, the checker it applies to every
//! packet that arrives, and tx bursts.

use crate::proto::{self, flag, Format, Header, Kind};
use crate::regs::{self, rx};
use crate::usb::{self, zero_copy, Ctrl};
use nusb::transfer::{Bulk, In, Out, TransferError};
use nusb::Endpoint;
use std::ops::Range;
use std::time::{Duration, Instant};

/// No rx transfer for this long is a stalled stream, not a slow host: a full
/// 16 KiB packet takes at most a few milliseconds at the test rates, and the
/// FPGA sends one whenever it has a packet's worth.
const RX_STALL: Duration = Duration::from_secs(2);

/// `flush_rx` collects leftover transfers for at most this long: ~25
/// packets at the slowest test rate, far more than a stopped stream leaves
/// in the FX3's DMA channel (two buffers).
const FLUSH_WAIT: Duration = Duration::from_millis(100);

/// A tx transfer that has not completed this long after the burst's start
/// is stuck, not queued: 5 s is over 1000 16 KiB packets at the bus rate.
/// `send` adds the lead before the burst, during which the FPGA's tx ring
/// fills and transfers wait for its tick.
const TX_STALL: Duration = Duration::from_secs(5);

/// Mismatching values a [`Check`] keeps for its report.
pub const REPORTED: usize = 5;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Usb(#[from] usb::Error),
    #[error("USB transfer: {0}")]
    Transfer(#[from] TransferError),
    #[error("no rx transfer within {0:?}")]
    RxStalled(Duration),
    #[error("a tx transfer did not complete within {0:?}")]
    TxStalled(Duration),
    #[error("rx stream: bad packet header ({0:?}); cannot find the next packet")]
    Stream(proto::Error),
    #[error("{0}")]
    Sink(&'static str),
}

pub type Result<T> = std::result::Result<T, Error>;

/// One stream's shape: its wire format and channel mask.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shape {
    pub format: Format,
    pub mask: u8,
}

impl Shape {
    /// The number of channels.
    pub fn count(self) -> usize {
        self.mask.count_ones() as usize
    }

    /// Sample times in a full packet.
    pub fn spp(self) -> usize {
        self.format.full_spp(self.count())
    }

    pub fn bytes_per_time(self) -> usize {
        self.format.bytes_per_time(self.count())
    }
}

/// A value that differed from what its tick must carry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mismatch {
    pub time: u64,
    /// I0 Q0 I1 Q1: 0 .. 3
    pub value: usize,
    pub got: i16,
    pub want: i16,
}

/// What an rx stream showed, packet by packet.
#[derive(Debug)]
pub struct Check {
    pub packets: u64,
    pub samples: u64,
    pub lost: u64,
    pub overflow_flags: u64,
    pub bad_values: u64,
    pub bad_headers: u64,
    /// Whether `values` compares samples against `expect` at all: off for a
    /// source with no closed form (the radio).
    pub check_values: bool,
    /// The first data packet's time.
    pub first: Option<u64>,
    /// The time and sequence the next packet must carry.
    pub next: Option<(u64, u16)>,
    /// The first [`REPORTED`] mismatching values.
    pub mismatches: Vec<Mismatch>,
    /// A packet with samples has arrived: an END_OF_BURST from now on ends
    /// this stream, not a stopped earlier one.
    data_seen: bool,
}

/// What one packet was to the stream.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Seen {
    /// The header of a data packet that passed `Check::header`; its values
    /// were checked.
    pub data: Option<Header>,
    /// The packet carried samples (whether or not its header passed).
    pub samples: bool,
    /// The packet ends the stream: END_OF_BURST after data.
    pub end: bool,
}

impl Default for Check {
    /// `check_values` on: a Check that does not compare samples must say so.
    fn default() -> Self {
        Check {
            packets: 0,
            samples: 0,
            lost: 0,
            overflow_flags: 0,
            bad_values: 0,
            bad_headers: 0,
            first: None,
            next: None,
            mismatches: Vec::new(),
            data_seen: false,
            check_values: true,
        }
    }
}

impl Check {
    /// Nothing lost, flagged or wrong.
    pub fn clean(&self) -> bool {
        self.lost == 0 && self.bad_values == 0 && self.bad_headers == 0 && self.overflow_flags == 0
    }

    /// One data packet's header (`n` sample times) against the stream so
    /// far: format and channels as configured, HAS_TIME, times contiguous
    /// unless OVERFLOW says samples were dropped (then the gap is counted
    /// lost), sequence +1. False for a header that must not be used.
    pub fn header(&mut self, h: &Header, s: Shape, n: usize) -> bool {
        if h.format != Some(s.format) || h.mask != s.mask || h.flags & flag::HAS_TIME == 0 {
            self.bad_headers += 1;
            return false;
        }
        let overflow = h.flags & flag::OVERFLOW != 0;
        if let Some((time, seq)) = self.next {
            let gap = proto::lost(time, 0, h.time);
            if h.sequence != seq || gap < 0 || (gap > 0) != overflow {
                self.bad_headers += 1;
            }
            self.lost += gap.max(0) as u64;
        }
        self.overflow_flags += overflow as u64;
        self.first.get_or_insert(h.time);
        self.packets += 1;
        self.samples += n as u64;
        self.next = Some((h.time + n as u64, h.sequence.wrapping_add(1)));
        true
    }

    /// Every sample time of a packet against `expect(t)`, the four values I0
    /// Q0 I1 Q1 tick t must carry (the first `2 x count` of them compared).
    pub fn values(&mut self, h: &Header, v: &[i16], s: Shape, expect: &impl Fn(u64) -> [i16; 4]) {
        if !self.check_values {
            return;
        }
        for (k, got) in v.chunks(2 * s.count()).enumerate() {
            let time = h.time + k as u64;
            let want = expect(time);
            for (j, &g) in got.iter().enumerate() {
                if g != want[j] {
                    if self.mismatches.len() < REPORTED {
                        self.mismatches.push(Mismatch { time, value: j, got: g, want: want[j] });
                    }
                    self.bad_values += 1;
                }
            }
        }
    }

    /// One rx packet's wire bytes (a range of `proto::packets`): a data
    /// packet's values are unpacked into `values` and, if its header
    /// passes, checked. A packet of another kind, or whose payload is not
    /// whole sample times, counts as a bad header. An END_OF_BURST before
    /// any data packet belongs to a stopped earlier stream and does not end
    /// this one.
    pub fn packet(&mut self, p: &[u8], s: Shape, expect: &impl Fn(u64) -> [i16; 4], values: &mut Vec<i16>) -> Seen {
        let mut seen = Seen::default();
        let h = match Header::decode(p) {
            Ok(h) if h.kind == Kind::Rx => h,
            _ => {
                self.bad_headers += 1;
                return seen;
            }
        };
        let payload = h.length as usize - proto::HEADER;
        if payload > 0 {
            let bpt = s.bytes_per_time();
            if !payload.is_multiple_of(bpt) {
                self.bad_headers += 1;
                return seen;
            }
            let n = payload / bpt;
            values.resize(n * 2 * s.count(), 0);
            proto::unpack(s.format, &p[proto::HEADER..proto::HEADER + payload], values);
            self.data_seen = true;
            seen.samples = true;
            if self.header(&h, s, n) {
                self.values(&h, values, s, expect);
                seen.data = Some(h);
            }
        }
        seen.end = self.data_seen && h.flags & flag::END_OF_BURST != 0;
        seen
    }
}

/// Fetch and discard whatever a previous stream left on the endpoint: a
/// stopped stream's packets (and its END_OF_BURST) sit in the FX3's DMA
/// channel, and the next run must begin with an empty one. Ends at the
/// first transfer that does not complete, or after [`FLUSH_WAIT`].
pub fn flush_rx(rx: &mut Endpoint<Bulk, In>) {
    let deadline = Instant::now() + FLUSH_WAIT;
    rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        if rx.wait_next_complete(left).is_none() {
            break;
        }
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    usb::drain(rx);
}

/// Run one rx stream: flush the endpoint, start the stream (continuous,
/// full packets, `depth` transfers in flight), put every packet through
/// `check`, and after each packet with samples call `packet` with the
/// header and values (I0 Q0 [I1 Q1] per sample time) of a packet whose
/// header passed (None otherwise) and the check so far. STOP is sent once
/// `packet` returns true; the stream ends at its END_OF_BURST. Returns the
/// seconds streamed. The endpoint is drained on every return.
///
/// Packets are walked by their length, not by transfer: a transfer may end
/// inside a packet or hold several (PROTOCOL.md 1, S(L)).
pub fn rx_stream(
    rx: &mut Endpoint<Bulk, In>,
    ctrl: &mut Ctrl,
    s: Shape,
    depth: usize,
    check: &mut Check,
    expect: &impl Fn(u64) -> [i16; 4],
    packet: impl FnMut(Option<(&Header, &[i16])>, &Check) -> Result<bool>,
) -> Result<f64> {
    ctrl.write(regs::RX_SPP, s.spp() as u32)?;
    ctrl.write(regs::RX_COUNT, 0)?;
    flush_rx(rx);
    for _ in 0..depth {
        rx.submit(zero_copy(rx.allocate(proto::DATA_BUFFER)));
    }
    let r = ctrl
        .write(regs::RX_CTRL, rx::START | rx::config(s.format, s.mask))
        .map_err(Error::from)
        .and_then(|()| rx_loop(rx, ctrl, s, check, expect, packet));
    usb::drain(rx);
    r
}

fn rx_loop(
    rx: &mut Endpoint<Bulk, In>,
    ctrl: &mut Ctrl,
    s: Shape,
    check: &mut Check,
    expect: &impl Fn(u64) -> [i16; 4],
    mut packet: impl FnMut(Option<(&Header, &[i16])>, &Check) -> Result<bool>,
) -> Result<f64> {
    let start = Instant::now();
    let mut values = Vec::new();
    let mut bytes: Vec<u8> = Vec::with_capacity(2 * proto::DATA_BUFFER);
    let (mut stopping, mut ended) = (false, false);
    while !ended {
        let c = rx.wait_next_complete(RX_STALL).ok_or(Error::RxStalled(RX_STALL))?;
        let n = c.actual_len;
        let buf = c.into_result()?;
        bytes.extend_from_slice(&buf[..n]);
        rx.submit(buf);
        let ranges = proto::packets(&bytes, proto::DATA_BUFFER).map_err(Error::Stream)?;
        let used = ranges.last().map_or(0, |r| r.end);
        for r in ranges {
            let seen = check.packet(&bytes[r], s, expect, &mut values);
            if seen.samples {
                let data = seen.data.as_ref().map(|h| (h, values.as_slice()));
                if packet(data, check)? && !stopping {
                    ctrl.write(regs::RX_CTRL, rx::STOP)?;
                    stopping = true;
                }
            }
            ended |= seen.end;
        }
        bytes.drain(..used);
    }
    Ok(start.elapsed().as_secs_f64())
}

/// A burst of `n` sample times starting at tick `at`, value v (I0 Q0 [I1
/// Q1]) of sample time i being `value(i, v)`, as packets: full ones, the
/// last one shorter; HAS_TIME on every one, START_OF_BURST on the first,
/// END_OF_BURST on the last; sequence numbers 0, 1, ... (mod 2^16).
pub fn burst(s: Shape, at: u64, n: u64, value: impl Fn(u64, usize) -> i16) -> impl Iterator<Item = (Header, Vec<i16>)> {
    let per = s.spp() as u64;
    let packets = n.div_ceil(per);
    let nv = 2 * s.count();
    (0..packets).map(move |p| {
        let i0 = p * per;
        let m = per.min(n - i0);
        let mut values = Vec::with_capacity(m as usize * nv);
        for i in 0..m {
            for v in 0..nv {
                values.push(value(i0 + i, v));
            }
        }
        let mut flags = flag::HAS_TIME;
        if p == 0 {
            flags |= flag::START_OF_BURST;
        }
        if p + 1 == packets {
            flags |= flag::END_OF_BURST;
        }
        let h = Header { length: 0, kind: Kind::Tx, format: Some(s.format), mask: s.mask, sequence: p as u16, flags, time: at + i0 };
        (h, values)
    })
}

/// Send `packets` on the tx endpoint with at most `depth` transfers in
/// flight, and wait for the last one; the packets sent. `lead` is the time
/// until the burst's first tick (transfers wait for it once the FPGA's tx
/// ring is full). The endpoint is drained on an error.
pub fn send(
    tx: &mut Endpoint<Bulk, Out>,
    packets: impl IntoIterator<Item = (Header, Vec<i16>)>,
    depth: usize,
    lead: Duration,
) -> Result<u64> {
    let wait = lead + TX_STALL;
    let r = send_all(tx, packets, depth, wait);
    if r.is_err() {
        usb::drain(tx);
    }
    r
}

fn send_all(
    tx: &mut Endpoint<Bulk, Out>,
    packets: impl IntoIterator<Item = (Header, Vec<i16>)>,
    depth: usize,
    wait: Duration,
) -> Result<u64> {
    let mut scratch = vec![0u8; proto::DATA_BUFFER];
    let mut sent = 0;
    for (h, values) in packets {
        let size = proto::tx_packet(h, &values, &mut scratch);
        let mut buf = if tx.pending() < depth {
            zero_copy(tx.allocate(proto::DATA_BUFFER))
        } else {
            tx.wait_next_complete(wait).ok_or(Error::TxStalled(wait))?.into_result()?
        };
        buf.clear();
        buf.extend_from_slice(&scratch[..size]);
        tx.submit(buf);
        sent += 1;
    }
    while tx.pending() > 0 {
        tx.wait_next_complete(wait).ok_or(Error::TxStalled(wait))?.into_result()?;
    }
    Ok(sent)
}

/// The sample times of a packet at tick `time` holding `n` of them that lie
/// in [from, to), as indices into the packet.
pub fn within(time: u64, n: usize, from: u64, to: u64) -> Range<usize> {
    let k0 = from.saturating_sub(time).min(n as u64) as usize;
    let k1 = to.saturating_sub(time).min(n as u64) as usize;
    k0..k1.max(k0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: Shape = Shape { format: Format::Sc12, mask: 0b11 };

    fn rx_header(time: u64, sequence: u16, flags: u16) -> Header {
        Header { length: 0, kind: Kind::Rx, format: Some(S.format), mask: S.mask, sequence, flags: flag::HAS_TIME | flags, time }
    }

    #[test]
    fn check_counts_a_gap_as_lost_only_with_overflow() {
        let mut c = Check::default();
        assert!(c.header(&rx_header(1000, 7, 0), S, 100));
        // contiguous, sequence +1: clean
        assert!(c.header(&rx_header(1100, 8, 0), S, 100));
        assert!(c.clean());
        // a gap of 50 flagged OVERFLOW: lost, header fine
        assert!(c.header(&rx_header(1250, 9, flag::OVERFLOW), S, 100));
        assert_eq!((c.lost, c.overflow_flags, c.bad_headers), (50, 1, 0));
        // a gap without OVERFLOW: lost and a bad header
        assert!(c.header(&rx_header(1360, 10, 0), S, 100));
        assert_eq!((c.lost, c.bad_headers), (60, 1));
        // OVERFLOW without a gap: a bad header, nothing lost
        assert!(c.header(&rx_header(1460, 11, flag::OVERFLOW), S, 100));
        assert_eq!((c.lost, c.bad_headers), (60, 2));
        // time going backwards: a bad header, nothing lost
        assert!(c.header(&rx_header(1500, 12, 0), S, 100));
        assert_eq!((c.lost, c.bad_headers), (60, 3));
        assert_eq!((c.packets, c.samples, c.first), (6, 600, Some(1000)));
        assert!(!c.clean());
    }

    #[test]
    fn check_wants_sequence_plus_one_across_the_wrap() {
        let mut c = Check::default();
        c.header(&rx_header(0, 0xFFFF, 0), S, 10);
        c.header(&rx_header(10, 0, 0), S, 10);
        assert_eq!(c.bad_headers, 0);
        c.header(&rx_header(20, 2, 0), S, 10); // 1 skipped
        assert_eq!(c.bad_headers, 1);
    }

    #[test]
    fn check_rejects_wrong_format_mask_or_no_time() {
        for h in [
            Header { format: Some(Format::Sc16), ..rx_header(0, 0, 0) },
            Header { format: None, ..rx_header(0, 0, 0) },
            Header { mask: 0b01, ..rx_header(0, 0, 0) },
            Header { flags: 0, ..rx_header(0, 0, 0) },
        ] {
            let mut c = Check::default();
            assert!(!c.header(&h, S, 10), "{h:?}");
            assert_eq!((c.bad_headers, c.packets, c.next), (1, 0, None), "a rejected header does not advance the stream");
        }
    }

    #[test]
    fn check_values_counts_every_mismatch_and_keeps_the_first_few() {
        let mut c = Check::default();
        let h = rx_header(100, 0, 0);
        let expect = |t: u64| [t as i16, 1, 2, 3];
        // 10 sample times, value 2 wrong in each
        let v: Vec<i16> = (0..10).flat_map(|k| [100 + k, 1, 9, 3]).collect();
        // check_values off counts nothing
        c.check_values = false;
        c.values(&h, &v, S, &expect);
        assert_eq!(c.bad_values, 0);
        c.check_values = true;
        c.values(&h, &v, S, &expect);
        assert_eq!(c.bad_values, 10);
        assert_eq!(c.mismatches.len(), REPORTED);
        assert_eq!(c.mismatches[1], Mismatch { time: 101, value: 2, got: 9, want: 2 });
        // one channel compares I0 Q0 only
        let one = Shape { mask: 0b01, ..S };
        let mut c = Check::default();
        c.values(&h, &[100, 1, 101, 1], one, &expect);
        assert_eq!(c.bad_values, 0);
    }

    /// An rx packet's wire bytes: `n` sample times of the pattern t, or none.
    fn wire(h: Header, n: usize) -> Vec<u8> {
        let values: Vec<i16> = (0..n as u64).flat_map(|k| [h.time + k, 1, 2, 3].map(|x| x as i16)).collect();
        let mut out = vec![0u8; proto::DATA_BUFFER];
        let size = proto::tx_packet(h, &values, &mut out); // kind becomes Tx: set Rx back
        let mut p = out[..size].to_vec();
        let length = Header::decode(&p).unwrap().length;
        p[..proto::HEADER].copy_from_slice(&Header { length, ..h }.encode());
        p
    }

    #[test]
    fn an_end_of_burst_before_data_is_a_stale_one() {
        let expect = |t: u64| [t as i16, 1, 2, 3];
        let mut c = Check::default();
        let mut values = Vec::new();
        // the stopped stream's END_OF_BURST, header only: ignored
        let stale = c.packet(&wire(rx_header(5, 3, flag::END_OF_BURST), 0), S, &expect, &mut values);
        assert_eq!(stale, Seen::default());
        let data = c.packet(&wire(rx_header(100, 0, 0), 4), S, &expect, &mut values);
        assert_eq!((data.data.map(|h| h.time), data.samples, data.end), (Some(100), true, false));
        assert_eq!(values.len(), 4 * 4);
        // now an END_OF_BURST ends the stream
        let end = c.packet(&wire(rx_header(104, 1, flag::END_OF_BURST), 0), S, &expect, &mut values);
        assert!(end.end && !end.samples);
        assert!(c.clean(), "{c:?}");
    }

    #[test]
    fn packet_counts_other_kinds_and_partial_sample_times_as_bad_headers() {
        let expect = |_| [0; 4];
        let mut c = Check::default();
        let mut values = Vec::new();
        let mut p = wire(rx_header(0, 0, 0), 4);
        let h = Header::decode(&p).unwrap();
        p[..proto::HEADER].copy_from_slice(&Header { kind: Kind::Result, ..h }.encode());
        assert_eq!(c.packet(&p, S, &expect, &mut values), Seen::default());
        // 4 sample times of 2 channels read as 1 channel: 24 bytes are 8 of 3
        let one = Shape { mask: 0b01, ..S };
        let p = wire(rx_header(0, 0, 0), 4);
        assert!(c.packet(&p, one, &expect, &mut values).samples, "whole sample times of the other shape");
        // a payload of 5 bytes is no whole sample time of either
        let mut odd = p.clone();
        odd[..proto::HEADER].copy_from_slice(&Header { length: proto::HEADER as u16 + 5, ..h }.encode());
        assert_eq!(c.packet(&odd, S, &expect, &mut values), Seen::default());
        assert_eq!(c.bad_headers, 3); // kind, mask (the 1-channel read), partial
    }

    #[test]
    fn burst_packetises_with_flags_sequences_and_times() {
        let s = Shape { format: Format::Sc16, mask: 0b01 }; // 4092 per packet
        let value = |i: u64, v: usize| (i as i16).wrapping_mul(3).wrapping_add(v as i16) & 0x7FF;
        let n = 2 * 4092 + 100;
        let p: Vec<(Header, Vec<i16>)> = burst(s, 1_000, n, value).collect();
        assert_eq!(p.len(), 3);
        let flags: Vec<u16> = p.iter().map(|(h, _)| h.flags).collect();
        assert_eq!(flags, [
            flag::HAS_TIME | flag::START_OF_BURST,
            flag::HAS_TIME,
            flag::HAS_TIME | flag::END_OF_BURST,
        ]);
        assert_eq!(p.iter().map(|(h, _)| (h.sequence, h.time)).collect::<Vec<_>>(), [(0, 1_000), (1, 5_092), (2, 9_184)]);
        assert_eq!(p.iter().map(|(_, v)| v.len()).collect::<Vec<_>>(), [2 * 4092, 2 * 4092, 2 * 100]);
        assert!(p.iter().all(|(h, _)| h.format == Some(s.format) && h.mask == s.mask && h.kind == Kind::Tx));
        // the values are value(i, v), i counted from the burst's start
        assert_eq!(&p[1].1[..4], &[value(4092, 0), value(4092, 1), value(4093, 0), value(4093, 1)]);
        assert_eq!(*p[2].1.last().unwrap(), value(n - 1, 1));
        // a burst of exactly one full packet: START and END on it
        let one: Vec<_> = burst(s, 0, 4092, value).collect();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].0.flags, flag::HAS_TIME | flag::START_OF_BURST | flag::END_OF_BURST);
        assert_eq!(burst(s, 0, 0, value).count(), 0);
    }

    #[test]
    fn within_slices_the_kept_interval() {
        // packet at 100 holding 50: [100, 150)
        assert_eq!(within(100, 50, 0, u64::MAX), 0..50);
        assert_eq!(within(100, 50, 120, 130), 20..30);
        assert_eq!(within(100, 50, 120, 1000), 20..50);
        assert_eq!(within(100, 50, 0, 110), 0..10);
        // before and after the interval: empty
        assert!(within(100, 50, 150, 200).is_empty());
        assert!(within(100, 50, 0, 100).is_empty());
        assert!(within(100, 50, 200, 300).is_empty());
    }
}
