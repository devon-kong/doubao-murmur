//! Converts the microphone's native format to the 16 kHz mono Int16 the ASR
//! service expects.
//!
//! WASAPI shared mode only opens at the device's own rate (typically 48 kHz), so
//! this does what AVAudioConverter does on macOS. Linux needs none of it because
//! PipeWire adapts the rate itself.
//!
//! A biquad low-pass ahead of linear interpolation is enough here: speech ASR is
//! forgiving, and it avoids pulling in a resampling crate for a fixed 3:1 case.

use crate::config::AUDIO_SAMPLE_RATE;

const CUTOFF_HZ: f64 = 7_000.0;
const Q: f64 = 0.707;

#[derive(Default, Clone, Copy)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    /// RBJ cookbook low-pass.
    fn low_pass(sample_rate: f64, cutoff: f64) -> Biquad {
        let omega = 2.0 * std::f64::consts::PI * cutoff / sample_rate;
        let (sin, cos) = omega.sin_cos();
        let alpha = sin / (2.0 * Q);

        let b0 = (1.0 - cos) / 2.0;
        let b1 = 1.0 - cos;
        let b2 = (1.0 - cos) / 2.0;
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cos;
        let a2 = 1.0 - alpha;

        Biquad {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
            ..Default::default()
        }
    }

    fn process(&mut self, x0: f64) -> f64 {
        let y0 = self.b0 * x0 + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x0;
        self.y2 = self.y1;
        self.y1 = y0;
        y0
    }
}

pub struct Resampler {
    /// Input samples consumed per output sample.
    step: f64,
    /// Fractional read position carried across chunks.
    position: f64,
    /// Last sample of the previous chunk, so interpolation spans the boundary.
    tail: f32,
    filter: Option<Biquad>,
    scratch: Vec<f32>,
}

impl Resampler {
    pub fn new(source_rate: u32) -> Resampler {
        let source = source_rate as f64;
        let target = AUDIO_SAMPLE_RATE as f64;
        Resampler {
            step: source / target,
            position: 0.0,
            tail: 0.0,
            // Only needed when downsampling; upsampling cannot alias.
            filter: (source > target).then(|| Biquad::low_pass(source, CUTOFF_HZ)),
            scratch: Vec::new(),
        }
    }

    /// Feed mono f32 samples in [-1, 1]; appends 16 kHz Int16 samples to `out`.
    pub fn process(&mut self, input: &[f32], out: &mut Vec<i16>) {
        if input.is_empty() {
            return;
        }

        self.scratch.clear();
        self.scratch.reserve(input.len() + 1);
        self.scratch.push(self.tail);
        match self.filter.as_mut() {
            Some(filter) => {
                for &sample in input {
                    self.scratch.push(filter.process(sample as f64) as f32);
                }
            }
            None => self.scratch.extend_from_slice(input),
        }

        let mut position = self.position;
        while (position as usize) + 1 < self.scratch.len() {
            let index = position as usize;
            let frac = position - index as f64;
            let value = self.scratch[index] as f64 * (1.0 - frac)
                + self.scratch[index + 1] as f64 * frac;
            out.push((value.clamp(-1.0, 1.0) * 32767.0) as i16);
            position += self.step;
        }

        let consumed = (self.scratch.len() - 1) as f64;
        self.position = position - consumed;
        self.tail = *self.scratch.last().unwrap_or(&0.0);
    }
}

/// Average interleaved channels down to mono, in place into `out`.
pub fn downmix(input: &[f32], channels: usize, out: &mut Vec<f32>) {
    out.clear();
    if channels <= 1 {
        out.extend_from_slice(input);
        return;
    }

    out.reserve(input.len() / channels);
    for frame in input.chunks_exact(channels) {
        out.push(frame.iter().sum::<f32>() / channels as f32);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_at_target_rate_preserves_length() {
        let mut resampler = Resampler::new(AUDIO_SAMPLE_RATE);
        let input = vec![0.0f32; 1600];
        let mut out = Vec::new();
        resampler.process(&input, &mut out);
        // One sample of latency from the boundary carry.
        assert!((out.len() as i64 - 1600).abs() <= 1, "got {}", out.len());
    }

    #[test]
    fn downsampling_48k_to_16k_thirds_the_sample_count() {
        let mut resampler = Resampler::new(48_000);
        let mut out = Vec::new();
        // Feed a second of audio in 10 ms chunks, as the capture callback would.
        for _ in 0..100 {
            resampler.process(&vec![0.0f32; 480], &mut out);
        }
        assert!((out.len() as i64 - 16_000).abs() <= 2, "got {}", out.len());
    }

    #[test]
    fn a_steady_tone_survives_the_conversion() {
        let mut resampler = Resampler::new(48_000);
        let mut out = Vec::new();
        let input: Vec<f32> = (0..4800)
            .map(|i| (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / 48_000.0).sin() * 0.5)
            .collect();
        resampler.process(&input, &mut out);

        let peak = out.iter().map(|s| s.abs()).max().unwrap_or(0);
        // 440 Hz sits well below the 7 kHz cutoff, so amplitude should be intact.
        assert!(peak > 12_000, "tone was attenuated, peak {peak}");
    }

    #[test]
    fn downmix_averages_stereo() {
        let mut out = Vec::new();
        downmix(&[1.0, 0.0, 0.5, 0.5], 2, &mut out);
        assert_eq!(out, vec![0.5, 0.5]);
    }

    #[test]
    fn downmix_passes_mono_through() {
        let mut out = Vec::new();
        downmix(&[0.1, 0.2], 1, &mut out);
        assert_eq!(out, vec![0.1, 0.2]);
    }
}
