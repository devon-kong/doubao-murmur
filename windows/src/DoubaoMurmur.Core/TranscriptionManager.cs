namespace DoubaoMurmur.Core;

/// <summary>
/// State machine for the recording lifecycle. Mirrors TranscriptionManager.swift:
/// idle -> starting -> recording -> stopping -> idle.
///
/// Every ASR callback arrives on a background thread and is marshalled onto the UI
/// thread through <see cref="IDispatcher"/>, so all state transitions happen on one
/// thread and need no locking.
/// </summary>
public sealed class TranscriptionManager : IDisposable
{
    private readonly AppState _state;
    private readonly IAsrClient _asr;
    private readonly IAudioSource _audio;
    private readonly IDispatcher _dispatcher;

    private bool _usingCachedParams;
    private bool _awaitingFinalResult;
    private IDisposable? _safetyTimer;

    public TranscriptionManager(AppState state, IAsrClient asr, IAudioSource audio, IDispatcher dispatcher)
    {
        _state = state;
        _asr = asr;
        _audio = audio;
        _dispatcher = dispatcher;

        _asr.Opened += () => _dispatcher.Post(OnAsrOpen);
        _asr.ResultReceived += text => _dispatcher.Post(() => OnAsrResult(text));
        _asr.Finished += () => _dispatcher.Post(OnAsrFinish);
        _asr.ErrorOccurred += error => _dispatcher.Post(() => OnAsrError(error));
        _asr.AuthErrorOccurred += () => _dispatcher.Post(HandleAuthFailure);
    }

    // Wired by the app shell. All fire on the UI thread.
    public Action? OnAuthExpired { get; set; }
    public Action? OnShowLogin { get; set; }
    public Action<Action<AsrParams?>>? OnParamsNeeded { get; set; }
    public Action? OnOverlayShow { get; set; }
    public Action? OnOverlayHide { get; set; }
    public Action<string>? OnOverlayUpdate { get; set; }
    public Action<string>? OnPaste { get; set; }
    public Action<bool>? OnCancelEnabledChanged { get; set; }

    // --- Toggle ---

    public void HandleToggle()
    {
        switch (_state.RecordingState)
        {
            case RecordingState.Idle:
                StartRecording();
                break;
            case RecordingState.Starting:
            case RecordingState.Recording:
                StopRecording();
                break;
            case RecordingState.Stopping:
                // Ignore: already finishing up.
                break;
        }
    }

    private void StartRecording()
    {
        if (_state.LoginStatus != LoginStatus.LoggedIn)
        {
            Log.Warn("Not logged in, showing login window");
            OnShowLogin?.Invoke();
            return;
        }

        Log.Info("Starting recording");
        SetState(RecordingState.Starting);
        _state.TranscriptionText = string.Empty;
        _state.ErrorMessage = null;
        OnOverlayShow?.Invoke();

        // Start audio immediately; the ASR client buffers until the socket opens.
        try
        {
            _audio.Start(_asr.SendAudio);
        }
        catch (Exception ex)
        {
            Log.Error("Audio capture failed", ex);
            _state.ErrorMessage = "麦克风启动失败";
            ScheduleReset();
            return;
        }

        var cached = AsrParamsStore.Load();
        if (cached is not null)
        {
            Log.Info("Using cached ASR params");
            _usingCachedParams = true;
            _asr.Connect(cached);
        }
        else if (OnParamsNeeded is not null)
        {
            _usingCachedParams = false;
            OnParamsNeeded(OnParamsExtracted);
        }
        else
        {
            _state.ErrorMessage = "无法获取连接参数，请重新登录";
            ScheduleReset();
        }
    }

    private void StopRecording()
    {
        Log.Info("Stopping recording");
        SetState(RecordingState.Stopping);
        _audio.Stop();
        _asr.FinishSending();
        _awaitingFinalResult = true;

        _safetyTimer?.Dispose();
        _safetyTimer = _dispatcher.Schedule(AppConfig.StopSafetyTimeout, () =>
        {
            _safetyTimer = null;
            if (_state.RecordingState != RecordingState.Stopping) return;
            Log.Info("Safety timeout, completing with current text");
            _awaitingFinalResult = false;
            CompleteTranscription();
        });
    }

    public void HandleCancel()
    {
        if (_state.RecordingState == RecordingState.Idle) return;
        Log.Info("Cancelling transcription");
        _awaitingFinalResult = false;
        _audio.Stop();
        _asr.Disconnect();
        ResetToIdle();
    }

    // --- ASR callbacks (already marshalled to the UI thread) ---

    private void OnAsrOpen()
    {
        if (_state.RecordingState == RecordingState.Starting)
        {
            SetState(RecordingState.Recording);
        }
    }

    private void OnAsrResult(string text)
    {
        _state.TranscriptionText = text;
        OnOverlayUpdate?.Invoke(text);

        if (_state.RecordingState == RecordingState.Starting)
        {
            SetState(RecordingState.Recording);
        }

        if (_awaitingFinalResult)
        {
            _awaitingFinalResult = false;
            CompleteTranscription();
        }
    }

    private void OnAsrFinish()
    {
        _awaitingFinalResult = false;
        if (_state.RecordingState is RecordingState.Stopping or RecordingState.Recording)
        {
            CompleteTranscription();
        }
    }

    private void OnAsrError(Exception? error)
    {
        if (_state.RecordingState == RecordingState.Idle) return;
        Log.Error($"ASR error: {error?.Message ?? "connection closed"}");

        if (_usingCachedParams)
        {
            // Stale cookies are by far the most likely cause of a failure when we
            // reused saved credentials, so treat it as an auth problem.
            HandleAuthFailure();
            return;
        }

        _state.ErrorMessage = "连接出错";
        ScheduleReset();
    }

    // --- Completion & reset ---

    private void CompleteTranscription()
    {
        var text = _state.TranscriptionText.Trim();
        Log.Info($"Completing transcription ({text.Length} chars)");
        if (text.Length > 0) OnPaste?.Invoke(text);
        ResetToIdle();
    }

    private void ScheduleReset()
    {
        _dispatcher.Schedule(AppConfig.AuthExpiryDelay, ResetToIdle);
    }

    private void ResetToIdle()
    {
        _safetyTimer?.Dispose();
        _safetyTimer = null;
        _awaitingFinalResult = false;
        _audio.Stop();
        _asr.Disconnect();
        SetState(RecordingState.Idle);
        _state.ErrorMessage = null;
        OnOverlayHide?.Invoke();
        _usingCachedParams = false;

        _dispatcher.Schedule(TimeSpan.FromMilliseconds(200),
            () => _state.TranscriptionText = string.Empty);
    }

    private void HandleAuthFailure()
    {
        Log.Warn("Auth failure, clearing cached params");
        AsrParamsStore.Clear();
        _usingCachedParams = false;
        _audio.Stop();
        _asr.Disconnect();
        ResetToIdle();
        _state.LoginStatus = LoginStatus.NotLoggedIn;
        OnAuthExpired?.Invoke();
    }

    private void SetState(RecordingState newState)
    {
        _state.RecordingState = newState;
        OnCancelEnabledChanged?.Invoke(newState != RecordingState.Idle);
    }

    private void OnParamsExtracted(AsrParams? parameters)
    {
        if (parameters is not null)
        {
            AsrParamsStore.Save(parameters);
            _asr.Connect(parameters);
        }
        else
        {
            _state.ErrorMessage = "无法获取连接参数，请重新登录";
            ScheduleReset();
        }
    }

    public void Dispose()
    {
        _safetyTimer?.Dispose();
        _audio.Stop();
        _asr.Disconnect();
    }
}
