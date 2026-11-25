//! One channel of I/Q samples on disk, and the arithmetic every view of it
//! needs.
//!
//! File format: little-endian signed 16-bit interleaved I, Q, I, Q, ... -
//! the natural output of the codecs (sc12 codes sign-extended into i16, or
//! the full 16 bits of sc16). One file per channel: `capture` writes
//! `<prefix>_ch0.raw`, `<prefix>_ch1.raw`, so any tool (and any number of
//! them) can read one channel without knowing the stream's channel mask.
//! The file name, not the length, identifies the channel.

use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

/// The file of channel `c` for a capture prefix `prefix`: `prefix_ch<c>.raw`
/// with a trailing `.raw` of the prefix replaced, so `cap.raw` gives
/// `cap_ch0.raw` rather than `cap.raw_ch0.raw`.
pub fn channel_path(prefix: &Path, c: usize) -> PathBuf {
    let stem = prefix.file_stem().map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "capture".into());
    prefix.with_file_name(format!("{stem}_ch{c}.raw"))
}

/// Write one channel: `samples` is interleaved I, Q, ... (even length).
pub fn write(path: &Path, samples: &[i16]) -> io::Result<()> {
    assert!(samples.len().is_multiple_of(2), "I/Q pairs");
    let mut w = BufWriter::new(File::create(path)?);
    let mut bytes = Vec::with_capacity(2 * samples.len());
    for v in samples {
        bytes.extend_from_slice(&v.to_le_bytes());
    }
    w.write_all(&bytes)?;
    w.flush()
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

/// Level of one channel, in the file's units (so full scale is 2048 for
/// sc12 codes and 32768 for sc16).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stats {
    pub min: i16,
    pub max: i16,
    /// Root mean square of I and Q together: one number for the channel's
    /// power, `sqrt(mean(i^2 + q^2) / 2)`.
    pub rms: f64,
}

impl Stats {
    pub fn of(samples: &[i16]) -> Stats {
        if samples.is_empty() {
            return Stats { min: 0, max: 0, rms: 0.0 };
        }
        let (mut min, mut max, mut sum) = (i16::MAX, i16::MIN, 0.0);
        for &v in samples {
            min = min.min(v);
            max = max.max(v);
            sum += (v as f64) * (v as f64);
        }
        // interleaved I and Q: two values per sample time
        Stats { min, max, rms: (sum / samples.len() as f64).sqrt() }
    }
    /// Fraction of the codes at or beyond `full_scale * 0.999`, i.e. a
    /// clipped capture. Zero for a capture that fits.
    pub fn clipped(&self, full_scale: f64) -> bool {
        self.min as f64 <= -full_scale * 0.999 || self.max as f64 >= full_scale * 0.999
    }
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
    fn stats_of_a_known_channel() {
        // I = 3, -4; Q = 0, 0: rms = sqrt((9 + 16)/4) = 2.5
        let s = [3, 0, -4, 0];
        let st = Stats::of(&s);
        assert_eq!((st.min, st.max), (-4, 3));
        assert!((st.rms - 2.5).abs() < 1e-12);
        assert!(!st.clipped(2048.0));
        assert!(Stats::of(&[2047, -2048]).clipped(2048.0));
    }

    #[test]
    fn round_trip_and_a_truncated_file_is_an_error() {
        let dir = std::env::temp_dir().join(format!("b210-iq-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("x_ch0.raw");
        write(&p, &[1, -2, 300, -4000]).unwrap();
        assert_eq!(read(&p).unwrap(), vec![1, -2, 300, -4000]);
        std::fs::write(&p, [0u8; 6]).unwrap();
        assert!(read(&p).is_err(), "6 bytes is not whole I/Q pairs");
        std::fs::remove_dir_all(&dir).ok();
    }
}
