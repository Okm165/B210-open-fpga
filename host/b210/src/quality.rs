//! Signal quality of one captured channel: the numbers an RF engineer
//! reads off a receiver, each with its derivation, and plain-language
//! findings with what to do about them.
//!
//! Everything is relative to a full-scale complex tone (0 dBFS: |x| = 2048
//! codes, `capture::FULL_SCALE`), see `dsp`.
//!
//! Level (time domain, all samples):
//!   DC        mean of I and of Q; `dc_dbfs` = power of the mean.
//!   rms, peak `rms_dbfs` = mean |x|^2 after removing DC; `peak_dbfs` from
//!             the largest |x|; crest factor = peak / rms (a tone: 0 dB,
//!             Gaussian noise: about 10-12 dB). Headroom for a signal of
//!             crest C is about -C dBFS.
//!   clipped   fraction of I/Q values at the code limits (-2048 or 2047),
//!             and the longest run of consecutive sample times with one:
//!             a burst edge and a one-sample glitch are not the same event.
//!
//! I/Q balance (time domain, DC removed). With Pi = E[I^2], Pq = E[Q^2],
//! Piq = E[I Q]:
//!   gain imbalance  g = sqrt(Pi / Pq), reported as 20 log10 g dB
//!   phase skew      phi = asin(Piq / sqrt(Pi Pq))
//!   image rejection IRR = (1 + 2 g cos phi + g^2) / (1 - 2 g cos phi + g^2)
//! valid for a circular signal (one whose I and Q are uncorrelated with
//! equal power when the receiver is perfect: a tone off DC, noise, any
//! modulated carrier). A real-valued signal (|rho| = |Piq| / sqrt(Pi Pq)
//! near 1, e.g. the FPGA's test pattern I = t, Q = ~t) has no meaningful
//! balance; `circular` says which case applies. The spectrum gives an
//! independent IRR when a tone is present: the image bin at -f.
//!
//! Caveat, measured: `rho` is the received signal's own statistic, so a
//! strong external carrier moves the time-domain estimate (two captures of
//! the same receiver, 44.2 dB and 59.4 dB, differed only in which ambient
//! carrier fell in band). Read it on noise alone (circular by construction)
//! or, with a tone, from the spectrum's image bin, which does not depend on
//! what else is in band.
//!
//! Tone (frequency domain, when one bin stands 30 dB above the median bin):
//!   power     the main lobe, +-`dsp::LOBE` bins
//!   SNR       tone / noise, noise = every bin except the tone, DC (+-3
//!             bins), harmonics 2..5 and the image (+-LOBE bins each), scaled
//!             up to the whole band by the fraction of bins excluded
//!   SINAD     tone / everything else except DC
//!             (every sum is over a bin mask, so a tone close to DC, whose
//!             lobe overlaps the DC bins, is never counted twice)
//!   SFDR      tone's peak bin / the largest other bin outside DC, dBc
//!             (peak bin to peak bin; a tone between bins loses a fraction
//!             of a dB to the window's scalloping)
//!   ENOB      (SINAD - 1.76 dB - tone dBFS) / 6.02: the bits of an ideal
//!             converter with the same SINAD at full scale. A perfect 12-bit
//!             capture of a full-scale tone gives 12.
//!   mirror    a component at the tone's mirror frequency is labelled
//!             MIRROR, not IMAGE: an I/Q image and a real signal there look
//!             the same in one capture. Moving the LO separates them - the
//!             image keeps the tone's offset mirrored, a real signal moves
//!             the other way. The mirror is only measured when its main
//!             lobe is disjoint from the tone's and from DC's: a tone within
//!             2 x LOBE bins of DC has its mirror band over the DC lobe, and
//!             the power read there is DC leakage, not a mirror.
//!   floor     the median bin, turned into the mean: a bin averaged over K
//!             segments is Gamma(K) distributed, whose median is the mean
//!             times about (1 - 1/(9K))^3 (Wilson-Hilferty; K = 1 gives
//!             0.70, the exponential's ln 2 = 0.69). Density = mean bin /
//!             bin width, dBFS/Hz.

use crate::dsp::{self, Spectrum};
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

#[derive(Clone, Debug)]
pub struct Level {
    pub dc_i: f64,
    pub dc_q: f64,
    pub dc_dbfs: f64,
    pub rms_dbfs: f64,
    pub peak_dbfs: f64,
    pub crest_db: f64,
    pub clipped_fraction: f64,
    /// Consecutive sample times with a value at a code limit (0: none).
    pub longest_clip: usize,
}

#[derive(Clone, Debug)]
pub struct Balance {
    pub gain_db: f64,
    pub phase_deg: f64,
    pub irr_db: f64,
    /// correlation of I and Q, -1 ..= 1
    pub rho: f64,
    /// |rho| < 0.9: the balance numbers mean something
    pub circular: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SpurKind {
    Harmonic(u32),
    /// A component at the tone's mirror frequency (an I/Q image or a real
    /// signal there - one capture cannot tell them apart).
    Mirror,
    Other,
}

#[derive(Clone, Debug)]
pub struct Spur {
    pub freq: f64,
    /// relative to the tone (dBc) when there is one, else dBFS per bin
    pub db: f64,
    pub kind: SpurKind,
}

#[derive(Clone, Debug)]
pub struct Tone {
    pub freq: f64,
    pub dbfs: f64,
    /// fraction of the signal's power (DC excluded) in the tone: near 1 for
    /// a single tone; the SNR/SINAD/ENOB of a signal with several strong
    /// components describe its largest one only
    pub share: f64,
    pub snr_db: f64,
    pub sinad_db: f64,
    pub sfdr_dbc: f64,
    pub enob: f64,
    /// Power at the mirror frequency relative to the tone; None when the
    /// mirror band is not disjoint from the tone's or DC's main lobe.
    pub mirror_dbc: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct Report {
    pub frames: usize,
    pub rate: f64,
    pub level: Level,
    pub balance: Balance,
    pub tone: Option<Tone>,
    pub spurs: Vec<Spur>,
    /// median bin, dBFS per bin, and the same as a density, dBFS/Hz
    pub floor_dbfs_bin: f64,
    pub floor_dbfs_hz: f64,
    pub fft: usize,
}

use crate::dsp::LOBE;
/// A peak must stand this far above the estimated floor to be called a
/// spur. With `segments` averaged, the largest of the noise's own bins sits
/// about 4-5 dB over the median (measured on the board: wifi-like noise, no
/// carrier, 4096 bins, 64 segments), so 10 dB is not noise.
pub const SPUR_DB: f64 = 10.0;

/// A tone must stand this far above the median bin to be analysed as one.
const TONE_DB: f64 = 30.0;

/// The sums one streaming pass over a capture can carry: n sample times, I,
/// Q, their squares and product, and the values at a code limit. Everything
/// in `level` and `balance` follows from these, so a file can be analysed in
/// bounded memory and a slice gets the same numbers from the same code.
#[derive(Clone, Copy, Default)]
struct Moments {
    n: usize,
    si: f64,
    sq: f64,
    si2: f64,
    sq2: f64,
    siq: f64,
    clip_values: usize,
    /// The run being counted, and the longest one seen: consecutive sample
    /// times with at least one value at a code limit.
    clip_run: usize,
    clip_longest: usize,
}

impl Moments {
    fn add(&mut self, i: i16, q: i16) {
        let rail = |v: i16| v <= -2048 || v >= 2047;
        if rail(i) || rail(q) {
            self.clip_values += rail(i) as usize + rail(q) as usize;
            self.clip_run += 1;
            self.clip_longest = self.clip_longest.max(self.clip_run);
        } else {
            self.clip_run = 0;
        }
        let (i, q) = (i as f64, q as f64);
        self.n += 1;
        self.si += i;
        self.sq += q;
        self.si2 += i * i;
        self.sq2 += q * q;
        self.siq += i * q;
    }

    fn of(s: &[i16]) -> Moments {
        let mut m = Moments::default();
        for p in s.as_chunks::<2>().0 { m.add(p[0], p[1]); }
        m
    }

    fn dc(&self) -> (f64, f64) {
        let n = self.n.max(1) as f64;
        (self.si / n, self.sq / n)
    }

    /// The balance with DC removed: Pi, Pq and Piq are the sums' DC-corrected
    /// forms (E[x^2] - E[x]^2 and E[I Q] - E[I] E[Q], times n).
    fn balance(&self) -> Balance {
        let (di, dq) = self.dc();
        let n = self.n as f64;
        let (pi, pq, piq) = (self.si2 - n * di * di, self.sq2 - n * dq * dq, self.siq - n * di * dq);
        if pi <= 0.0 || pq <= 0.0 {
            return Balance { gain_db: 0.0, phase_deg: 0.0, irr_db: 0.0, rho: 0.0, circular: false };
        }
        let g = (pi / pq).sqrt();
        let rho = piq / (pi * pq).sqrt();
        let phi = rho.clamp(-1.0, 1.0).asin();
        let c = 2.0 * g * phi.cos();
        let irr = (1.0 + c + g * g) / (1.0 - c + g * g).max(1e-30);
        Balance { gain_db: 20.0 * g.log10(), phase_deg: phi.to_degrees(), irr_db: 10.0 * irr.log10(), rho, circular: rho.abs() < 0.9 }
    }
}

/// `Moments` plus one pass over the samples for the DC-removed power and
/// peak: the mean is only known after the first pass.
fn finish(m: &Moments, pairs: impl Iterator<Item = (i16, i16)>) -> Level {
    let n = (m.n.max(1)) as f64;
    let (dc_i, dc_q) = m.dc();
    let (mut pow, mut peak) = (0.0f64, 0.0f64);
    for (i, q) in pairs {
        let (i, q) = (i as f64 - dc_i, q as f64 - dc_q);
        let x = i * i + q * q;
        pow += x;
        peak = peak.max(x);
    }
    pow /= n;
    Level {
        dc_i, dc_q,
        dc_dbfs: dsp::dbfs(dc_i * dc_i + dc_q * dc_q),
        rms_dbfs: dsp::dbfs(pow),
        peak_dbfs: dsp::dbfs(peak),
        crest_db: if pow > 0.0 { 10.0 * (peak / pow).log10() } else { 0.0 },
        clipped_fraction: m.clip_values as f64 / (2.0 * n),
        longest_clip: m.clip_longest,
    }
}

pub fn analyze(s: &[i16], rate: f64, fft: usize) -> Option<Report> {
    let sp = dsp::welch(s, fft, rate, 64)?;
    let m = Moments::of(s);
    let level = finish(&m, s.as_chunks::<2>().0.iter().map(|p| (p[0], p[1])));
    report(sp, s.len() / 2, rate, level, m.balance())
}

/// `analyze` of a capture file, in bounded memory: one pass for the sums,
/// one for the DC-removed power and peak, and one read per spectrum segment
/// (at most 64 segments of `n` frames each). The file is the raw format of
/// `capture`: interleaved little-endian i16, 4 bytes per sample time.
pub fn analyze_file(path: &Path, rate: f64, fft: usize) -> io::Result<Option<Report>> {
    let bytes = std::fs::metadata(path)?.len();
    if !bytes.is_multiple_of(4) {
        return Err(io::Error::new(io::ErrorKind::InvalidData,
            format!("{}: {bytes} bytes is not a whole number of I/Q pairs", path.display())));
    }
    analyze_file_range(path, rate, fft, 0, (bytes / 4) as usize)
}

/// `analyze_file` of `frames` sample times starting at `first`, which is
/// what `b210-plot` selects with t0/t1: the same bounded memory and the same
/// numbers as analysing that slice in memory.
pub fn analyze_file_range(path: &Path, rate: f64, fft: usize, first: usize, frames: usize) -> io::Result<Option<Report>> {
    if frames < 16 { return Ok(None); }
    let mut m = Moments::default();
    for p in pairs(File::open(path)?).skip(first).take(frames) { let (i, q) = p?; m.add(i, q); }
    let level = finish(&m, pairs(File::open(path)?).skip(first).take(frames)
        .map(|p| p.expect("the length was checked")));
    let mut f = File::open(path)?;
    let Some(sp) = dsp::welch_read(frames, fft, rate, 64, |start, seg| {
        use std::io::{Seek, SeekFrom};
        f.seek(SeekFrom::Start(4 * (first + start) as u64)).expect("the range was checked");
        let mut bytes = vec![0u8; 2 * seg.len()];
        f.read_exact(&mut bytes).expect("the segment lies within the range");
        for (v, b) in seg.iter_mut().zip(bytes.as_chunks::<2>().0) { *v = i16::from_le_bytes(*b); }
    }) else { return Ok(None) };
    Ok(report(sp, frames, rate, level, m.balance()))
}

/// The report both paths share: everything after the spectrum and the level.
fn report(sp: Spectrum, frames: usize, rate: f64, level: Level, balance: Balance) -> Option<Report> {
    let n = sp.n();
    let mut sorted = sp.power.clone();
    sorted.sort_by(f64::total_cmp);
    let median = sorted[n / 2].max(1e-30);
    let k = sp.segments as f64;
    let floor_bin = median / (1.0 - 1.0 / (9.0 * k)).powi(3);
    let dc = n / 2;
    let near = |a: usize, b: usize| { let d = a.abs_diff(b); d.min(n - d) <= LOBE };
    let peak = (0..n).filter(|&k| !near(k, dc)).max_by(|a, b| sp.power[*a].total_cmp(&sp.power[*b]))?;
    let has_tone = sp.power[peak] > median * 10f64.powf(TONE_DB / 10.0);
    let (tone, spurs) = if has_tone { tone(&sp, peak) } else { (None, spurs_of(&sp, None, floor_bin)) };
    Some(Report {
        frames, rate, level, balance, tone, spurs,
        floor_dbfs_bin: dsp::dbfs(floor_bin),
        floor_dbfs_hz: dsp::dbfs(floor_bin / sp.df()),
        fft: n,
    })
}

/// The (I, Q) pairs of a raw capture file, one 64 KiB read at a time, so the
/// whole file is never held. A file whose last read leaves a half pair is an
/// error, since `capture` wrote 4 bytes per sample time.
fn pairs<R: std::io::Read>(mut r: R) -> impl Iterator<Item = io::Result<(i16, i16)>> {
    let mut buf = vec![0u8; 1 << 16];
    let (mut filled, mut pos) = (0usize, 0usize);
    std::iter::from_fn(move || {
        if pos + 4 > filled {
            filled = match r.read(&mut buf) { Ok(0) => return None, Ok(k) => k, Err(e) => return Some(Err(e)) };
            pos = 0;
            if filled % 4 != 0 {
                return Some(Err(io::Error::new(io::ErrorKind::InvalidData, "a partial I/Q pair at the end")));
            }
        }
        let i = i16::from_le_bytes([buf[pos], buf[pos + 1]]);
        let q = i16::from_le_bytes([buf[pos + 2], buf[pos + 3]]);
        pos += 4;
        Some(Ok((i, q)))
    })
}

/// Circular distance between bins, in 0 ..= n/2.
fn apart(a: usize, b: usize, n: usize) -> usize {
    let d = a.abs_diff(b);
    d.min(n - d)
}

/// The mirror band is usable only when its main lobe (radius LOBE) meets
/// neither the tone's nor DC's.
fn mirror_separated(sp: &Spectrum, k0: usize, km: usize) -> bool {
    apart(km, k0, sp.n()) > 2 * LOBE && apart(km, sp.n() / 2, sp.n()) > 2 * LOBE
}

fn tone(sp: &Spectrum, k0: usize) -> (Option<Tone>, Vec<Spur>) {
    let n = sp.n();
    // frequency: power-weighted centroid of the main lobe
    let (mut wsum, mut fsum) = (0.0, 0.0);
    for d in 0..=2 * LOBE {
        let k = (k0 + n + d - LOBE) % n;
        let off = d as f64 - LOBE as f64;
        wsum += sp.power[k];
        fsum += sp.power[k] * (sp.freq(k0) + off * sp.df());
    }
    let f = fsum / wsum;
    let p_tone = sp.band(k0, LOBE);
    let mut mask = vec![false; n];
    let cover = |k: usize, mask: &mut Vec<bool>| for d in 0..=2 * LOBE { mask[(k + n + d - LOBE) % n] = true; };
    cover(k0, &mut mask);
    cover(n / 2, &mut mask);
    let total: f64 = sp.power.iter().sum();
    let p_dc_only: f64 = (0..n).filter(|k| { let d = k.abs_diff(n / 2); d.min(n - d) <= LOBE } )
        .filter(|k| !{ let d = k.abs_diff(k0); d.min(n - d) <= LOBE }).map(|k| sp.power[k]).sum();
    // everything outside the tone and DC: one pass over the mask
    let sinad_noise = (0..n).filter(|k| !mask[*k]).map(|k| sp.power[k]).sum::<f64>().max(1e-30);
    let km = sp.bin(-f);
    let mirror_dbc = mirror_separated(sp, k0, km)
        .then(|| 10.0 * (sp.band(km, LOBE) / p_tone).log10());
    // the largest bin outside the tone and DC: the SFDR spur
    let spur_peak = (0..n).filter(|k| !mask[*k]).map(|k| sp.power[k]).fold(1e-30, f64::max);
    let mut nmask = mask.clone();
    for h in 2..=5 { cover(sp.bin(h as f64 * f), &mut nmask); }
    cover(sp.bin(-f), &mut nmask);
    let (mut noise, mut m) = (0.0, 0usize);
    for (p, masked) in sp.power.iter().zip(&nmask) { if !masked { noise += p; m += 1; } }
    let noise_band = (noise * n as f64 / m.max(1) as f64).max(1e-30);
    let dbfs = dsp::dbfs(p_tone);
    let sinad = 10.0 * (p_tone / sinad_noise).log10();
    let t = Tone {
        freq: f, dbfs,
        share: p_tone / (total - p_dc_only).max(1e-30),
        snr_db: 10.0 * (p_tone / noise_band).log10(),
        sinad_db: sinad,
        sfdr_dbc: 10.0 * (sp.power[k0] / spur_peak).log10(),
        // ENOB for a full-scale tone; `dbfs` (negative) refers the measured
        // SINAD of this tone up to full scale, so enob <= (snr + |dbfs| -
        // 1.76) / 6.02: it is always below what the noise alone would give.
        enob: (sinad - 1.76 - dbfs) / 6.02,
        mirror_dbc,
    };
    let spurs = spurs_of(sp, Some((k0, f, p_tone)), 0.0);
    (Some(t), spurs)
}

/// The strongest local maxima outside DC and the tone, classified.
fn spurs_of(sp: &Spectrum, tone: Option<(usize, f64, f64)>, floor_bin: f64) -> Vec<Spur> {
    let n = sp.n();
    let near = |a: usize, b: usize, r: usize| { let d = a.abs_diff(b); d.min(n - d) <= r };
    let p = &sp.power;
    let above = floor_bin * 10f64.powf(SPUR_DB / 10.0);
    let mut peaks: Vec<usize> = (0..n).filter(|&k| {
        p[k] > above && p[k] > p[(k + n - 1) % n] && p[k] >= p[(k + 1) % n]
            && !near(k, n / 2, LOBE) && tone.is_none_or(|(k0, _, _)| !near(k, k0, LOBE))
    }).collect();
    peaks.sort_by(|a, b| p[*b].total_cmp(&p[*a]));
    peaks.truncate(6);
    peaks.into_iter().map(|k| {
        let (db, kind) = match tone {
            Some((k0, f, _)) => {
                let km = sp.bin(-f);
                let kind = if near(k, km, LOBE) && mirror_separated(sp, k0, km) { SpurKind::Mirror }
                    else if let Some(h) = (2..=5).find(|h| near(k, sp.bin(*h as f64 * f), LOBE)) { SpurKind::Harmonic(h) }
                    else { SpurKind::Other };
                (10.0 * (p[k] / p[k0]).log10(), kind)
            }
            None => (dsp::dbfs(p[k]), SpurKind::Other),
        };
        Spur { freq: sp.freq(k), db, kind }
    }).collect()
}

/// The clipped fraction at which a capture stops being a measurement of the
/// input. One value in a million: in a 1,048,576-sample analysis (64 x 16384,
/// `analyze`) that is about one clipped value per block, and every further
/// step adds broadband distortion above the 12-bit floor. Below it, isolated
/// values are reported but the capture is kept - an input may legitimately
/// exceed full scale for one sample, and refusing 918 M good samples over one
/// rail code is not a measurement rule.
pub const CLIP_REFUSE: f64 = 1e-6;

/// Is the clipping enough that the capture must be refused?
pub fn clipping_refuses(l: &Level) -> bool {
    l.clipped_fraction >= CLIP_REFUSE
}

/// What the clipping means, in two grades: material (refused; the gain advice
/// is the peak over the rails plus 3 dB of headroom) and isolated (reported,
/// kept). Both state the longest run: one sample is a transient, a run is the
/// edge of a burst.
pub fn clipping_note(l: &Level) -> Option<String> {
    let run = if l.longest_clip == 1 { "1 sample time".to_string() } else { format!("{} sample times", l.longest_clip) };
    if l.clipped_fraction >= CLIP_REFUSE {
        Some(format!("CLIPPING: {:.4}% of I/Q values sit at the code limits - the ADC saturates, so every \
            spectral number is distorted. Lower the rx gain by at least {:.0} dB (crest factor + 3 dB headroom); \
            the longest clipped run is {run}.",
            100.0 * l.clipped_fraction, (l.peak_dbfs + l.crest_db + 3.0).max(3.0)))
    } else if l.clipped_fraction > 0.0 {
        Some(format!("CLIPPING, isolated: {:.1e} of I/Q values sit at the code limits, below the {:.0e} at which \
            a capture is refused; the input exceeded full scale for those samples only (longest run {run}).",
            l.clipped_fraction, CLIP_REFUSE))
    } else {
        None
    }
}

/// What the numbers say, most serious first, each with its cause and fix.
pub fn findings(r: &Report) -> Vec<String> {
    let mut out = Vec::new();
    let l = &r.level;
    if let Some(note) = clipping_note(l) {
        out.push(note);
    } else if l.peak_dbfs < -40.0 {
        out.push(format!("LOW LEVEL: the peak is {:.1} dBFS, {:.0} dB of the converter's range unused; \
            raise the rx gain (aim for a peak near {:.0} dBFS).", l.peak_dbfs, -l.peak_dbfs, -l.crest_db.max(3.0) - 3.0));
    }
    if l.clipped_fraction == 0.0 && l.crest_db > 20.0 {
        out.push(format!("IMPULSIVE: crest factor {:.1} dB (Gaussian noise is about 10-12 dB) - bursts or \
            transients dominate the peak, while the rms and the floor describe the background between them; \
            b210-plot --view time shows where they are.", l.crest_db));
    }
    let dc_dbc = l.dc_dbfs - l.rms_dbfs;
    if l.dc_dbfs > -60.0 && dc_dbc > -40.0 {
        out.push(format!("DC OFFSET: I {:+.1}, Q {:+.1} codes ({:.1} dBFS, {:.1} dB relative to the signal) - \
            LO leakage or baseband offset; the AD9361's BB and RF DC tracking remove it.", l.dc_i, l.dc_q, l.dc_dbfs, dc_dbc));
    }
    let b = &r.balance;
    if !b.circular {
        out.push(format!("REAL-VALUED SIGNAL: I and Q are locked together (correlation {:+.3}), so the signal has a \
            mirror image of itself at -f and I/Q balance cannot be judged from it. Expected for the FPGA test pattern \
            (I = t, Q = ~t = -t - 1).", b.rho));
    } else if b.irr_db < 40.0 {
        out.push(format!("I/Q IMBALANCE: gain {:+.2} dB, phase {:+.2} deg -> image rejection {:.1} dB; anything at +f \
            appears at -f only {:.1} dB down. The AD9361 RX quadrature tracking corrects it.", b.gain_db, b.phase_deg, b.irr_db, b.irr_db));
    }
    if let Some(t) = r.tone.as_ref().filter(|t| t.share < 0.9) {
        out.push(format!("SEVERAL COMPONENTS: the strongest one ({:.3} kHz) holds only {:.0}% of the power, so the \
            signal is not a single tone and SNR/SINAD/ENOB below describe that component, not the receiver.",
            t.freq / 1e3, 100.0 * t.share));
    }
    if let Some(t) = &r.tone {
        // the quantisation limit of a 12-bit converter for a tone at this level
        let limit = 6.02 * 12.0 + 1.76 + t.dbfs;
        out.push(format!("TONE {:.3} kHz at {:.1} dBFS: SNR {:.1} dB, SINAD {:.1} dB, SFDR {:.1} dBc, ENOB {:.2} bits \
            (an ideal 12-bit converter gives SNR {:.1} dB at this level).",
            t.freq / 1e3, t.dbfs, t.snr_db, t.sinad_db, t.sfdr_dbc, t.enob, limit));
        if let Some(m) = t.mirror_dbc.filter(|m| b.circular && *m > -40.0) {
            // The mirror of a tone is either its I/Q image or a second signal
            // at that frequency; one capture cannot tell them apart (a crowded
            // band has both). Moving the LO separates them: the image keeps
            // the tone's offset mirrored, a real signal moves the other way.
            out.push(format!("MIRROR at {:.3} kHz, {:.1} dBc: a component at the tone's mirror frequency - its I/Q \
                image or a second signal there. The time-domain balance estimates {:.1} dB, which describes a \
                single coherent tone only; move the LO: the image keeps the tone's offset mirrored, a real signal \
                moves the other way.", -t.freq / 1e3, m, b.irr_db));
        }
        let harmonic = r.spurs.iter().find(|s| matches!(s.kind, SpurKind::Harmonic(_)) && s.db > -60.0);
        if let Some(s) = harmonic {
            out.push(format!("HARMONIC {:?} at {:.3} kHz, {:.1} dBc: nonlinearity - an overdriven stage (too much \
                gain before the ADC) or a test signal that is itself not a sine.", s.kind, s.freq / 1e3, s.db));
        }
        if let Some(s) = r.spurs.iter().find(|s| s.kind == SpurKind::Other && s.db > -60.0) {
            out.push(format!("SPUR at {:.3} kHz, {:.1} dBc, not a harmonic or the image: an interferer, a clock \
                product, or a second signal in the band.", s.freq / 1e3, s.db));
        }
    } else {
        out.push(format!("NO TONE: no bin stands {TONE_DB:.0} dB above the floor ({:.1} dBFS/Hz); a noise-like or \
            wideband signal - read the level, the floor and the spectrum's shape.", r.floor_dbfs_hz));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Complex tone at `f` cycles/sample, amplitude `a`, with I scaled by
    /// `g` and Q given a phase error `phi` (radians), a DC offset, and
    /// Gaussian noise of `sigma` codes per component; rounded to codes and
    /// clipped to 12 bits as an ADC would.
    fn signal(n: usize, f: f64, a: f64, g: f64, phi: f64, dc: (f64, f64), sigma: f64) -> Vec<i16> {
        let mut seed = 12345u64;
        let mut u = || { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                         ((seed >> 11) as f64 + 0.5) / (1u64 << 53) as f64 };
        let mut gauss = || (-2.0 * u().ln()).sqrt() * (2.0 * std::f64::consts::PI * u()).cos();
        let clip = |v: f64| v.round().clamp(-2048.0, 2047.0) as i16;
        (0..n).flat_map(|t| {
            let p = 2.0 * std::f64::consts::PI * f * t as f64;
            let i = g * a * p.cos() + dc.0 + sigma * gauss();
            let q = a * (p + phi).sin() + dc.1 + sigma * gauss();
            [clip(i), clip(q)]
        }).collect()
    }

    #[test]
    fn an_ideal_12_bit_tone_measures_at_the_quantisation_limit() {
        // -1 dBFS, off-bin: SNR = 6.02*12 + 1.76 - 1 = 73.0 dB
        let a = 2048.0 * 10f64.powf(-1.0 / 20.0);
        let s = signal(1 << 18, 0.1234567, a, 1.0, 0.0, (0.0, 0.0), 0.0);
        let r = analyze(&s, 1e6, 8192).unwrap();
        let t = r.tone.as_ref().unwrap();
        assert!((t.dbfs + 1.0).abs() < 0.05, "level {}", t.dbfs);
        assert!((t.freq - 123456.7).abs() < r.rate / 8192.0 / 10.0, "freq {}", t.freq);
        // rounding noise: 2/12 code^2 -> SNR 10 log10(a^2 * 6) = 73.0 dB
        let want = 10.0 * (a * a * 6.0).log10();
        assert!((t.snr_db - want).abs() < 1.5, "snr {} want {want}", t.snr_db);
        assert!((t.enob - 12.0).abs() < 0.3, "enob {}", t.enob);
        assert!(r.balance.irr_db > 60.0 && r.level.clipped_fraction == 0.0);
    }

    #[test]
    fn a_spur_must_clear_the_noise_by_the_stated_margin() {
        // noise alone: exponential power (the distribution of one averaged
        // segment), 4096 bins; its largest bin must not be called a spur
        let n = 4096usize;
        let mut seed = 7u64;
        let mut u = || { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                         ((seed >> 11) as f64 + 0.5) / (1u64 << 53) as f64 };
        // each bin is the mean of `segments` exponential draws: the gamma
        // distribution the analyser's floor estimate assumes
        let power: Vec<f64> = (0..n).map(|_| (0..64).map(|_| -u().ln()).sum::<f64>() / 64.0).collect();
        let mut sp = dsp::Spectrum { power, rate: 1e6, segments: 64 };
        let mut sorted = sp.power.clone();
        sorted.sort_by(f64::total_cmp);
        let median = sorted[n / 2];
        let floor = median / (1.0f64 - 1.0 / (9.0 * 64.0)).powi(3);
        assert!(spurs_of(&sp, None, floor).is_empty(), "noise's own maximum listed as a spur");
        // a line 6 dB over the floor is inside the noise's spread: not a spur
        sp.power[1000] = floor * 10f64.powf(6.0 / 10.0);
        assert!(spurs_of(&sp, None, floor).is_empty());
        // 12 dB over it is: one spur, at that bin
        sp.power[1000] = floor * 10f64.powf(12.0 / 10.0);
        let got = spurs_of(&sp, None, floor);
        assert_eq!(got.len(), 1);
        assert!((got[0].freq - sp.freq(1000)).abs() < 1.0);
    }

    #[test]
    fn snr_follows_added_noise() {
        // a = 1000 codes, sigma = 10 per component: SNR = a^2 / (2 sigma^2) = 37.0 dB
        let s = signal(1 << 17, -0.2, 1000.0, 1.0, 0.0, (0.0, 0.0), 10.0);
        let t = analyze(&s, 1e6, 4096).unwrap().tone.unwrap();
        assert!((t.snr_db - 36.99).abs() < 0.5, "snr {}", t.snr_db);
        assert!((t.freq + 200e3).abs() < 30.0, "negative frequency kept: {}", t.freq);
    }

    #[test]
    fn dc_offset_is_measured_and_reported() {
        let s = signal(1 << 16, 0.05, 800.0, 1.0, 0.0, (30.0, -40.0), 2.0);
        let r = analyze(&s, 1e6, 4096).unwrap();
        assert!((r.level.dc_i - 30.0).abs() < 0.2 && (r.level.dc_q + 40.0).abs() < 0.2);
        // |dc| = 50 codes: 20 log10(50 / 2048) = -32.2 dBFS
        assert!((r.level.dc_dbfs + 32.25).abs() < 0.1, "{}", r.level.dc_dbfs);
        assert!(findings(&r).iter().any(|f| f.starts_with("DC OFFSET")));
        // negative control: no offset, no finding
        let r0 = analyze(&signal(1 << 16, 0.05, 800.0, 1.0, 0.0, (0.0, 0.0), 2.0), 1e6, 4096).unwrap();
        assert!(!findings(&r0).iter().any(|f| f.starts_with("DC OFFSET")));
    }

    #[test]
    fn iq_imbalance_two_independent_estimates_agree_with_the_formula() {
        // g = 1.1 (0.83 dB), phi = 3 deg: IRR = 10 log10((1+2g cos+g^2)/(1-2g cos+g^2))
        let (g, phi) = (1.1f64, 3f64.to_radians());
        let c = 2.0 * g * phi.cos();
        let want = 10.0 * ((1.0 + c + g * g) / (1.0 - c + g * g)).log10();
        let s = signal(1 << 17, 0.0731, 1200.0, g, phi, (0.0, 0.0), 1.0);
        let r = analyze(&s, 1e6, 8192).unwrap();
        assert!((r.balance.gain_db - 20.0 * g.log10()).abs() < 0.02, "gain {}", r.balance.gain_db);
        assert!((r.balance.phase_deg - 3.0).abs() < 0.05, "phase {}", r.balance.phase_deg);
        assert!((r.balance.irr_db - want).abs() < 0.2, "irr {} want {want}", r.balance.irr_db);
        // the spectrum's image bin, measured independently, says the same
        let t = r.tone.as_ref().unwrap();
        let m = t.mirror_dbc.expect("the tone is far from DC: a measurable mirror");
        assert!((m + want).abs() < 0.5, "mirror {m} dBc, want {}", -want);
        assert!(r.spurs.first().is_some_and(|s| s.kind == SpurKind::Mirror));
        assert!(findings(&r).iter().any(|f| f.starts_with("I/Q IMBALANCE")));
    }

    fn raw_file(name: &str, s: &[i16]) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("b210-quality-{name}-{}.raw", std::process::id()));
        let mut bytes = Vec::with_capacity(2 * s.len());
        for v in s { bytes.extend_from_slice(&v.to_le_bytes()); }
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn a_file_analyses_to_the_same_report_as_a_slice() {
        // the streaming path (sums, then peak/power, then segment seeks) must
        // reproduce the in-memory one exactly, not approximately
        let s = signal(1 << 17, 0.0143, 900.0, 1.003, 0.04, (3.0, -2.0), 0.3);
        let path = raw_file("same", &s);
        let a = analyze(&s, 1e6, 8192).unwrap();
        let b = analyze_file(&path, 1e6, 8192).unwrap().unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(format!("{a:?}"), format!("{b:?}"));
    }

    #[test]
    fn a_file_that_is_not_whole_pairs_is_an_error_and_a_short_one_is_none() {
        let path = raw_file("odd", &[1, 2, 3]);
        assert!(matches!(analyze_file(&path, 1e6, 1024), Err(e) if e.kind() == std::io::ErrorKind::InvalidData));
        std::fs::remove_file(&path).ok();
        let path = raw_file("short", &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert!(analyze_file(&path, 1e6, 1024).unwrap().is_none());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn clipping_is_refused_only_above_one_value_in_a_million() {
        let level = |clipped_fraction| Level { dc_i: 0.0, dc_q: 0.0, dc_dbfs: -200.0, rms_dbfs: -20.0,
                                      peak_dbfs: 0.0, crest_db: 3.0, clipped_fraction, longest_clip: 1 };
        let limit = 1.0 / 1_000_000.0;
        assert!(!clipping_refuses(&level(0.0)));
        assert!(!clipping_refuses(&level(limit / 2.0)));
        assert!(clipping_refuses(&level(limit)));
        assert!(clipping_note(&level(0.0)).is_none());
        // isolated: reported, kept, and with no gain advice that a single
        // rail code cannot support
        let sparse = clipping_note(&level(limit / 10.0)).unwrap();
        assert!(sparse.contains("isolated") && !sparse.contains("Lower the rx gain"), "{sparse}");
        assert!(sparse.contains("longest run 1 sample time"), "{sparse}");
        // material: the saturated-capture text, with the headroom advice
        assert!(clipping_note(&level(0.01)).unwrap().contains("Lower the rx gain"));
    }

    #[test]
    fn the_longest_run_separates_a_burst_edge_from_one_sample() {
        let mut s = vec![0i16; 200]; // 100 sample times
        for k in 10..15 { s[2 * k] = 2047; } // five consecutive
        let r = analyze(&s, 1e6, 64).unwrap();
        assert_eq!(r.level.longest_clip, 5);
        assert!(clipping_note(&r.level).unwrap().contains("longest clipped run is 5 sample times"));
        // one value at the other rail: a run of one sample time
        s[2 * 10..2 * 15].fill(0);
        s[2 * 50] = -2048;
        let r = analyze(&s, 1e6, 64).unwrap();
        assert_eq!(r.level.longest_clip, 1);
        assert!(clipping_note(&r.level).unwrap().contains("longest clipped run is 1 sample time"));
        // negative control: nothing at a rail, no note
        s[2 * 50] = 0;
        let r = analyze(&s, 1e6, 64).unwrap();
        assert_eq!(r.level.longest_clip, 0);
        assert!(clipping_note(&r.level).is_none());
    }

    #[test]
    fn a_clean_signal_has_no_clipping_note() {
        // negative control for the note: 30 dB below full scale, nothing at the rails
        let s = signal(1 << 15, 0.03, 512.0, 1.0, 0.0, (0.0, 0.0), 0.032);
        let r = analyze(&s, 1e6, 4096).unwrap();
        assert_eq!(r.level.clipped_fraction, 0.0);
        assert!(clipping_note(&r.level).is_none());
    }

    #[test]
    fn clipping_is_found_and_a_harmonic_classified() {
        // 6 dB over full scale: hard clipping, odd harmonics of the complex tone
        let s = signal(1 << 16, 0.03, 4096.0, 1.0, 0.0, (0.0, 0.0), 0.0);
        let r = analyze(&s, 1e6, 4096).unwrap();
        assert!(r.level.clipped_fraction > 0.1);
        let f = findings(&r);
        assert!(f[0].starts_with("CLIPPING"), "{f:?}");
        // capture refuses a clipped stream through the same note
        let note = clipping_note(&r.level).expect("clipped: a note");
        assert_eq!(note, f[0]);
        assert!(note.contains(&format!("{:.4}%", 100.0 * r.level.clipped_fraction)), "{note}");
        assert!(r.tone.as_ref().unwrap().sfdr_dbc < 40.0);
    }

    #[test]
    fn a_real_valued_signal_is_recognised_not_misread_as_imbalance() {
        // the FPGA pattern: I = t, Q = ~t (a sawtooth and its negative)
        let s: Vec<i16> = (0..1u32 << 16).flat_map(|t| {
            let i = (t & 0xFFF) as i16; let q = (!t & 0xFFF) as i16;
            [(i << 4) >> 4, (q << 4) >> 4]
        }).collect();
        let r = analyze(&s, 30.72e6, 4096).unwrap();
        assert!(!r.balance.circular && r.balance.rho < -0.99);
        let f = findings(&r);
        assert!(f.iter().any(|x| x.starts_with("REAL-VALUED")) && !f.iter().any(|x| x.starts_with("I/Q IMBALANCE")));
    }

    #[test]
    fn an_impulsive_capture_is_named_not_just_peaky() {
        // noise alone: crest about 12 dB, no finding
        let mut s = signal(1 << 16, 0.03, 0.0, 1.0, 0.0, (0.0, 0.0), 100.0);
        let r = analyze(&s, 1e6, 4096).unwrap();
        assert!(r.level.crest_db < 20.0, "noise crest {}", r.level.crest_db);
        assert!(!findings(&r).iter().any(|f| f.starts_with("IMPULSIVE")));
        // four samples at +2000 codes raise the peak, not the rms
        for k in 0..4 { s[2 * (1000 + k)] = 2000; }
        let r = analyze(&s, 1e6, 4096).unwrap();
        assert!(r.level.crest_db > 20.0, "burst crest {}", r.level.crest_db);
        assert!(findings(&r).iter().any(|f| f.starts_with("IMPULSIVE")), "{:?}", findings(&r));
    }

    #[test]
    fn a_tone_reads_the_same_at_every_fft_size_and_segment_offset() {
        // an artefact would be a frequency or level that depends on the
        // analysis window: the same tone, four FFT sizes and three segment
        // offsets, must read the same within one bin and 0.05 dB
        let (rate, f, a) = (1e6, 123_456.7, 1000.0);
        let s = signal(1 << 18, f / rate, a, 1.0, 0.0, (0.0, 0.0), 0.0);
        let want_db = 20.0 * (a / crate::capture::FULL_SCALE).log10();
        for n in [1024usize, 2048, 8192, 16384] {
            for off in [0usize, 123, 4096] {
                let r = analyze(&s[2 * off..], rate, n).unwrap();
                let t = r.tone.as_ref().expect("a tone");
                assert!((t.freq - f).abs() < r.rate / n as f64, "n {n} off {off}: freq {}", t.freq);
                assert!((t.dbfs - want_db).abs() < 0.05, "n {n} off {off}: level {}", t.dbfs);
                assert!((t.snr_db - 68.0).abs() < 2.0, "n {n} off {off}: snr {}", t.snr_db);
            }
        }
    }

    #[test]
    fn a_tone_near_dc_has_no_measurable_mirror() {
        // 9.4 bins from DC (outside the DC mask, so it is a tone) with a DC
        // offset: the mirror band reaches into the DC lobe, which used to be
        // read as a -17.5 dBc mirror. Nothing at -f can be separated there.
        let n = 4096;
        let s = signal(1 << 16, 9.4 / n as f64, 1500.0, 1.0, 0.0, (300.0, -200.0), 0.0);
        let r = analyze(&s, 1e6, n).unwrap();
        let t = r.tone.as_ref().unwrap();
        assert!(t.mirror_dbc.is_none(), "mirror {:?} from DC leakage", t.mirror_dbc);
        let f = findings(&r);
        assert!(!f.iter().any(|x| x.starts_with("MIRROR")), "{f:#?}");
        assert!(!r.spurs.iter().any(|s| s.kind == SpurKind::Mirror), "{:?}", r.spurs);
        // just outside the reach: 2 x LOBE = 16 bins from DC, the mirror is
        // still over the DC lobe; 17 bins and it is measurable
        let r16 = analyze(&signal(1 << 16, 16.0 / n as f64, 1500.0, 1.0, 0.0, (0.0, 0.0), 0.0), 1e6, n).unwrap();
        assert!(r16.tone.as_ref().unwrap().mirror_dbc.is_none(), "bins touch at 16");
        let r17 = analyze(&signal(1 << 16, 17.2 / n as f64, 1500.0, 1.0, 0.0, (0.0, 0.0), 0.0), 1e6, n).unwrap();
        assert!(r17.tone.as_ref().unwrap().mirror_dbc.is_some(), "17 bins: disjoint");
    }

    #[test]
    fn a_tone_next_to_dc_is_never_counted_twice() {
        // 4 bins from DC with a strong DC offset: the lobes overlap; SINAD
        // must stay finite and at the quantisation level, never absurd
        let n = 4096;
        let s = signal(1 << 16, 4.3 / n as f64, 1500.0, 1.0, 0.0, (300.0, -200.0), 0.0);
        let t = analyze(&s, 1e6, n).unwrap().tone.unwrap();
        assert!(t.enob < 13.0 && t.enob > 8.0, "enob {}", t.enob);
        assert!(t.share > 0.0 && t.share <= 1.0 + 1e-9, "share {}", t.share);
    }

    #[test]
    fn a_sawtooth_is_reported_as_several_components() {
        let s: Vec<i16> = (0..1u32 << 16).flat_map(|t| { let v = ((t & 0xFFF) as i16) << 4 >> 4; [v, v / 2] }).collect();
        let r = analyze(&s, 30.72e6, 16384).unwrap();
        let t = r.tone.as_ref().unwrap();
        assert!(t.share < 0.9, "share {}", t.share);
        assert!(t.enob.is_finite() && t.enob < 13.0, "enob {}", t.enob);
        assert!(findings(&r).iter().any(|f| f.starts_with("SEVERAL COMPONENTS")));
        // negative control: a clean tone is one component
        let r1 = analyze(&signal(1 << 16, 0.1, 1500.0, 1.0, 0.0, (0.0, 0.0), 1.0), 1e6, 4096).unwrap();
        assert!(r1.tone.unwrap().share > 0.99);
    }

    #[test]
    fn noise_alone_has_no_tone_and_its_density_is_right() {
        // sigma = 100 per component: power 2e4 codes^2 over 1 MHz
        let s = signal(1 << 17, 0.0, 0.0, 1.0, 0.0, (0.0, 0.0), 100.0);
        let r = analyze(&s, 1e6, 2048).unwrap();
        assert!(r.tone.is_none());
        let want = dsp::dbfs(2e4 / 1e6);
        assert!((r.floor_dbfs_hz - want).abs() < 0.5, "floor {} want {want}", r.floor_dbfs_hz);
        assert!((r.level.crest_db - 12.0).abs() < 3.0, "gaussian crest {}", r.level.crest_db);
    }
}
