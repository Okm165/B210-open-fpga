//! Register addresses (docs/PROTOCOL.md section 6, fpga/rtl/regs.v).

pub const ID: u16 = 0x000;
pub const VERSION: u16 = 0x001;
pub const BUILD: u16 = 0x002;
pub const SCRATCH: u16 = 0x003;
pub const STATUS: u16 = 0x004;
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
/// Event counter of code k (PROTOCOL.md 5) at EVENTS + k - 1.
pub const EVENTS: u16 = 0x080;
pub const RX_LOST: u16 = 0x086;
pub const CMD_DROPPED: u16 = 0x087;
pub const TEST: u16 = 0x0F0;
pub const TEST_DIV: u16 = 0x0F1;

/// `id`: "B210".
pub const ID_VALUE: u32 = 0x4232_3130;

/// rx_ctrl bits.
pub mod rx {
    pub const START: u32 = 1 << 0;
    pub const STOP: u32 = 1 << 1;
    pub const AT_TIME: u32 = 1 << 3;
    /// The configuration word: format (1 sc16, 2 sc12) and channel mask.
    pub fn config(format: u32, channels: u32) -> u32 {
        format << 4 | channels << 8
    }
}

/// test: the rx source.
pub mod test {
    pub const RADIO: u32 = 0;
    pub const PATTERN: u32 = 1;
    pub const LOOPBACK: u32 = 2;

    /// The pattern value k (I0, Q0, I1, Q1) of sample time t, as a 12-bit
    /// two's-complement code: I0 = t, Q0 = !t, I1 = 7 t, Q1 = 13 t + 5,
    /// each modulo 2^12 (fpga/rtl/sample_core.v).
    pub fn pattern(t: u64, k: usize) -> i16 {
        let v = match k {
            0 => t,
            1 => !t,
            2 => t.wrapping_mul(7),
            _ => t.wrapping_mul(13).wrapping_add(5),
        } as u16 & 0xFFF;
        ((v << 4) as i16) >> 4
    }
}

#[cfg(test)]
mod tests {
    use super::test::pattern;

    #[test]
    fn pattern_is_sample_core_s() {
        // computed independently (12-bit arithmetic, two's complement)
        assert_eq!([0, 1, 2, 3].map(|k| pattern(0x123, k)), [291, -292, 2037, -308]);
        assert_eq!([0, 1, 2, 3].map(|k| pattern((1 << 40) + 4095, k)), [-1, 0, -7, -8]);
    }
}
