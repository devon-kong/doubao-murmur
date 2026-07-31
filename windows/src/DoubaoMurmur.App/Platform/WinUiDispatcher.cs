using DoubaoMurmur.Core;
using Microsoft.UI.Dispatching;

namespace DoubaoMurmur.Platform;

/// <summary>DispatcherQueue-backed <see cref="IDispatcher"/> for the UI thread.</summary>
internal sealed class WinUiDispatcher : IDispatcher
{
    private readonly DispatcherQueue _queue;

    public WinUiDispatcher(DispatcherQueue queue) => _queue = queue;

    public void Post(Action action)
    {
        if (_queue.TryEnqueue(() => Invoke(action))) return;
        Log.Warn("DispatcherQueue rejected work; the UI thread may be shutting down");
    }

    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var handle = new TimerHandle();

        // Timers must be created on the dispatcher thread, and callers are not
        // guaranteed to be there, so creation itself is queued.
        Post(() =>
        {
            var timer = _queue.CreateTimer();
            timer.Interval = delay;
            timer.IsRepeating = false;
            timer.Tick += (sender, _) =>
            {
                sender.Stop();
                Invoke(action);
            };
            timer.Start();
            handle.Attach(timer);
        });

        return handle;
    }

    private static void Invoke(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            // An exception escaping a dispatcher callback tears down the process.
            Log.Error("Dispatched action threw", ex);
        }
    }

    private sealed class TimerHandle : IDisposable
    {
        private DispatcherQueueTimer? _timer;
        private bool _disposed;

        public void Attach(DispatcherQueueTimer timer)
        {
            if (_disposed)
            {
                timer.Stop();
                return;
            }
            _timer = timer;
        }

        public void Dispose()
        {
            _disposed = true;
            _timer?.Stop();
            _timer = null;
        }
    }
}
