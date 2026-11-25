//! One channel of I/Q samples on disk, and the arithmetic every view of it
//! needs.
//!
//! File format: little-endian signed 16-bit interleaved I, Q, I, Q, ... -
//! the natural output of the codecs (sc12 codes sign-extended into i16, or
//! the full 16 bits of sc16). One file per channel: `capture` writes
//! `<prefix>_ch0.raw`, `<prefix>_ch1.raw`, so any tool (and any number of
//! them) can read one channel without knowing the stream's channel mask.
//! The file name, not the length, identifies the channel.

use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// Full scale of the codes: 12-bit two's complement, -2048 ..= 2047. Both
/// wire formats carry 12-bit codes (sc16 has them in its top 12 bits), so a
/// capture file always holds codes in this range.
pub const FULL_SCALE: f64 = 2048.0;

/// What a capture file holds, kept beside it as `<file stem>.toml` so a
/// tool reading the file needs no flags to interpret it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Meta {
    /// sample times per second
    pub rate_hz: f64,
    /// channel number on the board
    pub channel: usize,
    /// rx source register setting the capture was taken with
    pub source: String,
}

/// The sidecar of a capture file: same path, extension `.toml`.
pub fn meta_path(file: &Path) -> PathBuf {
    file.with_extension("toml")
}

pub fn write_meta(file: &Path, m: &Meta) -> io::Result<()> {
    let text = toml::to_string(m).map_err(io::Error::other)?;
    std::fs::write(meta_path(file), text)
}

/// The sidecar, or None when there is none (a file from elsewhere).
pub fn read_meta(file: &Path) -> io::Result<Option<Meta>> {
    match std::fs::read_to_string(meta_path(file)) {
        Ok(t) => toml::from_str(&t).map(Some).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The file of channel `c` for a capture prefix `prefix`: `prefix_ch<c>.raw`
/// with a trailing `.raw` of the prefix replaced, so `cap.raw` gives
/// `cap_ch0.raw` rather than `cap.raw_ch0.raw`.
pub fn channel_path(prefix: &Path, c: usize) -> PathBuf {
    let stem = prefix.file_stem().map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "capture".into());
    prefix.with_file_name(format!("{stem}_ch{c}.raw"))
}

/// Read one channel. A file whose length is not a whole number of I/Q pairs
/// is an error: a truncated capture must never be plotted as if complete.
pub fn read(path: &Path) -> io::Result<Vec<i16>> {
    let mut bytes = Vec::new();
    File::open(path)?.read_to_end(&mut bytes)?;
    if !bytes.len().is_multiple_of(4) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{}: {} bytes is not a whole number of I/Q pairs", path.display(), bytes.len()),
        ));
    }
    Ok(bytes.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_path_replaces_raw_and_keeps_other_extensions() {
        assert_eq!(channel_path(Path::new("/tmp/cap.raw"), 0), Path::new("/tmp/cap_ch0.raw"));
        assert_eq!(channel_path(Path::new("/tmp/cap.raw"), 1), Path::new("/tmp/cap_ch1.raw"));
        assert_eq!(channel_path(Path::new("/tmp/a.b.c"), 2), Path::new("/tmp/a.b_ch2.raw"));
        assert_eq!(channel_path(Path::new("/tmp/cap"), 1), Path::new("/tmp/cap_ch1.raw"));
    }

    #[test]
    fn round_trip_and_a_truncated_file_is_an_error() {
        let dir = std::env::temp_dir().join(format!("b210-iq-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("x_ch0.raw");
        std::fs::write(&p, [1i16, -2, 300, -4000].iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
        assert_eq!(read(&p).unwrap(), vec![1, -2, 300, -4000]);
        std::fs::write(&p, [0u8; 6]).unwrap();
        assert!(read(&p).is_err(), "6 bytes is not whole I/Q pairs");
        let m = Meta { rate_hz: 30.72e6, channel: 1, source: "pattern".into() };
        write_meta(&p, &m).unwrap();
        assert_eq!(read_meta(&p).unwrap(), Some(m));
        assert_eq!(read_meta(&dir.join("none.raw")).unwrap(), None);
        std::fs::write(meta_path(&p), "rate_hz = 1\nbogus = 2\n").unwrap();
        assert!(read_meta(&p).is_err(), "unknown keys are rejected");
        std::fs::remove_dir_all(&dir).ok();
    }
}
