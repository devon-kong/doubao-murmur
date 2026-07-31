using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>
/// Keeps a single tray instance alive. A named mutex is deliberately all this
/// does: a second launch simply exits rather than trying to talk to the first,
/// which would need a message-only IPC channel for very little benefit.
/// </summary>
internal sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\DoubaoMurmur.SingleInstance";
    private Mutex? _mutex;

    public bool TryAcquire()
    {
        try
        {
            _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
            if (createdNew) return true;

            _mutex.Dispose();
            _mutex = null;
            Log.Info("Another instance is already running");
            return false;
        }
        catch (Exception ex)
        {
            // If the mutex cannot be created, allow the launch rather than
            // leaving the user with an app that refuses to start.
            Log.Warn($"Single-instance check failed, continuing: {ex.Message}");
            return true;
        }
    }

    public void Dispose()
    {
        try
        {
            _mutex?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // Not the owner; nothing to release.
        }
        _mutex?.Dispose();
        _mutex = null;
    }
}
