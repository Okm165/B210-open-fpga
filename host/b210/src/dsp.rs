//! The DSP a spectrum view needs, with its arithmetic stated.
//!
//! Everything here works on power, not on a normalised amplitude: a tone of
//! amplitude A (in capture codes, peak A, so a full-scale sine has A = full
//! scale) has |X| = A * N / 2 in one bin of an N-point FFT, and the power
//! view reports `10 log10(P / P_peak)`, so the peak is 0 dB whatever A is.
//!
//! Window and averaging: a rectangular window leaks -13 dB into the nearest
//! sidelobe, so a Hann window (raised cosine, coherent gain 0.5) is applied
//! to every segment and the segment powers are averaged (Welch). Welch
//! reduces the variance of a noise floor by the number of segments; the
//! noise floor of a full-scale white signal therefore sits at
//! `10 log10(1 / N_eff)`, not at a fixed -x dB.

/// In-place iterative radix-2 FFT. `re.len()` must be a power of two; `im`
/// is the same length. The transform is unnormalised: a DC input of `A`
/// gives `N * A`. Negative frequencies are in the upper half of the output.
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
    // butterflies: at stage `len`, twiddles are exp(-2 pi i k / len)
    let mut len = 2;
    while len <= n {
        let ang = -2.0 * std::f32::consts::PI / len as f32;
        let (wr, wi) = (ang.cos(), ang.sin());
        let mut i = 0;
        while i < n {
            let (mut cr, mut ci) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let (ar, ai) = (re[i + k], im[i + k]);
                let (br, bi) = (re[i + k + len / 2], im[i + k + len / 2]);
                let (tr, ti) = (br * cr - bi * ci, br * ci + bi * cr);
                re[i + k] = ar + tr;
                im[i + k] = ai + ti;
                re[i + k + len / 2] = ar - tr;
                im[i + k + len / 2] = ai - ti;
                let nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
            i += len;
        }
        len <<= 1;
    }
}

/// Hann window of `n` points, symmetric (w[0] = w[n-1] = 0). Its coherent
/// gain is 0.5: a tone of peak A shows as A/2 in the windowed spectrum.
pub fn hann(n: usize) -> Vec<f32> {
    (0..n)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / (n.max(2) - 1) as f32).cos())
        .collect()
}

/// Welch power spectrum of interleaved I/Q `samples`, `n` points per
/// segment (a power of two), averaged over at most `max_segments` segments
/// spread evenly over the whole file. Returns `n/2` non-negative
/// frequencies' mean power; bin k is `k * rate / n` Hz.
pub fn welch(samples: &[i16], n: usize, max_segments: usize) -> Vec<f64> {
    let frames = samples.len() / 2;
    let n = n.min(frames.next_power_of_two() / 2).max(16);
    if frames < n {
        return vec![0.0; n / 2];         // shorter than one segment: no spectrum
    }
    let w = hann(n);
    let usable = frames / n;
    let segments = usable.clamp(1, max_segments.max(1));
    // frames between segment starts: spread the segments over the file, the
    // last one ending at the last whole frame
    let step = if segments > 1 { (usable - segments) / (segments - 1) } else { 0 };
    let mut acc = vec![0f64; n / 2];
    let mut re = vec![0f32; n];
    let mut im = vec![0f32; n];
    for s in 0..segments {
        // segment s starts at frame `s*step` of the `usable` whole frames,
        // so `start + n <= usable` and the read never runs past the file
        let base = s * step * n * 2;
        for k in 0..n {
            let i = samples[base + 2 * k] as f32 * w[k];
            let q = samples[base + 2 * k + 1] as f32 * w[k];
            re[k] = i;
            im[k] = q;
        }
        fft(&mut re, &mut im);
        for k in 0..n / 2 {
            acc[k] += (re[k] * re[k] + im[k] * im[k]) as f64;
        }
    }
    for a in &mut acc {
        *a /= segments as f64;
    }
    acc
}

/// `10 log10(p / peak)`, floored at `floor_db` so an empty bin is a finite
/// number the plotter can place.
pub fn relative_db(power: &[f64], floor_db: f64) -> Vec<f64> {
    let peak = power.iter().cloned().fold(0.0f64, f64::max);
    if peak <= 0.0 {
        return vec![floor_db; power.len()];
    }
    power.iter().map(|p| (10.0 * (p / peak).log10()).max(floor_db)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A complex tone at bin `k`: exp(+2 pi i k t / n). The FFT is
    /// unnormalised, so the peak is exactly n.
    fn tone(n: usize, k: usize) -> (Vec<f32>, Vec<f32>) {
        let (mut re, mut im) = (vec![0f32; n], vec![0f32; n]);
        for t in 0..n {
            let a = 2.0 * std::f32::consts::PI * (k * t % n) as f32 / n as f32;
            re[t] = a.cos();
            im[t] = a.sin();
        }
        (re, im)
    }

    #[test]
    fn a_tone_lands_in_its_own_bin_and_nowhere_else() {
        let n = 64;
        for k in [0, 1, 7, 31] {
            let (mut re, mut im) = tone(n, k);
            fft(&mut re, &mut im);
            let p: Vec<f64> = (0..n).map(|i| (re[i] * re[i] + im[i] * im[i]) as f64).collect();
            let peak = p.iter().cloned().fold(0.0, f64::max);
            assert!((peak - (n * n) as f64).abs() < 1e-4 * (n * n) as f64, "k={k}: peak {peak}");
            for (i, &v) in p.iter().enumerate() {
                if i != k { assert!(v < 1e-6 * peak, "k={k}: bin {i} = {v}"); }
            }
        }
    }

    #[test]
    fn an_impulse_is_flat_and_a_constant_is_one_bin() {
        let n = 32;
        let (mut re, mut im) = (vec![0f32; n], vec![0f32; n]);
        re[0] = 1.0;
        fft(&mut re, &mut im);
        assert!(re.iter().all(|v| (*v - 1.0).abs() < 1e-6), "impulse: flat magnitude 1");
        let mut re = vec![3.0f32; n];
        let mut im = vec![0f32; n];
        fft(&mut re, &mut im);
        assert!((re[0] - 3.0 * n as f32).abs() < 1e-3 && re[1..].iter().all(|v| v.abs() < 1e-3));
    }

    #[test]
    fn parseval_holds_for_the_unnormalised_transform() {
        // sum |x|^2 = (1/n) sum |X|^2
        let n = 128;
        let (mut re, mut im) = (vec![0f32; n], vec![0f32; n]);
        let mut seed = 1u32;
        for t in 0..n {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            re[t] = (seed >> 8) as f32 / 2f32.powi(24);
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            im[t] = (seed >> 8) as f32 / 2f32.powi(24);
        }
        let time: f64 = re.iter().chain(im.iter()).map(|v| (*v as f64).powi(2)).sum();
        let (mut xr, mut xi) = (re.clone(), im.clone());
        fft(&mut xr, &mut xi);
        let freq: f64 = xr.iter().chain(xi.iter()).map(|v| (*v as f64).powi(2)).sum::<f64>() / n as f64;
        assert!((time - freq).abs() < 1e-3 * time.max(1.0), "{time} vs {freq}");
    }

    #[test]
    fn welch_finds_a_tone_in_iq_and_the_peak_is_zero_db() {
        let n = 256;
        let k = 20;
        // 8 identical segments; I = cos, Q = sin => +f
        let samples: Vec<i16> = (0..8 * n)
            .flat_map(|t| {
                let a = 2.0 * std::f32::consts::PI * (k * (t % n)) as f32 / n as f32;
                [(1000.0 * a.cos()) as i16, (1000.0 * a.sin()) as i16]
            })
            .collect();
        let p = welch(&samples, n, 8);
        let db = relative_db(&p, -120.0);
        assert_eq!(db.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap().0, k);
        assert!(db[k].abs() < 1e-9);
        // Hann's response is 0.5 at +-1 bin (-6.02 dB) and 0 at +-2 bins
        assert!((db[k + 1] - (-6.0206)).abs() < 0.2, "next bin: {}", db[k + 1]);
        assert!(db[k + 2] < -40.0, "two bins away: {}", db[k + 2]);
    }

    #[test]
    fn a_zero_capture_has_no_peak_and_never_nan() {
        let p = welch(&vec![0i16; 2048], 256, 4);
        assert!(relative_db(&p, -100.0).iter().all(|d| *d == -100.0));
    }
}
