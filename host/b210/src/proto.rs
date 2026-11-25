//! The wire format of docs/PROTOCOL.md, both directions.
//!
//! Units throughout: lengths in bytes; `time` in ticks (sample periods at
//! the configured rate); sample values are the AD9361's 12-bit
//! two's-complement codes c in [-2048, 2047], held in `i16`.

use std::ops::Range;

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
/// The bus's data ceiling, bytes/s (section 3: 32 bits x 100 MHz): the
/// stream rate x bytes per sample time, rx and tx summed, must stay below it.
pub const BUS_BYTES_PER_SEC: f64 = 4.0 * 100e6;
/// The least rx packet the FPGA makes, sample times (section 3, rx_spp).
pub const MIN_SPP: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Rx = 0,
    Tx = 1,
    Command = 2,
    Result = 3,
    Event = 4,
}

/// Samples on the wire (section 3); a header's format 0 (no samples) is
/// `Header::format == None`. In a configuration file and on the command
/// line: "sc16", "sc12".
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Deserialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    /// Each value c << 4 in 16 bits: 4 bytes per complex sample.
    Sc16 = 1,
    /// Each value in 12 bits: 3 bytes per complex sample.
    Sc12 = 2,
}

impl std::fmt::Display for Format {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Format::Sc16 => "sc16",
            Format::Sc12 => "sc12",
        })
    }
}

impl Format {
    /// Bytes per sample time of `count` channels (I and Q each).
    pub fn bytes_per_time(self, count: usize) -> usize {
        match self {
            Format::Sc16 => 4 * count,
            Format::Sc12 => 3 * count,
        }
    }

    /// Sample times in a full data packet of `count` channels (count >= 1).
    pub fn full_spp(self, count: usize) -> usize {
        PAYLOAD / self.bytes_per_time(count)
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
    /// None: format 0, a packet without samples.
    pub format: Option<Format>,
    /// Channel mask: bit c set, channel c present.
    pub mask: u8,
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
            | self.format.map_or(0, |f| f as u32) << 20
            | (self.mask as u32 & 0xF) << 24
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
            0 => None,
            1 => Some(Format::Sc16),
            2 => Some(Format::Sc12),
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
            mask: ((w0 >> 24) & 0xF) as u8,
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

/// The complete packets in `stream`, a byte stream from an endpoint with
/// DMA buffer `buffer`: ranges of their wire bytes, a packet's size being
/// S(L) of its header's length L (section 1). Everything after the last
/// range is an incomplete packet, to be completed by the next transfer.
/// Pure: the result depends only on the concatenated stream, not on how it
/// was split into transfers. A header that does not decode is an error for
/// the whole stream: there is no length to resynchronise on.
pub fn packets(stream: &[u8], buffer: usize) -> Result<Vec<Range<usize>>, Error> {
    let mut out = Vec::new();
    let mut at = 0;
    while stream.len() - at >= HEADER {
        let h = Header::decode(&stream[at..at + HEADER])?;
        let size = transfer_size(h.length as usize, buffer);
        if size > buffer {
            // a length just below the buffer that rounds up to a multiple of
            // 1024 is padded by 4 and no longer fits the buffer: no packet
            // can have such a length
            return Err(Error::Length(h.length));
        }
        if at + size > stream.len() {
            break;
        }
        out.push(at..at + size);
        at += size;
    }
    Ok(out)
}

/// Samples lost between two consecutive packets of one stream:
/// `time - (previous time + sample times in the previous packet)`.
pub fn lost(previous_time: u64, previous_times: usize, time: u64) -> i64 {
    time.wrapping_sub(previous_time.wrapping_add(previous_times as u64)) as i64
}

// -- samples ------------------------------------------------------------------

/// The 12-bit two's-complement code in the low 12 bits of `x`, sign-extended.
pub fn sext12(x: u16) -> i16 {
    ((x << 4) as i16) >> 4
}

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
    for (b, pair) in bytes.as_chunks::<3>().0.iter().zip(out.as_chunks_mut::<2>().0) {
        pair[0] = sext12(b[0] as u16 | (b[1] as u16 & 0xF) << 8);
        pair[1] = sext12((b[1] as u16) >> 4 | (b[2] as u16) << 4);
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

/// Unpack `bytes` of `format` into `out` (`unpack_sc16` or `unpack_sc12`).
pub fn unpack(format: Format, bytes: &[u8], out: &mut [i16]) {
    match format {
        Format::Sc16 => unpack_sc16(bytes, out),
        Format::Sc12 => unpack_sc12(bytes, out),
    }
}

/// A data packet in `out`: the header `h` (its length and kind are set
/// here: kind Tx; its format must be set) and the values of whole sample
/// times (I0 Q0, or I0 Q0 I1 Q1 per time), packed in `h.format`,
/// zero-padded to the transfer size, which is returned.
pub fn tx_packet(mut h: Header, values: &[i16], out: &mut [u8]) -> usize {
    let format = h.format.expect("a data packet has a format");
    let per_time = 2 * h.mask.count_ones() as usize;
    assert!(per_time > 0 && values.len().is_multiple_of(per_time));
    let length = HEADER + values.len() / 2 * format.bytes_per_time(1);
    assert!(length <= DATA_BUFFER && out.len() >= DATA_BUFFER);
    h.length = length as u16;
    h.kind = Kind::Tx;
    out[..HEADER].copy_from_slice(&h.encode());
    match format {
        Format::Sc16 => pack_sc16(values, &mut out[HEADER..length]),
        Format::Sc12 => pack_sc12(values, &mut out[HEADER..length]),
    }
    let size = transfer_size(length, DATA_BUFFER);
    out[length..size].fill(0);
    size
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
    /// Repeat the last Read or Spi the FPGA executed (in this packet or an
    /// earlier one) until `(result[15:0] & mask) == value`, for at most `ms`
    /// milliseconds (0: one try).
    Poll { mask: u16, value: u16, ms: u8 },
}

impl Op {
    fn encode(&self) -> [u8; 8] {
        let (opcode, arg, addr, data): (u32, u32, u32, u32) = match *self {
            Op::Write { addr, data } => (1, 0, addr as u32, data),
            Op::Read { addr } => (2, 0, addr as u32, 0),
            Op::Spi { device, word } => (3, device as u32, 0, word & 0xFF_FFFF),
            Op::Wait { us } => (4, 0, 0, us),
            Op::Poll { mask, value, ms } => (5, ms as u32, 0, (mask as u32) << 16 | value as u32),
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
        format: None,
        mask: 0,
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
    UnknownOp,
    Other(u8),
}

impl Status {
    /// Status 0 only. Status 1 is a legitimate result of a POLL (the value
    /// never matched within the time limit), which `usb::Ctrl::exec` exposes
    /// to the caller; only `read` and `write`, whose operations have no
    /// timeout result, turn any non-zero status into an error.
    pub fn is_ok(self) -> bool {
        matches!(self, Status::Ok)
    }
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Status::Ok => f.write_str("ok"),
            Status::Timeout => f.write_str("timeout (poll)"),
            Status::UnknownOp => f.write_str("unknown opcode/argument"),
            Status::Other(code) => write!(f, "unknown status {code}"),
        }
    }
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
    pub mask: u8,
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
            mask: b[1],
            count: u32::from_le_bytes([b[4], b[5], b[6], b[7]]),
            time: u64::from_le_bytes([b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]]),
        })
        .collect()
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
        assert_eq!(Format::Sc16.full_spp(1), 4092);
        assert_eq!(Format::Sc16.full_spp(2), 2046);
        assert_eq!(Format::Sc12.full_spp(1), 5456);
        assert_eq!(Format::Sc12.full_spp(2), 2728);
        assert_eq!(MAX_OPS, 126);
    }

    #[test]
    fn header_round_trip_and_rejects() {
        let h = Header {
            length: 16_384,
            kind: Kind::Rx,
            format: Some(Format::Sc12),
            mask: 0b11,
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
        let mut b = h.encode();
        b[2] = 0x30 | (b[2] & 0x0F); // format 3
        assert_eq!(Header::decode(&b), Err(Error::Format(3)));
        // format 0 is a packet without samples
        let none = Header { format: None, ..h };
        assert_eq!(Header::decode(&none.encode()), Ok(none));
        assert_eq!(none.encode()[2] >> 4, 0);
        // lengths below the header and above the data buffer
        for (length, ok) in [(15u16, false), (16, true), (16_384, true), (16_385, false), (0xFFFF, false)] {
            let r = Header::decode(&Header { length, ..h }.encode());
            assert_eq!(r.is_ok(), ok, "{length}");
            if !ok {
                assert_eq!(r, Err(Error::Length(length)));
            }
        }
    }

    #[test]
    fn operations_encode_as_section_4() {
        // word 0: opcode << 24 | arg << 16 | addr; word 1: data (little-endian)
        let words = |op: Op| {
            let b = op.encode();
            (u32::from_le_bytes(b[0..4].try_into().unwrap()), u32::from_le_bytes(b[4..8].try_into().unwrap()))
        };
        assert_eq!(words(Op::Write { addr: 0x3FF, data: 0xDEAD_BEEF }), (0x0100_03FF, 0xDEAD_BEEF));
        assert_eq!(words(Op::Read { addr: 0x086 }), (0x0200_0086, 0));
        assert_eq!(words(Op::Spi { device: SPI_ADF4001, word: 0xFF12_3456 }), (0x0301_0000, 0x12_3456));
        assert_eq!(words(Op::Wait { us: 20_000 }), (0x0400_0000, 20_000));
        assert_eq!(words(Op::Poll { mask: 0x80, value: 0x40, ms: 255 }), (0x05FF_0000, 0x0080_0040));
    }

    #[test]
    fn events_decode_as_section_5() {
        // code, mask, 2 reserved bytes, count, time; codes 1 .. 6 and one unknown
        let mut payload = Vec::new();
        for (code, count) in [(1u8, 7u32), (2, 1), (3, 2), (4, 3), (5, 1), (6, 9), (9, 4)] {
            payload.extend_from_slice(&[code, 0b10, 0, 0]);
            payload.extend_from_slice(&count.to_le_bytes());
            payload.extend_from_slice(&(0x1_0000_0000u64 + code as u64).to_le_bytes());
        }
        let e = events(&payload);
        let codes: Vec<EventCode> = e.iter().map(|e| e.code).collect();
        assert_eq!(codes, [EventCode::Overflow, EventCode::Underflow, EventCode::Late, EventCode::SeqError,
                           EventCode::BurstAck, EventCode::BadPacket, EventCode::Other(9)]);
        assert_eq!(e[0], Event { code: EventCode::Overflow, mask: 0b10, count: 7, time: 0x1_0000_0001 });
        assert_eq!(e[5].count, 9);
        // a trailing partial record is not an event
        assert_eq!(events(&payload[..16 + 15]).len(), 1);
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
    fn status_mapping_is_protocol_section_4() {
        // one result per status code; 2 (reserved) is no status of its own
        let mut payload = Vec::new();
        for status in [0u8, 1, 2, 3, 7] {
            let a = 2u32 << 24 | (status as u32) << 16 | 3;
            payload.extend_from_slice(&a.to_le_bytes());
            payload.extend_from_slice(&0x11u32.to_le_bytes());
        }
        let r: Vec<Status> = replies(&payload).iter().map(|r| r.status).collect();
        assert_eq!(r, [Status::Ok, Status::Timeout, Status::Other(2), Status::UnknownOp, Status::Other(7)]);
        // only status 0 counts as ok; a POLL timeout is a legitimate non-ok reply
        assert!(r[0].is_ok() && r[1..].iter().all(|s| !s.is_ok()));
    }

    #[test]
    fn tx_packet_full_and_short() {
        let mut out = vec![0xAA; DATA_BUFFER];
        for (format, ch, times) in [(Format::Sc12, 0b11u8, 2728), (Format::Sc16, 0b01, 4092), (Format::Sc16, 0b11, 128)] {
            let nv = 2 * ch.count_ones() as usize * times;
            let values: Vec<i16> = (0..nv).map(|i| ((i * 2654435761) >> 7) as i16 >> 4).collect();
            let h = Header { length: 0, kind: Kind::Rx, format: Some(format), mask: ch, sequence: 9,
                             flags: flag::START_OF_BURST | flag::HAS_TIME, time: 77 };
            let size = tx_packet(h, &values, &mut out);
            let d = Header::decode(&out).unwrap();
            assert_eq!((d.kind, d.format, d.mask, d.sequence, d.time), (Kind::Tx, Some(format), ch, 9, 77));
            assert_eq!(size, transfer_size(d.length as usize, DATA_BUFFER));
            let mut back = vec![0; nv];
            let body = &out[HEADER..d.length as usize];
            unpack(format, body, &mut back);
            assert_eq!(back, values);
            assert!(out[d.length as usize..size].iter().all(|&b| b == 0));
        }
    }

    fn header(length: u16, kind: Kind, sequence: u16) -> Header {
        Header {
            length,
            kind,
            format: None,
            mask: 0,
            sequence,
            flags: if kind == Kind::Event { flag::HAS_TIME } else { 0 },
            time: 0,
        }
    }

    /// A packet padded to its wire size S(L).
    fn packet(length: usize, kind: Kind, sequence: u16) -> Vec<u8> {
        let size = transfer_size(length, CONTROL_BUFFER);
        let mut p = vec![0u8; size];
        p[..HEADER].copy_from_slice(&header(length as u16, kind, sequence).encode());
        p
    }

    /// Feed `chunks` the way `usb` feeds EP8 transfers and return the packets it saw.
    fn split_chunks(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        let mut pending = Vec::new();
        let mut out = Vec::new();
        for chunk in chunks {
            pending.extend_from_slice(chunk);
            match packets(&pending, CONTROL_BUFFER) {
                Ok(frames) => {
                    let used = frames.last().map_or(0, |r| r.end);
                    for r in frames {
                        out.push(pending[r].to_vec());
                    }
                    pending.drain(..used);
                }
                Err(e) => panic!("{e:?}"),
            }
        }
        out
    }

    #[test]
    fn splitter_keeps_awkward_sizes_across_transfer_boundaries() {
        // A table with full 1024-byte packets, packets whose pad is 4 (none:
        // 1021..1023 are invalid on a control endpoint), header-only packets
        // and lengths on both sides of 1024.
        let lengths = [16usize, 20, 24, 1008, 1016, 1024, 16, 1024, 1008, 24];
        let mut stream = Vec::new();
        for (i, &len) in lengths.iter().enumerate() {
            let kind = if i % 2 == 0 { Kind::Result } else { Kind::Event };
            stream.extend_from_slice(&packet(len, kind, i as u16));
        }
        let all: Vec<Vec<u8>> = lengths
            .iter()
            .enumerate()
            .map(|(i, &len)| packet(len, if i % 2 == 0 { Kind::Result } else { Kind::Event }, i as u16))
            .collect();

        // The same stream cut in awkward places: an 8-byte and a 15-byte
        // first chunk split the first header in two; cuts at 1023/1024/1025
        // straddle a full packet; one byte at a time proves the leftover.
        let cuts: &[&[usize]] = &[
            &[8, 20, stream.len()],
            &[15, 16, stream.len()],
            &[0, 1, 1023, 1024, 1025, stream.len()],
            &[1024, 2048, 3 * 1024, stream.len()],
            &[16],
        ];
        for cuts in cuts {
            let mut chunks = Vec::new();
            let mut at = 0;
            for &cut in *cuts {
                chunks.push(&stream[at..cut]);
                at = cut;
            }
            if at < stream.len() {
                chunks.push(&stream[at..]);
            }
            assert_eq!(split_chunks(&chunks), all, "cuts {cuts:?}");
        }
        assert_eq!(split_chunks(&[&stream]), all);
    }

    #[test]
    fn splitter_waits_for_a_whole_header_and_a_whole_packet() {
        let p = packet(24, Kind::Result, 7);
        // A header split in two: 8 bytes, then the rest.
        assert!(split_chunks(&[&p[..8]]).is_empty());
        assert!(split_chunks(&[&p[..15]]).is_empty());
        assert_eq!(split_chunks(&[&p[..8], &p[8..]]), vec![p.clone()]);
        // 16 bytes is a whole header but not a whole packet.
        assert!(split_chunks(&[&p[..16]]).is_empty());
        // One byte short of the wire size: still pending, not a packet.
        assert!(split_chunks(&[&p[..p.len() - 1]]).is_empty());
        assert_eq!(split_chunks(&[&p[..p.len() - 1], &p[p.len() - 1..]]), vec![p]);
    }

    #[test]
    fn splitter_rejects_a_length_that_cannot_fit_the_control_buffer() {
        // L = 1021 rounds to 1024 and the rule adds 4, so S(L) = 1028 > 1024.
        let mut buf = vec![0u8; 1028];
        buf[..HEADER].copy_from_slice(&header(1021, Kind::Result, 1).encode());
        assert_eq!(packets(&buf, CONTROL_BUFFER), Err(Error::Length(1021)));
        // Negative control: the largest valid non-full length is 1016.
        let mut ok = vec![0u8; 1016];
        ok[..HEADER].copy_from_slice(&header(1016, Kind::Result, 1).encode());
        assert_eq!(packets(&ok, CONTROL_BUFFER).unwrap().len(), 1);
    }


    #[test]
    fn lost_samples_from_time_gap() {
        assert_eq!(lost(1000, 2728, 3728), 0);
        assert_eq!(lost(1000, 2728, 3728 + 2728 * 3), 8184);
    }
}
