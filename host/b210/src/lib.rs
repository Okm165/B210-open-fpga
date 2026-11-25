//! Driver for the B210 board running this repository's FPGA image.
//! The wire format is defined in docs/PROTOCOL.md; `proto` implements it,
//! `usb` carries it, `regs` names the registers.
pub mod config;
pub mod ad9361;
pub mod device;
pub mod dsp;
pub mod iq;
pub mod quality;
pub mod proto;
pub mod regs;
pub mod usb;
