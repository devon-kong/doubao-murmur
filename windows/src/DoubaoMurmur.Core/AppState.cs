using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace DoubaoMurmur.Core;

public enum LoginStatus
{
    Checking,
    LoggedIn,
    NotLoggedIn,
}

public enum RecordingState
{
    Idle,
    Starting,
    Recording,
    Stopping,
}

/// <summary>Shared observable application state. Mirrors AppState.swift.</summary>
public sealed class AppState : INotifyPropertyChanged
{
    private LoginStatus _loginStatus = LoginStatus.Checking;
    private RecordingState _recordingState = RecordingState.Idle;
    private string _transcriptionText = string.Empty;
    private string? _errorMessage;

    public event PropertyChangedEventHandler? PropertyChanged;

    public LoginStatus LoginStatus
    {
        get => _loginStatus;
        set => Set(ref _loginStatus, value);
    }

    public RecordingState RecordingState
    {
        get => _recordingState;
        set => Set(ref _recordingState, value);
    }

    public string TranscriptionText
    {
        get => _transcriptionText;
        set => Set(ref _transcriptionText, value);
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        set => Set(ref _errorMessage, value);
    }

    public bool IsRecording =>
        _recordingState is RecordingState.Recording or RecordingState.Starting;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
