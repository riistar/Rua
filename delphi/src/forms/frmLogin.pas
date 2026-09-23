unit frmLogin;
{
  Two-step login: open nexon.com in system browser, then import cookies.
  No embedded browser. No Edge. No CEF.

  After clicking Open, a 1-second poll timer auto-detects TpaSession/NxLSession
  in the browser and triggers the exchange immediately — before TpaSession expires.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ExtCtrls,
  uBrowserCookies;

type
  TFormLogin = class(TForm)
    PnlMain:         TPanel;
    LblEPHeader:     TLabel;
    LblEmailAddr:    TLabel;
    LblEmailPwd:     TLabel;
    LblOrBrowser:    TLabel;
    EdtEmail:        TEdit;
    EdtPassword:     TEdit;
    BtnEmailLogin:   TButton;
    BtnCancelOtp:    TButton;
    Bevel2:          TBevel;
    Bevel3:          TBevel;
    LblStep1:        TLabel;
    LblStep1Desc:    TLabel;
    BtnOpenBrowser:  TButton;
    Bevel1:          TBevel;
    LblStep2:        TLabel;
    LblStep2Desc:    TLabel;
    BtnImport:       TButton;
    BtnManual:       TButton;
    LblStatus:       TLabel;
    PnlButtons:      TPanel;
    BtnCancel:       TButton;
    TimerPoll:       TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnEmailLoginClick(Sender: TObject);
    procedure BtnCancelOtpClick(Sender: TObject);
    procedure BtnOpenBrowserClick(Sender: TObject);
    procedure BtnImportClick(Sender: TObject);
    procedure BtnManualClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure TimerPollTimer(Sender: TObject);
  private
    FCookies:        string;
    FMfaKey:         string;
    FProfileName:    string;
    FForceRelogin:   Boolean;
    FPollSeconds:    Integer;
    FOldTpaSession:  string;
    FBrowserOpened:  Boolean;
    FPollActive:     Boolean; // guard: prevents re-entrant background poll
    FLoginDone:      Boolean; // guard: prevents double-close from timer + Import race
    FDestroying:     Boolean; // guard: set in FormDestroy, checked in TThread.Queue callbacks
    procedure TryImportCookies(const RawCookies: string; Browser: TBrowserType);
  public
    class function Execute(out Cookies: string; const ProfileName: string = ''; ForceRelogin: Boolean = False): Boolean;
    property CapturedCookies: string read FCookies;
  end;

implementation

{$R *.dfm}

uses Winapi.ShellAPI, Vcl.Dialogs, System.IOUtils, System.Threading,
  uNexonAPI, uDeviceId, frmLoginWebView;

const
  NEXON_URL = 'https://www.nexon.com/account/en/login'
           + '?autologin=false'
           + '&return_url=https%3A%2F%2Fnxl.nxfs.nexon.com%2F';
  POLL_TIMEOUT_S = 90; // stop polling after 90 seconds

// Returns comma-separated list of cookie names from a 'name=value; ...' string.
function CookieNamesStr(const C: string): string;
var
  P:    TArray<string>;
  N:    TArray<string>;
  I, E: Integer;
  S:    string;
begin
  P := C.Split([';']);
  SetLength(N, Length(P));
  I := 0;
  for S in P do
  begin
    E := Pos('=', Trim(S));
    if E > 0 then
    begin
      N[I] := Trim(Copy(Trim(S), 1, E - 1));
      Inc(I);
    end;
  end;
  SetLength(N, I);
  Result := string.Join(', ', N);
end;

class function TFormLogin.Execute(out Cookies: string; const ProfileName: string = ''; ForceRelogin: Boolean = False): Boolean;
var
  F: TFormLogin;
begin
  F := TFormLogin.Create(nil);
  try
    F.FProfileName  := ProfileName;
    F.FForceRelogin := ForceRelogin;
    // Force re-login: prevent Firefox timer from racing ahead with stale cookies.
    // Timer polls Firefox every 1s and can close the form before user clicks Open Browser.
    if ForceRelogin then
    begin
      F.TimerPoll.Enabled := False;
      F.FBrowserOpened    := True;
    end;
    Result := F.ShowModal = mrOK;
    if Result then Cookies := F.CapturedCookies;
  finally
    F.Free;
  end;
end;

procedure TFormLogin.FormCreate(Sender: TObject);
begin
  FBrowserOpened    := False;
  FPollSeconds      := 0;
  FPollActive       := False;
  FDestroying       := False;
  FForceRelogin     := False;
  // FOldTpaSession starts empty — first async timer poll establishes the baseline.
  // Any valid TpaSession in Firefox will be treated as "new" and imported immediately.
  // For Refresh Login this is desired (reuse any valid session without waiting).
  FOldTpaSession    := '';
  Self.OnDestroy    := FormDestroy;
  // TimerPoll is DISABLED — Firefox polling caused stale cookie races.
  // All login uses the WebView2 browser directly (TFormLoginWebView).
  TimerPoll.Enabled := False;
end;

procedure TFormLogin.FormDestroy(Sender: TObject);
begin
  FDestroying       := True;
  TimerPoll.Enabled := False;
end;

procedure TFormLogin.BtnOpenBrowserClick(Sender: TObject);
var
  Cookies: string;
begin
  TimerPoll.Enabled := False;
  LblStatus.Caption := 'Opening browser...';
  Application.ProcessMessages;

  if TFormLoginWebView.Execute(Cookies, FProfileName, FForceRelogin) then
  begin
    FCookies := Cookies;
    LblStatus.Caption := 'Logged in via browser. Closing...';
    ModalResult := mrOK;
  end
  else
  begin
    LblStatus.Caption := 'Browser login cancelled. Use email/password above, or try again.';
    FBrowserOpened    := True;
    FPollSeconds      := 0;
    // Reset baseline — next timer poll will detect any newly-set Firefox TpaSession.
    FOldTpaSession    := '';
    TimerPoll.Enabled := True;
  end;
end;

// Shared import logic used by both auto-detect (timer) and manual Import button.
procedure TFormLogin.TryImportCookies(const RawCookies: string; Browser: TBrowserType);
var
  TpaSession: string;
  HttpStatus: Integer;
  NexonCode:  Integer;
begin
  if FLoginDone then Exit;

  // If user already clicked "Open Browser", the WebView2 is handling login.
  // Don't race it with stale Firefox cookies — WebView2 takes priority.
  if FBrowserOpened then
  begin
    LblStatus.Caption := 'Browser login in progress — ignoring Firefox poll.';
    Exit;
  end;

  BtnImport.Enabled := False;

  // TPA path first: if TpaSession present, always exchange to get a launcher-scoped AToken.
  // NxLSession from a browser session carries a browser-scoped AToken that game-auth2/playable
  // rejects, causing check_playable_not_executed on passport. Exchange returns the correct AToken.
  TpaSession := ExtractCookieValue(RawCookies, 'TpaSession');
  if TpaSession <> '' then
  begin
    LblStatus.Caption := 'Exchanging TpaSession → NxLSession...';
    Application.ProcessMessages;

    FCookies := ExchangeTpaForNxLSession(TpaSession, GetDeviceId(FProfileName), HttpStatus, NexonCode);
    if FCookies = '' then
    begin
      if NexonCode = 20027 then
        LblStatus.Caption :=
          'Nexon has not trusted this device for the launcher yet. Open the official ' +
          'Nexon Launcher, log in there and complete its device verification once, then ' +
          'come back and Import again.'
      else
        LblStatus.Caption := Format(
          'Exchange failed (HTTP %d). ' +
          'TpaSession expires in seconds. Log OUT of nexon.com completely in Firefox, ' +
          'then log back in, then Import immediately.',
          [HttpStatus]);
      BtnImport.Enabled := True;
      Exit;
    end;

    var IdToken := ExtractCookieValue(RawCookies, 'id_token');
    if (IdToken <> '') and (Pos('id_token', FCookies) = 0) then
      FCookies := FCookies + '; id_token=' + IdToken;

    LblStatus.Caption := 'Logged in via ' + BrowserName(Browser) + '. Closing...';
    FLoginDone    := True;
    ModalResult   := mrOK;
    Exit;
  end;

  // Fast path: NxLSession without TpaSession (direct session or email/password browser login).
  if Pos('NxLSession', RawCookies) > 0 then
  begin
    FCookies          := RawCookies;
    LblStatus.Caption := 'Session found via ' + BrowserName(Browser) + '. Closing...';
    FLoginDone        := True;
    ModalResult       := mrOK;
    Exit;
  end;

  LblStatus.Caption :=
    'No session cookie found in browser. ' +
    'Try email/password above, or log in via Google/TPA. ' +
    'Browser cookies: [' + CookieNamesStr(RawCookies) + ']';
  BtnImport.Enabled := True;
end;

// Auto-detect: fires every second from FormCreate onward.
// Firefox SQLite read runs in a background task to avoid blocking the UI thread.
procedure TFormLogin.TimerPollTimer(Sender: TObject);
begin
  if FPollActive then Exit; // previous read still in progress

  if FBrowserOpened then
  begin
    Inc(FPollSeconds);
    if FPollSeconds > POLL_TIMEOUT_S then
    begin
      TimerPoll.Enabled := False;
      LblStatus.Caption := 'Waiting for login... If already logged in to nexon.com, log OUT first, then log back in.';
      Exit;
    end;
    LblStatus.Caption := Format('Waiting for login... (%ds)', [FPollSeconds]);
  end;

  FPollActive := True;
  TTask.Run(procedure
  var
    FFCookies, NewTpa: string;
  begin
    try
      GetNexonCookiesFromFirefox(FFCookies);
    except
      FFCookies := '';
    end;
    TThread.Queue(nil, procedure
    begin
      FPollActive := False;
      if FDestroying then Exit; // form being freed — don't touch any fields
      if not TimerPoll.Enabled then Exit; // user opened browser — stale poll result
      if FFCookies = '' then Exit;
      NewTpa := ExtractCookieValue(FFCookies, 'TpaSession');
      if not (Pos('NxLSession', FFCookies) > 0)
         and not ((NewTpa <> '') and (NewTpa <> FOldTpaSession)) then Exit;
      // Update baseline so next poll doesn't re-detect the same TpaSession.
      FOldTpaSession := NewTpa;
      TimerPoll.Enabled := False;
      if FBrowserOpened then
        LblStatus.Caption := 'Firefox cookies detected — importing...'
      else
        LblStatus.Caption := 'Firefox session found — importing...';
      Application.ProcessMessages;
      TryImportCookies(FFCookies, btFirefox);
    end);
  end);
end;

procedure TFormLogin.BtnImportClick(Sender: TObject);
begin
  TimerPoll.Enabled := False;
  BtnImport.Enabled := False;
  LblStatus.Caption := 'Searching browser cookie stores...';
  Application.ProcessMessages;

  // Run all browser reads + exchange on a background thread — never block UI.
  TTask.Run(procedure
  var
    Browser:         TBrowserType;
    RawCookies:      string;
    ChromeEncrypted: Boolean;
    FFProfile, Msg:  string;
  begin
    RawCookies := '';
    if not GetNexonCookies(RawCookies, Browser) then
    begin
      // Determine best failure message off-thread
      FFProfile        := FindFirefoxProfile;
      ChromeEncrypted  := ChromeHasNexonCookiesEncrypted;
      if ChromeEncrypted then
        Msg := 'Chrome v20 (App-Bound Enc.) — use Firefox or email/password above.'
      else if FFProfile = '' then
        Msg := 'No browser session found. Log in via Firefox, or use email/password above.'
      else
        Msg := 'No nexon.com session cookies found. Log in to nexon.com in Firefox, then click Import again.';
      TThread.Queue(nil, procedure
      begin
        if FDestroying then Exit;
        LblStatus.Caption := Msg;
        BtnImport.Enabled := True;
        TimerPoll.Enabled := True;
      end);
      Exit;
    end;

    // Hand RawCookies to TryImportCookies on the UI thread (it updates labels + calls exchange)
    TThread.Queue(nil, procedure
    begin
      if FDestroying then Exit;
      if FBrowserOpened then Exit; // WebView2 already handling it
      TryImportCookies(RawCookies, Browser);
    end);
  end);

  // TryImportCookies will re-enable BtnImport on failure, or close dialog on success.
end;

procedure TFormLogin.BtnManualClick(Sender: TObject);
var
  Input:      string;
  TpaSession: string;
  HttpStatus: Integer;
  NexonCode:  Integer;
begin
  Input := Trim(InputBox(
    'Manual TpaSession entry',
    'In Firefox/Chrome DevTools → Storage/Application → Cookies → nexon.com' + #13#10 +
    'Copy the Value of the TpaSession cookie and paste below:',
    ''));
  if Input = '' then Exit;

  // Accept bare UUID or "TpaSession=UUID" prefix
  TpaSession := Input;
  if SameText(Copy(TpaSession, 1, 11), 'TpaSession=') then
    TpaSession := Copy(TpaSession, 12, MaxInt);
  TpaSession := Trim(TpaSession);
  if TpaSession = '' then Exit;

  BtnManual.Enabled := False;
  BtnImport.Enabled := False;
  LblStatus.Caption := 'Exchanging TpaSession → NxLSession...';
  Application.ProcessMessages;

  FCookies := ExchangeTpaForNxLSession(TpaSession, GetDeviceId(FProfileName), HttpStatus, NexonCode);
  if FCookies = '' then
  begin
    if NexonCode = 20027 then
      LblStatus.Caption :=
        'Nexon has not trusted this device for the launcher yet. Open the official ' +
        'Nexon Launcher, log in there and complete its device verification once, then ' +
        'come back and retry.'
    else
      LblStatus.Caption := Format(
        'Exchange failed (HTTP %d). TpaSession may be expired — re-login and retry.',
        [HttpStatus]);
    BtnManual.Enabled := True;
    BtnImport.Enabled := True;
    Exit;
  end;

  LblStatus.Caption := 'Logged in (manual entry). Closing...';
  ModalResult := mrOK;
end;

procedure TFormLogin.BtnEmailLoginClick(Sender: TObject);
var
  Email, Pwd, Otp: string;
  Cookies:         string;
begin
  TimerPoll.Enabled     := False;
  BtnEmailLogin.Enabled := False;

  if FMfaKey <> '' then
  begin
    // OTP submission
    Otp := Trim(EdtEmail.Text);
    if Otp = '' then
    begin
      LblStatus.Caption     := 'Enter the OTP code.';
      BtnEmailLogin.Enabled := True;
      Exit;
    end;
    LblStatus.Caption := 'Submitting OTP...';
    Application.ProcessMessages;
    try
      Cookies  := LoginOTP(FMfaKey, Otp, GetDeviceId(FProfileName));
      FCookies := Cookies;
      LblStatus.Caption := 'Logged in. Closing...';
      ModalResult := mrOK;
    except
      on E: ELoginFailed do
      begin
        LblStatus.Caption     := 'OTP failed: ' + E.Message;
        BtnEmailLogin.Enabled := True;
      end;
      on E: Exception do
      begin
        LblStatus.Caption     := 'Error: ' + E.Message;
        BtnEmailLogin.Enabled := True;
      end;
    end;
    Exit;
  end;

  // Email/password mode
  Email := Trim(EdtEmail.Text);
  Pwd   := EdtPassword.Text;
  if (Email = '') or (Pwd = '') then
  begin
    LblStatus.Caption     := 'Enter email and password.';
    BtnEmailLogin.Enabled := True;
    Exit;
  end;
  LblStatus.Caption := 'Signing in...';
  Application.ProcessMessages;
  try
    Cookies  := LoginEmailPassword(Email, Pwd, GetDeviceId(FProfileName));
    FCookies := Cookies;
    LblStatus.Caption := 'Logged in. Closing...';
    ModalResult := mrOK;
  except
    on E: ELoginMfaRequired do
    begin
      FMfaKey := E.MfaKey;
      LblEPHeader.Caption   := 'One-Time Password Required';
      LblEmailAddr.Caption  := 'OTP code:';
      EdtEmail.Text         := '';
      EdtEmail.PasswordChar := #0;
      LblEmailPwd.Visible   := False;
      EdtPassword.Visible   := False;
      BtnCancelOtp.Visible  := True;
      BtnEmailLogin.Caption  := 'Submit OTP';
      BtnEmailLogin.Enabled  := True;
      LblStatus.Caption :=
        'OTP required. Check your email or authenticator app for the code.';
      EdtEmail.SetFocus;
    end;
    on E: ELoginCaptchaRequired do
    begin
      // CAPTCHA required — direct API won't work.
      // Fall through to WebView2 browser login which handles reCAPTCHA v3 automatically.
      LblStatus.Caption := 'CAPTCHA required — opening browser...';
      Application.ProcessMessages;
      TimerPoll.Enabled := False;
      BtnOpenBrowserClick(Sender);
    end;
    on E: ELoginFailed do
    begin
      LblStatus.Caption     := 'Login failed: ' + E.Message;
      BtnEmailLogin.Enabled := True;
    end;
    on E: Exception do
    begin
      LblStatus.Caption     := 'Error: ' + E.Message;
      BtnEmailLogin.Enabled := True;
    end;
  end;
end;

procedure TFormLogin.BtnCancelOtpClick(Sender: TObject);
begin
  FMfaKey := '';
  LblEPHeader.Caption   := 'Email / Password Login';
  LblEmailAddr.Caption  := '&Email:';
  EdtEmail.Text         := '';
  EdtEmail.PasswordChar := #0;
  LblEmailPwd.Visible   := True;
  EdtPassword.Visible   := True;
  EdtPassword.Text      := '';
  BtnCancelOtp.Visible  := False;
  BtnEmailLogin.Caption  := 'Sign In';
  BtnEmailLogin.Enabled  := True;
  LblStatus.Caption     := '';
  EdtEmail.SetFocus;
end;

procedure TFormLogin.BtnCancelClick(Sender: TObject);
begin
  TimerPoll.Enabled := False;
  ModalResult := mrCancel;
end;

end.
