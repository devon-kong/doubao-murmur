//! Microphone capture via cpal (WASAPI). Mirrors AudioCaptureManager.swift.
//!
//! cpal's Stream is not Send on Windows, so it lives on its own thread for the
//! lifetime of a recording and is dropped there. Start-up errors are reported
//! back synchronously so the state machine can surface "麦克风启动失败".

use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;

use crate::config;
use crate::resample::{downmix, Resampler};
use crate::{log_error, log_info, log_warn};

pub struct AudioCapture {
    stop: Option<mpsc::Sender<()>>,
}

impl AudioCapture {
    pub fn new() -> AudioCapture {
        AudioCapture { stop: None }
    }

    pub fn is_capturing(&self) -> bool {
        self.stop.is_some()
    }

    /// `sink` receives 16 kHz mono Int16 LE chunks on the audio thread.
    pub fn start<F>(&mut self, sink: F) -> Result<(), String>
    where
        F: Fn(Vec<u8>) + Send + 'static,
    {
        if self.is_capturing() {
            return Ok(());
        }

        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<String, String>>();

        std::thread::spawn(move || match build_stream(sink) {
            Ok((stream, description)) => {
                if let Err(e) = stream.play() {
                    let _ = ready_tx.send(Err(format!("无法启动录音流: {e}")));
                    return;
                }
                let _ = ready_tx.send(Ok(description));
                // Hold the stream on this thread until asked to stop.
                let _ = stop_rx.recv();
                drop(stream);
                log_info!("Audio capture stopped");
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e));
            }
        });

        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(description)) => {
                log_info!("Audio capture started: {description}");
                self.stop = Some(stop_tx);
                Ok(())
            }
            Ok(Err(e)) => {
                log_error!("Audio capture failed: {e}");
                Err(e)
            }
            Err(RecvTimeoutError::Timeout) => Err("录音设备打开超时".to_string()),
            Err(RecvTimeoutError::Disconnected) => Err("录音线程意外退出".to_string()),
        }
    }

    pub fn stop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

impl Drop for AudioCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

fn build_stream<F>(sink: F) -> Result<(cpal::Stream, String), String>
where
    F: Fn(Vec<u8>) + Send + 'static,
{
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or_else(|| {
        "没有可用的录音设备。请检查麦克风是否插好，以及「设置 → 隐私和安全性 → 麦克风 \
         → 允许桌面应用访问麦克风」是否已开启。"
            .to_string()
    })?;

    let supported = device
        .default_input_config()
        .map_err(|e| format!("无法读取录音设备格式: {e}"))?;

    let sample_format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();
    let channels = config.channels as usize;
    let source_rate = config.sample_rate.0;

    let description = format!(
        "{}Hz {}ch {:?} -> {}Hz mono int16",
        source_rate,
        channels,
        sample_format,
        config::AUDIO_SAMPLE_RATE
    );

    let mut pump = Pump::new(source_rate, channels, sink);
    let on_error = |e| log_warn!("Audio stream error: {e}");

    let stream = match sample_format {
        SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _| pump.push_f32(data),
            on_error,
            None,
        ),
        SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _| {
                pump.push_iter(data.iter().map(|&s| s as f32 / 32768.0));
            },
            on_error,
            None,
        ),
        SampleFormat::U16 => device.build_input_stream(
            &config,
            move |data: &[u16], _| {
                pump.push_iter(data.iter().map(|&s| (s as f32 - 32768.0) / 32768.0));
            },
            on_error,
            None,
        ),
        other => return Err(format!("不支持的采样格式: {other:?}")),
    }
    .map_err(|e| format!("无法打开麦克风: {e}"))?;

    Ok((stream, description))
}

/// Per-callback conversion pipeline: interleaved native samples in, fixed-size
/// 16 kHz Int16 chunks out.
struct Pump<F> {
    channels: usize,
    resampler: Resampler,
    sink: F,
    mono: Vec<f32>,
    staging: Vec<f32>,
    pending: Vec<i16>,
    chunk_samples: usize,
}

impl<F: Fn(Vec<u8>)> Pump<F> {
    fn new(source_rate: u32, channels: usize, sink: F) -> Pump<F> {
        Pump {
            channels,
            resampler: Resampler::new(source_rate),
            sink,
            mono: Vec::new(),
            staging: Vec::new(),
            pending: Vec::new(),
            chunk_samples: config::audio_chunk_samples(),
        }
    }

    fn push_f32(&mut self, data: &[f32]) {
        downmix(data, self.channels, &mut self.mono);
        self.emit();
    }

    fn push_iter(&mut self, samples: impl Iterator<Item = f32>) {
        self.staging.clear();
        self.staging.extend(samples);
        // Avoids borrowing self twice while downmixing into self.mono.
        let staging = std::mem::take(&mut self.staging);
        downmix(&staging, self.channels, &mut self.mono);
        self.staging = staging;
        self.emit();
    }

    fn emit(&mut self) {
        let mono = std::mem::take(&mut self.mono);
        self.resampler.process(&mono, &mut self.pending);
        self.mono = mono;

        while self.pending.len() >= self.chunk_samples {
            let rest = self.pending.split_off(self.chunk_samples);
            let chunk = std::mem::replace(&mut self.pending, rest);

            let mut bytes = Vec::with_capacity(chunk.len() * 2);
            for sample in chunk {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }
            (self.sink)(bytes);
        }
    }
}
