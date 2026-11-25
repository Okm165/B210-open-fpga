// SPDX-License-Identifier: GPL-3.0-or-later
//
// b210-plot - one channel of a capture, analysed and drawn in the terminal.
//
//   b210-plot cap_ch0.raw                          # every view
//   b210-plot cap_ch0.raw --view report            # the numbers and findings
//   b210-plot cap_ch0.raw --view spectrum --lo -1e6 --hi 1e6   # zoom: the FFT
//                                                  # grows so the band has bins
//   b210-plot cap_ch1.raw --view time,iq --t0 0.5  # waveform at 0.5 s
//
// The file is one channel of interleaved i16 I, Q (12-bit codes) as written
// by `b210 capture`; its sidecar `<stem>.toml` gives the rate (--rate
// overrides it, and is needed for a file without one). All levels are dBFS:
// 0 dBFS is a full-scale complex tone, |I + jQ| = 2048 (b210::dsp).
//
// Views (--view takes a comma list):
//   report     level, DC, I/Q balance, tone SNR/SINAD/SFDR/ENOB, noise floor,
//              spurs, and findings with causes (b210::quality)
//   spectrum   two-sided power spectrum, -rate/2 .. +rate/2, dBFS per bin,
//              peak hold per column so a narrow tone is never lost
//   waterfall  the spectrum against time, one row per slice of the interval
//   time       I and Q against time over --span seconds, per-column min..max
//   hist       distribution of the I and Q codes: clipping, DC, missing codes
//   iq         I against Q (constellation): circle, ellipse, line or blob
//
// The drawing is braille (2 x 4 dots per character cell) with labelled
// axes; --width/--height are in cells.

use anyhow::{bail, Context, Result};
use b210::{dsp, iq, quality};
use clap::{Parser, ValueEnum};
use std::path::PathBuf;

const FS: f64 = iq::FULL_SCALE;

#[derive(Clone, Copy, Debug, PartialEq, ValueEnum)]
enum View { All, Report, Spectrum, Waterfall, Time, Hist, Iq }

#[derive(Parser)]
#[command(about = "Analyse and draw one channel of a b210 capture")]
struct Cli {
    /// one channel, interleaved i16 I, Q (`b210 capture` writes <prefix>_chN.raw)
    file: PathBuf,
    /// sample rate, Hz (default: from the capture's .toml sidecar)
    #[arg(long)]
    rate: Option<f64>,
    /// views to show, comma separated
    #[arg(long, value_enum, value_delimiter = ',', default_value = "all")]
    view: Vec<View>,
    /// FFT points per segment, a power of two (default: 4096, or what a
    /// --lo/--hi zoom needs for 4 bins per plotted dot)
    #[arg(long)]
    fft: Option<usize>,
    /// lowest frequency shown, Hz (may be negative; default -rate/2)
    #[arg(long, allow_hyphen_values = true)]
    lo: Option<f64>,
    /// highest frequency shown, Hz (default +rate/2)
    #[arg(long, allow_hyphen_values = true)]
    hi: Option<f64>,
    /// top of the dB axis, dBFS
    #[arg(long, default_value_t = 0.0, allow_hyphen_values = true)]
    top_db: f64,
    /// dB from the top of the axis to its bottom
    #[arg(long, default_value_t = 110.0)]
    range_db: f64,
    /// start of the analysed interval, s
    #[arg(long, default_value_t = 0.0)]
    t0: f64,
    /// end of the analysed interval, s (default: end of file)
    #[arg(long)]
    t1: Option<f64>,
    /// window of the time view, s, from --t0
    #[arg(long, default_value_t = 100e-6)]
    span: f64,
    /// plot width in character cells
    #[arg(long, default_value_t = 100)]
    width: usize,
    /// plot height in character cells
    #[arg(long, default_value_t = 14)]
    height: usize,
}

fn main() -> Result<()> {
    let a = Cli::parse();
    let s = iq::read(&a.file).with_context(|| a.file.display().to_string())?;
    let meta = iq::read_meta(&a.file).with_context(|| iq::meta_path(&a.file).display().to_string())?;
    let rate = match (a.rate, &meta) {
        (Some(r), _) => r,
        (None, Some(m)) => m.rate_hz,
        (None, None) => bail!("{}: no sidecar {} - give --rate", a.file.display(), iq::meta_path(&a.file).display()),
    };
    if !(rate.is_finite() && rate > 0.0) || a.width < 20 || a.height < 4 || a.range_db <= 0.0 {
        bail!("--rate > 0, --width >= 20, --height >= 4, --range-db > 0");
    }
    let frames = s.len() / 2;
    let i0 = (a.t0 * rate) as usize;
    let i1 = a.t1.map_or(frames, |t| (t * rate) as usize).min(frames);
    if i1 < i0 + 64 {
        bail!("--t0/--t1 select {} sample times of {frames}: need at least 64", i1.saturating_sub(i0));
    }
    let x = &s[2 * i0..2 * i1];
    let (lo, hi) = (a.lo.unwrap_or(-rate / 2.0).max(-rate / 2.0), a.hi.unwrap_or(rate / 2.0).min(rate / 2.0));
    if hi <= lo {
        bail!("--lo {lo} must be below --hi {hi}, both within +-rate/2");
    }
    let n = fft_size(a.fft, lo, hi, rate, a.width, i1 - i0)?;
    println!("{}: {} sample times = {:.6} s at {:.6} MS/s{}; analysing {:.6} .. {:.6} s",
             a.file.display(), frames, frames as f64 / rate, rate / 1e6,
             meta.as_ref().map_or(String::new(), |m| format!(", channel {}, source {}", m.channel, m.source)),
             i0 as f64 / rate, i1 as f64 / rate);
    let views: Vec<View> = if a.view.contains(&View::All) {
        vec![View::Report, View::Spectrum, View::Waterfall, View::Time, View::Hist, View::Iq]
    } else { a.view.clone() };
    let g = Geometry { width: a.width, height: a.height, lo, hi, top: a.top_db, bottom: a.top_db - a.range_db };
    for v in views {
        println!();
        match v {
            View::Report => report(x, rate, n)?,
            View::Spectrum => spectrum(x, rate, n, &g)?,
            View::Waterfall => waterfall(x, rate, n, &g),
            View::Time => time(&x[..2 * ((a.span * rate) as usize).clamp(16, i1 - i0)], rate, &g),
            View::Hist => hist(x, &g),
            View::Iq => constellation(x, &g),
            View::All => unreachable!(),
        }
    }
    Ok(())
}

/// The FFT size: given, or 4096, or for a zoom the power of two that puts 4
/// bins under each plotted dot column (2 per cell): n = rate / (span / (8 w)).
/// Never more than the interval holds, never more than 2^20.
fn fft_size(given: Option<usize>, lo: f64, hi: f64, rate: f64, width: usize, frames: usize) -> Result<usize> {
    let fit = 1usize << (usize::BITS - 1 - frames.leading_zeros());
    let n = match given {
        Some(n) if !n.is_power_of_two() || n < 16 => bail!("--fft {n}: a power of two >= 16"),
        Some(n) => n,
        None if hi - lo < rate * 0.999 => ((rate / ((hi - lo) / (8 * width) as f64)) as usize).next_power_of_two().clamp(4096, 1 << 20),
        None => 4096,
    };
    Ok(n.min(fit))
}

struct Geometry { width: usize, height: usize, lo: f64, hi: f64, top: f64, bottom: f64 }

fn mhz(f: f64) -> String { format!("{:+.4} MHz", f / 1e6) }

// -- report --------------------------------------------------------------------------------

fn report(x: &[i16], rate: f64, n: usize) -> Result<()> {
    let r = quality::analyze(x, rate, n).context("too short to analyse")?;
    let l = &r.level;
    let b = &r.balance;
    println!("REPORT  ({} sample times, {}-point spectrum)", r.frames, r.fft);
    println!("  level     rms {:.1} dBFS, peak {:.1} dBFS, crest factor {:.1} dB, clipped {:.4}% of values",
             l.rms_dbfs, l.peak_dbfs, l.crest_db, 100.0 * l.clipped);
    println!("  DC        I {:+.2}, Q {:+.2} codes = {:.1} dBFS", l.dc_i, l.dc_q, l.dc_dbfs);
    if b.circular {
        println!("  balance   gain {:+.3} dB, phase {:+.3} deg -> image rejection {:.1} dB (I/Q correlation {:+.3})",
                 b.gain_db, b.phase_deg, b.irr_db, b.rho);
    } else {
        println!("  balance   not measurable: I and Q correlation {:+.3} (a real-valued signal)", b.rho);
    }
    match &r.tone {
        Some(t) => println!("  tone      {} at {:.2} dBFS: SNR {:.1} dB, SINAD {:.1} dB, SFDR {:.1} dBc, ENOB {:.2}, image {:.1} dBc",
                            mhz(t.freq), t.dbfs, t.snr_db, t.sinad_db, t.sfdr_dbc, t.enob, t.image_dbc),
        None => println!("  tone      none ({} dB above the floor needed)", 30),
    }
    println!("  floor     {:.1} dBFS per bin ({:.0} Hz) = {:.1} dBFS/Hz", r.floor_dbfs_bin, rate / r.fft as f64, r.floor_dbfs_hz);
    for s in &r.spurs {
        let unit = if r.tone.is_some() { "dBc" } else { "dBFS/bin" };
        println!("  spur      {} {:7.1} {unit}  {:?}", mhz(s.freq), s.db, s.kind);
    }
    println!("FINDINGS");
    for (k, f) in quality::findings(&r).iter().enumerate() {
        println!("  {}. {f}", k + 1);
    }
    Ok(())
}

// -- spectrum, waterfall ------------------------------------------------------------------------

/// The strongest bin's dBFS under each of `cols` equal frequency slices of
/// [lo, hi]: peak hold, so a tone narrower than a column still shows.
fn columns(sp: &dsp::Spectrum, lo: f64, hi: f64, cols: usize) -> Vec<f64> {
    (0..cols).map(|c| {
        let f0 = lo + (hi - lo) * c as f64 / cols as f64;
        let f1 = lo + (hi - lo) * (c + 1) as f64 / cols as f64;
        let (k0, k1) = (sp.bin(f0).min(sp.n() - 1), sp.bin(f1).min(sp.n() - 1));
        let p = (k0..=k1.max(k0)).map(|k| sp.power[k]).fold(0.0, f64::max);
        dsp::dbfs(p, FS)
    }).collect()
}

fn spectrum(x: &[i16], rate: f64, n: usize, g: &Geometry) -> Result<()> {
    let sp = dsp::welch(x, n, rate, 64).context("too short for a spectrum")?;
    let mut cv = Canvas::new(g.width, g.height);
    let val = columns(&sp, g.lo, g.hi, cv.dot_cols());
    for (c, v) in val.iter().enumerate() {
        let y = cv.row(*v, g.bottom, g.top);
        cv.vline(c, y, cv.dot_rows() - 1);
    }
    println!("SPECTRUM  {}-point Blackman-Harris, {} averages, bin {:.1} Hz, {} .. {}", sp.n(), sp.segments, sp.df(), mhz(g.lo), mhz(g.hi));
    cv.print(&format!("{:.0} dBFS", g.top), &format!("{:.0}", (g.top + g.bottom) / 2.0), &format!("{:.0} dBFS", g.bottom),
             &mhz(g.lo), &mhz(g.hi), "frequency");
    let (k, v) = val.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap();
    let mut sorted = val.clone();
    sorted.sort_by(f64::total_cmp);
    println!("  peak {} at {:.1} dBFS/bin; median column {:.1} dBFS/bin",
             mhz(g.lo + (g.hi - g.lo) * (k as f64 + 0.5) / val.len() as f64), v, sorted[sorted.len() / 2]);
    println!("  read: height = power in one bin. A tone's power spreads over its main lobe, so a full-scale tone");
    println!("  peaks at {:.1} dBFS/bin; noise spreads over all {} bins, so its floor sits {:.0} dB under its total",
             dsp::peak_bin_db(), sp.n(), 10.0 * (sp.n() as f64).log10());
    println!("  power (more points: lower floor, same tone). DC is the middle of a centred view; an I/Q image of");
    println!("  a tone at +f appears at -f.");
    Ok(())
}

fn waterfall(x: &[i16], rate: f64, n: usize, g: &Geometry) {
    const SHADES: &[u8] = b" .:-=+*#%@";
    let frames = x.len() / 2;
    let rows = g.height;
    let slice = frames / rows;
    let nw = n.min(1 << (usize::BITS - 1 - slice.max(16).leading_zeros()));
    println!("WATERFALL  {rows} slices of {:.3} ms, {nw}-point spectra, {} .. {}; shade {:.0} (' ') .. {:.0} dBFS ('@')",
             slice as f64 / rate * 1e3, mhz(g.lo), mhz(g.hi), g.bottom, g.top);
    for r in 0..rows {
        let part = &x[2 * r * slice..2 * (r + 1) * slice];
        let line: String = match dsp::welch(part, nw, rate, 8) {
            Some(sp) => columns(&sp, g.lo, g.hi, g.width).iter().map(|d| {
                let f = ((d - g.bottom) / (g.top - g.bottom)).clamp(0.0, 1.0);
                SHADES[(f * (SHADES.len() - 1) as f64).round() as usize] as char
            }).collect(),
            None => String::new(),
        };
        println!("{:>8.3} ms |{line}|", r as f64 * slice as f64 / rate * 1e3);
    }
    println!("  read: time runs down. A steady tone is a vertical line; a line that comes and goes is an");
    println!("  intermittent signal or a gap in the stream; a line that leans is a drifting frequency.");
}

// -- time, histogram, constellation ------------------------------------------------------------

/// The axis half-range for codes: the next power of two above the peak, at
/// most full scale, so small signals are visible and the label is exact.
fn code_scale(x: &[i16]) -> f64 {
    let peak = x.iter().map(|v| (*v as i32).unsigned_abs()).max().unwrap_or(1).max(1);
    (peak as f64).log2().ceil().exp2().clamp(16.0, FS)
}

fn time(x: &[i16], rate: f64, g: &Geometry) {
    let frames = x.len() / 2;
    let full = code_scale(x);
    println!("TIME  {:.3} us = {frames} sample times, scale +-{full:.0} codes (full scale +-2048)", frames as f64 / rate * 1e6);
    for (name, q) in [("I", 0usize), ("Q", 1)] {
        let mut cv = Canvas::new(g.width, g.height / 2 + 2);
        let cols = cv.dot_cols();
        for c in 0..cols {
            let (a, b) = (frames * c / cols, (frames * (c + 1) / cols).max(frames * c / cols + 1));
            let (lo, hi) = (a..b).map(|k| x[2 * k + q]).fold((i16::MAX, i16::MIN), |(l, h), v| (l.min(v), h.max(v)));
            cv.vline(c, cv.row(hi as f64, -full, full), cv.row(lo as f64, -full, full));
        }
        cv.print(&format!("{name} +{full:.0}"), "0", &format!("-{full:.0}"), "0 us",
                 &format!("{:.2} us", frames as f64 / rate * 1e6), "time");
    }
    println!("  read: each column is the min..max of the samples under it, so nothing is lost to decimation.");
    println!("  A tone is a sine in both, Q a quarter period behind I for +f; flat tops at +-2048 are clipping.");
}

fn hist(x: &[i16], g: &Geometry) {
    println!("HISTOGRAM  codes -2048 .. 2047, height log10(count)");
    for (name, q) in [("I", 0usize), ("Q", 1)] {
        let mut count = vec![0u64; 4096];
        for p in x.as_chunks::<2>().0 { count[(p[q] as i32 + 2048) as usize] += 1; }
        let mut cv = Canvas::new(g.width, g.height / 2 + 1);
        let cols = cv.dot_cols();
        let top = (count.iter().copied().max().unwrap_or(1) as f64 + 1.0).log10();
        for c in 0..cols {
            let n: u64 = count[4096 * c / cols..4096 * (c + 1) / cols].iter().sum();
            if n > 0 {
                cv.vline(c, cv.row((n as f64 + 1.0).log10(), 0.0, top), cv.dot_rows() - 1);
            }
        }
        cv.print(&format!("{name} 10^{top:.1}"), "", "1", "-2048", "2047", "code");
        let (first, last) = (count.iter().position(|c| *c > 0).unwrap_or(0), count.iter().rposition(|c| *c > 0).unwrap_or(0));
        let missing = count[first..=last].iter().filter(|c| **c == 0).count();
        let per_code = (x.len() / 2) as f64 / (last - first + 1) as f64;
        println!("  {name}: codes {} .. {}, {} at -2048, {} at 2047{}", first as i32 - 2048, last as i32 - 2048,
                 count[0], count[4095],
                 if per_code >= 16.0 { format!(", {missing} codes never hit inside that range") } else { String::new() });
    }
    println!("  read: a tone gives a bowl (most time near its peaks), noise a bell; a shifted centre is DC; spikes");
    println!("  at the ends are clipping; codes never hit (with many samples per code) point at a converter fault.");
}

fn constellation(x: &[i16], g: &Geometry) {
    let full = code_scale(x);
    // a square in dots: height h cells = 4h dots, so width 2h cells = 4h dots
    let h = g.height.max(6);
    let mut cv = Canvas::new(2 * h, h);
    let d = cv.dot_rows();
    let stride = (x.len() / 2 / 200_000).max(1);
    for p in x.as_chunks::<2>().0.iter().step_by(stride) {
        let cx = ((p[0] as f64 + full) / (2.0 * full) * (d - 1) as f64).round() as usize;
        cv.dot(cx, cv.row(p[1] as f64, -full, full));
    }
    for k in (0..d).step_by(4) { cv.dot(d / 2, k); cv.dot(k, d / 2); }
    println!("I/Q  constellation, both axes +-{full:.0} codes, {} points", x.len() / 2 / stride);
    cv.print(&format!("Q +{full:.0}"), "0", &format!("-{full:.0}"), &format!("I -{full:.0}"), &format!("+{full:.0}"), "I");
    println!("  read: a clean tone is a circle centred on the cross; an ellipse or a tilted one is I/Q gain or phase");
    println!("  imbalance; an off-centre circle is DC; a line through the centre is a real-valued signal; a fuzzy");
    println!("  ring is noise, its thickness against the radius the SNR.");
}

// -- braille canvas ---------------------------------------------------------------------------

struct Canvas { cols: usize, rows: usize, bits: Vec<u8> }

impl Canvas {
    fn new(cols: usize, rows: usize) -> Canvas { Canvas { cols, rows, bits: vec![0; cols * rows] } }
    fn dot_rows(&self) -> usize { 4 * self.rows }
    fn dot_cols(&self) -> usize { 2 * self.cols }
    /// The dot row of value v on an axis from `bottom` (last row) to `top`
    /// (row 0), clamped.
    fn row(&self, v: f64, bottom: f64, top: f64) -> usize {
        let f = ((top - v) / (top - bottom)).clamp(0.0, 1.0);
        (f * (self.dot_rows() - 1) as f64).round() as usize
    }
    fn dot(&mut self, x: usize, y: usize) {
        if x >= self.dot_cols() || y >= self.dot_rows() { return; }
        // braille dots: left column 1 2 3 7, right column 4 5 6 8
        const BIT: [[u8; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
        self.bits[(y / 4) * self.cols + x / 2] |= BIT[y % 4][x % 2];
    }
    fn vline(&mut self, x: usize, y0: usize, y1: usize) {
        for y in y0.min(y1)..=y0.max(y1) { self.dot(x, y); }
    }
    fn render(&self) -> Vec<String> {
        (0..self.rows).map(|r| (0..self.cols).map(|c| char::from_u32(0x2800 + self.bits[r * self.cols + c] as u32).unwrap()).collect()).collect()
    }
    /// The canvas with a labelled frame: y labels at the top, middle and
    /// bottom rows, x labels under the left and right ends.
    fn print(&self, ytop: &str, ymid: &str, ybot: &str, xl: &str, xr: &str, xname: &str) {
        for (r, line) in self.render().iter().enumerate() {
            let label = if r == 0 { ytop } else if r == self.rows / 2 { ymid } else if r == self.rows - 1 { ybot } else { "" };
            println!("{label:>11} |{line}|");
        }
        let gap = self.cols.saturating_sub(xl.len() + xr.len() + xname.len()) / 2;
        println!("{:>11}  {xl}{:gap$}{xname}{:gap$}{xr}", "", "", "");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn braille_dots_map_as_documented() {
        let mut c = Canvas::new(1, 1);
        c.dot(0, 0);
        c.dot(1, 3);
        assert_eq!(c.render(), vec!["\u{2881}".to_string()]);
        c.dot(9, 9); // outside: ignored
    }

    #[test]
    fn rows_run_top_to_bottom_and_clamp() {
        let c = Canvas::new(4, 2); // 8 dot rows
        assert_eq!((c.row(0.0, -100.0, 0.0), c.row(-100.0, -100.0, 0.0), c.row(-500.0, -100.0, 0.0)), (0, 7, 7));
        assert_eq!(c.row(5.0, -100.0, 0.0), 0);
    }

    #[test]
    fn zoom_chooses_enough_bins_and_respects_limits() {
        // 30.72 MHz over a 1 MHz zoom at 100 cells: 800 dot... 4 bins per dot
        // column -> rate / (1e6 / 800) = 24576 -> 32768
        assert_eq!(fft_size(None, -0.5e6, 0.5e6, 30.72e6, 100, 1 << 22).unwrap(), 32768);
        assert_eq!(fft_size(None, -15.36e6, 15.36e6, 30.72e6, 100, 1 << 22).unwrap(), 4096);
        assert_eq!(fft_size(None, 0.0, 10.0, 30.72e6, 100, 1 << 30).unwrap(), 1 << 20);
        assert_eq!(fft_size(Some(65536), 0.0, 1.0, 1e6, 100, 5000).unwrap(), 4096, "never more than the interval");
        assert!(fft_size(Some(1000), 0.0, 1.0, 1e6, 100, 1 << 20).is_err());
    }

    #[test]
    fn peak_hold_keeps_a_one_bin_tone_in_a_wide_column() {
        let mut p = vec![1.0; 1024];
        p[700] = 1e6;
        let sp = dsp::Spectrum { power: p, rate: 1024.0, segments: 1 };
        let col = columns(&sp, -512.0, 512.0, 16);
        assert_eq!(col.iter().filter(|d| **d > dsp::dbfs(1e5, FS)).count(), 1);
    }

    #[test]
    fn code_scale_is_a_power_of_two_above_the_peak() {
        assert_eq!(code_scale(&[100, -3]), 128.0);
        assert_eq!(code_scale(&[2047, -2048]), 2048.0);
        assert_eq!(code_scale(&[0, 0]), 16.0);
    }
}
