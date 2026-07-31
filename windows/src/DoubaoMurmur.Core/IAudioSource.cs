namespace DoubaoMurmur.Core;

/// <summary>
/// Source of 16 kHz mono Int16 LE PCM.
///
/// Abstracted so the ASR pipeline can be exercised from a WAV file — CI runners have
/// no audio input device, and a file source makes transcription tests deterministic.
/// </summary>
public interface IAudioSource : IDisposable
{
    bool IsCapturing { get; }

    /// <summary>Start producing audio. The callback runs on a background thread.</summary>
    void Start(Action<byte[]> onAudioData);

    void Stop();
}
