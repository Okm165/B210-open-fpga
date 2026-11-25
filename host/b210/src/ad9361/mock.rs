// SPDX-License-Identifier: GPL-3.0-or-later

//! A recording [`Bus`] for tests: every write, read, wait and poll is logged
//! in order, and a read returns what a rule says, given the register values
//! written so far.
//!
//! [`settled`] is the rule of a chip whose every calibration has finished
//! and every PLL is locked. The golden-trace harness
//! (tests/ad9361_golden/harness.cpp) answers UHD's reads with the same rule,
//! so the same driver decisions follow on both sides.

use super::{Bus, Error, Result};

/// One bus access, as the driver issued it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Write { reg: u16, value: u8 },
    /// A read: by `Bus::read`, or the first read of a `Bus::poll`.
    Read { reg: u16, value: u8 },
    Wait { us: u32 },
    /// The condition of a poll, after its `Read`, and whether that read met it.
    Poll { mask: u8, want: u8, ms: u32, ok: bool },
}

pub type Rule = Box<dyn FnMut(u16, &[u8; 1024]) -> u8>;

pub struct Mock {
    pub log: Vec<Access>,
    /// The last value written to each register (0 before any write, except
    /// 0x0A3: 0x4A, see `settled`).
    pub regs: [u8; 1024],
    /// Queue runs that carried operations: the command packets a USB binding
    /// would send (before splitting at 126 operations).
    pub round_trips: usize,
    queued: usize,
    rule: Rule,
    failed: Option<Error>,
}

impl Mock {
    pub fn new(rule: impl FnMut(u16, &[u8; 1024]) -> u8 + 'static) -> Mock {
        let mut regs = [0; 1024];
        regs[0x0A3] = 0x4A;
        Mock { log: Vec::new(), regs, round_trips: 0, queued: 0, rule: Box::new(rule), failed: None }
    }

    /// A mock answering with [`settled`].
    pub fn settled() -> Mock {
        Mock::new(settled)
    }

    fn value(&mut self, reg: u16) -> u8 {
        let value = (self.rule)(reg, &self.regs);
        self.log.push(Access::Read { reg, value });
        value
    }

    fn run(&mut self) -> Result<()> {
        if self.queued > 0 {
            self.round_trips += 1;
            self.queued = 0;
        }
        self.failed.take().map_or(Ok(()), Err)
    }
}

impl Bus for Mock {
    fn write(&mut self, reg: u16, value: u8) -> Result<()> {
        self.queued += 1;
        self.regs[reg as usize] = value;
        self.log.push(Access::Write { reg, value });
        Ok(())
    }

    fn wait(&mut self, us: u32) -> Result<()> {
        self.queued += 1;
        self.log.push(Access::Wait { us });
        Ok(())
    }

    fn poll(&mut self, reg: u16, mask: u8, want: u8, ms: u32) -> Result<()> {
        self.queued += 1;
        let value = self.value(reg);
        let ok = value & mask == want;
        self.log.push(Access::Poll { mask, want, ms, ok });
        if !ok && self.failed.is_none() {
            self.failed = Some(Error::Poll { reg, mask, want, value });
        }
        Ok(())
    }

    fn read<const N: usize>(&mut self, regs: [u16; N]) -> Result<[u8; N]> {
        self.queued += 1;
        self.run()?;
        Ok(regs.map(|reg| self.value(reg)))
    }

    fn flush(&mut self) -> Result<()> {
        self.run()
    }
}

/// A chip at rest: what each register reads, given the values written.
///
/// | register | reads |
/// | --- | --- |
/// | 0x037 product id | 0x0A: product 0x08, revision 2, as this board reads (docs/STATUS.md) |
/// | 0x017 ENSM state | from the last 0x014 write: bit 5 (force TX on) FDD 0x0A; else bit 0 or 2 (to / force ALERT) ALERT 0x05; else 0x00 |
/// | 0x016 calibrations | 0x00: all finished |
/// | 0x05E BBPLL | 0x80: locked |
/// | 0x244, 0x284 charge pump calibrations | 0x80: done |
/// | 0x247, 0x287 RF PLLs | 0x02: locked |
/// | 0x1EB, 0x1EC, 0x1E6 rx filter C and R | (0x1FB x 3 + 1) & 0x3F, 0x1FC & 0x7F, (0x1F8 & 7) or 1: they follow the bandwidth written, so both TIA branches occur |
/// | any other | the last value written (0x0A3 starts at 0x4A: the TX quadrature NCO bits 7:6 = 1) |
pub fn settled(reg: u16, regs: &[u8; 1024]) -> u8 {
    match reg {
        0x037 => 0x0A,
        0x017 => {
            let ctrl = regs[0x014];
            if ctrl & 0x20 != 0 {
                0x0A
            } else if ctrl & 0x05 != 0 {
                0x05
            } else {
                0x00
            }
        }
        0x016 => 0x00,
        0x05E | 0x244 | 0x284 => 0x80,
        0x247 | 0x287 => 0x02,
        0x1EB => regs[0x1FB].wrapping_mul(3).wrapping_add(1) & 0x3F,
        0x1EC => regs[0x1FC] & 0x7F,
        0x1E6 => regs[0x1F8] & 0x07 | 0x01,
        _ => regs[reg as usize],
    }
}
