namespace DoubaoMurmur.Core;

/// <summary>
/// Marshals work onto the UI thread. The Core layer deliberately knows nothing
/// about WinUI, so the app supplies a DispatcherQueue-backed implementation and
/// tests supply a synchronous one.
/// </summary>
public interface IDispatcher
{
    /// <summary>Queue an action on the UI thread.</summary>
    void Post(Action action);

    /// <summary>Run an action on the UI thread after a delay. Dispose to cancel.</summary>
    IDisposable Schedule(TimeSpan delay, Action action);
}
