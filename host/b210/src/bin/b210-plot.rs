// SPDX-License-Identifier: GPL-3.0-or-later
//
// b210-plot - one capture file, one channel, in the terminal.
//
//   b210-plot cap_ch0.raw --rate 30.77e6                  # spectrum + I/Q
//   b210-plot cap_ch0.raw --view spectrum --fft 65536     # zoom FFT: finer bins
//   b210-plot cap_ch0.raw --lo 1e5 --hi 1e6               # zoom in frequency
//   b210-plot cap_ch0.raw --t0 0.1 --t1 0.2 --view time   # zoom in time
//
// Two views of the same file, both in physical units:
//
//   spectrum  Welch-averaged power of interleaved I/Q, Hann window, one
//             segment of --fft points (a power of two). A bin is
//             rate/--fft Hz wide; --lo/--hi select the bins shown, so
//             "zoom FFT" = more points (finer bins) plus the band you want.
//             The vertical axis is dB relative to the strongest bin, which
//             is 0 dB by construction; --range-db sets the floor.
//   time      I and Q against time, min/max per terminal column over the
//             --t0/--t1 seconds (the peak envelope, so no sample is hidden
//             by decimation).
//
// The drawing is braille (2x4 dots per cell), so no graphics library, no
// display and no file: stdout is the plot. --width/--height are in cells.

use anyhow::{bail, Context, Result};
use b210::{dsp, iq};
use clap::Parser;
use std::path::PathBuf;

#[derive(Parser)]
struct Cli {
    /// one channel, as written by `b210 capture` (interleaved i16 I, Q)
    file: PathBuf,
    /// sample rate of the capture, Hz
    #[arg(long, default_value_t = 30.72e6)]
    rate: f64,
    /// spectrum, time or both
    #[arg(long, default_value = "both")]
    view: String,
    /// spectrum points per segment: a power of two. Resolution = rate / fft.
    #[arg(long, default_value_t = 4096)]
    fft: usize,
    /// lowest frequency shown, Hz (default 0)
    #[arg(long)]
    lo: Option<f64>,
    /// highest frequency shown, Hz (default rate / 2)
    #[arg(long)]
    hi: Option<f64>,
    /// dB below the strongest bin at the bottom of the plot
    #[arg(long, default_value_t = 80.0)]
    range_db: f64,
    /// start of the analysed interval, seconds
    #[arg(long, default_value_t = 0.0)]
    t0: f64,
    /// end of the analysed interval, seconds (default: end of file)
    #[arg(long)]
    t1: Option<f64>,
    /// width of the I/Q plot in seconds (spectrum uses t0..t1)
    #[arg(long, default_value_t = 2e-3)]
    time_span: f64,
    /// plot width in cells (2 dots each)
    #[arg(long, default_value_t = 100)]
    width: usize,
    /// plot height in cells (4 dots each)
    #[arg(long, default_value_t = 18)]
    height: usize,
}

fn main() -> Result<()> {
    let a = Cli::parse();
    let s = iq::read(&a.file).with_context(|| format!("{}", a.file.display()))?;
    if s.len() < 64 {
        bail!("{}: {} samples is too short to plot", a.file.display(), s.len() / 2);
    }
    if !a.rate.is_finite() || a.rate <= 0.0 {
        bail!("--rate must be positive");
    }
    if a.width < 10 || a.height < 4 {
        bail!("--width >= 10, --height >= 4");
    }
    let frames = s.len() / 2;
    let seconds = frames as f64 / a.rate;
    let st = iq::Stats::of(&s);
    // a capture of 12-bit codes never leaves +-2048; sc16 can use the full
    // 16-bit range. Clipping is judged against whichever applies.
    let fs = if st.min >= -2048 && st.max <= 2048 { 2048.0 } else { 32768.0 };
    println!(
        "{}: {} sample times, {:.6} s at {:.3} MS/s; I/Q min {} max {} rms {:.1}{}",
        a.file.display(),
        frames,
        seconds,
        a.rate / 1e6,
        st.min,
        st.max,
        st.rms,
        if st.clipped(fs) { " (CLIPPED)" } else { "" }
    );

    let i0 = ((a.t0 * a.rate) as usize).min(frames.saturating_sub(64));
    let i1 = a.t1.map(|t| (t * a.rate) as usize).unwrap_or(frames).min(frames);
    if i1 <= i0 + 16 {
        bail!("--t0/--t1 select {} samples: need at least 16", i1.saturating_sub(i0));
    }

    match a.view.as_str() {
        "spectrum" => spectrum(&s[2 * i0..2 * i1], &a)?,
        "time" => {
            // --time-span is the window when --t1 is not given
            let n = ((a.time_span * a.rate) as usize).max(16);
            let end = a.t1.map(|_| i1).unwrap_or((i0 + n).min(i1));
            time(&s[2 * i0..2 * end], &a)?
        }
        "both" => {
            spectrum(&s[2 * i0..2 * i1], &a)?;
            // the waveform needs far less time than the spectrum: the first
            // --time-span of the same interval, so both describe one moment
            let n = ((a.time_span * a.rate) as usize).max(16).min(i1 - i0);
            println!();
            time(&s[2 * i0..2 * (i0 + n)], &a)?;
        }
        v => bail!("--view: spectrum, time or both, not {v}"),
    }
    Ok(())
}

/// Welch power, dB relative to the peak, over [lo, hi], peak-hold per column.
fn spectrum(samples: &[i16], a: &Cli) -> Result<()> {
    let n = a.fft.next_power_of_two();
    if n != a.fft {
        bail!("--fft {} is not a power of two (use {n})", a.fft);
    }
    // cap the work: 64 segments is plenty for a smooth floor and keeps a
    // multi-second capture to 64 FFTs
    let p = dsp::welch(samples, n, 64);
    if p.iter().all(|v| *v == 0.0) {
        bail!("capture is all zero or shorter than one --fft segment");
    }
    let db = dsp::relative_db(&p, -a.range_db);
    let df = a.rate / n as f64;
    let lo = a.lo.unwrap_or(0.0).max(0.0);
    let hi = a.hi.unwrap_or(a.rate / 2.0).min(a.rate / 2.0);
    if hi <= lo || !hi.is_finite() || !lo.is_finite() {
        bail!("--lo {lo} Hz and --hi {hi} Hz: hi must be above lo and below rate/2");
    }
    let k0 = ((lo / df).floor() as usize).min(p.len() - 1);
    let k1 = ((hi / df).ceil() as usize).clamp(k0 + 1, p.len());
    let (peak_k, peak_db) = db.iter().enumerate().max_by(|x, y| x.1.total_cmp(y.1)).unwrap();
    let peak_f = peak_k as f64 * df;
    println!(
        "spectrum: {} points/bin {:.3} Hz, {} bins in {:.6} .. {:.6} MHz, Welch over {} segments, Hann",
        n, df, k1 - k0, lo / 1e6, hi / 1e6, (samples.len() / 2 / n).min(64)
    );
    println!("peak {:.6} MHz at {:.2} dB (0 dB = strongest bin), floor -{} dB", peak_f / 1e6, peak_db, a.range_db);
    // peak-hold: the strongest bin in each column, so a narrow tone is not
    // lost between columns
    let cols = 2 * a.width;
    let mut val = vec![-a.range_db; cols];
    for (c, v) in val.iter_mut().enumerate() {
        let k = k0 + ((k1 - k0) * c / cols);
        let e = k0 + ((k1 - k0) * (c + 1) / cols);
        *v = db[k..e.max(k + 1)].iter().cloned().fold(-a.range_db, f64::max);
    }
    let mut cv = Canvas::new(a.width, a.height);
    for (c, v) in val.iter().enumerate() {
        let y = db_to_row(*v, -a.range_db, 0.0, cv.dot_rows());
        cv.dot(c, y);
    }
    println!("0 dB = strongest bin (top); -{} dB floor (bottom)", a.range_db);
    print!("{}", cv.render());
    println!(
        "  {:.6} MHz{:^width$}{:.6} MHz   ({:.3} MHz/div)",
        lo / 1e6,
        "",
        hi / 1e6,
        (hi - lo) / 1e6 / a.width as f64,
        width = a.width.saturating_sub(20)
    );
    Ok(())
}

/// I and Q against time: min/max per column, the peak envelope.
fn time(samples: &[i16], a: &Cli) -> Result<()> {
    let frames = samples.len() / 2;
    let span = frames as f64 / a.rate;
    println!("time: {:.6} s, {} samples, {:.3} MS/s, peak envelope", span, frames, a.rate / 1e6);
    let mut cv = Canvas::new(a.width, a.height);
    let full = samples.iter().map(|v| (*v as i32).unsigned_abs()).max().unwrap_or(1).max(1) as f64;
    for (name, q) in [("I", 0usize), ("Q", 1usize)] {
        let cols = cv.dot_cols();
        // min and max of the column, both drawn: the trace fills its range
        for c in 0..cols {
            let i0 = frames * c / cols;
            let i1 = (frames * (c + 1) / cols).max(i0 + 1);
            let (mut lo, mut hi) = (i32::MAX, i32::MIN);
            for k in i0..i1 {
                let v = samples[2 * k + q] as i32;
                lo = lo.min(v);
                hi = hi.max(v);
            }
            let yl = value_to_row(lo as f64, -full, full, cv.dot_rows());
            let yh = value_to_row(hi as f64, -full, full, cv.dot_rows());
            for y in yl.min(yh)..=yl.max(yh) {
                cv.dot(c, y);
            }
        }
        println!("{name}: +{full:.0}");
        print!("{}", cv.render());
        println!("{name}: -{full:.0}    (0 at the middle line, dot = column's min..max)");
        cv.clear();
    }
    Ok(())
}

/// Map a dB value to a dot row: 0 dB at the top, `floor` dB at the bottom.
fn db_to_row(db: f64, floor: f64, top: f64, rows: usize) -> usize {
    let f = ((top - db) / (top - floor)).clamp(0.0, 1.0);
    ((f * (rows.saturating_sub(1)) as f64).round() as usize).min(rows - 1)
}

/// Map a signed value to a dot row, `-full` at the bottom, `+full` at the top.
fn value_to_row(v: f64, neg: f64, pos: f64, rows: usize) -> usize {
    let f = ((v - neg) / (pos - neg)).clamp(0.0, 1.0);
    (((1.0 - f) * (rows.saturating_sub(1)) as f64).round() as usize).min(rows - 1)
}

/// A braille canvas: each cell is 2 dots wide and 4 dots tall.
struct Canvas {
    cols: usize,
    rows: usize,
    bits: Vec<u8>,
}

impl Canvas {
    fn new(cols: usize, rows: usize) -> Canvas {
        Canvas { cols, rows, bits: vec![0; cols * rows] }
    }
    fn dot_rows(&self) -> usize {
        self.rows * 4
    }
    fn dot_cols(&self) -> usize {
        self.cols * 2
    }
    fn clear(&mut self) {
        self.bits.fill(0);
    }
    /// Set one dot; x in dot columns, y in dot rows, y down.
    fn dot(&mut self, x: usize, y: usize) {
        if x >= self.dot_cols() || y >= self.dot_rows() {
            return;
        }
        // braille's 8 dots: left column 1,2,3,7; right column 4,5,6,8
        let bit = match (y % 4, x % 2) {
            (0, 0) => 0x01,
            (1, 0) => 0x02,
            (2, 0) => 0x04,
            (3, 0) => 0x40,
            (0, 1) => 0x08,
            (1, 1) => 0x10,
            (2, 1) => 0x20,
            _ => 0x80,
        };
        self.bits[(y / 4) * self.cols + x / 2] |= bit;
    }
    fn render(&self) -> String {
        let mut out = String::with_capacity(self.rows * (self.cols * 3 + 1));
        for r in 0..self.rows {
            for c in 0..self.cols {
                let b = self.bits[r * self.cols + c];
                out.push(char::from_u32(0x2800 + b as u32).unwrap_or(' '));
            }
            out.push('\n');
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn braille_dots_and_rows_map_as_documented() {
        let mut c = Canvas::new(1, 1);
        c.dot(0, 0);
        assert_eq!(c.render(), "\u{2801}\n");
        c.clear();
        c.dot(1, 3);
        assert_eq!(c.render(), "\u{2880}\n");
        // out of range is ignored, not a panic
        c.dot(99, 99);
    }

    #[test]
    fn db_and_value_rows_are_clamped_and_ordered() {
        assert_eq!(db_to_row(0.0, -80.0, 0.0, 8), 0);
        assert_eq!(db_to_row(-80.0, -80.0, 0.0, 8), 7);
        assert_eq!(db_to_row(-200.0, -80.0, 0.0, 8), 7);
        assert_eq!(value_to_row(2048.0, -2048.0, 2048.0, 8), 0);
        assert_eq!(value_to_row(-2048.0, -2048.0, 2048.0, 8), 7);
        assert_eq!(value_to_row(0.0, -2048.0, 2048.0, 8), 4);
    }
}
