//! The AD9361's BIST pseudo-random sequence, checked against what the chip
//! must have sent (register 0x3F4, Tone/PRBS bit clear, injected at the rx
//! data port; ADI "AD936x Built-In Self-Test (BIST)" FAQ).
//!
//! The generator is a 16-bit shift register whose next bit is the XOR of 14
//! of its stages, feeding bit 15 while the register shifts down:
//!
//!   b' = b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6 ^ b7 ^ b8 ^ b9 ^ b10 ^ b11 ^ b13 ^ b14
//!   b15 .. b0 := b' , b15 .. b1
//!
//! which is the 16th-order polynomial with exponents {2, 3, 5, 6, ..., 16}
//! (ADI's FAQ states it as "polynomial - 16 15 14 13 12 11 10 9 8 7 6 5 3 2").
//!
//! The data port carries one bit of that register per sample time in bit 0
//! of each 12-bit word, so the received word stream, read at bit 0, obeys
//!
//!   s[n] = s[n-2] ^ s[n-3] ^ s[n-5] ^ ... ^ s[n-16]
//!
//! for every n >= 16. Berlekamp-Massey on a board capture gives linear
//! complexity exactly 16 with that same tap set, on both the I and the Q
//! words, so this is a check of the received bits and nothing assumed about
//! phase: a stream that is shifted (a wrong number of samples) still obeys
//! it, a stream with one wrong bit does not, from that bit on.
//!
//! An all-zero stream obeys the recurrence too (its polynomial has no
//! constant term to break the fixed point), so the checker also counts ones:
//! a real PRBS has about half, and `ok` requires the share to be near that.

/// The earlier bits XORed into the next one, as distances back from it: the
/// polynomial's exponents {2, 3, 5, ..., 16} (the FAQ's register taps
/// 0..11, 13, 14 are its stages; each is one further back once shifted out).
pub const TAPS: [u32; 14] = [2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

/// Bits of history the recurrence needs.
pub const DEGREE: u32 = 16;

/// Share of ones a real PRBS keeps; outside this the stream is degenerate.
pub const ONES_RANGE: (f64, f64) = (0.40, 0.60);

/// Accumulates the received bit stream and counts failures of the recurrence.
#[derive(Clone, Debug, Default)]
pub struct Checker {
    /// The last `DEGREE` bits of each word position (I0 Q0 I1 Q1), bit 0
    /// the most recent; the chip runs one register per data line.
    history: [u32; 4],
    /// Bits received per position: a position is checked only once its
    /// history holds `DEGREE` real bits.
    seen: [u64; 4],
    /// Bits checked so far (each needs `DEGREE` bits before it).
    bits: u64,
    ones: u64,
    mismatches: u64,
}

impl Checker {
    /// Feed one sample time's words (I0 Q0 I1 Q1, the first `2 x channels`
    /// used): bit 0 of each word is the next bit of its channel's sequence.
    /// Each channel has its own register (I and Q are separate sequences),
    /// so the checker keeps one per word position.
    pub fn feed(&mut self, words: &[i16], channels: usize) {
        let nv = 2 * channels;              // words per sample time
        for frame in words.chunks(nv) {
            for (pos, word) in frame.iter().enumerate() {
                self.bit(pos, (word & 1) as u32);
            }
        }
    }

    /// One bit of the sequence at word position `pos`.
    fn bit(&mut self, pos: usize, b: u32) {
        self.ones += b as u64;
        self.seen[pos] += 1;
        if self.seen[pos] > DEGREE as u64 {
            let mut predicted = 0;
            for tap in TAPS {
                // history bit 0 is the previous sample: distance d is bit d-1
                predicted ^= (self.history[pos] >> (tap - 1)) & 1;
            }
            if predicted != b {
                self.mismatches += 1;
            }
        }
        self.bits += 1;
        self.history[pos] = (self.history[pos] << 1 | b) & ((1 << DEGREE) - 1);
    }

    pub fn bits(&self) -> u64 {
        self.bits
    }

    pub fn mismatches(&self) -> u64 {
        self.mismatches
    }

    /// Share of ones, 0 ..= 1.
    pub fn ones(&self) -> f64 {
        self.ones as f64 / self.bits.max(1) as f64
    }

    /// No mismatch and not a degenerate stream.
    pub fn ok(&self) -> bool {
        self.mismatches == 0
            && self.bits > DEGREE as u64
            && (ONES_RANGE.0..=ONES_RANGE.1).contains(&self.ones())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ADI's generator, as the FAQ writes it.
    fn sequence(n: usize) -> Vec<i16> {
        let mut r: u32 = 0x0A54;
        (0..n)
            .map(|_| {
                let out = (r & 1) as i16;
                let b = (r & 1) ^ (r >> 1 & 1) ^ (r >> 2 & 1) ^ (r >> 3 & 1)
                    ^ (r >> 4 & 1) ^ (r >> 5 & 1) ^ (r >> 6 & 1) ^ (r >> 7 & 1)
                    ^ (r >> 8 & 1) ^ (r >> 9 & 1) ^ (r >> 10 & 1) ^ (r >> 11 & 1)
                    ^ (r >> 13 & 1) ^ (r >> 14 & 1);
                r = (b << 15) | (r >> 1);
                out
            })
            .collect()
    }

    fn feed(bits: &[i16]) -> Checker {
        let mut c = Checker::default();
        for &b in bits {
            c.bit(0, b as u32);
        }
        c
    }

    #[test]
    fn the_chips_sequence_passes() {
        let c = feed(&sequence(1 << 16));
        assert_eq!(c.mismatches(), 0);
        assert!(c.ok(), "ones {:.3}", c.ones());
        // about half ones, as a 16-bit maximal-length sequence has
        assert!((c.ones() - 0.5).abs() < 0.01, "ones {:.4}", c.ones());
    }

    #[test]
    fn one_wrong_bit_fails_from_there_on() {
        let mut bits = sequence(2000);
        bits[100] ^= 1;
        let c = feed(&bits);
        // the error itself and the predictions still using it: about the
        // register's length, and certainly not zero
        assert!((10..=20).contains(&c.mismatches()), "mismatches {}", c.mismatches());
        assert!(!c.ok());
    }

    #[test]
    fn a_shifted_sequence_still_passes_but_a_stuck_stream_does_not() {
        let bits = sequence(2000);
        // a stream that starts later (a wrong sample alignment) still obeys
        // the recurrence; rotating the prefix instead would break it at the
        // wrap, which is not a time shift
        assert_eq!(feed(&bits[7..]).mismatches(), 0);
        assert!(!feed(&[0; 2000]).ok(), "all zeros must not pass");
        assert!(!feed(&[1; 2000]).ok(), "all ones must not pass");
        let random: Vec<i16> = (0..2000).map(|k| ((k * 7919 + 13) % 2) as i16).collect();
        assert!(!feed(&random).ok());
    }

    #[test]
    fn words_feed_each_channel_separately() {
        // the same sequence on both channels of one sample time must pass
        let bits = sequence(1000);
        // one packet of many sample times, four words each: every position
        // gets the full sequence and every sample time is consumed
        let words: Vec<i16> = bits.iter().flat_map(|&b| [b, b, b, b]).collect();
        let mut c = Checker::default();
        c.feed(&words, 2);
        assert_eq!(c.bits(), 4 * 1000);
        assert!(c.ok(), "mismatches {} ones {:.3}", c.mismatches(), c.ones());
    }
}
