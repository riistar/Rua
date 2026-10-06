unit uLoginBrowserWV;
{
  WebView2 (Edge) backend for TLoginBrowser, via WebView4Delphi.
  Session data persists across launches in %APPDATA%\Rua\WebView2.
}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.ExtCtrls,
  uWVBrowser, uWVWindowParent, uWVLoader,
  uWVTypes, uWVInterfaces, uWVTypeLibrary,
  uLoginBrowser;

type
  TLoginBrowserWV = class(TLoginBrowser)
  private
    FBrowser:      TWVBrowser;
    FWindowParent: TWVWindowParent;
    FTimerInit:    TTimer;
    FDestroying:   Boolean;
    procedure TimerInitTimer(Sender: TObject);
    procedure WVAfterCreated(Sender: TObject);
    procedure WVGetCookiesCompleted(Sender: TObject; aResult: HRESULT;
      const aCookieList: ICoreWebView2CookieList);
    procedure WVNavigationCompleted(Sender: TObject; const aWebView: ICoreWebView2;
      const aArgs: ICoreWebView2NavigationCompletedEventArgs);
    procedure WVNavigationStarting(Sender: TObject; const aWebView: ICoreWebView2;
      const aArgs: ICoreWebView2NavigationStartingEventArgs);
    procedure WVInitializationError(Sender: TObject; aErrorCode: HRESULT;
      const aErrorMessage: wvstring);
    function  TryCreateBrowser: Boolean;
  public
    destructor Destroy; override;
    procedure Start(Parent: TWinControl); override;
    procedure Navigate(const Url: string); override;
    procedure ExecuteScript(const Js: string); override;
    procedure AddStartupScript(const Js: string); override;
    procedure RequestCookies(const Url: string); override;
    procedure SetUserAgent(const UA: string); override;
    function  UserAgent: string; override;
    function  Source: string; override;
    function  Ready: Boolean; override;
    function  EngineName: string; override;
    procedure NotifyMoved; override;
  end;

implementation

uses
  Winapi.ActiveX,
  uWVCoreWebView2CookieList, uWVCoreWebView2Cookie;

destructor TLoginBrowserWV.Destroy;
begin
  FDestroying := True; // guard all async WebView2 callbacks
  if Assigned(FTimerInit) then FTimerInit.Enabled := False;
  inherited;
end;

procedure TLoginBrowserWV.Start(Parent: TWinControl);
begin
  // Initialize WebView2 loader on first use (lazy so startup is unaffected).
  if not Assigned(GlobalWebView2Loader) then
  begin
    GlobalWebView2Loader := TWVLoader.Create(nil);
    GlobalWebView2Loader.UserDataFolder :=
      GetEnvironmentVariable('APPDATA') + '\Rua\WebView2';
    GlobalWebView2Loader.StartWebView2;
  end;

  // TWVWindowParent hosts the WebView2 child window.
  FWindowParent        := TWVWindowParent.Create(Self);
  FWindowParent.Parent := Parent;
  FWindowParent.Align  := alClient;

  FBrowser := TWVBrowser.Create(Self);
  FBrowser.OnAfterCreated        := WVAfterCreated;
  FBrowser.OnGetCookiesCompleted := WVGetCookiesCompleted;
  FBrowser.OnNavigationCompleted := WVNavigationCompleted;
  FBrowser.OnNavigationStarting  := WVNavigationStarting;
  FBrowser.OnInitializationError := WVInitializationError;
  FWindowParent.Browser := FBrowser;

  FTimerInit          := TTimer.Create(Self);
  FTimerInit.Enabled  := False;
  FTimerInit.Interval := 250;
  FTimerInit.OnTimer  := TimerInitTimer;

  if not TryCreateBrowser then
    FTimerInit.Enabled := True;
end;

// Returns True when polling can stop (browser created or fatal error reported).
function TLoginBrowserWV.TryCreateBrowser: Boolean;
begin
  Result := True;
  if GlobalWebView2Loader.InitializationError then
    DoError('WebView2 error: ' + GlobalWebView2Loader.ErrorMessage)
  else if GlobalWebView2Loader.Initialized then
    FBrowser.CreateBrowser(FWindowParent.Handle)
  else
    Result := False; // Edge runtime still starting
end;

procedure TLoginBrowserWV.TimerInitTimer(Sender: TObject);
begin
  FTimerInit.Enabled := False;
  if FDestroying then Exit;
  if not TryCreateBrowser then
    FTimerInit.Enabled := True;
end;

procedure TLoginBrowserWV.WVAfterCreated(Sender: TObject);
begin
  if FDestroying then Exit;
  // This window only signs in to Nexon: no developer tools (which could read
  // the session), no default context menu, no status-bar link previews.
  FBrowser.DevToolsEnabled            := False;
  FBrowser.DefaultContextMenusEnabled := False;
  FBrowser.StatusBarEnabled           := False;
  FWindowParent.UpdateSize;
  DoReady;
end;

// Sign-in pages load only over HTTPS. A host allowlist is deliberately not
// applied: Nexon's Google/Apple/social sign-in and captcha flows redirect
// through other providers, and blocking them would break sign-in and 2FA.
procedure TLoginBrowserWV.WVNavigationStarting(Sender: TObject;
  const aWebView: ICoreWebView2; const aArgs: ICoreWebView2NavigationStartingEventArgs);
var
  P:   PWideChar;
  Uri: string;
begin
  if FDestroying or (aArgs = nil) then Exit;
  P := nil;
  if (aArgs.Get_uri(P) <> S_OK) or (P = nil) then Exit;
  try
    Uri := P;
  finally
    CoTaskMemFree(P);
  end;
  if not (Uri.StartsWith('https://', True) or SameText(Uri, 'about:blank')) then
    aArgs.Set_Cancel(1);
end;

procedure TLoginBrowserWV.WVInitializationError(Sender: TObject;
  aErrorCode: HRESULT; const aErrorMessage: wvstring);
begin
  if FDestroying then Exit;
  FTimerInit.Enabled := False;
  DoError('WebView2 error: ' + aErrorMessage);
end;

procedure TLoginBrowserWV.WVNavigationCompleted(Sender: TObject;
  const aWebView: ICoreWebView2; const aArgs: ICoreWebView2NavigationCompletedEventArgs);
var
  IsSuccessInt: Integer;
begin
  if FDestroying or (aArgs = nil) then Exit;
  if aArgs.Get_IsSuccess(IsSuccessInt) <> S_OK then Exit;
  DoNavigationCompleted(IsSuccessInt <> 0);
end;

procedure TLoginBrowserWV.WVGetCookiesCompleted(Sender: TObject;
  aResult: HRESULT; const aCookieList: ICoreWebView2CookieList);
var
  CookieList: TCoreWebView2CookieList;
  Cookie:     TCoreWebView2Cookie;
  Cookies:    TLoginCookies;
  I:          Cardinal;
begin
  if FDestroying then Exit;
  if (aResult <> S_OK) or (aCookieList = nil) then Exit;

  CookieList := TCoreWebView2CookieList.Create(aCookieList);
  Cookie     := TCoreWebView2Cookie.Create(nil);
  try
    SetLength(Cookies, CookieList.Count);
    I := 0;
    while I < CookieList.Count do
    begin
      Cookie.BaseIntf    := CookieList.Items[I];
      Cookies[I].Name    := Cookie.Name;
      Cookies[I].Value   := Cookie.Value;
      Cookies[I].Domain  := Cookie.Domain;
      Inc(I);
    end;
  finally
    FreeAndNil(Cookie);
    FreeAndNil(CookieList);
  end;
  DoCookies(Cookies);
end;

procedure TLoginBrowserWV.Navigate(const Url: string);
begin
  FBrowser.Navigate(Url);
end;

procedure TLoginBrowserWV.ExecuteScript(const Js: string);
begin
  FBrowser.ExecuteScript(Js);
end;

procedure TLoginBrowserWV.AddStartupScript(const Js: string);
begin
  FBrowser.AddScriptToExecuteOnDocumentCreated(Js);
end;

procedure TLoginBrowserWV.RequestCookies(const Url: string);
begin
  FBrowser.GetCookies(Url);
end;

procedure TLoginBrowserWV.SetUserAgent(const UA: string);
begin
  FBrowser.UserAgent := UA;
end;

function TLoginBrowserWV.UserAgent: string;
begin
  Result := FBrowser.UserAgent;
end;

function TLoginBrowserWV.Source: string;
begin
  Result := FBrowser.Source;
end;

function TLoginBrowserWV.Ready: Boolean;
begin
  Result := Assigned(FBrowser) and FBrowser.Initialized;
end;

function TLoginBrowserWV.EngineName: string;
begin
  Result := 'WebView2';
end;

// Keep WebView2 rendering in sync with window position.
procedure TLoginBrowserWV.NotifyMoved;
begin
  if Assigned(FBrowser) then
    FBrowser.NotifyParentWindowPositionChanged;
end;

end.
