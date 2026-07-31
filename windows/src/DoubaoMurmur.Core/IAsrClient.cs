namespace DoubaoMurmur.Core;

/// <summary>
/// Streaming ASR transport. Abstracted so the state machine can be unit tested
/// without a live Doubao connection.
/// </summary>
public interface IAsrClient : IDisposable
{
    bool IsConnected { get; }

    /// <summary>Raised once the WebSocket handshake succeeds. Fires off the UI thread.</summary>
    event Action? Opened;

    /// <summary>Partial or final transcription text. Fires off the UI thread.</summary>
    event Action<string>? ResultReceived;

    /// <summary>Server signalled it is done. Fires off the UI thread.</summary>
    event Action? Finished;

    /// <summary>Transport failure. Fires off the UI thread.</summary>
    event Action<Exception?>? ErrorOccurred;

    /// <summary>Credentials rejected — distinct from a generic error. Fires off the UI thread.</summary>
    event Action? AuthErrorOccurred;

    void Connect(AsrParams parameters);

    /// <summary>Send Int16 LE PCM. Thread-safe; buffers until the socket is open.</summary>
    void SendAudio(byte[] data);

    /// <summary>Stop sending audio but keep the socket open for the final result.</summary>
    void FinishSending();

    void Disconnect();
}
