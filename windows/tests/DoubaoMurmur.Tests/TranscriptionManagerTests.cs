using DoubaoMurmur.Core;
using Xunit;

namespace DoubaoMurmur.Tests;

public class TranscriptionManagerTests
{
    private sealed class Harness : IDisposable
    {
        public TempConfigDir Config { get; } = new();
        public AppState State { get; } = new();
        public FakeAsrClient Asr { get; } = new();
        public FakeAudioSource Audio { get; } = new();
        public TestDispatcher Dispatcher { get; } = new();
        public TranscriptionManager Manager { get; }

        public string? Pasted { get; private set; }
        public int ShowLoginCount { get; private set; }
        public int AuthExpiredCount { get; private set; }
        public bool OverlayVisible { get; private set; }
        public string LastOverlayText { get; private set; } = string.Empty;

        public Harness(bool loggedInWithParams)
        {
            if (loggedInWithParams)
            {
                AsrParamsStore.Save(new AsrParams
                {
                    Cookies = new Dictionary<string, string> { ["sessionid"] = "s" },
                    DeviceId = "device",
                    WebId = "web",
                });
                State.LoginStatus = LoginStatus.LoggedIn;
            }
            else
            {
                State.LoginStatus = LoginStatus.NotLoggedIn;
            }

            Manager = new TranscriptionManager(State, Asr, Audio, Dispatcher)
            {
                OnPaste = text => Pasted = text,
                OnShowLogin = () => ShowLoginCount++,
                OnAuthExpired = () => AuthExpiredCount++,
                OnOverlayShow = () => OverlayVisible = true,
                OnOverlayHide = () => OverlayVisible = false,
                OnOverlayUpdate = text => LastOverlayText = text,
            };
        }

        public void Dispose()
        {
            Manager.Dispose();
            Config.Dispose();
        }
    }

    [Fact]
    public void Toggle_WhenNotLoggedIn_AsksForLogin()
    {
        using var harness = new Harness(loggedInWithParams: false);

        harness.Manager.HandleToggle();

        Assert.Equal(1, harness.ShowLoginCount);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
        Assert.Equal(0, harness.Audio.StartCount);
    }

    [Fact]
    public void Toggle_WithCachedParams_StartsAudioAndConnects()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();

        Assert.Equal(RecordingState.Starting, harness.State.RecordingState);
        Assert.Equal(1, harness.Audio.StartCount);
        Assert.Equal(1, harness.Asr.ConnectCount);
        Assert.True(harness.OverlayVisible);
    }

    [Fact]
    public void AudioIsStreamedBeforeTheSocketOpens()
    {
        using var harness = new Harness(loggedInWithParams: true);
        harness.Manager.HandleToggle();

        // Recording starts immediately; the client buffers until connected.
        harness.Audio.Emit(new byte[] { 1, 2, 3, 4 });

        Assert.Single(harness.Asr.Sent);
    }

    [Fact]
    public void OpenedEvent_MovesToRecording()
    {
        using var harness = new Harness(loggedInWithParams: true);
        harness.Manager.HandleToggle();

        harness.Asr.RaiseOpened();

        Assert.Equal(RecordingState.Recording, harness.State.RecordingState);
    }

    [Fact]
    public void FullRoundTrip_PastesTheFinalText()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseOpened();
        harness.Asr.RaiseResult("你好");
        Assert.Equal("你好", harness.LastOverlayText);

        harness.Manager.HandleToggle();
        Assert.Equal(RecordingState.Stopping, harness.State.RecordingState);
        Assert.True(harness.Asr.FinishSendingCalled);

        harness.Asr.RaiseResult("你好世界");

        Assert.Equal("你好世界", harness.Pasted);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
        Assert.False(harness.OverlayVisible);
        Assert.Equal(1, harness.Audio.StopCount);
    }

    [Fact]
    public void SafetyTimeout_CompletesWithWhateverTextArrived()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseOpened();
        harness.Asr.RaiseResult("半句话");
        harness.Manager.HandleToggle();

        // The server never sends a final result; the safety timer must not hang.
        harness.Dispatcher.RunScheduled();

        Assert.Equal("半句话", harness.Pasted);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
    }

    [Fact]
    public void FinishEvent_CompletesTranscription()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseOpened();
        harness.Asr.RaiseResult("结束");
        harness.Asr.RaiseFinished();

        Assert.Equal("结束", harness.Pasted);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
    }

    [Fact]
    public void Cancel_DiscardsTheTranscription()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseOpened();
        harness.Asr.RaiseResult("不要这句");
        harness.Manager.HandleCancel();

        Assert.Null(harness.Pasted);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
        Assert.False(harness.OverlayVisible);
    }

    [Fact]
    public void AuthError_ClearsCredentialsAndPromptsRelogin()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseAuthError();

        Assert.Equal(1, harness.AuthExpiredCount);
        Assert.False(AsrParamsStore.HasSaved());
        Assert.Equal(LoginStatus.NotLoggedIn, harness.State.LoginStatus);
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
    }

    [Fact]
    public void TransportErrorOnCachedParams_IsTreatedAsExpiredAuth()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseError(new IOException("closed"));

        Assert.Equal(1, harness.AuthExpiredCount);
        Assert.False(AsrParamsStore.HasSaved());
    }

    [Fact]
    public void MicrophoneFailure_ShowsAnErrorAndReturnsToIdle()
    {
        using var harness = new Harness(loggedInWithParams: true);
        harness.Audio.StartException = new InvalidOperationException("no device");

        harness.Manager.HandleToggle();
        Assert.Equal("麦克风启动失败", harness.State.ErrorMessage);
        Assert.Equal(0, harness.Asr.ConnectCount);

        harness.Dispatcher.RunScheduled();
        Assert.Equal(RecordingState.Idle, harness.State.RecordingState);
    }

    [Fact]
    public void ToggleWhileStopping_IsIgnored()
    {
        using var harness = new Harness(loggedInWithParams: true);

        harness.Manager.HandleToggle();
        harness.Asr.RaiseOpened();
        harness.Manager.HandleToggle();
        Assert.Equal(RecordingState.Stopping, harness.State.RecordingState);

        harness.Manager.HandleToggle();
        Assert.Equal(RecordingState.Stopping, harness.State.RecordingState);
        Assert.Equal(1, harness.Audio.StartCount);
    }
}
