using DoubaoMurmur.Core;

// AppConfig.OverrideConfigDir is process-global, so tests must not run concurrently.
[assembly: Xunit.CollectionBehavior(DisableTestParallelization = true)]

namespace DoubaoMurmur.Tests;

/// <summary>Runs posted work inline and holds scheduled work until the test fires it.</summary>
internal sealed class TestDispatcher : IDispatcher
{
    private readonly List<Entry> _scheduled = new();

    public int PendingCount => _scheduled.Count;

    public void Post(Action action) => action();

    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var entry = new Entry(delay, action);
        _scheduled.Add(entry);
        return new Handle(() => _scheduled.Remove(entry));
    }

    /// <summary>Fire everything currently scheduled, in order.</summary>
    public void RunScheduled()
    {
        var due = _scheduled.ToList();
        _scheduled.Clear();
        foreach (var entry in due) entry.Action();
    }

    private sealed record Entry(TimeSpan Delay, Action Action);

    private sealed class Handle : IDisposable
    {
        private readonly Action _cancel;
        public Handle(Action cancel) => _cancel = cancel;
        public void Dispose() => _cancel();
    }
}

internal sealed class FakeAsrClient : IAsrClient
{
    public bool IsConnected { get; private set; }
    public int ConnectCount { get; private set; }
    public int DisconnectCount { get; private set; }
    public bool FinishSendingCalled { get; private set; }
    public List<byte[]> Sent { get; } = new();
    public AsrParams? LastParams { get; private set; }

    public event Action? Opened;
    public event Action<string>? ResultReceived;
    public event Action? Finished;
    public event Action<Exception?>? ErrorOccurred;
    public event Action? AuthErrorOccurred;

    public void Connect(AsrParams parameters)
    {
        ConnectCount++;
        LastParams = parameters;
        IsConnected = true;
    }

    public void SendAudio(byte[] data) => Sent.Add(data);

    public void FinishSending()
    {
        FinishSendingCalled = true;
        IsConnected = false;
    }

    public void Disconnect()
    {
        DisconnectCount++;
        IsConnected = false;
    }

    public void Dispose() => Disconnect();

    public void RaiseOpened() => Opened?.Invoke();
    public void RaiseResult(string text) => ResultReceived?.Invoke(text);
    public void RaiseFinished() => Finished?.Invoke();
    public void RaiseError(Exception? error) => ErrorOccurred?.Invoke(error);
    public void RaiseAuthError() => AuthErrorOccurred?.Invoke();
}

internal sealed class FakeAudioSource : IAudioSource
{
    public bool IsCapturing { get; private set; }
    public int StartCount { get; private set; }
    public int StopCount { get; private set; }
    public Exception? StartException { get; set; }

    private Action<byte[]>? _sink;

    public void Start(Action<byte[]> onAudioData)
    {
        if (StartException is not null) throw StartException;
        StartCount++;
        IsCapturing = true;
        _sink = onAudioData;
    }

    public void Emit(byte[] data) => _sink?.Invoke(data);

    public void Stop()
    {
        if (IsCapturing) StopCount++;
        IsCapturing = false;
        _sink = null;
    }

    public void Dispose() => Stop();
}

/// <summary>Points AppConfig at a throwaway directory for the duration of a test.</summary>
internal sealed class TempConfigDir : IDisposable
{
    public string Path { get; }

    public TempConfigDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "doubao-murmur-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
        AppConfig.OverrideConfigDir(Path);
    }

    public void Dispose()
    {
        AppConfig.OverrideConfigDir(null);
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
            // Best effort.
        }
    }
}
