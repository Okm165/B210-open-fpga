//! The wire format of docs/PROTOCOL.md, both directions.
//!
//! Units throughout: lengths in bytes; `time` in ticks (sample periods at
//! the configured rate); sample values are the AD9361's 12-bit
//! two's-complement codes c in [-2048, 2047], held in `i16`.

/// FX3 DMA buffer of a data endpoint (EP2, EP6), bytes.
pub const DATA_BUFFER: usize = 16_384;
/// FX3 DMA buffer of a control endpoint (EP4, EP8) at SuperSpeed, bytes.
pub const CONTROL_BUFFER: usize = 1_024;
/// Every packet starts with this many header bytes.
pub const HEADER: usize = 16;
/// Payload of a full data packet: 16 368 = 2^4 x 3 x 11 x 31, so a whole
/// number of sample times for 3, 4, 6 and 8 bytes per sample time.
pub const PAYLOAD: usize = DATA_BUFFER - HEADER;
/// Operations per command packet: (1024 - 16) / 8.
pub const MAX_OPS: usize = (CONTROL_BUFFER - HEADER) / 8;
pub const VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Rx = 0,
    Tx = 1,
    Command = 2,
    Result = 3,
    Event = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    None = 0,
    Sc16 = 1,
    Sc12 = 2,
}

impl Format {
    /// Bytes per sample time for `channels` channels (I and Q each).
    pub fn bytes_per_time(self, channels: usize) -> usize {
        match self {
            Format::None => 0,
            Format::Sc16 => 4 * channels,
            Format::Sc12 => 3 * channels,
        }
    }

    /// Sample times in a full data packet.
    pub fn times_per_packet(self, channels: usize) -> usize {
        PAYLOAD / self.bytes_per_time(channels)
    }
}

/// Header flags (word 1, bits 16 + k).
pub mod flag {
    pub const HAS_TIME: u16 = 1 << 0;
    pub const START_OF_BURST: u16 = 1 << 1;
    pub const END_OF_BURST: u16 = 1 << 2;
    pub const OVERFLOW: u16 = 1 << 3;
    pub const ALL: u16 = (1 << 4) - 1;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    /// Meaningful bytes, header included.
    pub length: u16,
    pub kind: Kind,
    pub format: Format,
    /// Bit c set: channel c present.
    pub channels: u8,
    pub sequence: u16,
    pub flags: u16,
    /// Tick of the first sample time (valid with `flag::HAS_TIME`).
    pub time: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Short(usize),
    Version(u8),
    Kind(u8),
    Format(u8),
    Length(u16),
    Flags(u16),
    TooManyOps(usize),
}

impl Header {
    pub fn encode(&self) -> [u8; HEADER] {
        let w0 = self.length as u32
            | (self.kind as u32) << 16
            | (self.format as u32) << 20
            | (self.channels as u32 & 0xF) << 24
            | (VERSION as u32) << 28;
        let w1 = self.sequence as u32 | (self.flags as u32) << 16;
        let mut b = [0; HEADER];
        b[0..4].copy_from_slice(&w0.to_le_bytes());
        b[4..8].copy_from_slice(&w1.to_le_bytes());
        b[8..16].copy_from_slice(&self.time.to_le_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Result<Header, Error> {
        if b.len() < HEADER {
            return Err(Error::Short(b.len()));
        }
        let w0 = u32::from_le_bytes(b[0..4].try_into().unwrap());
        let w1 = u32::from_le_bytes(b[4..8].try_into().unwrap());
        let version = (w0 >> 28) as u8;
        if version != VERSION {
            return Err(Error::Version(version));
        }
        let kind = match (w0 >> 16) & 0xF {
            0 => Kind::Rx,
            1 => Kind::Tx,
            2 => Kind::Command,
            3 => Kind::Result,
            4 => Kind::Event,
            k => return Err(Error::Kind(k as u8)),
        };
        let format = match (w0 >> 20) & 0xF {
            0 => Format::None,
            1 => Format::Sc16,
            2 => Format::Sc12,
            f => return Err(Error::Format(f as u8)),
        };
        let length = w0 as u16;
        if (length as usize) < HEADER || length as usize > DATA_BUFFER {
            return Err(Error::Length(length));
        }
        let flags = (w1 >> 16) as u16;
        if flags & !flag::ALL != 0 {
            return Err(Error::Flags(flags));
        }
        Ok(Header {
            length,
            kind,
            format,
            channels: ((w0 >> 24) & 0xF) as u8,
            sequence: w1 as u16,
            flags,
            time: u64::from_le_bytes(b[8..16].try_into().unwrap()),
        })
    }
}

/// Bytes actually transferred for a packet of `length` meaningful bytes on
/// an endpoint with DMA buffer `buffer` (PROTOCOL.md section 1):
/// `buffer` if the packet fills it, else the length rounded up to 4 bytes,
/// plus 4 more if that is a multiple of 1024 (the FX3 sends no zero-length
/// packet, so such a transfer would not end).
pub fn transfer_size(length: usize, buffer: usize) -> usize {
    if length == buffer {
        return buffer;
    }
    let words = length.div_ceil(4) * 4;
    words + if words.is_multiple_of(1024) { 4 } else { 0 }
}

/// Samples lost between two consecutive packets of one stream:
/// `time - (previous time + sample times in the previous packet)`.
pub fn lost(previous_time: u64, previous_times: usize, time: u64) -> i64 {
    time.wrapping_sub(previous_time.wrapping_add(previous_times as u64)) as i64
}

// -- samples ------------------------------------------------------------------

/// sc12: value v occupies bits [12 v, 12 v + 12) of the little-endian
/// byte stream, low bit first; two values make three bytes.
pub fn pack_sc12(values: &[i16], out: &mut [u8]) {
    assert!(values.len().is_multiple_of(2) && out.len() >= values.len() / 2 * 3);
    for (pair, b) in values.as_chunks::<2>().0.iter().zip(out.as_chunks_mut::<3>().0) {
        let (a, c) = (pair[0] as u16 & 0xFFF, pair[1] as u16 & 0xFFF);
        b[0] = a as u8;
        b[1] = (a >> 8) as u8 | (c << 4) as u8;
        b[2] = (c >> 4) as u8;
    }
}

/// Inverse of `pack_sc12`; each 12-bit field is sign-extended.
pub fn unpack_sc12(bytes: &[u8], out: &mut [i16]) {
    assert!(bytes.len().is_multiple_of(3) && out.len() >= bytes.len() / 3 * 2);
    let sext = |x: u16| ((x << 4) as i16) >> 4;
    for (b, pair) in bytes.as_chunks::<3>().0.iter().zip(out.as_chunks_mut::<2>().0) {
        pair[0] = sext(b[0] as u16 | (b[1] as u16 & 0xF) << 8);
        pair[1] = sext((b[1] as u16) >> 4 | (b[2] as u16) << 4);
    }
}

/// sc16: each value the 16-bit word c << 4 (full scale 32768).
pub fn pack_sc16(values: &[i16], out: &mut [u8]) {
    assert!(out.len() >= 2 * values.len());
    for (v, b) in values.iter().zip(out.as_chunks_mut::<2>().0) {
        b.copy_from_slice(&(v << 4).to_le_bytes());
    }
}

/// Inverse of `pack_sc16`: c = word >> 4 (arithmetic shift).
pub fn unpack_sc16(bytes: &[u8], out: &mut [i16]) {
    assert!(bytes.len().is_multiple_of(2) && out.len() >= bytes.len() / 2);
    for (b, v) in bytes.as_chunks::<2>().0.iter().zip(out.iter_mut()) {
        *v = i16::from_le_bytes(*b) >> 4;
    }
}

// -- commands, results, events --------------------------------------------------

/// SPI device numbers of the SPI operation.
pub const SPI_AD9361: u8 = 0;
pub const SPI_ADF4001: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// Register `addr` := `data`.
    Write { addr: u16, data: u32 },
    /// Value of register `addr`.
    Read { addr: u16 },
    /// Shift `word[23:0]` out to `device`, MSB first; result: 8 bits read back.
    Spi { device: u8, word: u32 },
    /// Wait `us` microseconds.
    Wait { us: u32 },
    /// Repeat the previous Read or Spi until `(result & mask) == value`, for
    /// at most `ms` milliseconds.
    Poll { mask: u16, value: u16, ms: u8 },
    /// Hold the following operations until time `time` (32 bits are sent; the
    /// FPGA resolves them with `resolve_time`).
    At { time: u64 },
}

impl Op {
    fn encode(&self) -> [u8; 8] {
        let (opcode, arg, addr, data): (u32, u32, u32, u32) = match *self {
            Op::Write { addr, data } => (1, 0, addr as u32, data),
            Op::Read { addr } => (2, 0, addr as u32, 0),
            Op::Spi { device, word } => (3, device as u32, 0, word & 0xFF_FFFF),
            Op::Wait { us } => (4, 0, 0, us),
            Op::Poll { mask, value, ms } => (5, ms as u32, 0, (mask as u32) << 16 | value as u32),
            Op::At { time } => (6, 0, 0, time as u32),
        };
        let a = opcode << 24 | arg << 16 | addr;
        let mut b = [0; 8];
        b[0..4].copy_from_slice(&a.to_le_bytes());
        b[4..8].copy_from_slice(&data.to_le_bytes());
        b
    }
}

/// A command packet, padded to its transfer size.
pub fn command(sequence: u16, ops: &[Op]) -> Result<Vec<u8>, Error> {
    if ops.len() > MAX_OPS {
        return Err(Error::TooManyOps(ops.len()));
    }
    let length = HEADER + 8 * ops.len();
    let header = Header {
        length: length as u16,
        kind: Kind::Command,
        format: Format::None,
        channels: 0,
        sequence,
        flags: 0,
        time: 0,
    };
    let mut p = Vec::with_capacity(transfer_size(length, CONTROL_BUFFER));
    p.extend_from_slice(&header.encode());
    for op in ops {
        p.extend_from_slice(&op.encode());
    }
    p.resize(transfer_size(length, CONTROL_BUFFER), 0);
    Ok(p)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Ok,
    Timeout,
    Late,
    UnknownOp,
    Other(u8),
}

/// One operation's result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Reply {
    pub opcode: u8,
    pub status: Status,
    pub addr: u16,
    pub data: u32,
}

/// The results in a result packet's payload.
pub fn replies(payload: &[u8]) -> Vec<Reply> {
    payload
        .as_chunks::<8>()
        .0
        .iter()
        .map(|b| {
            let a = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
            Reply {
                opcode: (a >> 24) as u8,
                status: match (a >> 16) as u8 {
                    0 => Status::Ok,
                    1 => Status::Timeout,
                    2 => Status::Late,
                    3 => Status::UnknownOp,
                    s => Status::Other(s),
                },
                addr: a as u16,
                data: u32::from_le_bytes([b[4], b[5], b[6], b[7]]),
            }
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventCode {
    Overflow,
    Underflow,
    Late,
    SeqError,
    BurstAck,
    BadPacket,
    Other(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub code: EventCode,
    pub channels: u8,
    /// Samples dropped, bursts or packets, by code.
    pub count: u32,
    pub time: u64,
}

/// The events in an event packet's payload.
pub fn events(payload: &[u8]) -> Vec<Event> {
    payload
        .as_chunks::<16>()
        .0
        .iter()
        .map(|b| Event {
            code: match b[0] {
                1 => EventCode::Overflow,
                2 => EventCode::Underflow,
                3 => EventCode::Late,
                4 => EventCode::SeqError,
                5 => EventCode::BurstAck,
                6 => EventCode::BadPacket,
                c => EventCode::Other(c),
            },
            channels: b[1],
            count: u32::from_le_bytes([b[4], b[5], b[6], b[7]]),
            time: u64::from_le_bytes([b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]]),
        })
        .collect()
}

/// The time an At operation means: the t with t mod 2^32 = `bits` and
/// t - now in [-2^31, 2^31). The FPGA computes the same.
pub fn resolve_time(now: u64, bits: u32) -> u64 {
    now.wrapping_add(bits.wrapping_sub(now as u32) as i32 as i64 as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_holds_whole_sample_times() {
        assert_eq!(PAYLOAD, 16 * 3 * 11 * 31);
        for f in [Format::Sc16, Format::Sc12] {
            for ch in [1, 2] {
                assert_eq!(PAYLOAD % f.bytes_per_time(ch), 0, "{f:?} x {ch}");
            }
        }
        assert_eq!(Format::Sc16.times_per_packet(1), 4092);
        assert_eq!(Format::Sc16.times_per_packet(2), 2046);
        assert_eq!(Format::Sc12.times_per_packet(1), 5456);
        assert_eq!(Format::Sc12.times_per_packet(2), 2728);
        assert_eq!(MAX_OPS, 126);
    }

    #[test]
    fn header_round_trip_and_rejects() {
        let h = Header {
            length: 16_384,
            kind: Kind::Rx,
            format: Format::Sc12,
            channels: 0b11,
            sequence: 0xBEEF,
            flags: flag::HAS_TIME | flag::OVERFLOW,
            time: 0x0123_4567_89AB_CDEF,
        };
        assert_eq!(Header::decode(&h.encode()), Ok(h));
        let mut b = h.encode();
        b[3] = 0x20 | (b[3] & 0x0F); // version 2
        assert_eq!(Header::decode(&b), Err(Error::Version(2)));
        let mut b = h.encode();
        b[2] = 0x07 | (b[2] & 0xF0); // kind 7
        assert_eq!(Header::decode(&b), Err(Error::Kind(7)));
        let mut b = h.encode();
        b[7] |= 0x80; // undefined flag
        assert!(matches!(Header::decode(&b), Err(Error::Flags(_))));
        assert_eq!(Header::decode(&b[..8]), Err(Error::Short(8)));
    }

    #[test]
    fn transfer_size_never_a_short_multiple_of_1024() {
        for buffer in [DATA_BUFFER, CONTROL_BUFFER] {
            for length in HEADER..=buffer {
                let s = transfer_size(length, buffer);
                assert!(s >= length && s - length < 8 && s.is_multiple_of(4));
                assert!(s == buffer || !s.is_multiple_of(1024), "length {length}: {s}");
            }
        }
    }

    #[test]
    fn sc12_bit_layout() {
        // value 0 = 0x123 in bits 0..12, value 1 = 0x456 in bits 12..24
        let mut b = [0; 3];
        pack_sc12(&[0x123, 0x456], &mut b);
        assert_eq!(b, [0x23, 0x61, 0x45]);
    }

    #[test]
    fn sc12_round_trip_every_code() {
        let codes: Vec<i16> = (-2048..=2047).collect();
        for shift in [0, 1] {
            // every code in both positions of a pair
            let vals: Vec<i16> = codes.iter().flat_map(|&c| if shift == 0 { [c, -c.max(-2047)] } else { [7, c] }).collect();
            let mut bytes = vec![0; vals.len() / 2 * 3];
            pack_sc12(&vals, &mut bytes);
            let mut back = vec![0; vals.len()];
            unpack_sc12(&bytes, &mut back);
            assert_eq!(back, vals);
        }
    }

    #[test]
    fn sc16_round_trip_every_code() {
        let vals: Vec<i16> = (-2048..=2047).collect();
        let mut bytes = vec![0; 2 * vals.len()];
        pack_sc16(&vals, &mut bytes);
        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), -32768); // -2048 << 4: full scale
        let mut back = vec![0; vals.len()];
        unpack_sc16(&bytes, &mut back);
        assert_eq!(back, vals);
    }

    #[test]
    fn command_packets_fit_one_control_buffer() {
        let ops = vec![Op::Read { addr: 3 }; MAX_OPS];
        assert_eq!(command(1, &ops).unwrap().len(), CONTROL_BUFFER);
        assert_eq!(command(1, &[Op::Read { addr: 3 }; MAX_OPS + 1]), Err(Error::TooManyOps(MAX_OPS + 1)));
        let p = command(7, &[Op::Spi { device: SPI_AD9361, word: 0x80_37_00 }]).unwrap();
        let h = Header::decode(&p).unwrap();
        assert_eq!((h.kind, h.sequence, h.length), (Kind::Command, 7, 24));
        assert_eq!(&p[16..24], &[0x00, 0x00, 0x00, 0x03, 0x00, 0x37, 0x80, 0x00]);
    }

    #[test]
    fn at_time_resolves_within_half_the_wrap() {
        let now = 5u64 << 32 | 0x8000_0000;
        for t in [now, now + 1, now + (1 << 31) - 1, now - (1 << 31)] {
            assert_eq!(resolve_time(now, t as u32), t);
        }
        // 2^31 ahead is the same 32 bits as 2^31 behind: resolved as behind
        assert_eq!(resolve_time(now, (now + (1 << 31)) as u32), now - (1 << 31));
    }

    #[test]
    fn lost_samples_from_time_gap() {
        assert_eq!(lost(1000, 2728, 3728), 0);
        assert_eq!(lost(1000, 2728, 3728 + 2728 * 3), 8184);
    }
}
