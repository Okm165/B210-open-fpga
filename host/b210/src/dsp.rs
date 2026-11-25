//! The spectral arithmetic every view and every quality metric shares.
//!
//! Units. Samples are 12-bit codes (`iq::FULL_SCALE` = 2048), I and Q of one
//! complex value x = I + jQ. Power is |x|^2 in codes^2; a complex tone of
//! amplitude A (|x| = A at every instant) has power A^2, so a full-scale
//! complex tone (A = 2048) is 0 dBFS: `dbfs(p) = 10 log10(p / 2048^2)`.
//!
//! Spectrum. Complex baseband has no mirror symmetry: a tone at +f and one
//! at -f are different signals (the IQ image of a tone sits at -f). So the
//! spectrum has all N bins, ordered from -rate/2 to +rate/2 (bin N/2 is DC):
//! bin i is at `(i - N/2) * rate / N` Hz.
//!
//! Window. A 12-bit converter has about 74 dB of SNR; a window whose
//! sidelobes are higher than that turns a tone's leakage into "noise" and
//! hides spurs beside it (Hann: -31 dB first sidelobe, falling 18 dB per
//! octave - an off-bin tone reads as 43 dB SNR). So every segment is
//! multiplied by the periodic 7-term Blackman-Harris window (sidelobes
//! below -180 dB, main lobe +-7 bins wide), as ADC test practice does when
//! the tone is not coherently sampled.
//!
//! Scaling. Parseval for the windowed segment gives sum_k |X_k|^2 =
//! N sum_t |w_t x_t|^2, so dividing by N * sum_t w_t^2 makes the bins sum
//! to the signal's power: a tone of power A^2 puts A^2 into its main lobe
//! (`LOBE` bins each side), white noise of power s^2 puts s^2 / N into each
//! bin on average. That is why a noise floor read per bin sits 10 log10(N) dB below
//! the total noise power, and why a longer FFT lowers the floor but not a
//! tone (processing gain).
//!
//! Averaging. Segments are spread evenly over the interval and their bin
//! powers averaged (Welch). Averaging K segments reduces the floor's
//! scatter by about sqrt(K) without moving its mean.

/// In-place iterative radix-2 FFT, unnormalised (a DC input of A gives N A
/// in bin 0), negative frequencies in the upper half.
pub fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    assert!(n.is_power_of_two() && im.len() == n, "power-of-two FFT");
    // bit reversal: index i is read from the index with i's bits reversed
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    // butterflies: at stage `len` the twiddles are exp(-2 pi i k / len),
    // computed directly (not by recurrence, which drifts at large N)
    let mut len = 2;
    while len <= n {
        let half = len / 2;
        let step = -2.0 * std::f64::consts::PI / len as f64;
        let tw: Vec<(f32, f32)> = (0..half).map(|k| {
            let a = step * k as f64;
            (a.cos() as f32, a.sin() as f32)
        }).collect();
        for base in (0..n).step_by(len) {
            for (k, &(cr, ci)) in tw.iter().enumerate() {
                let (a, b) = (base + k, base + k + half);
                let (tr, ti) = (re[b] * cr - im[b] * ci, re[b] * ci + im[b] * cr);
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        len <<= 1;
    }
}

/// Bins on each side of a tone's centre that hold its main lobe: the
/// window's first zero is 7 bins out, plus one for a tone between bins.
pub const LOBE: usize = 8;

/// 7-term Blackman-Harris coefficients a_m (w = sum (-1)^m a_m cos(2 pi m t / n)).
const BH7: [f64; 7] = [0.271_051_400_693_42, 0.433_297_939_234_48, 0.218_122_999_543_11, 0.065_925_446_388_03,
                       0.010_811_742_098_37, 0.000_776_584_825_22, 0.000_013_887_217_35];

/// The periodic 7-term Blackman-Harris window of `n` points.
pub fn window(n: usize) -> Vec<f32> {
    (0..n).map(|t| {
        let x = 2.0 * std::f64::consts::PI * t as f64 / n as f64;
        BH7.iter().enumerate().map(|(m, &a)| if m % 2 == 0 { a } else { -a } * (m as f64 * x).cos()).sum::<f64>() as f32
    }).collect()
}

/// The dB of a bin-centred tone's peak bin relative to its total power:
/// (sum w)^2 / (N sum w^2) = a0^2 / (a0^2 + sum_{m>0} a_m^2 / 2). A
/// full-scale tone peaks this far below 0 dBFS in a per-bin view.
pub fn peak_bin_db() -> f64 {
    let rest: f64 = BH7[1..].iter().map(|a| a * a / 2.0).sum();
    10.0 * (BH7[0] * BH7[0] / (BH7[0] * BH7[0] + rest)).log10()
}

/// A two-sided power spectrum in codes^2 per bin (see the module header).
#[derive(Clone, Debug)]
pub struct Spectrum {
    /// N bins, index N/2 = DC, index 0 = -rate/2
    pub power: Vec<f64>,
    pub rate: f64,
    /// segments averaged
    pub segments: usize,
}

impl Spectrum {
    pub fn n(&self) -> usize {
        self.power.len()
    }
    /// Bin width, Hz.
    pub fn df(&self) -> f64 {
        self.rate / self.n() as f64
    }
    /// Frequency of bin i, Hz.
    pub fn freq(&self, i: usize) -> f64 {
        (i as f64 - (self.n() / 2) as f64) * self.df()
    }
    /// The bin holding frequency f (wrapped into -rate/2 .. rate/2, so an
    /// aliased harmonic lands where the ADC puts it).
    pub fn bin(&self, f: f64) -> usize {
        let n = self.n() as i64;
        let k = (f / self.df()).round() as i64 + n / 2;
        k.rem_euclid(n) as usize
    }
    /// Sum of the bins within `half` bins of `k` (circularly).
    pub fn band(&self, k: usize, half: usize) -> f64 {
        let n = self.n();
        (0..=2 * half).map(|d| self.power[(k + n + d - half) % n]).sum()
    }
}

/// Welch spectrum of interleaved I/Q `samples`: `n` points per segment (a
/// power of two, reduced to the largest power of two that fits), averaged
/// over at most `max_segments` segments spread over the whole interval.
/// None when fewer than 16 sample times are given.
pub fn welch(samples: &[i16], n: usize, rate: f64, max_segments: usize) -> Option<Spectrum> {
    let frames = samples.len() / 2;
    if frames < 16 {
        return None;
    }
    let n = n.max(16).min(1 << (usize::BITS - 1 - frames.leading_zeros()));
    let w = window(n);
    let scale = 1.0 / (n as f64 * w.iter().map(|v| (*v as f64).powi(2)).sum::<f64>());
    let segments = (frames / n).clamp(1, max_segments.max(1));
    // segment s starts at frame s * (frames - n) / (segments - 1): the
    // first at 0, the last ending at the last frame
    let start = |s: usize| if segments > 1 { s * (frames - n) / (segments - 1) } else { 0 };
    let mut acc = vec![0f64; n];
    let (mut re, mut im) = (vec![0f32; n], vec![0f32; n]);
    for s in 0..segments {
        let b = 2 * start(s);
        for k in 0..n {
            re[k] = samples[b + 2 * k] as f32 * w[k];
            im[k] = samples[b + 2 * k + 1] as f32 * w[k];
        }
        fft(&mut re, &mut im);
        for k in 0..n {
            // fftshift: FFT bin k (k < n/2 positive) goes to k + n/2
            acc[(k + n / 2) % n] += (re[k] as f64).powi(2) + (im[k] as f64).powi(2);
        }
    }
    for a in &mut acc {
        *a *= scale / segments as f64;
    }
    Some(Spectrum { power: acc, rate, segments })
}

/// Codes^2 -> dB relative to a full-scale complex tone (|x| = 2048,
/// `iq::FULL_SCALE`), floored so an empty bin is a finite number.
pub fn dbfs(power: f64) -> f64 {
    let fs = crate::iq::FULL_SCALE;
    (10.0 * (power / (fs * fs)).log10()).max(-200.0)
}

/// A complex test tone, coherently sampled: its frequency is snapped to
/// f = m rate / L with L = 2^16 and m odd (coprime with L, so the tone
/// passes through all L phases before it repeats), and its L complex values
/// are computed once. Sample time i is then entry (i m) mod L: exact,
/// periodic, and a table lookup - computing cos/sin per value (250 M/s at
/// 2 x 30.72 MS/s) is more than one host core can do, and a tx stream then
/// underflows. Channel 0 plays +f, channel 1 -f (the conjugate), so a
/// swapped I/Q or a swapped channel shows in the spectrum. Amplitude
/// A = 2048 x 10^(dbfs/20) codes, rounded and held to the 12-bit range.
pub struct Tone {
    table: Vec<[i16; 2]>,
    /// The tone's frequency, in rate / L.
    pub m: u64,
}

impl Tone {
    pub const L: u64 = 1 << 16;

    pub fn new(f: f64, rate: f64, dbfs: f64) -> Tone {
        // the nearest odd m: 2 round((x - 1) / 2) + 1, at most one step away
        let x = f / rate * Self::L as f64;
        let m = (2 * ((x - 1.0) / 2.0).round() as i64 + 1).rem_euclid(Self::L as i64) as u64;
        let a = crate::iq::FULL_SCALE * 10f64.powf(dbfs / 20.0);
        let code = |x: f64| (a * x).round().clamp(-2048.0, 2047.0) as i16;
        let table = (0..Self::L)
            .map(|k| {
                let p = 2.0 * std::f64::consts::PI * k as f64 / Self::L as f64;
                [code(p.cos()), code(p.sin())]
            })
            .collect();
        Tone { table, m }
    }

    /// The frequency actually played, Hz, in -rate/2 .. rate/2.
    pub fn freq(&self, rate: f64) -> f64 {
        let m = if self.m >= Self::L / 2 { self.m as f64 - Self::L as f64 } else { self.m as f64 };
        m * rate / Self::L as f64
    }

    /// Value v (I0 Q0 I1 Q1) of sample time i.
    pub fn value(&self, i: u64, v: usize) -> i16 {
        let [c, s] = self.table[(i.wrapping_mul(self.m) % Self::L) as usize];
        match v {
            0 | 2 => c,
            1 => s,
            _ => s.saturating_neg(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tone_is_coherent_conjugate_on_channel_1_and_matches_direct_computation() {
        let rate = 30.72e6;
        let t = Tone::new(1.234567e6, rate, -1.0);
        assert_eq!(t.m % 2, 1, "m odd: coprime with L");
        assert!((t.freq(rate) - 1.234567e6).abs() <= rate / Tone::L as f64, "snapped within one step");
        let a = 2048.0 * 10f64.powf(-1.0 / 20.0);
        for i in [0u64, 1, 12345, 1 << 40] {
            let p = 2.0 * std::f64::consts::PI * (t.m * (i % Tone::L) % Tone::L) as f64 / Tone::L as f64;
            assert_eq!(t.value(i, 0), (a * p.cos()).round() as i16, "i={i}");
            assert_eq!(t.value(i, 1), (a * p.sin()).round() as i16, "i={i}");
            assert_eq!((t.value(i, 2), t.value(i, 3)), (t.value(i, 0), -t.value(i, 1)));
        }
        assert!(Tone::new(-2e6, rate, 0.0).freq(rate) < 0.0, "negative frequencies stay negative");
    }

    /// A complex tone of amplitude `a` at frequency `f` cycles per sample,
    /// rounded to codes.
    pub(crate) fn tone(n: usize, f: f64, a: f64) -> Vec<i16> {
        (0..n).flat_map(|t| {
            let p = 2.0 * std::f64::consts::PI * f * t as f64;
            [(a * p.cos()).round() as i16, (a * p.sin()).round() as i16]
        }).collect()
    }

    #[test]
    fn a_tone_lands_in_its_own_bin_and_nowhere_else() {
        let n = 1024;
        for k in [0usize, 1, 7, 31, 511] {
            let (mut re, mut im): (Vec<f32>, Vec<f32>) = (0..n).map(|t| {
                let a = 2.0 * std::f64::consts::PI * (k * t % n) as f64 / n as f64;
                (a.cos() as f32, a.sin() as f32)
            }).unzip();
            fft(&mut re, &mut im);
            for i in 0..n {
                let p = (re[i] * re[i] + im[i] * im[i]) as f64;
                if i == k { assert!((p - (n * n) as f64).abs() < 1e-3 * (n * n) as f64, "k={k}: {p}"); }
                else { assert!(p < 1e-6 * (n * n) as f64, "k={k}: bin {i} = {p}"); }
            }
        }
    }

    #[test]
    fn parseval_holds_for_the_unnormalised_transform() {
        let n = 256;
        let mut seed = 1u32;
        let mut r = || { seed = seed.wrapping_mul(1664525).wrapping_add(1013904223); (seed >> 8) as f32 / 1.6e7 };
        let (re, im): (Vec<f32>, Vec<f32>) = (0..n).map(|_| (r(), r())).unzip();
        let time: f64 = re.iter().chain(&im).map(|v| (*v as f64).powi(2)).sum();
        let (mut xr, mut xi) = (re, im);
        fft(&mut xr, &mut xi);
        let freq: f64 = xr.iter().chain(&xi).map(|v| (*v as f64).powi(2)).sum::<f64>() / n as f64;
        assert!((time - freq).abs() < 1e-4 * time);
    }

    #[test]
    fn positive_and_negative_tones_are_told_apart() {
        let rate = 1e6;
        let n = 1024;
        for f in [100e3, -100e3, 250e3, -390.625e3] {
            let s = welch(&tone(8 * n, f / rate, 1000.0), n, rate, 8).unwrap();
            let peak = (0..n).max_by(|a, b| s.power[*a].total_cmp(&s.power[*b])).unwrap();
            assert!((s.freq(peak) - f).abs() <= s.df() / 2.0, "{f}: peak at {}", s.freq(peak));
            // the mirror bin is empty: a correct complex spectrum
            assert!(s.power[s.bin(-f)] < 1e-6 * s.power[peak], "{f}: image present");
        }
    }

    /// Unrounded complex tone as f32 pairs, for window tests below the
    /// 12-bit quantisation floor.
    fn exact(n: usize, f: f64, a: f64) -> (Vec<f32>, Vec<f32>) {
        (0..n).map(|t| { let p = 2.0 * std::f64::consts::PI * f * t as f64; ((a * p.cos()) as f32, (a * p.sin()) as f32) }).unzip()
    }

    #[test]
    fn a_tone_of_amplitude_a_carries_power_a_squared() {
        // bin-centred and half-way between bins: the main lobe holds A^2
        // either way
        let (rate, n, a) = (1e6, 2048, 1500.0);
        for f in [125e3, 125e3 + rate / n as f64 / 2.0] {
            let s = welch(&tone(16 * n, f / rate, a), n, rate, 16).unwrap();
            let p = s.band(s.bin(f), LOBE);
            assert!((10.0 * (p / (a * a)).log10()).abs() < 0.01, "{f}: {} dB", 10.0 * (p / (a * a)).log10());
        }
    }

    #[test]
    fn leakage_outside_the_main_lobe_is_below_a_12_bit_floor() {
        // the worst case, a tone half-way between bins: every bin beyond
        // LOBE must be > 140 dB down (Hann gives ~-40 dB at 4 bins: fails)
        let n = 1024;
        let w = window(n);
        let f = 100.5 / n as f64;
        let (mut re, mut im) = exact(n, f, 1.0);
        for t in 0..n { re[t] *= w[t]; im[t] *= w[t]; }
        fft(&mut re, &mut im);
        let p: Vec<f64> = (0..n).map(|k| (re[k] as f64).powi(2) + (im[k] as f64).powi(2)).collect();
        let peak = p.iter().cloned().fold(0.0, f64::max);
        for (k, v) in p.iter().enumerate() {
            let d = (k as i64 - 100).unsigned_abs().min((k as i64 - 101).unsigned_abs()) as usize;
            if d > LOBE { assert!(*v < peak * 1e-14, "bin {k}: {} dB", 10.0 * (v / peak).log10()); }
        }
        // the per-bin peak of a bin-centred tone matches the closed form
        let (mut re, mut im) = exact(n, 100.0 / n as f64, 1.0);
        for t in 0..n { re[t] *= w[t]; im[t] *= w[t]; }
        fft(&mut re, &mut im);
        let sw2: f64 = w.iter().map(|v| (*v as f64).powi(2)).sum();
        let peak_db = 10.0 * (((re[100] as f64).powi(2) + (im[100] as f64).powi(2)) / (n as f64 * sw2)).log10();
        assert!((peak_db - peak_bin_db()).abs() < 1e-3, "{peak_db} vs {}", peak_bin_db());
    }

    #[test]
    fn white_noise_puts_its_power_spread_evenly() {
        // uniform +-q codes on I and Q: power 2 q^2 / 3 in total
        let (n, q) = (512, 1000.0f64);
        let mut seed = 7u64;
        let s: Vec<i16> = (0..64 * n * 2).map(|_| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((((seed >> 33) as f64 / (1u64 << 31) as f64) * 2.0 - 1.0) * q) as i16
        }).collect();
        let sp = welch(&s, n, 1e6, 64).unwrap();
        let total: f64 = sp.power.iter().sum();
        assert!((total / (2.0 * q * q / 3.0) - 1.0).abs() < 0.03, "total {total}");
    }

    #[test]
    fn too_short_or_all_zero_is_handled() {
        assert!(welch(&[0; 20], 256, 1e6, 4).is_none());
        let s = welch(&[0; 4096], 256, 1e6, 4).unwrap();
        assert!(s.power.iter().all(|p| *p == 0.0) && dbfs(0.0) == -200.0);
    }
}
