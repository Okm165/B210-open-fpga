// SPDX-License-Identifier: GPL-3.0-or-later
//
// b210-plot - one channel of a capture, analysed and drawn in the terminal.
//
//   b210-plot cap_ch0.raw                          # every view
//   b210-plot cap_ch0.raw --view report            # the numbers and findings
//   b210-plot cap_ch0.raw --view spectrum --lo -1e6 --hi 1e6   # zoom: the FFT
//                                                  # grows so the band has bins
//   b210-plot cap_ch1.raw --view time,iq --t0 0.5  # waveform at 0.5 s
//   b210-plot cap_ch0.raw --png out/radio          # the views as PNG images:
//                                                  # out/radio_spectrum.png, _waterfall,
//                                                  # _time, _hist, _iq (report stays text)
//   b210-plot cap_ch0.raw --config zoom.toml       # settings kept in a file,
//                                                  # keys = flag names; flags win
//
// The file is one channel of interleaved i16 I, Q (12-bit codes) as written
// by `b210 capture`; its sidecar `<stem>.toml` gives the rate (--rate
// overrides it, and is needed for a file without one). All levels are dBFS:
// 0 dBFS is a full-scale complex tone, |I + jQ| = 2048 (b210::dsp).
//
// Memory: only the selected interval (t0/t1) is read, never the whole
// channel, and --view report alone streams it (quality::analyze_file_range):
// a report on a 233 MB file peaks at 3.3 MB. The other views hold their
// interval, since they draw its samples.
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
use b210::{capture, dsp, quality};
use clap::{Args, Parser, ValueEnum};
use serde::Deserialize;
use std::path::PathBuf;

const FS: f64 = capture::FULL_SCALE;

#[derive(Clone, Copy, Debug, PartialEq, ValueEnum, Deserialize)]
#[serde(rename_all = "lowercase")]
enum View { All, Report, Spectrum, Waterfall, Time, Hist, Iq }

#[derive(Parser)]
#[command(about = "Analyse and draw one channel of a b210 capture")]
struct Cli {
    /// one channel, interleaved i16 I, Q (`b210 capture` writes <prefix>_chN.raw)
    file: PathBuf,
    /// a TOML file of settings, keyed exactly like the flags below
    /// (`fft = 65536`, `lo = -2e6`, `view = ["report", "spectrum"]`); a flag
    /// given on the command line overrides the file's value for that key
    #[arg(long)]
    config: Option<PathBuf>,
    #[command(flatten)]
    settings: Settings,
}

/// Every setting, as a flag and as a key of the --config file: one struct,
/// one name each, so the two can never drift apart. Every field is optional
/// here; `Plot::from` applies the defaults after the file and the flags are
/// merged.
#[derive(Args, Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
struct Settings {
    /// sample rate, Hz [default: from the capture's .toml sidecar]
    #[arg(long)]
    rate: Option<f64>,
    /// views to show, comma separated [default: all]
    #[arg(long, value_enum, value_delimiter = ',')]
    view: Option<Vec<View>>,
    /// FFT points per segment, a power of two [default: 4096, or what a
    /// --lo/--hi zoom needs for 4 bins per plotted dot]
    #[arg(long)]
    fft: Option<usize>,
    /// lowest frequency shown, Hz, may be negative [default: -rate/2]
    #[arg(long, allow_hyphen_values = true)]
    lo: Option<f64>,
    /// highest frequency shown, Hz [default: +rate/2]
    #[arg(long, allow_hyphen_values = true)]
    hi: Option<f64>,
    /// top of the dB axis, dBFS [default: 0]
    #[arg(long, allow_hyphen_values = true)]
    top_db: Option<f64>,
    /// dB from the top of the axis to its bottom [default: 110]
    #[arg(long)]
    range_db: Option<f64>,
    /// start of the analysed interval, s [default: 0]
    #[arg(long)]
    t0: Option<f64>,
    /// end of the analysed interval, s [default: end of file]
    #[arg(long)]
    t1: Option<f64>,
    /// window of the time view, s, from --t0 [default: 100e-6]
    #[arg(long)]
    span: Option<f64>,
    /// plot width in character cells [default: 100]
    #[arg(long)]
    width: Option<usize>,
    /// plot height in character cells [default: 14]
    #[arg(long)]
    height: Option<usize>,
    /// write the image views as PNG files, PREFIX_view.png (grayscale; the
    /// terminal keeps the labelled axes) [default: none]
    #[arg(long)]
    png: Option<PathBuf>,
}

impl Settings {
    /// Each field from `self` where given, else from `base`.
    fn over(self, base: Settings) -> Settings {
        Settings {
            rate: self.rate.or(base.rate), view: self.view.or(base.view), fft: self.fft.or(base.fft),
            lo: self.lo.or(base.lo), hi: self.hi.or(base.hi), top_db: self.top_db.or(base.top_db),
            range_db: self.range_db.or(base.range_db), t0: self.t0.or(base.t0), t1: self.t1.or(base.t1),
            span: self.span.or(base.span), width: self.width.or(base.width), height: self.height.or(base.height),
            png: self.png.or(base.png),
        }
    }
}

/// The settings with every default applied and every value checked.
struct Plot {
    views: Vec<View>,
    rate: f64,
    fft: Option<usize>,
    lo: Option<f64>,
    hi: Option<f64>,
    top_db: f64,
    range_db: f64,
    t0: f64,
    t1: Option<f64>,
    span: f64,
    width: usize,
    height: usize,
    png: Option<PathBuf>,
}

impl Plot {
    fn from(s: Settings, sidecar_rate: Option<f64>) -> Result<Plot> {
        let Some(rate) = s.rate.or(sidecar_rate) else { bail!("no sample rate: no .toml sidecar - give --rate or `rate`") };
        let mut views = s.view.unwrap_or(vec![View::All]);
        if views.contains(&View::All) {
            views = vec![View::Report, View::Spectrum, View::Waterfall, View::Time, View::Hist, View::Iq];
        }
        let p = Plot {
            views, rate, fft: s.fft, lo: s.lo, hi: s.hi,
            top_db: s.top_db.unwrap_or(0.0), range_db: s.range_db.unwrap_or(110.0),
            t0: s.t0.unwrap_or(0.0), t1: s.t1, span: s.span.unwrap_or(100e-6),
            width: s.width.unwrap_or(100), height: s.height.unwrap_or(14), png: s.png,
        };
        // written positively, so a NaN anywhere fails the check
        let ok = p.rate.is_finite() && p.rate > 0.0 && p.width >= 20 && p.height >= 4 && p.range_db > 0.0
            && p.t0 >= 0.0 && p.span > 0.0;
        if !ok {
            bail!("rate > 0, width >= 20, height >= 4, range_db > 0, t0 >= 0, span > 0");
        }
        Ok(p)
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let file_settings = match &cli.config {
        Some(path) => {
            let text = std::fs::read_to_string(path).with_context(|| path.display().to_string())?;
            toml::from_str(&text).with_context(|| path.display().to_string())?
        }
        None => Settings::default(),
    };
    let bytes = std::fs::metadata(&cli.file).with_context(|| cli.file.display().to_string())?.len();
    if !bytes.is_multiple_of(4) {
        bail!("{}: {bytes} bytes is not a whole number of I/Q pairs", cli.file.display());
    }
    let frames = (bytes / 4) as usize;
    let meta = capture::read_meta(&cli.file).with_context(|| capture::meta_path(&cli.file).display().to_string())?;
    let a = Plot::from(cli.settings.over(file_settings), meta.as_ref().map(|m| m.rate_hz))?;
    let rate = a.rate;
    let i0 = (a.t0 * rate) as usize;
    let i1 = a.t1.map_or(frames, |t| (t * rate) as usize).min(frames);
    if i1 < i0 + 64 {
        bail!("t0/t1 select {} sample times of {frames}: need at least 64", i1.saturating_sub(i0));
    }
    let (lo, hi) = (a.lo.unwrap_or(-rate / 2.0).max(-rate / 2.0), a.hi.unwrap_or(rate / 2.0).min(rate / 2.0));
    if hi <= lo {
        bail!("lo {lo} must be below hi {hi}, both within +-rate/2");
    }
    let n = fft_size(a.fft, lo, hi, rate, a.width, i1 - i0)?;
    println!("{}: {} sample times = {:.6} s at {:.6} MS/s{}; analysing {:.6} .. {:.6} s",
             cli.file.display(), frames, frames as f64 / rate, rate / 1e6,
             meta.as_ref().map_or(String::new(), |m| format!(", channel {}, source {}", m.channel, m.source)),
             i0 as f64 / rate, i1 as f64 / rate);
    let g = Geometry { width: a.width, height: a.height, lo, hi, top: a.top_db, bottom: a.top_db - a.range_db };
    // the report alone needs no samples in memory: it streams the interval
    if let [View::Report] = a.views.as_slice()
        && a.png.is_none()
    {
        println!();
        let r = quality::analyze_file_range(&cli.file, rate, n, i0, i1 - i0)?
            .context("too short to analyse")?;
        return report_of(&r);
    }
    // every other view needs its interval; read only that, not the channel
    let x = capture::read_range(&cli.file, i0, i1 - i0).with_context(|| cli.file.display().to_string())?;
    for v in &a.views {
        println!();
        match v {
            View::Report => report(&x, rate, n)?,
            View::Spectrum => spectrum(&x, rate, n, &g)?,
            View::Waterfall => waterfall(&x, rate, n, &g),
            View::Time => time(&x[..2 * ((a.span * rate) as usize).clamp(16, i1 - i0)], rate, &g),
            View::Hist => hist(&x, &g),
            View::Iq => constellation(&x, &g),
            View::All => unreachable!("expanded in Plot::from"),
        }
    }
    if let Some(prefix) = &a.png {
        let views: Vec<View> = a.views.iter().filter(|v| **v != View::Report).copied().collect();
        anyhow::ensure!(!views.is_empty(), "--png writes the spectrum, waterfall, time, hist and iq views; --view report alone has no image");
        println!();
        png_views(&x, rate, n, &g, &views, prefix)?;
    }
    Ok(())
}

/// The FFT size: given, or 4096, or for a zoom the power of two that puts 4
/// bins under each plotted dot column (2 per cell): n = rate / (span / (8 w)).
/// Never more than the interval holds, never more than 2^20.
fn fft_size(given: Option<usize>, lo: f64, hi: f64, rate: f64, width: usize, frames: usize) -> Result<usize> {
    let fit = 1usize << (usize::BITS - 1 - frames.leading_zeros());
    let n = match given {
        Some(n) if !n.is_power_of_two() || n < 16 => bail!("fft {n}: a power of two >= 16"),
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
    report_of(&r)
}

/// Print a `Report`; the report view and the streamed file path share it.
fn report_of(r: &quality::Report) -> Result<()> {
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
        Some(t) => {
            let mirror = match t.mirror_dbc {
                Some(m) => format!("mirror {m:.1} dBc"),
                None => "mirror not measurable (inside the tone's or DC's main lobe)".to_string(),
            };
            println!("  tone      {} at {:.2} dBFS: SNR {:.1} dB, SINAD {:.1} dB, SFDR {:.1} dBc, ENOB {:.2}, {mirror}",
                     mhz(t.freq), t.dbfs, t.snr_db, t.sinad_db, t.sfdr_dbc, t.enob);
        }
        None => println!("  tone      none ({} dB above the floor needed)", 30),
    }
    println!("  floor     {:.1} dBFS per bin ({:.0} Hz) = {:.1} dBFS/Hz", r.floor_dbfs_bin, r.rate / r.fft as f64, r.floor_dbfs_hz);
    for s in &r.spurs {
        let unit = if r.tone.is_some() { "dBc" } else { "dBFS/bin" };
        println!("  spur      {} {:7.1} {unit}  {:?}", mhz(s.freq), s.db, s.kind);
    }
    if r.spurs.is_empty() {
        println!("  spur      none above the floor + {:.0} dB", quality::SPUR_DB);
    }
    println!("FINDINGS");
    for (k, f) in quality::findings(r).iter().enumerate() {
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
        dsp::dbfs(p)
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

// -- png --------------------------------------------------------------------------------------

/// 4 pixels per braille dot: the terminal views carry the labelled axes,
/// the images are the same data at 4x the dot grid.
const PNG_SCALE: u32 = 4;

/// The pixel row of value v on an axis bottom .. top in an image h tall.
fn row_px(v: f64, bottom: f64, top: f64, h: u32) -> u32 {
    (((top - v) / (top - bottom)).clamp(0.0, 1.0) * (h - 1) as f64).round() as u32
}

/// The spectrum's bins under pixel column c of w across [lo, hi].
fn bin_range(sp: &dsp::Spectrum, lo: f64, hi: f64, c: u32, w: u32) -> (usize, usize) {
    let n = sp.n();
    let at = |frac: f64| (lo + (hi - lo) * frac + sp.rate / 2.0) / sp.df();
    let k = |f: f64| f.round().clamp(0.0, (n - 1) as f64) as usize;
    let (a, b) = (k(at(c as f64 / w as f64)), k(at((c + 1) as f64 / w as f64)));
    (a.min(b), a.max(b))
}

/// The image views as PNG files, PREFIX_view.png. Grayscale, 8-bit:
/// brighter is more power (spectrum, waterfall) or more density (hist, iq);
/// the time view draws I bright over Q dimmer.
fn png_views(x: &[i16], rate: f64, n: usize, g: &Geometry, views: &[View], prefix: &std::path::Path) -> Result<()> {
    let (w, h) = (g.width as u32 * 2 * PNG_SCALE, g.height as u32 * 4 * PNG_SCALE);
    let frames = x.len() / 2;
    let stem = prefix.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "plot".into());
    let out = |name: &str| prefix.with_file_name(format!("{stem}_{name}.png"));
    for v in views {
        let (name, im) = match v {
            View::Spectrum => {
                let sp = dsp::welch(x, n, rate, 64).context("too short for a spectrum")?;
                let mut im = png::Gray::new(w, h);
                let mut db = g.top - 20.0;
                while db > g.bottom { // gridlines every 20 dB, and the DC line
                    for xx in 0..w { im.set(xx, row_px(db, g.bottom, g.top, h), 40); }
                    db -= 20.0;
                }
                let dc = (((0.0 - g.lo) / (g.hi - g.lo)).clamp(0.0, 1.0) * (w - 1) as f64).round() as u32;
                for y in 0..h { im.set(dc, y, 40); }
                for c in 0..w {
                    let (k0, k1) = bin_range(&sp, g.lo, g.hi, c, w);
                    let p = (k0..=k1).map(|k| sp.power[k]).fold(0.0, f64::max);
                    im.stem(c, row_px(dsp::dbfs(p), g.bottom, g.top, h), 255);
                }
                ("spectrum", im)
            }
            View::Waterfall => {
                let mut im = png::Gray::new(w, h);
                let rows = h as usize;
                let slice = (frames / rows).max(1);
                for r in 0..rows {
                    if frames < rows { break; }
                    let part = &x[2 * r * slice..2 * (r + 1) * slice];
                    let nw = n.min(1 << (usize::BITS - 1 - slice.leading_zeros()));
                    let Some(sp) = dsp::welch(part, nw, rate, 8) else { continue };
                    for c in 0..w {
                        let (k0, k1) = bin_range(&sp, g.lo, g.hi, c, w);
                        let p = (k0..=k1).map(|k| sp.power[k]).fold(0.0, f64::max);
                        let f = ((dsp::dbfs(p) - g.bottom) / (g.top - g.bottom)).clamp(0.0, 1.0);
                        im.set(c, r as u32, (f * 255.0).round() as u8);
                    }
                }
                ("waterfall", im)
            }
            View::Time => {
                let full = code_scale(x);
                let mut im = png::Gray::new(w, h);
                for c in 0..w {
                    let a = frames * c as usize / w as usize;
                    let b = (frames * (c + 1) as usize / w as usize).clamp(a + 1, frames);
                    let mut m = [(i16::MAX, i16::MIN); 2];
                    for k in a..b {
                        for (q, v) in [(0usize, x[2 * k]), (1, x[2 * k + 1])] {
                            m[q] = (m[q].0.min(v), m[q].1.max(v));
                        }
                    }
                    for (q, val) in [(1usize, 110u8), (0, 255)] {
                        im.band(c, row_px(m[q].1 as f64, -full, full, h), row_px(m[q].0 as f64, -full, full, h), val);
                    }
                }
                ("time", im)
            }
            View::Hist => {
                let mut count = [vec![0u64; 4096], vec![0u64; 4096]];
                for p in x.as_chunks::<2>().0 {
                    count[0][(p[0] as i32 + 2048) as usize] += 1;
                    count[1][(p[1] as i32 + 2048) as usize] += 1;
                }
                ("hist", hist_image(&count, w, h))
            }
            View::Iq => {
                let full = code_scale(x);
                let mut im = png::Gray::new(h, h); // square
                let stride = (frames / 200_000).max(1);
                for p in x.as_chunks::<2>().0.iter().step_by(stride) {
                    let cx = (((p[0] as f64 + full) / (2.0 * full)).clamp(0.0, 1.0) * (h - 1) as f64).round() as u32;
                    im.set(cx, row_px(p[1] as f64, -full, full, h), 255);
                }
                ("iq", im)
            }
            View::Report | View::All => unreachable!("filtered and expanded"),
        };
        let path = out(name);
        im.write(&path).with_context(|| path.display().to_string())?;
        println!("png {} ({} x {})", path.display(), im.w, im.h);
    }
    Ok(())
}

/// The code histogram as an image: each channel's count per code as a
/// trace over the codes that were hit (the axis spans just that range, so a
/// distribution over a few dozen codes is a shape, not a spike on a
/// 4096-code axis), high count toward the top, log scale. I is bright, Q
/// dimmer; a bell is noise, a bowl a sinusoid's arcsine distribution.
fn hist_image(count: &[Vec<u64>], w: u32, h: u32) -> png::Gray {
    let top = count.iter().flatten().copied().max().unwrap_or(1) as f64;
    let first = count.iter().flat_map(|c| c.iter().position(|v| *v > 0)).min().unwrap_or(0);
    let last = count.iter().flat_map(|c| c.iter().rposition(|v| *v > 0)).max().unwrap_or(4095);
    let span = (last - first + 1).max(1);
    let mut im = png::Gray::new(w, h);
    for (q, val) in [(1usize, 110u8), (0, 255)] {
        let mut prev: Option<u32> = None;
        for c in 0..w {
            let a = first + span * c as usize / w as usize;
            let b = (first + span * (c as usize + 1) / w as usize).max(a + 1).min(4096);
            let k: u64 = count[q][a..b].iter().sum();
            let frac = ((k as f64 + 1.0).log10() / (top + 1.0).log10()).clamp(0.0, 1.0);
            let y = ((1.0 - frac) * (h - 1) as f64).round() as u32;
            if let Some(p) = prev { im.band(c, p, y, val); } else { im.set(c, y, val); }
            prev = Some(y);
        }
    }
    im
}

/// A minimal 8-bit grayscale PNG writer: signature, one IHDR, one IDAT
/// (zlib with stored deflate blocks, so there is no compressor to depend
/// on), IEND. No filters: the rows are the pixels.
mod png {
    /// An 8-bit grayscale image, one byte per pixel, 0 = black.
    pub struct Gray { pub w: u32, pub h: u32, pub(super) px: Vec<u8> }

    impl Gray {
        pub fn new(w: u32, h: u32) -> Gray { Gray { w, h, px: vec![0; w as usize * h as usize] } }
        pub fn set(&mut self, x: u32, y: u32, v: u8) {
            if x < self.w && y < self.h { self.px[y as usize * self.w as usize + x as usize] = v; }
        }
        /// One column from row y down to the bottom (a spectrum's stem).
        pub fn stem(&mut self, x: u32, y: u32, v: u8) { for yy in y..self.h { self.set(x, yy, v); } }
        /// One column between rows y0 and y1 (a time/hist bar).
        pub fn band(&mut self, x: u32, y0: u32, y1: u32, v: u8) {
            for yy in y0.min(y1)..=y0.max(y1) { self.set(x, yy, v); }
        }
        pub fn write(&self, path: &std::path::Path) -> std::io::Result<()> {
            let mut out = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A].to_vec();
            let mut ihdr = self.w.to_be_bytes().to_vec();
            ihdr.extend_from_slice(&self.h.to_be_bytes());
            ihdr.extend_from_slice(&[8, 0, 0, 0, 0]); // 8-bit grayscale, deflate, no filter, no interlace
            chunk(&mut out, b"IHDR", &ihdr);
            let mut raw = Vec::with_capacity(self.px.len() + self.h as usize);
            for row in self.px.chunks(self.w as usize) { raw.push(0); raw.extend_from_slice(row); }
            let mut idat = vec![0x78, 0x01]; // zlib header: deflate, no dictionary
            let mut rest = &raw[..];
            while !rest.is_empty() { // stored deflate blocks, at most 65 535 bytes each
                let take = rest.len().min(65_535);
                let (block, left) = rest.split_at(take);
                idat.push(left.is_empty() as u8); // BFINAL, BTYPE 00 = stored
                idat.extend_from_slice(&(take as u16).to_le_bytes());
                idat.extend_from_slice(&(!(take as u16)).to_le_bytes());
                idat.extend_from_slice(block);
                rest = left;
            }
            idat.extend_from_slice(&adler32(&raw).to_be_bytes());
            chunk(&mut out, b"IDAT", &idat);
            chunk(&mut out, b"IEND", &[]);
            std::fs::write(path, out)
        }
    }

    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(data);
        let mut c = Vec::with_capacity(4 + data.len());
        c.extend_from_slice(kind);
        c.extend_from_slice(data);
        out.extend_from_slice(&crc32(&c).to_be_bytes());
    }

    /// CRC-32 (ISO 3309), PNG's chunk checksum.
    pub(super) fn crc32(data: &[u8]) -> u32 {
        let mut table = [0u32; 256];
        for (i, t) in table.iter_mut().enumerate() {
            let mut c = i as u32;
            for _ in 0..8 { c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 }; }
            *t = c;
        }
        let mut c = 0xFFFF_FFFF;
        for &b in data { c = table[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8); }
        c ^ 0xFFFF_FFFF
    }

    /// Adler-32 (RFC 1950), the zlib stream's checksum.
    pub(super) fn adler32(data: &[u8]) -> u32 {
        let (mut a, mut b) = (1u32, 0u32);
        for &x in data { a = (a + x as u32) % 65_521; b = (b + a) % 65_521; }
        (b << 16) | a
    }
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
    fn a_config_file_uses_the_flag_names_and_flags_override_it() {
        let file: Settings = toml::from_str("view = [\"report\", \"spectrum\"]\nfft = 65536\nlo = -2e6\nhi = 2e6\nwidth = 80\n").unwrap();
        let cli = Cli::parse_from(["b210-plot", "x.raw", "--fft", "8192", "--height", "20"]);
        let s = cli.settings.over(file);
        assert_eq!(s.fft, Some(8192), "the flag wins");
        assert_eq!((s.lo, s.hi, s.width, s.height), (Some(-2e6), Some(2e6), Some(80), Some(20)));
        let p = Plot::from(s, Some(30.72e6)).unwrap();
        assert_eq!(p.views, vec![View::Report, View::Spectrum]);
        assert_eq!((p.top_db, p.range_db, p.t0), (0.0, 110.0, 0.0), "defaults fill the rest");
        // every flag is a key: a file naming each one parses
        let all = "rate = 1e6\nview = [\"all\"]\nfft = 4096\nlo = 0\nhi = 1\ntop_db = 0\nrange_db = 90\n\
                   t0 = 0\nt1 = 1\nspan = 1e-4\nwidth = 50\nheight = 10\npng = \"out/plot\"\n";
        assert!(toml::from_str::<Settings>(all).is_ok());
        // negative controls: an unknown key, and a rate from nowhere
        assert!(toml::from_str::<Settings>("ftt = 4096\n").is_err());
        assert!(Plot::from(Settings::default(), None).is_err());
        assert!(Plot::from(Settings { width: Some(5), ..Default::default() }, Some(1e6)).is_err());
    }

    #[test]
    fn crc32_and_adler32_match_their_check_values() {
        assert_eq!(png::crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(png::adler32(b"abc"), (589 << 16) | 295);
    }

    /// Walk the chunks of a written file, inflate the stored blocks by hand
    /// and compare every pixel: the writer's structure is the test.
    #[test]
    fn a_written_png_parses_back_to_the_same_pixels() {
        let mut g = png::Gray::new(5, 3);
        g.set(2, 1, 200);
        g.stem(4, 1, 7);
        g.band(0, 0, 2, 9);
        g.set(9, 9, 1); // outside: ignored
        let p = std::env::temp_dir().join(format!("b210-plot-png-{}.png", std::process::id()));
        g.write(&p).unwrap();
        let b = std::fs::read(&p).unwrap();
        std::fs::remove_file(&p).ok();
        assert_eq!(&b[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        let (mut at, mut w, mut h, mut idat) = (8usize, 0u32, 0u32, Vec::new());
        while at < b.len() {
            let len = u32::from_be_bytes(b[at..at + 4].try_into().unwrap()) as usize;
            let kind = &b[at + 4..at + 8];
            let data = &b[at + 8..at + 8 + len];
            let want = u32::from_be_bytes(b[at + 8 + len..at + 12 + len].try_into().unwrap());
            let mut c = kind.to_vec();
            c.extend_from_slice(data);
            assert_eq!(png::crc32(&c), want, "{kind:?}");
            match kind {
                b"IHDR" => {
                    w = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    h = u32::from_be_bytes(data[4..8].try_into().unwrap());
                    assert_eq!(&data[8..], &[8, 0, 0, 0, 0]);
                }
                b"IDAT" => idat.extend_from_slice(data),
                b"IEND" => break,
                other => panic!("unexpected chunk {other:?}"),
            }
            at += 12 + len;
        }
        assert_eq!((w, h), (5, 3));
        assert_eq!(&idat[..2], &[0x78, 0x01]);
        let (mut i, mut raw) = (2usize, Vec::new());
        loop {
            let last = idat[i] & 1 != 0;
            assert_eq!(idat[i] >> 1, 0, "stored blocks only");
            let len = u16::from_le_bytes(idat[i + 1..i + 3].try_into().unwrap()) as usize;
            assert_eq!(len as u16, !u16::from_le_bytes(idat[i + 3..i + 5].try_into().unwrap()));
            raw.extend_from_slice(&idat[i + 5..i + 5 + len]);
            i += 5 + len;
            if last { break; }
        }
        assert_eq!(&idat[i..], &png::adler32(&raw).to_be_bytes());
        for y in 0..h as usize {
            assert_eq!(raw[y * (w as usize + 1)], 0, "filter none");
            for x in 0..w as usize {
                assert_eq!(raw[y * (w as usize + 1) + 1 + x], g.px[y * w as usize + x]);
            }
        }
    }

    #[test]
    fn the_histogram_zooms_to_the_hit_codes_and_puts_high_counts_on_top() {
        let mut count = vec![vec![0u64; 4096], vec![0u64; 4096]];
        let bell = [1u64, 3, 10, 30, 100, 300, 1000, 1000, 300, 100, 30, 10, 3, 1];
        for (k, v) in bell.iter().enumerate() { count[0][2100 + k] = *v; }
        let (w, h) = (80u32, 40u32);
        let im = hist_image(&count, w, h);
        let first_y = |x: u32| (0..h).find(|&y| im.px[(y * w + x) as usize] > 0);
        let centre = first_y(w / 2).expect("the peak is drawn");
        let tail = first_y(1).expect("the first occupied code is drawn");
        assert!(centre < tail, "the peak is above the tail: {centre} vs {tail}");
        // the 14 hit codes span the whole width: the axis zoomed to them
        assert!(first_y(w - 3).is_some(), "no trace at the right edge");
    }

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
        assert_eq!(col.iter().filter(|d| **d > dsp::dbfs(1e5)).count(), 1);
    }

    #[test]
    fn code_scale_is_a_power_of_two_above_the_peak() {
        assert_eq!(code_scale(&[100, -3]), 128.0);
        assert_eq!(code_scale(&[2047, -2048]), 2048.0);
        assert_eq!(code_scale(&[0, 0]), 16.0);
    }
}
