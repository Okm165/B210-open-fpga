//! The board on USB: the stock FX3 firmware's vendor requests (FPGA load,
//! GPIF reset) and the four bulk endpoints of docs/PROTOCOL.md section 1.
//!
//! Each endpoint is alone on its interface (1 tx, 2 rx, 3 command, 4
//! result/event). An IN transfer of 16 384 bytes ends at the end of one FX3
//! buffer: full, or a short USB packet, which the transfer-size rule S(L)
//! guarantees for every shorter packet. So one IN transfer is one packet.
//!
//! FPGA load, the sequence of the firmware's vendor requests
//! (b200_main.c, b200_const.h):
//!   0x55 FPGA_CONFIG, wait for state 1 (ready for an image)
//!   0x02 FPGA_START,  wait for state 2 (configuring)
//!   0x12 FPGA_DATA,   the image in pieces of the control buffer (512 bytes)
//!   wait for state 4 (running), then 0x72 GPIF_RESET: the firmware starts
//!   its bus state machine only on that request.

use crate::proto::{self, Event, Header, Kind, Op, Reply};
use nusb::transfer::{Buffer, Bulk, ControlIn, ControlOut, ControlType, In, Out, Recipient, TransferError};
use nusb::{Endpoint, MaybeFuture};
use std::time::{Duration, Instant};

pub const VID: u16 = 0x2500;
pub const PID: u16 = 0x0020;

const VREQ_FPGA_START: u8 = 0x02;
const VREQ_FPGA_DATA: u8 = 0x12;
const VREQ_FPGA_CONFIG: u8 = 0x55;
const VREQ_GPIF_RESET: u8 = 0x72;
const VREQ_GET_STATUS: u8 = 0x83;
/// The firmware's control buffer at SuperSpeed.
const VREQ_CHUNK: usize = 512;

const STATE_FPGA_READY: u8 = 1;
const STATE_CONFIGURING: u8 = 2;
const STATE_RUNNING: u8 = 4;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("no B210 ({VID:04x}:{PID:04x}) on USB")]
    NotFound,
    #[error("USB: {0}")]
    Usb(#[from] nusb::Error),
    #[error("USB transfer: {0}")]
    Transfer(#[from] TransferError),
    #[error("FX3 firmware state {state} while waiting for {want}")]
    Fx3State { state: u8, want: u8 },
    #[error("protocol: {0:?}")]
    Proto(proto::Error),
    #[error("no result for command {0} within {1:?}")]
    Timeout(u16, Duration),
}

pub type Result<T> = std::result::Result<T, Error>;

/// The board: control (vendor requests, commands and their results) and
/// the two data endpoints, separate so that each can run on its own thread.
pub struct Usb {
    pub ctrl: Ctrl,
    pub tx: Endpoint<Bulk, Out>,
    pub rx: Endpoint<Bulk, In>,
}

/// The control side: FX3 vendor requests and the command/result endpoints.
pub struct Ctrl {
    device: nusb::Device,
    cmd: Endpoint<Bulk, Out>,
    rsp: Endpoint<Bulk, In>,
    sequence: u16,
    /// Events that arrived while waiting for results.
    pub events: Vec<Event>,
}

impl Usb {
    pub fn open() -> Result<Usb> {
        let info = nusb::list_devices()
            .wait()?
            .find(|d| d.vendor_id() == VID && d.product_id() == PID)
            .ok_or(Error::NotFound)?;
        let device = info.open().wait()?;
        let ep = |n: u8| device.detach_and_claim_interface(n).wait();
        let (i1, i2, i3, i4) = (ep(1)?, ep(2)?, ep(3)?, ep(4)?);
        Ok(Usb {
            tx: i1.endpoint::<Bulk, Out>(0x02)?,
            rx: i2.endpoint::<Bulk, In>(0x86)?,
            ctrl: Ctrl {
                cmd: i3.endpoint::<Bulk, Out>(0x04)?,
                rsp: i4.endpoint::<Bulk, In>(0x88)?,
                device,
                sequence: 0,
                events: Vec::new(),
            },
        })
    }
}

impl Ctrl {

    fn vendor_out(&self, request: u8, data: &[u8]) -> Result<()> {
        let c = ControlOut { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, data };
        Ok(self.device.control_out(c, Duration::from_secs(5)).wait()?)
    }

    fn vendor_in(&self, request: u8, length: u16) -> Result<Vec<u8>> {
        let c = ControlIn { control_type: ControlType::Vendor, recipient: Recipient::Device, request, value: 0, index: 0, length };
        Ok(self.device.control_in(c, Duration::from_secs(5)).wait()?)
    }

    /// The firmware's state (1 ready for an image, 2 configuring, 4 running).
    pub fn fx3_state(&self) -> Result<u8> {
        Ok(self.vendor_in(VREQ_GET_STATUS, 1)?.first().copied().unwrap_or(0))
    }

    fn wait_state(&self, want: u8, limit: Duration) -> Result<()> {
        let start = Instant::now();
        loop {
            let state = self.fx3_state()?;
            if state == want {
                return Ok(());
            }
            if start.elapsed() > limit {
                return Err(Error::Fx3State { state, want });
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Load an FPGA image (the .bin the build writes) and start the bus.
    pub fn load_fpga(&self, image: &[u8]) -> Result<()> {
        self.vendor_out(VREQ_FPGA_CONFIG, &[0])?;
        self.wait_state(STATE_FPGA_READY, Duration::from_secs(5))?;
        self.vendor_out(VREQ_FPGA_START, &[0])?;
        self.wait_state(STATE_CONFIGURING, Duration::from_secs(10))?;
        for chunk in image.chunks(VREQ_CHUNK) {
            self.vendor_out(VREQ_FPGA_DATA, chunk)?;
        }
        self.wait_state(STATE_RUNNING, Duration::from_secs(5))?;
        self.gpif_reset()
    }

    /// Restart the firmware's GPIF state machine (needed after every load).
    pub fn gpif_reset(&self) -> Result<()> {
        self.vendor_out(VREQ_GPIF_RESET, &[0; 4])
    }

    /// Run operations in one command packet; their results, in order.
    /// Event packets arriving meanwhile are kept in `self.events`.
    pub fn exec(&mut self, ops: &[Op]) -> Result<Vec<Reply>> {
        let sequence = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);
        let packet = proto::command(sequence, ops).map_err(Error::Proto)?;
        let mut buf = Buffer::new(packet.len());
        buf.extend_from_slice(&packet);
        self.cmd.transfer_blocking(buf, Duration::from_secs(1)).into_result()?;
        // a WAIT or POLL may run for seconds: the limit follows the operations
        let limit = Duration::from_secs(1)
            + ops.iter().map(|op| match *op {
                Op::Wait { us } => Duration::from_micros(us as u64),
                Op::Poll { ms, .. } => Duration::from_millis(ms as u64),
                _ => Duration::ZERO,
            }).sum::<Duration>();
        let start = Instant::now();
        loop {
            let left = limit.checked_sub(start.elapsed()).ok_or(Error::Timeout(sequence, limit))?;
            let c = self.rsp.transfer_blocking(Buffer::new(proto::CONTROL_BUFFER), left);
            let actual = c.actual_len;
            let buf = c.into_result()?;
            let h = Header::decode(&buf[..actual]).map_err(Error::Proto)?;
            let body = &buf[proto::HEADER..(h.length as usize).min(actual)];
            match h.kind {
                Kind::Event => self.events.extend(proto::events(body)),
                Kind::Result if h.sequence == sequence => return Ok(proto::replies(body)),
                _ => {} // a stale result (an earlier command that timed out)
            }
        }
    }

    pub fn write(&mut self, addr: u16, data: u32) -> Result<()> {
        self.exec(&[Op::Write { addr, data }]).map(|_| ())
    }

    pub fn read(&mut self, addr: u16) -> Result<u32> {
        Ok(self.exec(&[Op::Read { addr }])?.first().map_or(0, |r| r.data))
    }
}
