unit uCefRuntime;
{
  Chromium Embedded (CEF) runtime management for the CEF login backend.

  Runtime lookup order:
    1. <exe dir>\cef\  — bundled in the Wine/Linux release zip
    2. %APPDATA%\Rua\cef\<CEF version>\ — downloaded on first use as a zip
       (built by build/package-cef-runtime.ps1)
  Browser profile (cookies/cache) lives in %APPDATA%\Rua\CEF.

  Rua.exe doubles as the CEF subprocess executable: CEF relaunches it with
  --type=renderer|gpu-process|utility|...; Rua.dpr calls RunCefSubProcess first thing
  in that case.

  CEF is initialized lazily (first login that needs it) and can only be
  initialized once per process — never re-initialized after shutdown.

  config.ini [Browser]:
    CefRuntimeUrl = override download URL
    CefSwitches   = extra Chromium switches, space separated (e.g. --in-process-gpu)
    CefLog        = 1 → write %APPDATA%\Rua\CEF\debug.log
}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes;

const
  // Posted to the installer's notify window. WParam unused; read the installer's fields.
  WM_CEFRT_PROGRESS = WM_APP + $C10;
  WM_CEFRT_DONE     = WM_APP + $C11;

  // SHA-256 (hex, lowercase) of the runtime zip published for this CEF version.
  // Printed by build/package-cef-runtime.ps1. Empty = no pin (integrity relies on HTTPS only).
  CEF_RUNTIME_SHA256 = 'd0174255b71c991465847e0fc1ef7325d4a3f3b2216f6a1a9c7d4eaa8fc1ef9a';

type
  // Downloads + extracts the runtime zip on a worker thread. Terminate to cancel.
  TCefRuntimeInstaller = class(TThread)
  private
    FUrl:       string;
    FNotifyWnd: HWND;
    FReceived:  Int64;
    FTotal:     Int64;
    FError:     string;
    FLastPost:  Cardinal;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
    procedure Download(const ZipPath: string);
    procedure Extract(const ZipPath: string);
  protected
    procedure Execute; override;
  public
    constructor Create(NotifyWnd: HWND);
    property Received: Int64  read FReceived;
    property Total:    Int64  read FTotal;
    property Error:    string read FError;   // '' = success (valid after WM_CEFRT_DONE)
    property Url:      string read FUrl;
  end;

function CefVersionString: string;
function CefRuntimeDir: string;
function CefProfileDir: string;
function CefRuntimeInstalled: Boolean;
function CefRuntimeUrl: string;

// Main process: create GlobalCEFApp + CefInitialize. Safe to call repeatedly;
// the first result is cached (CEF cannot be initialized twice).
function StartCefRuntime(out ErrorMsg: string): Boolean;
function CefRuntimeStarted: Boolean;
// Rua.dpr: True when this process was launched by CEF as a subprocess.
function IsCefSubProcess: Boolean;
// Rua.dpr: run the CEF subprocess to completion. Caller exits afterwards.
procedure RunCefSubProcess;
// Rua.dpr: after Application.Run. No-op when CEF was never started.
procedure ShutdownCefRuntime;

implementation

uses
  System.IOUtils, System.IniFiles, System.Zip, System.Hash,
  System.Net.HttpClient, System.Net.URLClient,
  uCEFApplication, uCEFApplicationCore, uCEFConstants,
  uLoginBrowser;

const
  DEFAULT_RUNTIME_URL =
    'https://github.com/riistar/Rua/releases/download/cef-%0:s/cef-runtime-%0:s-win64.zip';
  INSTALLED_MARKER = '.rua-installed';

var
  GStartAttempted: Boolean = False;
  GStartOk:        Boolean = False;
  GStartError:     string  = '';

function ReadBrowserIni(const Key, Default: string): string;
var
  INI: TIniFile;
begin
  Result := Default;
  try
    INI := TIniFile.Create(RuaConfigPath);
    try
      Result := INI.ReadString('Browser', Key, Default);
    finally
      INI.Free;
    end;
  except
  end;
end;

function CefVersionString: string;
begin
  Result := Format('%d.%d.%d', [CEF_SUPPORTED_VERSION_MAJOR,
    CEF_SUPPORTED_VERSION_MINOR, CEF_SUPPORTED_VERSION_RELEASE]);
end;

// <exe dir>\cef — shipped in the Wine/Linux release zip (no download needed).
function CefBundledDir: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'cef');
end;

// %APPDATA%\Rua\cef\<ver> — where the on-demand download is installed.
function CefDownloadDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'),
    'Rua\cef\' + CefVersionString);
end;

// Bundled runtime wins over the downloaded one.
function CefRuntimeDir: string;
begin
  if TFile.Exists(TPath.Combine(CefBundledDir, 'libcef.dll')) then
    Result := CefBundledDir
  else
    Result := CefDownloadDir;
end;

function CefProfileDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Rua\CEF');
end;

function CefRuntimeInstalled: Boolean;
begin
  Result := TFile.Exists(TPath.Combine(CefBundledDir, 'libcef.dll'))
    or (TFile.Exists(TPath.Combine(CefDownloadDir, INSTALLED_MARKER))
        and TFile.Exists(TPath.Combine(CefDownloadDir, 'libcef.dll')));
end;

function CefRuntimeUrl: string;
begin
  Result := Trim(ReadBrowserIni('CefRuntimeUrl', ''));
  if Result = '' then
    Result := Format(DEFAULT_RUNTIME_URL, [CefVersionString]);
end;

{ ------------------------------------------------------------------ }
{  GlobalCEFApp configuration (shared by browser + subprocesses)     }
{ ------------------------------------------------------------------ }

// Must produce identical settings in the browser process and every subprocess.
procedure ConfigureGlobalCefApp;
var
  Dir, Extra: string;
begin
  Dir := CefRuntimeDir;
  GlobalCEFApp := TCefApplication.Create;
  GlobalCEFApp.FrameworkDirPath := Dir;
  GlobalCEFApp.ResourcesDirPath := Dir;
  GlobalCEFApp.LocalesDirPath   := TPath.Combine(Dir, 'locales');
  GlobalCEFApp.RootCache        := CefProfileDir;
  GlobalCEFApp.Cache            := TPath.Combine(CefProfileDir, 'cache');
  GlobalCEFApp.NoSandbox        := True;
  GlobalCEFApp.EnableGPU        := False;
  GlobalCEFApp.ShowMessageDlg   := False; // errors are reported through the login form

  if ReadBrowserIni('CefLog', '0') = '1' then
  begin
    GlobalCEFApp.LogFile     := TPath.Combine(CefProfileDir, 'debug.log');
    GlobalCEFApp.LogSeverity := LOGSEVERITY_INFO;
  end;

  // Wine has no usable GPU path for Chromium; software rendering is reliable.
  if IsRunningUnderWine then
  begin
    GlobalCEFApp.AddCustomCommandLine('--disable-gpu');
    GlobalCEFApp.AddCustomCommandLine('--disable-gpu-compositing');
  end;

  for Extra in Trim(ReadBrowserIni('CefSwitches', '')).Split([' '], TStringSplitOptions.ExcludeEmpty) do
  begin
    var Eq := Pos('=', Extra);
    if Eq > 0 then
      GlobalCEFApp.AddCustomCommandLine(Copy(Extra, 1, Eq - 1), Copy(Extra, Eq + 1, MaxInt))
    else
      GlobalCEFApp.AddCustomCommandLine(Extra);
  end;
end;

function StartCefRuntime(out ErrorMsg: string): Boolean;
begin
  if not GStartAttempted then
  begin
    GStartAttempted := True;
    try
      if not CefRuntimeInstalled then
        GStartError := 'Chromium runtime not installed.'
      else
      begin
        TDirectory.CreateDirectory(CefProfileDir);
        ConfigureGlobalCefApp;
        GStartOk := GlobalCEFApp.StartMainProcess;
        if not GStartOk then
        begin
          GStartError := Trim(GlobalCEFApp.LastErrorMessage);
          if GlobalCEFApp.MissingLibFiles <> '' then
            GStartError := GStartError + ' Missing: ' + GlobalCEFApp.MissingLibFiles;
          if GStartError = '' then
            GStartError := 'CEF initialization failed.';
        end;
      end;
    except
      on E: Exception do
      begin
        GStartOk    := False;
        GStartError := E.Message;
      end;
    end;
  end;
  Result   := GStartOk;
  ErrorMsg := GStartError;
end;

function CefRuntimeStarted: Boolean;
begin
  Result := GStartOk;
end;

function IsCefSubProcess: Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I).StartsWith('--type=') then
      Exit(True);
  Result := False;
end;

procedure RunCefSubProcess;
begin
  ConfigureGlobalCefApp;
  try
    GlobalCEFApp.StartSubProcess;
  finally
    DestroyGlobalCEFApp;
  end;
end;

procedure ShutdownCefRuntime;
begin
  if GlobalCEFApp <> nil then
    DestroyGlobalCEFApp;
end;

{ ------------------------------------------------------------------ }
{  TCefRuntimeInstaller                                               }
{ ------------------------------------------------------------------ }

constructor TCefRuntimeInstaller.Create(NotifyWnd: HWND);
begin
  FUrl       := CefRuntimeUrl;
  FNotifyWnd := NotifyWnd;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TCefRuntimeInstaller.Execute;
var
  ZipPath: string;
begin
  ZipPath := TPath.Combine(TPath.GetDirectoryName(CefDownloadDir),
    'cef-runtime-' + CefVersionString + '.zip.part');
  try
    TDirectory.CreateDirectory(TPath.GetDirectoryName(ZipPath));
    try
      Download(ZipPath);
      if not Terminated then
        Extract(ZipPath);
    finally
      if TFile.Exists(ZipPath) then
        try TFile.Delete(ZipPath); except end;
    end;
    if Terminated and (FError = '') then
      FError := 'Cancelled.';
  except
    on E: Exception do
      FError := E.Message;
  end;
  PostMessage(FNotifyWnd, WM_CEFRT_DONE, 0, 0);
end;

procedure TCefRuntimeInstaller.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin
  FTotal    := AContentLength;
  FReceived := AReadCount;
  AAbort    := Terminated;
  // Throttle UI updates to ~5/s.
  if GetTickCount - FLastPost >= 200 then
  begin
    FLastPost := GetTickCount;
    PostMessage(FNotifyWnd, WM_CEFRT_PROGRESS, 0, 0);
  end;
end;

procedure TCefRuntimeInstaller.Download(const ZipPath: string);
var
  Client: THTTPClient;
  FS:     TFileStream;
  Resp:   IHTTPResponse;
begin
  Client := THTTPClient.Create;
  try
    Client.HandleRedirects := True; // GitHub release assets redirect to a CDN
    Client.ReceiveDataCallBack := ReceiveData;
    FS := TFileStream.Create(ZipPath, fmCreate);
    try
      Resp := Client.Get(FUrl, FS);
    finally
      FS.Free;
    end;
  finally
    Client.Free;
  end;
  if Terminated then Exit;
  if Resp.StatusCode <> 200 then
    raise Exception.CreateFmt('Download failed: HTTP %d (%s)', [Resp.StatusCode, FUrl]);

  if CEF_RUNTIME_SHA256 <> '' then
  begin
    if LowerCase(THashSHA2.GetHashStringFromFile(ZipPath, SHA256)) <> LowerCase(CEF_RUNTIME_SHA256) then
      raise Exception.Create('Downloaded runtime failed integrity check (SHA-256 mismatch).');
  end;
end;

procedure TCefRuntimeInstaller.Extract(const ZipPath: string);
var
  Zip:       TZipFile;
  Name, Staging, Root, Final: string;
  Subdirs:   TArray<string>;
begin
  Final   := CefDownloadDir;
  Staging := Final + '.staging';
  if TDirectory.Exists(Staging) then
    TDirectory.Delete(Staging, True);

  Zip := TZipFile.Create;
  try
    Zip.Open(ZipPath, zmRead);
    // Reject path traversal before extracting anything.
    for Name in Zip.FileNames do
      if (Pos('..', Name) > 0) or (Pos(':', Name) > 0)
         or Name.StartsWith('/') or Name.StartsWith('\') then
        raise Exception.Create('Runtime archive contains an unsafe path: ' + Name);
    Zip.ExtractAll(Staging);
  finally
    Zip.Free;
  end;

  // Accept either files at the zip root or a single top-level folder.
  Root := Staging;
  if not TFile.Exists(TPath.Combine(Root, 'libcef.dll')) then
  begin
    Subdirs := TDirectory.GetDirectories(Staging);
    if (Length(Subdirs) = 1) and TFile.Exists(TPath.Combine(Subdirs[0], 'libcef.dll')) then
      Root := Subdirs[0]
    else
      raise Exception.Create('Runtime archive does not contain libcef.dll.');
  end;

  if TDirectory.Exists(Final) then
    TDirectory.Delete(Final, True);
  TDirectory.Move(Root, Final);
  if TDirectory.Exists(Staging) then
    TDirectory.Delete(Staging, True);
  TFile.WriteAllText(TPath.Combine(Final, INSTALLED_MARKER), FUrl);
end;

end.
