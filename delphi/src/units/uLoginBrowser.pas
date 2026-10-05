unit uLoginBrowser;
{
  Engine-neutral embedded browser used by the login form (frmLoginWebView).

  Two backends:
    TLoginBrowserWV  (uLoginBrowserWV)  — Edge WebView2 via WebView4Delphi. Default on Windows.
    TLoginBrowserCEF (uLoginBrowserCEF) — Chromium Embedded via CEF4Delphi. Default under
                                          Wine/Proton, where the WebView2 runtime is unreliable.

  All events fire on the VCL main thread.
  Engine choice: config.ini [Browser] Engine = auto | webview2 | cef  (auto = CEF under Wine).
}

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls;

type
  TLoginCookie = record
    Name:   string;
    Value:  string;
    Domain: string;
  end;
  TLoginCookies = TArray<TLoginCookie>;

  TLoginCookiesEvent = procedure(Sender: TObject; const Cookies: TLoginCookies) of object;
  TLoginNavEvent     = procedure(Sender: TObject; Success: Boolean) of object;
  TLoginTextEvent    = procedure(Sender: TObject; const Text: string) of object;

  TLoginBrowser = class(TComponent)
  protected
    FOnReady:               TNotifyEvent;
    FOnError:               TLoginTextEvent;
    FOnStatus:              TLoginTextEvent;
    FOnCookies:             TLoginCookiesEvent;
    FOnNavigationCompleted: TLoginNavEvent;
    FOnClosed:              TNotifyEvent;
    procedure DoReady;
    procedure DoError(const Msg: string);
    procedure DoStatus(const Msg: string);
    procedure DoCookies(const Cookies: TLoginCookies);
    procedure DoNavigationCompleted(Success: Boolean);
    procedure DoClosed;
  public
    // Begins (async) engine + browser creation inside Parent. Fires OnReady once
    // the browser can navigate, or OnError if the engine fails to start.
    procedure Start(Parent: TWinControl); virtual; abstract;
    procedure Navigate(const Url: string); virtual; abstract;
    procedure ExecuteScript(const Js: string); virtual; abstract;
    // Script run on every top-level document before the user interacts with it.
    procedure AddStartupScript(const Js: string); virtual; abstract;
    // Async. Fires OnCookies with every cookie (incl. HttpOnly) that applies to Url.
    procedure RequestCookies(const Url: string); virtual; abstract;
    procedure SetUserAgent(const UA: string); virtual; abstract;
    function  UserAgent: string; virtual; abstract;
    function  Source: string; virtual; abstract;
    function  Ready: Boolean; virtual; abstract;
    function  EngineName: string; virtual; abstract;
    procedure NotifyMoved; virtual;
    // True → safe to destroy now. False → async shutdown started; OnClosed fires when done.
    function  RequestClose: Boolean; virtual;

    property OnReady:               TNotifyEvent       read FOnReady               write FOnReady;
    property OnError:               TLoginTextEvent    read FOnError               write FOnError;
    property OnStatus:              TLoginTextEvent    read FOnStatus              write FOnStatus;
    property OnCookies:             TLoginCookiesEvent read FOnCookies             write FOnCookies;
    property OnNavigationCompleted: TLoginNavEvent     read FOnNavigationCompleted write FOnNavigationCompleted;
    property OnClosed:              TNotifyEvent       read FOnClosed              write FOnClosed;
  end;

  TLoginEngine = (leWebView2, leCEF);

const
  // The only VCL style that renders correctly under Wine.
  WINE_THEME = 'Windows';

function IsRunningUnderWine: Boolean;
function SelectLoginEngine: TLoginEngine;
function RuaConfigPath: string;

implementation

uses
  Winapi.Windows, System.IniFiles, System.IOUtils;

function RuaConfigPath: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Rua\config.ini');
end;

function IsRunningUnderWine: Boolean;
var
  Ntdll: HMODULE;
begin
  Ntdll  := GetModuleHandle('ntdll.dll');
  Result := (Ntdll <> 0) and (GetProcAddress(Ntdll, 'wine_get_version') <> nil);
end;

function SelectLoginEngine: TLoginEngine;
var
  INI:    TIniFile;
  Engine: string;
begin
  Engine := 'auto';
  try
    INI := TIniFile.Create(RuaConfigPath);
    try
      Engine := LowerCase(Trim(INI.ReadString('Browser', 'Engine', 'auto')));
    finally
      INI.Free;
    end;
  except
  end;
  if Engine = 'cef' then
    Result := leCEF
  else if Engine = 'webview2' then
    Result := leWebView2
  else if IsRunningUnderWine then
    Result := leCEF
  else
    Result := leWebView2;
end;

{ TLoginBrowser }

procedure TLoginBrowser.NotifyMoved;
begin
end;

function TLoginBrowser.RequestClose: Boolean;
begin
  Result := True;
end;

procedure TLoginBrowser.DoReady;
begin
  if Assigned(FOnReady) then FOnReady(Self);
end;

procedure TLoginBrowser.DoError(const Msg: string);
begin
  if Assigned(FOnError) then FOnError(Self, Msg);
end;

procedure TLoginBrowser.DoStatus(const Msg: string);
begin
  if Assigned(FOnStatus) then FOnStatus(Self, Msg);
end;

procedure TLoginBrowser.DoCookies(const Cookies: TLoginCookies);
begin
  if Assigned(FOnCookies) then FOnCookies(Self, Cookies);
end;

procedure TLoginBrowser.DoNavigationCompleted(Success: Boolean);
begin
  if Assigned(FOnNavigationCompleted) then FOnNavigationCompleted(Self, Success);
end;

procedure TLoginBrowser.DoClosed;
begin
  if Assigned(FOnClosed) then FOnClosed(Self);
end;

end.
