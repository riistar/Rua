unit uLoginBrowserCEF;
{
  Chromium Embedded (CEF4Delphi) backend for TLoginBrowser. Used under Wine/Proton,
  where WebView2 works poorly.

  Lifecycle:
    Start → (download runtime if missing) → StartCefRuntime → TChromium.CreateBrowser
          → OnAfterCreated → OnReady
  CEF runs its own UI thread (multi-threaded message loop), so every TChromium event
  arrives off the VCL thread. They are marshalled back with PostMessage to a private
  message window (PostMessage to a destroyed HWND is harmless, unlike TThread.Queue on
  a freed object).

  Close: TChromium must be closed asynchronously before the form is destroyed.
  RequestClose returns False and fires OnClosed after CEF's OnBeforeClose.
}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  Vcl.Controls, Vcl.ExtCtrls,
  uCEFChromium, uCEFWindowParent, uCEFInterfaces, uCEFTypes, uCEFChromiumEvents,
  uLoginBrowser, uCefRuntime;

type
  TLoginBrowserCEF = class(TLoginBrowser)
  private
    FParent:        TWinControl;
    FWindowParent:  TCEFWindowParent;
    FChromium:      TChromium;
    FMsgWnd:        HWND;
    FInstaller:     TCefRuntimeInstaller;
    FTimerCreate:   TTimer;
    FLock:          TCriticalSection;
    FUserAgent:     string;          // guarded by FLock (read on CEF IO thread)
    FSource:        string;          // guarded by FLock
    FScripts:       TArray<string>;  // guarded by FLock
    FCookieJobs:    TDictionary<Integer, TLoginCookies>; // guarded by FLock
    FNextCookieId:  Integer;
    FPendingNav:    string;          // Navigate() before ready
    FReady:         Boolean;
    FClosing:       Boolean;
    FClosed:        Boolean;
    FDestroying:    Boolean;
    procedure WndProc(var Msg: TMessage);
    procedure Post(Msg: UINT; WParam: WPARAM = 0; LParam: LPARAM = 0);
    procedure BeginInstall;
    procedure InstallProgress;
    procedure InstallDone;
    procedure StartBrowser;
    procedure TimerCreateTimer(Sender: TObject);
    procedure InjectScripts(const Frame: ICefFrame);
    procedure SetSourceLocked(const Url: string);
    // TChromium events (CEF UI / IO threads)
    procedure CefAfterCreated(Sender: TObject; const browser: ICefBrowser);
    procedure CefBeforeClose(Sender: TObject; const browser: ICefBrowser);
    procedure CefLoadStart(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; transitionType: TCefTransitionType);
    procedure CefLoadEnd(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; httpStatusCode: Integer);
    procedure CefLoadError(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; errorCode: TCefErrorCode; const errorText, failedUrl: ustring);
    procedure CefAddressChange(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const url: ustring);
    procedure CefBeforeResourceLoad(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const request: ICefRequest; const callback: ICefCallback;
      out Result: TCefReturnValue);
    procedure CefBeforePopup(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; popup_id: Integer; const targetUrl, targetFrameName: ustring;
      targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
      const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
      var client: ICefClient; var settings: TCefBrowserSettings;
      var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
      var Result: Boolean);
    procedure CefCookiesVisited(Sender: TObject; const name_, value, domain, path: ustring;
      secure, httponly, hasExpires: Boolean; const creation, lastAccess, expires: TDateTime;
      count, total, aID: Integer; same_site: TCefCookieSameSite;
      priority: TCefCookiePriority; var aDeleteCookie, aResult: Boolean);
    procedure CefCookieVisitorDestroyed(Sender: TObject; aID: Integer);
  public
    constructor Create(AOwner: TComponent); override;
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
    function  RequestClose: Boolean; override;
  end;

implementation

uses
  uCEFConstants;

const
  WM_LB_CREATED   = WM_APP + $C20;
  WM_LB_CLOSED    = WM_APP + $C21;
  WM_LB_NAVDONE   = WM_APP + $C22; // WParam = success
  WM_LB_COOKIES   = WM_APP + $C23; // WParam = job id
  WM_LB_LOADERR   = WM_APP + $C24;

{ TLoginBrowserCEF }

constructor TLoginBrowserCEF.Create(AOwner: TComponent);
begin
  inherited;
  FLock       := TCriticalSection.Create;
  FCookieJobs := TDictionary<Integer, TLoginCookies>.Create;
  FMsgWnd     := AllocateHWnd(WndProc);
end;

destructor TLoginBrowserCEF.Destroy;
begin
  FDestroying := True;
  if Assigned(FTimerCreate) then FTimerCreate.Enabled := False;
  if Assigned(FInstaller) then
  begin
    FInstaller.Terminate;
    FInstaller.WaitFor;
    FreeAndNil(FInstaller);
  end;
  // Owner should have completed RequestClose; force-close as a last resort.
  if Assigned(FChromium) and not FClosed and FChromium.Initialized then
    FChromium.CloseBrowser(True);
  DeallocateHWnd(FMsgWnd);
  FMsgWnd := 0;
  inherited; // frees owned components (FChromium, FWindowParent, FTimerCreate)
  FCookieJobs.Free;
  FLock.Free;
end;

procedure TLoginBrowserCEF.Post(Msg: UINT; WParam: WPARAM; LParam: LPARAM);
begin
  if FMsgWnd <> 0 then
    PostMessage(FMsgWnd, Msg, WParam, LParam);
end;

procedure TLoginBrowserCEF.WndProc(var Msg: TMessage);
var
  Cookies: TLoginCookies;
  Found:   Boolean;
begin
  if FDestroying then
  begin
    Msg.Result := DefWindowProc(FMsgWnd, Msg.Msg, Msg.WParam, Msg.LParam);
    Exit;
  end;
  case Msg.Msg of
    WM_CEFRT_PROGRESS: InstallProgress;
    WM_CEFRT_DONE:     InstallDone;
    WM_LB_CREATED:
      begin
        FReady := True;
        if Assigned(FWindowParent) then FWindowParent.UpdateSize;
        if UserAgent <> '' then FChromium.SetUserAgentOverride(UserAgent);
        DoReady;
        if FPendingNav <> '' then
        begin
          Navigate(FPendingNav);
          FPendingNav := '';
        end;
      end;
    WM_LB_CLOSED:
      begin
        FClosed := True;
        FReady  := False;
        DoClosed;
      end;
    WM_LB_NAVDONE:
      if not FClosing then DoNavigationCompleted(Msg.WParam <> 0);
    WM_LB_COOKIES:
      begin
        FLock.Enter;
        try
          Found := FCookieJobs.TryGetValue(Integer(Msg.WParam), Cookies);
          if Found then FCookieJobs.Remove(Integer(Msg.WParam));
        finally
          FLock.Leave;
        end;
        if Found and not FClosing then DoCookies(Cookies);
      end;
  else
    Msg.Result := DefWindowProc(FMsgWnd, Msg.Msg, Msg.WParam, Msg.LParam);
  end;
end;

{ ---- startup ---- }

procedure TLoginBrowserCEF.Start(Parent: TWinControl);
begin
  FParent := Parent;
  if CefRuntimeInstalled or CefRuntimeStarted then
    StartBrowser
  else
    BeginInstall;
end;

procedure TLoginBrowserCEF.BeginInstall;
begin
  DoStatus('Downloading Chromium runtime...');
  FInstaller := TCefRuntimeInstaller.Create(FMsgWnd);
end;

procedure TLoginBrowserCEF.InstallProgress;
begin
  if not Assigned(FInstaller) then Exit;
  if FInstaller.Total > 0 then
    DoStatus(Format('Downloading Chromium runtime... %d / %d MB (%d%%)',
      [FInstaller.Received div (1024 * 1024), FInstaller.Total div (1024 * 1024),
       FInstaller.Received * 100 div FInstaller.Total]))
  else
    DoStatus(Format('Downloading Chromium runtime... %d MB',
      [FInstaller.Received div (1024 * 1024)]));
end;

procedure TLoginBrowserCEF.InstallDone;
var
  Err: string;
begin
  if not Assigned(FInstaller) then Exit;
  FInstaller.WaitFor;
  Err := FInstaller.Error;
  FreeAndNil(FInstaller);
  if FClosing then
  begin
    FClosed := True;
    DoClosed;
    Exit;
  end;
  if Err <> '' then
  begin
    DoError('Chromium runtime download failed: ' + Err);
    Exit;
  end;
  DoStatus('Starting Chromium...');
  StartBrowser;
end;

procedure TLoginBrowserCEF.StartBrowser;
var
  Err: string;
begin
  if not StartCefRuntime(Err) then
  begin
    DoError('Chromium failed to start: ' + Err);
    Exit;
  end;

  FWindowParent        := TCEFWindowParent.Create(Self);
  FWindowParent.Parent := FParent;
  FWindowParent.Align  := alClient;

  FChromium := TChromium.Create(Self);
  FChromium.RuntimeStyle            := CEF_RUNTIME_STYLE_ALLOY;
  FChromium.OnAfterCreated          := CefAfterCreated;
  FChromium.OnBeforeClose           := CefBeforeClose;
  FChromium.OnLoadStart             := CefLoadStart;
  FChromium.OnLoadEnd               := CefLoadEnd;
  FChromium.OnLoadError             := CefLoadError;
  FChromium.OnAddressChange         := CefAddressChange;
  FChromium.OnBeforeResourceLoad    := CefBeforeResourceLoad;
  FChromium.OnBeforePopup           := CefBeforePopup;
  FChromium.OnCookiesVisited        := CefCookiesVisited;
  FChromium.OnCookieVisitorDestroyed := CefCookieVisitorDestroyed;

  FTimerCreate          := TTimer.Create(Self);
  FTimerCreate.Enabled  := False;
  FTimerCreate.Interval := 250;
  FTimerCreate.OnTimer  := TimerCreateTimer;

  // CreateBrowser fails until CEF's global context is initialized; retry on a timer.
  if not FChromium.CreateBrowser(FWindowParent) then
    FTimerCreate.Enabled := True;
end;

procedure TLoginBrowserCEF.TimerCreateTimer(Sender: TObject);
begin
  FTimerCreate.Enabled := False;
  if FDestroying or FClosing then Exit;
  if not FChromium.Initialized and not FChromium.CreateBrowser(FWindowParent) then
    FTimerCreate.Enabled := True;
end;

{ ---- CEF events (non-VCL threads) ---- }

procedure TLoginBrowserCEF.CefAfterCreated(Sender: TObject; const browser: ICefBrowser);
begin
  Post(WM_LB_CREATED);
end;

procedure TLoginBrowserCEF.CefBeforeClose(Sender: TObject; const browser: ICefBrowser);
begin
  Post(WM_LB_CLOSED);
end;

procedure TLoginBrowserCEF.SetSourceLocked(const Url: string);
begin
  FLock.Enter;
  try
    FSource := Url;
  finally
    FLock.Leave;
  end;
end;

procedure TLoginBrowserCEF.InjectScripts(const Frame: ICefFrame);
var
  Scripts: TArray<string>;
  I:       Integer;
begin
  FLock.Enter;
  try
    Scripts := Copy(FScripts);
  finally
    FLock.Leave;
  end;
  // CEF has no "run on document created" API from the browser process; run at load
  // start and again at load end, guarded so each script runs once per document.
  for I := 0 to High(Scripts) do
    Frame.ExecuteJavaScript(
      Format('if(!window.__ruaInit%d){window.__ruaInit%0:d=1;%s}', [I, Scripts[I]]),
      Frame.GetUrl, 0);
end;

procedure TLoginBrowserCEF.CefLoadStart(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; transitionType: TCefTransitionType);
begin
  if (frame <> nil) and frame.IsMain then
  begin
    SetSourceLocked(frame.GetUrl);
    InjectScripts(frame);
  end;
end;

procedure TLoginBrowserCEF.CefLoadEnd(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; httpStatusCode: Integer);
begin
  if (frame <> nil) and frame.IsMain then
  begin
    SetSourceLocked(frame.GetUrl);
    InjectScripts(frame);
    Post(WM_LB_NAVDONE, Ord((httpStatusCode = 0) or (httpStatusCode < 400)));
  end;
end;

procedure TLoginBrowserCEF.CefLoadError(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; errorCode: TCefErrorCode; const errorText, failedUrl: ustring);
begin
  // ERR_ABORTED (-3) = navigation superseded by another; not a failure.
  if (frame <> nil) and frame.IsMain and (errorCode <> ERR_ABORTED) then
    Post(WM_LB_NAVDONE, 0);
end;

procedure TLoginBrowserCEF.CefAddressChange(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; const url: ustring);
begin
  if (frame <> nil) and frame.IsMain then
    SetSourceLocked(url);
end;

procedure TLoginBrowserCEF.CefBeforeResourceLoad(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; const request: ICefRequest; const callback: ICefCallback;
  out Result: TCefReturnValue);
var
  UA: string;
begin
  Result := RV_CONTINUE;
  FLock.Enter;
  try
    UA := FUserAgent;
  finally
    FLock.Leave;
  end;
  // DevTools UA emulation covers navigator.userAgent; the header needs setting here
  // for requests CEF issues before emulation applies (e.g. first navigation).
  if (UA <> '') and (request <> nil) then
    request.SetHeaderByName('User-Agent', UA, True);
end;

procedure TLoginBrowserCEF.CefBeforePopup(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; popup_id: Integer; const targetUrl, targetFrameName: ustring;
  targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
  const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
  var client: ICefClient; var settings: TCefBrowserSettings;
  var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
  var Result: Boolean);
begin
  // window.open() popups (OAuth/SSO) keep opener semantics → allow as native popup.
  // target=_blank tabs/windows → load in the login view instead (like WebView2 does
  // in-place for our flows) so cookies stay observable.
  if targetDisposition = CEF_WOD_NEW_POPUP then
    Result := False
  else
  begin
    Result := True;
    if (frame <> nil) and (targetUrl <> '') then
      frame.LoadUrl(targetUrl);
  end;
end;

procedure TLoginBrowserCEF.CefCookiesVisited(Sender: TObject;
  const name_, value, domain, path: ustring; secure, httponly, hasExpires: Boolean;
  const creation, lastAccess, expires: TDateTime; count, total, aID: Integer;
  same_site: TCefCookieSameSite; priority: TCefCookiePriority;
  var aDeleteCookie, aResult: Boolean);
var
  List: TLoginCookies;
  C:    TLoginCookie;
begin
  aDeleteCookie := False;
  aResult       := True;
  C.Name   := name_;
  C.Value  := value;
  C.Domain := domain;
  FLock.Enter;
  try
    if FCookieJobs.TryGetValue(aID, List) then
    begin
      List := List + [C];
      FCookieJobs[aID] := List;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLoginBrowserCEF.CefCookieVisitorDestroyed(Sender: TObject; aID: Integer);
begin
  // Fires after the last cookie (or immediately when there are none).
  Post(WM_LB_COOKIES, WPARAM(aID));
end;

{ ---- public API (VCL thread) ---- }

procedure TLoginBrowserCEF.Navigate(const Url: string);
begin
  if not FReady then
  begin
    FPendingNav := Url;
    Exit;
  end;
  SetSourceLocked(Url);
  FChromium.LoadURL(Url);
end;

procedure TLoginBrowserCEF.ExecuteScript(const Js: string);
begin
  if FReady then
    FChromium.ExecuteJavaScript(Js, 'about:blank');
end;

procedure TLoginBrowserCEF.AddStartupScript(const Js: string);
begin
  FLock.Enter;
  try
    FScripts := FScripts + [Js];
  finally
    FLock.Leave;
  end;
end;

procedure TLoginBrowserCEF.RequestCookies(const Url: string);
var
  Id: Integer;
begin
  if not FReady or FClosing then Exit;
  Inc(FNextCookieId);
  Id := FNextCookieId;
  FLock.Enter;
  try
    FCookieJobs.AddOrSetValue(Id, nil);
  finally
    FLock.Leave;
  end;
  if not FChromium.VisitURLCookies(Url, True, Id) then
  begin
    FLock.Enter;
    try
      FCookieJobs.Remove(Id);
    finally
      FLock.Leave;
    end;
  end;
end;

procedure TLoginBrowserCEF.SetUserAgent(const UA: string);
begin
  FLock.Enter;
  try
    FUserAgent := UA;
  finally
    FLock.Leave;
  end;
  if FReady then
    FChromium.SetUserAgentOverride(UA);
end;

function TLoginBrowserCEF.UserAgent: string;
begin
  FLock.Enter;
  try
    Result := FUserAgent;
  finally
    FLock.Leave;
  end;
end;

function TLoginBrowserCEF.Source: string;
begin
  FLock.Enter;
  try
    Result := FSource;
  finally
    FLock.Leave;
  end;
end;

function TLoginBrowserCEF.Ready: Boolean;
begin
  Result := FReady and not FClosing;
end;

function TLoginBrowserCEF.EngineName: string;
begin
  Result := 'Chromium (CEF)';
end;

procedure TLoginBrowserCEF.NotifyMoved;
begin
  if FReady then
    FChromium.NotifyMoveOrResizeStarted;
end;

function TLoginBrowserCEF.RequestClose: Boolean;
begin
  if FClosed then Exit(True);
  if FClosing then Exit(False);

  if Assigned(FInstaller) then
  begin
    // Cancel download; InstallDone fires OnClosed.
    FClosing := True;
    FInstaller.Terminate;
    Exit(False);
  end;

  if not (Assigned(FChromium) and FChromium.Initialized) then
  begin
    if Assigned(FTimerCreate) then FTimerCreate.Enabled := False;
    FClosed := True;
    Exit(True);
  end;

  FClosing := True;
  FChromium.CloseBrowser(True);
  // Destroying the parent window lets CEF finish closing (CEF4Delphi demo pattern).
  FreeAndNil(FWindowParent);
  Result := False;
end;

end.
