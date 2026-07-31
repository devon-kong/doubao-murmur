using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace DoubaoMurmur.Core;

/// <summary>
/// WebSocket client for Doubao's streaming ASR service. Mirrors DoubaoASRClient.swift.
///
/// Audio arriving before the handshake completes is buffered and flushed on connect,
/// matching the macOS/Linux behaviour: recording starts instantly and the first words
/// are not lost to connection latency.
/// </summary>
public sealed class DoubaoAsrClient : IAsrClient
{
    private readonly object _gate = new();
    private readonly List<byte[]> _pending = new();
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    private ClientWebSocket? _ws;
    private CancellationTokenSource? _cts;
    private volatile bool _connected;
    private volatile bool _shuttingDown;

    public bool IsConnected => _connected;

    public event Action? Opened;
    public event Action<string>? ResultReceived;
    public event Action? Finished;
    public event Action<Exception?>? ErrorOccurred;
    public event Action? AuthErrorOccurred;

    /// <summary>
    /// Builds the full WSS URL. Exposed for tests; web_tab_id is passed in so the
    /// result is deterministic.
    /// </summary>
    public static string BuildUrl(AsrParams parameters, string webTabId)
    {
        var query = new List<(string Key, string Value)>();
        foreach (var (key, value) in AppConfig.FixedQueryParams)
        {
            query.Add((key, value));
        }
        query.Add(("device_id", parameters.DeviceId));
        query.Add(("web_id", parameters.WebId));
        query.Add(("tea_uuid", parameters.WebId));
        query.Add(("web_tab_id", webTabId));

        var encoded = string.Join("&", query.Select(p =>
            $"{Uri.EscapeDataString(p.Key)}={Uri.EscapeDataString(p.Value)}"));
        return $"{AppConfig.WssBaseUrl}?{encoded}";
    }

    public void Connect(AsrParams parameters)
    {
        _shuttingDown = false;
        var cts = new CancellationTokenSource();
        lock (_gate)
        {
            _cts = cts;
        }
        _ = Task.Run(() => RunAsync(parameters, cts.Token));
    }

    private async Task RunAsync(AsrParams parameters, CancellationToken ct)
    {
        var ws = new ClientWebSocket();

        try
        {
            // Cookie is set as a raw header rather than through Options.Cookies:
            // CookieContainer rejects values containing characters Doubao actually
            // uses, and this matches the header the macOS/Linux clients send.
            ws.Options.SetRequestHeader("Cookie", parameters.CookieHeader);
            ws.Options.SetRequestHeader("Origin", AppConfig.Origin);
            try
            {
                ws.Options.SetRequestHeader("User-Agent", AppConfig.WebViewUserAgent);
            }
            catch (Exception ex)
            {
                // Optional; some runtimes treat User-Agent as reserved here.
                Log.Warn($"Could not set User-Agent header: {ex.Message}");
            }
        }
        catch (Exception ex)
        {
            Log.Error("Failed to set WebSocket request headers", ex);
            ws.Dispose();
            ErrorOccurred?.Invoke(ex);
            return;
        }

        var url = BuildUrl(parameters, Guid.NewGuid().ToString());

        try
        {
            Log.Info("Connecting to ASR WebSocket");
            using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            connectCts.CancelAfter(AppConfig.ConnectTimeout);
            await ws.ConnectAsync(new Uri(url), connectCts.Token).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            ws.Dispose();
            if (_shuttingDown || ct.IsCancellationRequested)
            {
                Log.Info("Connect aborted by shutdown");
                return;
            }
            Log.Error("WebSocket connect failed", ex);
            ErrorOccurred?.Invoke(ex);
            return;
        }

        lock (_gate)
        {
            _ws = ws;
            _connected = true;
        }
        Log.Info("Connected");

        await FlushPendingAsync(ws, ct).ConfigureAwait(false);
        Opened?.Invoke();

        await ReceiveLoopAsync(ws, ct).ConfigureAwait(false);
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();

        try
        {
            while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct).ConfigureAwait(false);

                if (result.MessageType == WebSocketMessageType.Close)
                {
                    Log.Info($"Server closed: {result.CloseStatus} {result.CloseStatusDescription}");
                    break;
                }

                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;

                var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                HandleMessage(text);
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown.
        }
        catch (Exception ex)
        {
            if (!_shuttingDown && _connected)
            {
                _connected = false;
                Log.Error("WebSocket receive failed", ex);
                ErrorOccurred?.Invoke(ex);
                return;
            }
            Log.Info($"Receive loop ended: {ex.GetType().Name}");
        }

        // The socket went away while we still expected to be streaming.
        if (!_shuttingDown && _connected)
        {
            _connected = false;
            ErrorOccurred?.Invoke(null);
        }
    }

    private void HandleMessage(string json)
    {
        long code = 0;
        var eventName = string.Empty;
        var message = string.Empty;
        string? resultText = null;

        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;

            if (root.TryGetProperty("code", out var codeElement) &&
                codeElement.ValueKind == JsonValueKind.Number)
            {
                codeElement.TryGetInt64(out code);
            }
            if (root.TryGetProperty("event", out var eventElement) &&
                eventElement.ValueKind == JsonValueKind.String)
            {
                eventName = eventElement.GetString() ?? string.Empty;
            }
            if (root.TryGetProperty("message", out var messageElement) &&
                messageElement.ValueKind == JsonValueKind.String)
            {
                message = messageElement.GetString() ?? string.Empty;
            }
            if (root.TryGetProperty("result", out var resultElement) &&
                resultElement.ValueKind == JsonValueKind.Object &&
                resultElement.TryGetProperty("Text", out var textElement) &&
                textElement.ValueKind == JsonValueKind.String)
            {
                resultText = textElement.GetString();
            }
        }
        catch (JsonException)
        {
            return;
        }

        if (code != 0 && IsAuthError(code, message))
        {
            Log.Warn($"Auth error detected: code={code}, message={message}");
            _connected = false;
            AuthErrorOccurred?.Invoke();
            return;
        }

        switch (eventName)
        {
            case "result":
                if (!string.IsNullOrEmpty(resultText)) ResultReceived?.Invoke(resultText!);
                break;
            case "finish":
                Log.Info("Received finish event");
                Finished?.Invoke();
                break;
        }
    }

    /// <summary>Exposed for tests.</summary>
    public static bool IsAuthError(long code, string message)
    {
        if (code == AppConfig.AuthErrorCode) return true;
        var lower = message.ToLowerInvariant();
        return AppConfig.AuthErrorKeywords.Any(keyword => lower.Contains(keyword));
    }

    public void SendAudio(byte[] data)
    {
        ClientWebSocket? ws;
        CancellationToken ct;

        lock (_gate)
        {
            if (!_connected || _ws is null)
            {
                _pending.Add(data);
                return;
            }
            ws = _ws;
            ct = _cts?.Token ?? CancellationToken.None;
        }

        _ = SendBinaryAsync(ws, data, ct);
    }

    private async Task SendBinaryAsync(ClientWebSocket ws, byte[] data, CancellationToken ct)
    {
        try
        {
            await _sendLock.WaitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (ObjectDisposedException)
        {
            return;
        }

        try
        {
            if (ws.State == WebSocketState.Open)
            {
                await ws.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Binary,
                    true, ct).ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException
            or WebSocketException or InvalidOperationException)
        {
            Log.Warn($"Audio send dropped: {ex.GetType().Name}");
        }
        finally
        {
            try { _sendLock.Release(); } catch (ObjectDisposedException) { }
        }
    }

    private async Task FlushPendingAsync(ClientWebSocket ws, CancellationToken ct)
    {
        List<byte[]> buffered;
        lock (_gate)
        {
            if (_pending.Count == 0) return;
            buffered = new List<byte[]>(_pending);
            _pending.Clear();
        }

        Log.Info($"Flushing {buffered.Count} buffered audio chunks");
        foreach (var chunk in buffered)
        {
            await SendBinaryAsync(ws, chunk, ct).ConfigureAwait(false);
        }
    }

    public void FinishSending()
    {
        lock (_gate)
        {
            _pending.Clear();
        }
        _connected = false;
        Log.Info("Finished sending audio, waiting for server response");
    }

    public void Disconnect()
    {
        ClientWebSocket? ws;
        CancellationTokenSource? cts;

        lock (_gate)
        {
            ws = _ws;
            cts = _cts;
            _ws = null;
            _cts = null;
            _pending.Clear();
        }

        if (ws is null && cts is null) return;

        _shuttingDown = true;
        _connected = false;
        _ = Task.Run(async () =>
        {
            if (ws is not null)
            {
                try
                {
                    if (ws.State == WebSocketState.Open)
                    {
                        using var closeCts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                        await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "1000-",
                            closeCts.Token).ConfigureAwait(false);
                    }
                }
                catch (Exception ex)
                {
                    Log.Info($"Close handshake skipped: {ex.GetType().Name}");
                }
            }

            try { cts?.Cancel(); } catch (ObjectDisposedException) { }
            cts?.Dispose();
            ws?.Dispose();
            Log.Info("Disconnected");
        });
    }

    public void Dispose()
    {
        Disconnect();
        _sendLock.Dispose();
    }
}
