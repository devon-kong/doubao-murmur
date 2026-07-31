using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace DoubaoMurmur.Core;

/// <summary>
/// Microphone capture via WASAPI. Mirrors AudioCaptureManager.swift.
///
/// WASAPI shared mode only opens at the device's native format (typically 48 kHz
/// float32 stereo), so — like the macOS build and unlike the Linux one, where
/// PipeWire adapts the rate — the samples are downmixed and resampled in-process to
/// 16 kHz mono Int16.
/// </summary>
public sealed class WasapiMicSource : IAudioSource
{
    private readonly object _gate = new();

    private WasapiCapture? _capture;
    private BufferedWaveProvider? _buffer;
    private IWaveProvider? _pipeline;
    private CancellationTokenSource? _cts;
    private Action<byte[]>? _onAudioData;

    public bool IsCapturing
    {
        get { lock (_gate) return _capture is not null; }
    }

    public void Start(Action<byte[]> onAudioData)
    {
        lock (_gate)
        {
            if (_capture is not null) return;
        }

        _onAudioData = onAudioData;

        WasapiCapture capture;
        try
        {
            // Default input device, shared mode.
            capture = new WasapiCapture();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "无法打开麦克风。请检查是否有可用的录音设备，以及「设置 → 隐私和安全性 → " +
                "麦克风 → 允许桌面应用访问麦克风」是否已开启。", ex);
        }

        var format = capture.WaveFormat;
        var buffer = new BufferedWaveProvider(format)
        {
            BufferDuration = TimeSpan.FromSeconds(10),
            DiscardOnBufferOverflow = true,
            // Read() must return only what is actually available, otherwise the
            // pump loop spins at full speed emitting padded silence.
            ReadFully = false,
        };

        ISampleProvider samples = buffer.ToSampleProvider();
        if (format.Channels == 2)
        {
            samples = new StereoToMonoSampleProvider(samples);
        }
        else if (format.Channels > 2)
        {
            samples = new MultiplexingSampleProvider(new[] { samples }, 1);
        }

        if (samples.WaveFormat.SampleRate != AppConfig.AudioSampleRate)
        {
            samples = new WdlResamplingSampleProvider(samples, AppConfig.AudioSampleRate);
        }

        var pipeline = new SampleToWaveProvider16(samples);
        var cts = new CancellationTokenSource();

        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;

        lock (_gate)
        {
            _capture = capture;
            _buffer = buffer;
            _pipeline = pipeline;
            _cts = cts;
        }

        try
        {
            capture.StartRecording();
        }
        catch (Exception ex)
        {
            Stop();
            throw new InvalidOperationException("麦克风启动失败。", ex);
        }

        _ = Task.Run(() => PumpAsync(pipeline, cts.Token));

        Log.Info($"Audio capture started: device {format.SampleRate}Hz {format.Channels}ch " +
                 $"{format.Encoding} -> {AppConfig.AudioSampleRate}Hz mono int16");
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        BufferedWaveProvider? buffer;
        lock (_gate) buffer = _buffer;
        if (buffer is null || e.BytesRecorded <= 0) return;

        try
        {
            buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        }
        catch (Exception ex)
        {
            Log.Warn($"Dropped captured audio: {ex.Message}");
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null) Log.Error("Recording stopped unexpectedly", e.Exception);
    }

    private async Task PumpAsync(IWaveProvider pipeline, CancellationToken ct)
    {
        var chunkSize = AppConfig.AudioChunkBytes;
        var chunk = new byte[chunkSize];
        var filled = 0;

        while (!ct.IsCancellationRequested)
        {
            int read;
            try
            {
                read = pipeline.Read(chunk, filled, chunkSize - filled);
            }
            catch (Exception ex)
            {
                if (!ct.IsCancellationRequested) Log.Error("Audio pump failed", ex);
                return;
            }

            if (read <= 0)
            {
                try
                {
                    await Task.Delay(AppConfig.AudioChunkMilliseconds / 4, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                continue;
            }

            filled += read;
            if (filled < chunkSize) continue;

            var payload = new byte[chunkSize];
            Buffer.BlockCopy(chunk, 0, payload, 0, chunkSize);
            filled = 0;

            _onAudioData?.Invoke(payload);
        }
    }

    public void Stop()
    {
        WasapiCapture? capture;
        CancellationTokenSource? cts;

        lock (_gate)
        {
            capture = _capture;
            cts = _cts;
            _capture = null;
            _cts = null;
            _buffer = null;
            _pipeline = null;
        }

        if (capture is null && cts is null) return;

        try { cts?.Cancel(); } catch (ObjectDisposedException) { }
        cts?.Dispose();

        if (capture is not null)
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.RecordingStopped -= OnRecordingStopped;
            try { capture.StopRecording(); } catch (Exception ex) { Log.Warn($"StopRecording: {ex.Message}"); }
            try { capture.Dispose(); } catch (Exception ex) { Log.Warn($"Dispose capture: {ex.Message}"); }
        }

        _onAudioData = null;
        Log.Info("Audio capture stopped");
    }

    public void Dispose() => Stop();
}
