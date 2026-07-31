; Inno Setup script for Doubao Murmur (Windows).
;
; Installs per-user into %LOCALAPPDATA%\Programs so no UAC prompt is needed.
; Strings are kept ASCII so the script stays encoding-safe on any toolchain.
;
; Build:
;   ISCC.exe /DMyAppVersion=1.2.3 /DSourceDir=<publish dir> /DOutputDir=<dist dir> installer.iss

#define MyAppName "Doubao Murmur"
#define MyAppExeName "DoubaoMurmur.exe"
#define MyAppPublisher "lilong7676"
#define MyAppURL "https://github.com/lilong7676/doubao-murmur"

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#ifndef SourceDir
  #define SourceDir "..\publish\DoubaoMurmur"
#endif

#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

#ifndef OutputName
  #define OutputName "Doubao-Murmur-Setup"
#endif

[Setup]
AppId={{F68A81DE-36A8-4471-B166-5459BB477679}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}

; Per-user install: no administrator rights, no UAC prompt.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\src\DoubaoMurmur.App\Assets\AppIcon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
const
  WebView2ClientKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  WebView2Wow6432Key = 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  WebView2DownloadURL = 'https://developer.microsoft.com/microsoft-edge/webview2/';

function WebView2Installed: Boolean;
var
  Version: String;
begin
  Result :=
    (RegQueryStringValue(HKLM, WebView2Wow6432Key, 'pv', Version) and (Version <> '')) or
    (RegQueryStringValue(HKLM, WebView2ClientKey, 'pv', Version) and (Version <> '')) or
    (RegQueryStringValue(HKCU, WebView2ClientKey, 'pv', Version) and (Version <> ''));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorCode: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;

  // The login window is a WebView2 control. Windows 11 and recent Windows 10
  // ship the runtime; older machines need it installed once.
  if WebView2Installed then
    Exit;

  if MsgBox('Microsoft Edge WebView2 Runtime was not found.' + #13#10#13#10 +
            'It is required to sign in to Doubao. Open the download page now?',
            mbConfirmation, MB_YESNO) = IDYES then
  begin
    ShellExec('open', WebView2DownloadURL, '', '', SW_SHOW, ewNoWait, ErrorCode);
  end;
end;
