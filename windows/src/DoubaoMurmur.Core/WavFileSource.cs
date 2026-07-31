using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace DoubaoMurmur.Core;

/// <summary>
/// Replays a WAV file as if it were microphone input, paced in real time and
/// converted to 16 kHz mono Int16. Used by tests and by the diagnostics tool on
/// machines (or CI runners) with no recording device.
/// </summary>
public sealed class WavFileSource : IAudioSource
{
    private readonly string _path;
    private readonly bool _realTime;
    private CancellationTokenSource? _cts;

    public WavFileSource(string path, bool realTime = true)
    {
        _path = path;
        _realTime = realTime;
    }

    public bool IsCapturing => _cts is { IsCancellationRequested: false };

    /// <summary>Raised once the file has been fully replayed.</summary>
    public event Action? Completed;

    public void Start(Action<byte[]> onAudioData)
    {
        if (IsCapturing) return;
        var cts = new CancellationTokenSource();
        _cts = cts;
        _ = Task.Run(() => ReplayAsync(onAudioData, cts.Token));
    }

    private async Task ReplayAsync(Action<byte[]> onAudioData, CancellationToken ct)
    {
        try
        {
            using var reader = new AudioFileReader(_path);
            ISampleProvider samples = reader;

            if (samples.WaveFormat.Channels == 2)
            {
                samples = new StereoToMonoSampleProvider(samples);
            }
            else if (samples.WaveFormat.Channels > 2)
            {
                samples = new MultiplexingSampleProvider(new[] { samples }, 1);
            }

            if (samples.WaveFormat.SampleRate != AppConfig.AudioSampleRate)
            {
                samples = new WdlResamplingSampleProvider(samples, AppConfig.AudioSampleRate);
            }

            IWaveProvider pipeline = new SampleToWaveProvider16(samples);

            var chunkSize = AppConfig.AudioChunkBytes;
            var chunk = new byte[chunkSize];

            while (!ct.IsCancellationRequested)
            {
                var filled = 0;
                while (filled < chunkSize)
                {
                    var read = pipeline.Read(chunk, filled, chunkSize - filled);
                    if (read <= 0) break;
                    filled += read;
                }

                if (filled == 0) break;

                var payload = new byte[filled];
                Buffer.BlockCopy(chunk, 0, payload, 0, filled);
                onAudioData(payload);

                if (_realTime)
                {
                    await Task.Delay(AppConfig.AudioChunkMilliseconds, ct).ConfigureAwait(false);
                }

                if (filled < chunkSize) break;
            }

            Log.Info("WAV replay finished");
            Completed?.Invoke();
        }
        catch (OperationCanceledException)
        {
            // Stopped.
        }
        catch (Exception ex)
        {
            Log.Error("WAV replay failed", ex);
        }
    }

    public void Stop()
    {
        var cts = _cts;
        _cts = null;
        try { cts?.Cancel(); } catch (ObjectDisposedException) { }
        cts?.Dispose();
    }

    public void Dispose() => Stop();
}
