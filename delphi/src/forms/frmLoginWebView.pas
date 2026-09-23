unit frmLoginWebView;
{
  Embedded WebView2 (Edge) browser for Nexon login.
  Navigates to nexon.com login. Polls for TpaSession / NxLSession every 1.5s.
  When either appears, exchanges / returns the session cookies and closes.
  Session data persists across launches in %APPDATA%\Rua\WebView2.
}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.IOUtils,
  Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls, Vcl.StdCtrls,
  uWVBrowser, uWVWindowParent, uWVLoader,
  uWVTypes, uWVInterfaces, uWVTypeLibrary;

type
  TFormLoginWebView = class(TForm)
    PnlStatus:    TPanel;
    LblStatus:    TLabel;
    BtnCancel:    TButton;
    PnlUrl:       TPanel;
    LblUrl:       TLabel;
    PnlBrowser:   TPanel;
    TimerInit:    TTimer;
    TimerCookies: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure TimerInitTimer(Sender: TObject);
    procedure TimerCookiesTimer(Sender: TObject);
  private
    FWVBrowser:      TWVBrowser;
    FWVWindowParent: TWVWindowParent;
    FCookies:        string;
    FProfileName:    string;
    FForceRelogin:   Boolean; // True → skip cached session, navigate to login page immediately
    FDestroying:       Boolean;
    FExchanging:       Boolean;
    FSilentChecked:    Boolean; // True after initial cookie check before navigating to login page
    FPostLoginCapture: Boolean; // True when GetCookies was triggered by post-login navigation
    FPostLoginNavCount: Integer; // Count of post-login navigations to launcher pages (avoids redirect loops)
    FExchangeFailed:     Boolean; // True when TPA exchange failed — skip re-exchange, use NxLSession fast path
    FFailedTpa:          string;  // TpaSession value that failed to exchange (reset when a new TpaSession appears)
    FAltCookieUri:     Boolean; // Alternates between www.nexon.com and nxl.nxfs.nexon.com for GetCookies
    FClosePending:     Integer; // Countdown: NxLSession found, wait N more polls for cookies to stabilize before closing
    FChoicePanel:      TPanel;  // Login method chooser (Nexon Account vs SSO)
    FOldTpaSession:    string;  // TpaSession value found in WebView2 cache at startup (stale — do not re-exchange)
    procedure WVAfterCreated(Sender: TObject);
    procedure WVGetCookiesCompleted(Sender: TObject; aResult: HRESULT;
      const aCookieList: ICoreWebView2CookieList);
    procedure WVNavigationCompleted(Sender: TObject; const aWebView: ICoreWebView2;
      const aArgs: ICoreWebView2NavigationCompletedEventArgs);
    procedure WVInitializationError(Sender: TObject; aErrorCode: HRESULT;
      const aErrorMessage: wvstring);
    procedure BtnLoginChoiceClick(Sender: TObject);

  protected
    procedure WMMove(var Msg: TWMMove); message WM_MOVE;
    procedure WMMoving(var Msg: TMessage); message WM_MOVING;
  public
    class function Execute(out Cookies: string; const ProfileName: string = ''; ForceRelogin: Boolean = False): Boolean;
    property CapturedCookies: string read FCookies;
  end;

var
  FormLoginWebView: TFormLoginWebView;

implementation

{$R *.dfm}

uses
  System.StrUtils,
  uWVCoreWebView2CookieList, uWVCoreWebView2Cookie,
  uNexonAPI, uDeviceId, uBrowserCookies;

const
  // Login page — nexon.com account login. After email/password login the page
  // redirects to main nexon.com. At that point the arenaSid handler navigates to
  // nxl.nxfs.nexon.com/nxl/main to trigger launcher JS and upgrade token scope.
  NEXON_URL = 'https://www.nexon.com/account/en/login'
           + '?autologin=false'
           + '&return_url=https%3A%2F%2Fnxl.nxfs.nexon.com%2F';

  // Launcher main page — after login the launcher JS redirects here.
  NXL_MAIN  = 'https://nxl.nxfs.nexon.com/nxl/main?index_tag=live';

  // NexonLauncher UA — set globally on the WebView2. Required for launcher API to
  // return proper session tokens. Google SSO works with this UA (official launcher).
  NXL_UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
         + '(KHTML, like Gecko) NexonLauncher/4.7.9 Chrome/108.0.5359.215 '
         + 'Electron/22.3.27 Safari/537.36';

  // Maximum consecutive navigations to launcher main page without getting session.
  // Prevents infinite redirect loop if the page doesn't set cookies.
  MAX_MAIN_NAV = 3;

  // Injected before any page script via AddScriptToExecuteOnDocumentCreated.
  // Wraps fetch + XHR to intercept launcher auth responses. If the page calls
  // a launcher endpoint that returns NxLSession in its JSON body, the interceptor
  // writes it to document.cookie so GetCookies picks it up on the next poll.
  INTERCEPT_JS =
    '(function(){' +
    // Inject arenaSid if missing (required by launcher/email/login API).
    // The official launcher's nxl redirector sets this via arena-sid.js.
    // Without it, the login API returns a web-only session (no NxLSession).
    'if(!document.cookie.match(/(^| )arenaSid=/)){' +
    'var u=function(){return Math.floor(65536*(1+Math.random())).toString(16).slice(1);};' +
    'document.cookie="arenaSid="+(u()+u()+"-"+u()+"-4"+u().slice(0,3)+"-"+((8+3*Math.random())|0).toString(16)+u().slice(0,3)+"-"+u()+u()+u())+"; path=/; domain=.nexon.com";}' +
    // Intercept fetch/XHR to launcher auth endpoints. If response JSON
    // contains session tokens, write them as cookies for GetCookies to find.
    'function cap(u,t){try{var d=JSON.parse(t);' +
    'var nxl=d.nxLSession||d.NxLSession||"";' +
    'var at=d.aToken||d.AToken||"";' +
    'var ng=d.nxGUN||d.NxGUN||"";' +
    'if(nxl){document.cookie="NxLSession="+nxl+"; path=/; domain=.nexon.com";' +
    'if(at)document.cookie="AToken="+at+"; path=/; domain=.nexon.com";' +
    'if(ng)document.cookie="NxGUN="+ng+"; path=/; domain=.nexon.com";}' +
    'if(!nxl&&at){document.cookie="AToken="+at+"; path=/; domain=.nexon.com";}}' +
    '}catch(e){}}' +
    'function want(u){return u&&(' +
    'u.indexOf("no-auth/login")>=0||' +
    'u.indexOf("regional-auth")>=0||' +
    'u.indexOf("passport")>=0);}' +
    'var of_=window.fetch;' +
    'if(of_){window.fetch=function(url,opts){' +
    'var u=typeof url==="string"?url:(url&&url.href?url.href:"");' +
    'var p=of_.call(this,url,opts);' +
    'if(want(u))p.then(function(r){r.clone().text().then(function(t){cap(u,t);});});' +
    'return p;};}' +
    'var oo=XMLHttpRequest.prototype.open;' +
    'var os=XMLHttpRequest.prototype.send;' +
    'XMLHttpRequest.prototype.open=function(m,u){this.__u=u;return oo.apply(this,arguments);};' +
    'XMLHttpRequest.prototype.send=function(){' +
    'if(want(this.__u)){var x=this,u=this.__u;' +
    'x.addEventListener("loadend",function(){cap(u,x.responseText);});}' +
    'return os.apply(this,arguments);};' +
    '})()';

{ ------------------------------------------------------------------ }

class function TFormLoginWebView.Execute(out Cookies: string;
  const ProfileName: string; ForceRelogin: Boolean): Boolean;
var
  F: TFormLoginWebView;
begin
  // Initialize WebView2 loader on first use (lazy so startup is unaffected).
  if not Assigned(GlobalWebView2Loader) then
  begin
    GlobalWebView2Loader := TWVLoader.Create(nil);
    GlobalWebView2Loader.UserDataFolder :=
      GetEnvironmentVariable('APPDATA') + '\Rua\WebView2';
    GlobalWebView2Loader.StartWebView2;
  end;

  F := TFormLoginWebView.Create(nil);
  try
    F.FProfileName  := ProfileName;
    F.FForceRelogin := ForceRelogin;
    Result := F.ShowModal = mrOK;
    if Result then Cookies := F.FCookies;
  finally
    F.Free;
  end;
end;

{ ------------------------------------------------------------------ }

procedure TFormLoginWebView.FormCreate(Sender: TObject);
begin
  // TWVWindowParent hosts the WebView2 child window.
  FWVWindowParent := TWVWindowParent.Create(Self);
  FWVWindowParent.Parent := PnlBrowser;
  FWVWindowParent.Align  := alClient;

  // Login method choice panel
  FChoicePanel := TPanel.Create(Self);
  FChoicePanel.Parent := PnlBrowser;
  FChoicePanel.Align  := alClient;
  FChoicePanel.BevelOuter := bvNone;
  var LblPrompt := TLabel.Create(Self);
  LblPrompt.Parent := FChoicePanel;
  LblPrompt.Align := alTop;
  LblPrompt.Height := 80;
  LblPrompt.Caption := 'Choose login method:';
  LblPrompt.Font.Size := 14;
  LblPrompt.Alignment := taCenter;
  LblPrompt.Layout := tlCenter;
  var BtnNexon := TButton.Create(Self);
  BtnNexon.Parent := FChoicePanel;
  BtnNexon.Caption := 'Nexon Account (Email/Password)';
  BtnNexon.SetBounds((900 - 300) div 2, 200, 300, 50);
  BtnNexon.Font.Size := 12;
  BtnNexon.Tag := 0;
  BtnNexon.OnClick := BtnLoginChoiceClick;
  var BtnSSO := TButton.Create(Self);
  BtnSSO.Parent := FChoicePanel;
  BtnSSO.Caption := 'SSO (Google / Facebook / Apple / X)';
  BtnSSO.SetBounds((900 - 300) div 2, 270, 300, 50);
  BtnSSO.Font.Size := 12;
  BtnSSO.Tag := 1;
  BtnSSO.OnClick := BtnLoginChoiceClick;

  FWVBrowser := TWVBrowser.Create(Self);
  FWVBrowser.OnAfterCreated          := WVAfterCreated;
  FWVBrowser.OnGetCookiesCompleted   := WVGetCookiesCompleted;
  FWVBrowser.OnNavigationCompleted   := WVNavigationCompleted;
  FWVBrowser.OnInitializationError   := WVInitializationError;

  // Link browser to window parent so it knows where to render.
  FWVWindowParent.Browser := FWVBrowser;
end;

procedure TFormLoginWebView.FormDestroy(Sender: TObject);
begin
  FDestroying          := True; // guard all async WebView2 callbacks
  TimerCookies.Enabled := False;
  TimerInit.Enabled    := False;
  // FWVBrowser and FWVWindowParent owned by Self — VCL destructor handles cleanup.
end;

procedure TFormLoginWebView.FormShow(Sender: TObject);
begin
  if not Assigned(GlobalWebView2Loader) then
  begin
    LblStatus.Caption := 'WebView2 loader not initialized.';
    Exit;
  end;
  if GlobalWebView2Loader.InitializationError then
  begin
    LblStatus.Caption := 'WebView2 error: ' + GlobalWebView2Loader.ErrorMessage;
    Exit;
  end;
  if GlobalWebView2Loader.Initialized then
  begin
    FWVBrowser.CreateBrowser(FWVWindowParent.Handle);
end
  else
    TimerInit.Enabled := True;
end;

{ ------------------------------------------------------------------ }
{  Initialization polling (waits for Edge runtime to be ready)       }
{ ------------------------------------------------------------------ }

procedure TFormLoginWebView.TimerInitTimer(Sender: TObject);
begin
  TimerInit.Enabled := False;
  if FDestroying or not Assigned(GlobalWebView2Loader) then Exit;
  if GlobalWebView2Loader.InitializationError then
  begin
    LblStatus.Caption := 'WebView2 error: ' + GlobalWebView2Loader.ErrorMessage;
    Exit;
  end;
  if GlobalWebView2Loader.Initialized then
  begin
    FWVBrowser.CreateBrowser(FWVWindowParent.Handle);
end
  else
    TimerInit.Enabled := True;
end;

{ ------------------------------------------------------------------ }
{  Browser lifecycle                                                  }
{ ------------------------------------------------------------------ }

procedure TFormLoginWebView.WVAfterCreated(Sender: TObject);
begin
  FWVWindowParent.UpdateSize;

    // Inject interceptor before any page scripts run.
  FWVBrowser.AddScriptToExecuteOnDocumentCreated(INTERCEPT_JS);

  // Show the login method choice panel. User picks Nexon Account or SSO,
  // then navigation happens with the appropriate User-Agent.
  LblStatus.Caption := 'Choose login method:';
  FChoicePanel.Show;
  FChoicePanel.BringToFront;



  // Check both www.nexon.com and nxl.nxfs.nexon.com URIs for existing session cookies.
  // Session cookies may be host-only for either domain depending on Set-Cookie domain attr.
  FWVBrowser.GetCookies('https://www.nexon.com');
end;

// Fires when any top-level navigation completes.
// - nxl.nxfs.nexon.com/nxl/login or nexon.com/account/en/login = login page — ignore.
// - nxl.nxfs.nexon.com/nxl/main = post-login success — grab cookies.
// - Any other nexon/nxfs page = potential post-login redirect — grab cookies.
// Trigger GetCookies immediately to capture NxLSession without waiting for the timer.
procedure TFormLoginWebView.WVNavigationCompleted(Sender: TObject;
  const aWebView: ICoreWebView2; const aArgs: ICoreWebView2NavigationCompletedEventArgs);
var
  IsSuccessInt: Integer;
  Src:          wvstring;
  SrcLower:     string;
begin
  if FDestroying then Exit;
  if FExchanging then Exit;
  if not FSilentChecked then Exit; // still in initial check phase
  if aArgs = nil then Exit;
  if aArgs.Get_IsSuccess(IsSuccessInt) <> S_OK then Exit;
  if IsSuccessInt = 0 then Exit;
  Src := FWVBrowser.Source;
  SrcLower := LowerCase(Src);
  LblUrl.Caption := Src;

  // Log all navigation URLs for debugging redirect issues.
  try
    TFile.AppendAllText(
      GetEnvironmentVariable('TEMP') + '\nxl_nav_log.txt',
      FormatDateTime('[hh:nn:ss.zzz] ', Now) + Src + sLineBreak,
      TEncoding.UTF8);
  except end;



  // Login pages — hide irrelevant sections based on chosen login method.
  if (Pos('/nxl/login', SrcLower) > 0) or (Pos('/account/en/login', SrcLower) > 0) then
  begin
    if FWVBrowser.UserAgent = NXL_UA then
      // Nexon Account: hide SSO buttons
      FWVBrowser.ExecuteScript(
        'try{var e=document.querySelector(''.third-party-container'');'+
        'if(e)e.style.display=''none'';}catch(ex){}')
    else
      // SSO: hide email/password form
      FWVBrowser.ExecuteScript(
        'try{var e=document.querySelector(''.input-container'');'+
        'if(e)e.style.display=''none'';}catch(ex){}');
    Exit;
  end;

  // Trigger GetCookies on post-login pages only. The timer handles everything
  // else. This speeds up form close after successful login.
  // Safe URLs: /nxl/main (launcher), /main (nexon web post-login).
  if (Pos('/main', SrcLower) > 0) then
    FWVBrowser.GetCookies('https://www.nexon.com');
end;

procedure TFormLoginWebView.WVInitializationError(Sender: TObject;
  aErrorCode: HRESULT; const aErrorMessage: wvstring);
begin
  TimerInit.Enabled    := False;
  TimerCookies.Enabled := False;
  LblStatus.Caption    := 'WebView2 error: ' + aErrorMessage;
end;

// Login method choice: Tag=0 = Nexon Account (needs NexonLauncher UA),
// Tag=1 = SSO (keeps default WebView2 UA).
procedure TFormLoginWebView.BtnLoginChoiceClick(Sender: TObject);
begin
  if FChoicePanel <> nil then
    FChoicePanel.Hide;
  if TButton(Sender).Tag = 0 then
  begin
    FWVBrowser.UserAgent := NXL_UA;
    LblStatus.Caption := 'Loading Nexon login...';
  end
  else
    LblStatus.Caption := 'Loading SSO login...';
  TimerCookies.Enabled := True;
  FWVBrowser.Navigate(NEXON_URL);
end;

{ ------------------------------------------------------------------ }
{  Cookie polling                                                     }
{ ------------------------------------------------------------------ }

procedure TFormLoginWebView.TimerCookiesTimer(Sender: TObject);
begin
  if FDestroying or FExchanging or not FWVBrowser.Initialized then Exit;
  FAltCookieUri := not FAltCookieUri;
  // Alternate between www.nexon.com and nxl.nxfs.nexon.com URIs.
  // Session cookies may be host-only for either domain; polling both ensures capture.
  if FAltCookieUri then
    FWVBrowser.GetCookies('https://www.nexon.com')
  else
    FWVBrowser.GetCookies('https://nxl.nxfs.nexon.com');
end;

procedure TFormLoginWebView.WVGetCookiesCompleted(Sender: TObject;
  aResult: HRESULT; const aCookieList: ICoreWebView2CookieList);
const
  WANT: array[0..10] of string = (
    'NxLSession', 'AToken', 'g_AToken', 'NexonUserID', 'id_token', 'TpaSession', 'NxGUN',
    'arenaSid', 'tpatype', 'PARTNERKEY', 'FromMarvelMachine');
var
  CookieList:  TCoreWebView2CookieList;
  Cookie:      TCoreWebView2Cookie;
  I:           Cardinal;
  SB:          TStringBuilder;
  Raw, TpaSession, DebugNames, CurSrc: string;
  HttpStatus:  Integer;
  NexonCode:   Integer;
  IsPostLogin: Boolean;
begin
  if FDestroying then Exit;
  if (aResult <> S_OK) or (aCookieList = nil) or FExchanging then Exit;

  // Snapshot and reset immediately to be re-entry safe.
  IsPostLogin       := FPostLoginCapture;
  FPostLoginCapture := False;

  CookieList := TCoreWebView2CookieList.Create(aCookieList);

  Cookie     := TCoreWebView2Cookie.Create(nil);
  SB         := TStringBuilder.Create;
  try
    I := 0;
    while I < CookieList.Count do
    begin
      Cookie.BaseIntf := CookieList.Items[I];
      if Pos('nexon', LowerCase(Cookie.Domain)) > 0 then
      begin
        // Post-login: collect ALL nexon-domain cookies so we don't miss session tokens
        // set by regional-auth web login (which may use names not in the WANT list).
        if IsPostLogin or MatchText(Cookie.Name, WANT) then
        begin
          if SB.Length > 0 then SB.Append('; ');
          SB.Append(Cookie.Name + '=' + Cookie.Value);
        end;
      end;
      Inc(I);
    end;
    Raw := SB.ToString;

  CurSrc := LowerCase(FWVBrowser.Source);

  // Skip processing on non-nexon pages (SSO OAuth providers).
  // The TPA path, fast path, and arenaSid handler all have their own URL guards
  // to prevent premature processing on the login page.
  if FSilentChecked and (Pos('nexon.com', CurSrc) = 0) and (Pos('nxfs.nexon.com', CurSrc) = 0) then
  begin
    LblStatus.Caption := 'Waiting for SSO to complete...';
    Exit;
  end;

  // Build debug name list so the early-exit message shows what WebView2 actually has.
  if IsPostLogin then
  begin
    var DBG := TStringBuilder.Create;
    try
      var J: Cardinal := 0;
      while J < CookieList.Count do
      begin
        Cookie.BaseIntf := CookieList.Items[J];
        if Pos('nexon', LowerCase(Cookie.Domain)) > 0 then
        begin
          if DBG.Length > 0 then DBG.Append(', ');
          DBG.Append(Cookie.Name + '@' + Cookie.Domain);
        end;
        Inc(J);
      end;
      DebugNames := DBG.ToString;
    finally
      DBG.Free;
    end;
  end;
  finally
    SB.Free;
    FreeAndNil(Cookie);
    FreeAndNil(CookieList);
  end;

  // Post-login path: NavigationCompleted fired on nexon.com after web login.
  // Check for session tokens. NxLSession has domain=www.nexon.com (not .nexon.com),
  // so it only appears when GetCookies is called with 'https://www.nexon.com' URI.
  // If neither token present yet, yield to timer (page still committing cookies).
  // If TpaSession present → fall through to TPA exchange.
  // If NxLSession present → fall through to fast-path.
  if IsPostLogin then
  begin
    if (Pos('NxLSession', Raw) = 0) and (ExtractCookieValue(Raw, 'TpaSession') = '') then
    begin
      // arenaSid present but no NxLSession — web login completed but launcher API
      // hasn't been called. Call the launcher API directly from Delphi to upgrade
      // the web session to a launcher session. nxl.nxfs page is broken (JS errors).
      if (Pos('arenaSid=', Raw) > 0) and (FPostLoginNavCount <= MAX_MAIN_NAV)
         and (Pos('nexon.com', CurSrc) > 0) and (Pos('/account/en/login', CurSrc) = 0) then
      begin
        LblStatus.Caption := 'Establishing launcher session...';
        Application.ProcessMessages;
        Inc(FPostLoginNavCount);

        // Try to get launcher-scoped tokens by calling APIs directly.
        var Merged := uNexonAPI.FetchAccess(Raw, '10200');
        Merged := uNexonAPI.FetchAccountAndMerge(Merged);
        if (ExtractCookieValue(Merged, 'AToken') <> '')
           and (ExtractCookieValue(Raw, 'AToken') = '') then
        begin
          FCookies := Merged;
          LblStatus.Caption := 'Session upgraded. Closing...';
          TimerCookies.Enabled := False;
          ModalResult := mrOK;
          Exit;
        end;
        // Web login complete but no launcher tokens — close with web cookies.
        // PromptReLogin will validate and retry if they don't work for launch.
        TimerCookies.Enabled := False;
        FCookies := Raw;
        LblStatus.Caption := 'Logged in. Closing...';
        ModalResult := mrOK;
        Exit;
      end;
      if DebugNames <> '' then
        LblStatus.Caption := 'Logged in — waiting for session. Got: ' + DebugNames
      else
        LblStatus.Caption := 'Logged in — waiting for session cookies...';
      TimerCookies.Enabled := True;
      Exit;
    end;
  end;

  // Silent-check gate: first call after WVAfterCreated, before we navigate to login page.
  if not FSilentChecked then
  begin
    FSilentChecked := True;

    // Don't navigate — the login method choice panel handles navigation.
    // If no existing session, the user must pick Nexon Account or SSO first.
    // If there IS an existing session (from SSO), reuse it.
    FOldTpaSession := ExtractCookieValue(Raw, 'TpaSession');
    if (FOldTpaSession = '') and (Pos('NxLSession', Raw) = 0) then
    begin
      // No session yet — show choice panel.
      FChoicePanel.Show;
      FChoicePanel.BringToFront;
      Exit;
    end;
    // Has an existing session — fall through to TPA/NxLSession handling below.
    LblStatus.Caption := 'Restoring session...';
  end;

  // TPA path: exchange TpaSession for a launcher-scoped AToken when present AND fresh.
  // Google OAuth sets both TpaSession and NxLSession; the browser NxLSession carries a
  // browser-scoped AToken that game-auth2/playable rejects, so we must exchange.
  // EXCEPTION: if TpaSession == FOldTpaSession it is a stale WebView2 cache cookie from
  // a previous Google session. Email/password login via regional-auth sets NxLSession
  // without updating TpaSession, so the old value must be ignored and NxLSession used directly.
  TpaSession := ExtractCookieValue(Raw, 'TpaSession');

  // A new TpaSession since the last failed exchange → fresh login, retry the exchange.
  if FExchangeFailed and (TpaSession <> FFailedTpa) then
    FExchangeFailed := False;

  if (TpaSession <> '') and (not FExchangeFailed) then
  begin
    // Only process TPA if on a nexon domain — SSO OAuth pages (accounts.google.com,
    // facebook.com, etc.) set cookies unrelated to the TPA exchange.
    if (Pos('nexon.com', CurSrc) = 0) and (Pos('nxfs.nexon.com', CurSrc) = 0) then
    begin
      LblStatus.Caption := 'Waiting for SSO to complete...';
      Exit;
    end;

    if (TpaSession = FOldTpaSession) and (Pos('NxLSession', Raw) > 0) then
    begin
      // Stale TpaSession + fresh NxLSession — use NxLSession directly.
      TimerCookies.Enabled := False;
      FCookies              := Raw;
      if (ExtractCookieValue(FCookies, 'AToken') = '')
         and (ExtractCookieValue(FCookies, 'g_AToken') <> '') then
        FCookies := FCookies + '; AToken=' + ExtractCookieValue(FCookies, 'g_AToken');
      LblStatus.Caption     := 'Email login detected. Closing...';
      ModalResult           := mrOK;
      Exit;
    end;

    TimerCookies.Enabled := False;
    FExchanging          := True;
    LblStatus.Caption    := 'Logged in — exchanging session...';

    try
      FCookies := ExchangeTpaForNxLSession(TpaSession, GetDeviceId(FProfileName), HttpStatus, NexonCode);
    except
      // Network/TLS failure — treat as a failed exchange (fall back below).
      FCookies   := '';
      HttpStatus := -1;
      NexonCode  := 0;
    end;
    if FCookies = '' then
    begin
      // Exchange failed. This is NOT a cancellation — SSO/web login already succeeded.
      // TpaSession is single-use and expires in seconds, so a rejected exchange must
      // not discard the valid browser session. If the page set a browser NxLSession,
      // fall through to the fast-path handling below. Otherwise keep the dialog open
      // with a clear error so the user can re-login or cancel.
      FExchangeFailed := True;
      FFailedTpa      := TpaSession;
      FExchanging     := False;
      if Pos('NxLSession', Raw) = 0 then
      begin
        if NexonCode = 20027 then
          // Nexon requires this device/browser be verified before launcher exchange works.
          // Check email for a "Trust this device" link from Nexon, click it, then retry here.
          LblStatus.Caption :=
            'Nexon requires this device to be verified first. Check your email for a ' +
            '"trust this device" message from Nexon, approve it, then log in again.'
        else
          LblStatus.Caption := Format(
            'Session exchange failed (HTTP %d). TpaSession expires in seconds — ' +
            'log in again and retry, or press Cancel.',
            [HttpStatus]);
        TimerCookies.Enabled := True;
        Exit;
      end;
      // NxLSession present — fall through to fast-path handling below.
    end
    else
    begin
      // Carry browser-session cookies not returned by the exchange endpoint.
      var CarryNames: TArray<string> := ['id_token', 'TpaSession', 'arenaSid', 'tpatype', 'PARTNERKEY'];
      for var CName in CarryNames do
      begin
        var CVal := ExtractCookieValue(Raw, CName);
        if (CVal <> '') and (Pos(CName + '=', FCookies) = 0) then
          FCookies := FCookies + '; ' + CName + '=' + CVal;
      end;
      // PARTNERKEY=3269 identifies the Nexon Launcher client — hardcode if missing.
      if Pos('PARTNERKEY=', FCookies) = 0 then
        FCookies := FCookies + '; PARTNERKEY=3269';

      LblStatus.Caption := 'Logged in. Closing...';
      ModalResult := mrOK;
      Exit;
    end;
  end;

  // Fast path: NxLSession without TpaSession.
  // IMPORTANT: only process when currently on a nexon/nxfs page. When the user
  // clicks Google SSO, the browser navigates to accounts.google.com. The cookie
  // jar still has stale nexon.com cookies from the login page — polling them
  // prematurely would close the form before the user completes the OAuth flow.
  if (Pos('NxLSession', Raw) > 0)
     and ((Pos('nexon.com', CurSrc) > 0) or (Pos('nxfs.nexon.com', CurSrc) > 0)) then
  begin
    // Don't close immediately — the launcher API's Set-Cookie may arrive after the
    // page redirects. Wait a few poll cycles for cookies to stabilize.
    if FClosePending = 0 then
    begin
      // First detection: start stabilization countdown
      FClosePending := 1;
      var Keys := '';
      for var K in ['NxLSession', 'AToken', 'g_AToken', 'NxGUN', 'NexonUserID'] do
        if ExtractCookieValue(Raw, K) <> '' then Keys := Keys + K + ' ';
      LblStatus.Caption := 'Session [' + Trim(Keys) + '] — confirming...';
      Exit;
    end;

    Dec(FClosePending);
    if FClosePending > 0 then Exit; // keep polling

    // Countdown complete — cookies should be stable now
    TimerCookies.Enabled := False;
    FCookies := Raw;

    // Some launcher API responses return g_AToken but not AToken with the same value.
    // FetchPassport needs AToken specifically for the Bearer header. If AToken missing
    // but g_AToken present, duplicate it as AToken.
    if (ExtractCookieValue(FCookies, 'AToken') = '')
       and (ExtractCookieValue(FCookies, 'g_AToken') <> '') then
      FCookies := FCookies + '; AToken=' + ExtractCookieValue(FCookies, 'g_AToken');

    var Keys := '';
    for var K in ['NxLSession', 'AToken', 'g_AToken', 'NxGUN', 'NexonUserID'] do
      if ExtractCookieValue(FCookies, K) <> '' then Keys := Keys + K + ' ';
    LblStatus.Caption := 'Session confirmed [' + Trim(Keys) + ']. Closing...';
    ModalResult := mrOK;
    Exit;
  end;
end;

{ ------------------------------------------------------------------ }

procedure TFormLoginWebView.BtnCancelClick(Sender: TObject);
begin
  TimerCookies.Enabled := False;
  TimerInit.Enabled    := False;
  ModalResult := mrCancel;
end;

{ Keep WebView2 rendering in sync with window position. }
procedure TFormLoginWebView.WMMove(var Msg: TWMMove);
begin
  inherited;
  if Assigned(FWVBrowser) then
    FWVBrowser.NotifyParentWindowPositionChanged;
end;

procedure TFormLoginWebView.WMMoving(var Msg: TMessage);
begin
  inherited;
  if Assigned(FWVBrowser) then
    FWVBrowser.NotifyParentWindowPositionChanged;
end;

{ ------------------------------------------------------------------ }

end.
