unit uCLI;
{
  Headless CLI entry point for Rua.exe.

  Usage:  Rua.exe --cli <command> [options]

  Commands:
    login          Check/refresh stored session, or log in with email+password
    login-otp      Submit OTP after a login returned an MFA challenge
    check-update   Check if a game update is available
    update         Download and apply pending game updates
    launch         Launch the game headlessly

  Common options:
    --profile NAME       Profile to use (default: first profile in list)
    --game-path PATH     Full path to Client.exe
    --product-id N       Nexon product ID (default: 10200 = Mabinogi)

  login options:
    --email E  --password P    Log in with credentials and save to profile

  login-otp options:
    --mfa-key KEY   Challenge key from the prior login attempt
    --otp CODE      One-time password from your authenticator

  update options:
    --force-all    Re-download every file regardless of local state
    --verify       Repair mode: re-verify + fix size-mismatched files

  Exit codes:
    0   success / up-to-date
    1   error
    2   update available (check-update only)
}
interface

function IsCLIMode: Boolean;
function RunCLI: Integer;

implementation

uses
  Winapi.Windows,
  System.SysUtils, System.IOUtils, System.Classes, System.SyncObjs, System.StrUtils,
  uProfiles, uDeviceId, uNexonAPI, uNxlPatcher, uGameLaunch,
  uBrowserCookies, uIgnoreList, uHooks;

const
  EXITCODE_OK     = 0;
  EXITCODE_ERR    = 1;
  EXITCODE_UPDATE = 2;

// ---------------------------------------------------------------------------
// Console I/O (WriteConsoleW — works from a Windows-subsystem GUI exe)
// ---------------------------------------------------------------------------

procedure SetupConsoleIO;
begin
  if not AttachConsole(ATTACH_PARENT_PROCESS) then
    AllocConsole;
end;

procedure ConWrite(const S: string; StdErr: Boolean = False);
var
  H: THandle;
  N: DWORD;
begin
  if StdErr then H := GetStdHandle(STD_ERROR_HANDLE)
  else           H := GetStdHandle(STD_OUTPUT_HANDLE);
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then Exit;
  if S = '' then Exit;
  WriteConsoleW(H, PChar(S), Length(S), N, nil);
end;

procedure ConLn(const S: string = '');
begin
  ConWrite(S + sLineBreak);
end;

procedure ConErr(const S: string);
begin
  ConWrite('ERROR: ' + S + sLineBreak, True);
end;

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

function GetArg(const Key: string; const Default: string = ''): string;
var
  I: Integer;
  K: string;
begin
  K := '--' + Key.ToLower;
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), K) then
      Exit(ParamStr(I + 1));
  Result := Default;
end;

function HasFlag(const Key: string): Boolean;
var
  I: Integer;
  K: string;
begin
  K := '--' + Key.ToLower;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), K) then Exit(True);
  Result := False;
end;

// ---------------------------------------------------------------------------
// Profile helpers
// ---------------------------------------------------------------------------

function FirstProfileName: string;
var
  Profs: TArray<TNexonProfile>;
begin
  Profs := LoadProfiles;
  if Length(Profs) > 0 then Result := Profs[0].Name
  else Result := '';
end;

function FindProfile(const Name: string): TNexonProfile;
var
  Profs: TArray<TNexonProfile>;
begin
  FillChar(Result, SizeOf(Result), 0);
  Profs := LoadProfiles;
  for var P in Profs do
    if (Name = '') or SameText(P.Name, Name) then
    begin
      Result := P;
      Exit;
    end;
end;

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

function CmdLogin: Integer;
var
  ProfileName, Email, Password, DevId, Cookies: string;
  Prof: TNexonProfile;
  HttpStatus, NexonCode, RefreshStatus: Integer;
  NxLSess, Refreshed: string;
begin
  ProfileName := GetArg('profile');
  Email       := GetArg('email');
  Password    := GetArg('password');

  if (Email <> '') and (Password <> '') then
  begin
    // Direct email/password login.
    Prof := FindProfile(ProfileName);
    if Prof.Name = '' then
    begin
      Prof.Name     := IfThen(ProfileName <> '', ProfileName, Email);
      Prof.DeviceId := '';
    end;
    DevId := Prof.DeviceId;
    if DevId = '' then
    begin
      DevId         := GetDeviceId(Prof.Name);
      Prof.DeviceId := DevId;
    end;

    ConLn('Logging in: ' + Email);
    try
      Cookies := LoginEmailPassword(Email, Password, DevId);
    except
      on E: ELoginMfaRequired do
      begin
        ConErr('MFA required.');
        ConLn('MFA key:  ' + E.MfaKey);
        ConLn('MFA type: ' + E.MfaType);
        ConLn('Submit OTP:  Rua.exe --cli login-otp --mfa-key ' + E.MfaKey
          + ' --otp <CODE>'
          + IfThen(Prof.Name <> '', ' --profile ' + Prof.Name, ''));
        Exit(EXITCODE_ERR);
      end;
      on E: ELoginCaptchaRequired do
      begin
        ConErr('CAPTCHA required — use the GUI browser login. ' + E.Message);
        Exit(EXITCODE_ERR);
      end;
      on E: ELoginFailed do
      begin
        ConErr('Login failed: ' + E.Message);
        Exit(EXITCODE_ERR);
      end;
    end;

    Prof.Email := Email;
    AddOrUpdateProfile(Prof, Cookies);
    ConLn('Saved. Profile: ' + Prof.Name);
    Exit(EXITCODE_OK);
  end;

  // No email+password: check / refresh existing session.
  if ProfileName = '' then ProfileName := FirstProfileName;
  if ProfileName = '' then
  begin
    ConErr('No profiles. Pass --email and --password to create one.');
    Exit(EXITCODE_ERR);
  end;

  Cookies := LoadCookies(ProfileName);
  if Cookies = '' then
  begin
    ConErr('No credentials stored for: ' + ProfileName);
    Exit(EXITCODE_ERR);
  end;

  if CheckSessionValid(Cookies, HttpStatus, NexonCode) then
  begin
    ConLn('Session valid: ' + ProfileName);
    Exit(EXITCODE_OK);
  end;

  ConLn(Format('Session expired (HTTP %d) — attempting refresh...', [HttpStatus]));
  Prof     := FindProfile(ProfileName);
  DevId    := Prof.DeviceId;
  NxLSess  := ExtractCookieValue(Cookies, 'NxLSession');
  if (NxLSess <> '') and (DevId <> '') then
  begin
    RefreshStatus := 0;
    Refreshed     := AutoLoginRefresh(NxLSess, DevId, RefreshStatus);
    if Refreshed <> '' then
    begin
      AddOrUpdateProfile(Prof, Refreshed);
      ConLn('Session refreshed: ' + ProfileName);
      Exit(EXITCODE_OK);
    end;
    ConLn(Format('Autologin failed (HTTP %d).', [RefreshStatus]));
  end;

  ConErr('Session expired and could not auto-refresh. Use the GUI browser login.');
  Result := EXITCODE_ERR;
end;

function CmdLoginOtp: Integer;
var
  MfaKey, Otp, ProfileName, DevId, Cookies: string;
  Prof: TNexonProfile;
begin
  MfaKey      := GetArg('mfa-key');
  Otp         := GetArg('otp');
  ProfileName := GetArg('profile');

  if (MfaKey = '') or (Otp = '') then
  begin
    ConErr('Usage: --cli login-otp --mfa-key KEY --otp CODE [--profile NAME]');
    Exit(EXITCODE_ERR);
  end;

  if ProfileName = '' then ProfileName := FirstProfileName;
  Prof  := FindProfile(ProfileName);
  DevId := Prof.DeviceId;
  if DevId = '' then
    DevId := GetDeviceId(IfThen(ProfileName <> '', ProfileName, 'default'));

  try
    Cookies := LoginOTP(MfaKey, Otp, DevId);
  except
    on E: ELoginFailed do
    begin
      ConErr('OTP failed: ' + E.Message);
      Exit(EXITCODE_ERR);
    end;
  end;

  if Prof.Name <> '' then
    AddOrUpdateProfile(Prof, Cookies)
  else
    ConLn('Cookies: ' + Cookies);

  ConLn('Login OK: ' + IfThen(Prof.Name <> '', Prof.Name, '(profile not saved)'));
  Result := EXITCODE_OK;
end;

function CmdCheckUpdate: Integer;
var
  ProfileName, GamePath, Cookies, RemoteHash, LocalHash, HashFile: string;
  ProductId: Integer;
  Prof: TNexonProfile;
begin
  ProfileName := GetArg('profile');
  GamePath    := GetArg('game-path');
  ProductId   := StrToIntDef(GetArg('product-id'), 10200);

  if ProfileName = '' then ProfileName := FirstProfileName;
  Prof    := FindProfile(ProfileName);
  Cookies := '';
  if Prof.Name <> '' then Cookies := LoadCookies(Prof.Name);

  try
    RemoteHash := FetchManifestHash(Cookies, ProductId);
  except
    on E: Exception do
    begin
      ConErr('Update check failed: ' + E.Message);
      Exit(EXITCODE_ERR);
    end;
  end;

  ConLn('Remote hash: ' + RemoteHash);

  if GamePath = '' then
  begin
    ConLn('No --game-path supplied; cannot compare local version. Assuming update needed.');
    Exit(EXITCODE_UPDATE);
  end;

  HashFile  := TPath.Combine(GamePath, 'patchdata\' + IntToStr(ProductId) + '.manifest.hash');
  LocalHash := '';
  if TFile.Exists(HashFile) then
    LocalHash := Trim(TFile.ReadAllText(HashFile));

  if LocalHash = RemoteHash then
  begin
    ConLn('Up to date.');
    Result := EXITCODE_OK;
  end
  else
  begin
    ConLn('Update available (local: ' + IfThen(LocalHash = '', '<none>', LocalHash) + ')');
    Result := EXITCODE_UPDATE;
  end;
end;

function CmdUpdate: Integer;
var
  ProfileName, GamePath, Cookies, RemoteHash: string;
  ProductId: Integer;
  ForceAll: Boolean;
  Prof: TNexonProfile;
begin
  ProfileName := GetArg('profile');
  GamePath    := GetArg('game-path');
  ProductId   := StrToIntDef(GetArg('product-id'), 10200);
  ForceAll    := HasFlag('force-all');

  // --verify: same as normal update but OldManifestJSON='' (full reverify).
  // We always pass '' for simplicity in CLI; it re-verifies every file against
  // the remote manifest rather than diffing against the last-applied one.

  if GamePath = '' then
  begin
    ConErr('--game-path <path-to-Client.exe> is required.');
    Exit(EXITCODE_ERR);
  end;

  if ProfileName = '' then ProfileName := FirstProfileName;
  Prof    := FindProfile(ProfileName);
  Cookies := '';
  if Prof.Name <> '' then Cookies := LoadCookies(Prof.Name);

  try
    RemoteHash := FetchManifestHash(Cookies, ProductId);
  except
    on E: Exception do
    begin
      ConErr('Hash fetch failed: ' + E.Message);
      Exit(EXITCODE_ERR);
    end;
  end;

  ConLn('Patching: ' + GamePath);
  var Hooks := LoadHooks;
  RunHookCmd(Hooks.BeforePatch, Prof.Name);
  try
    RunPatcher(RemoteHash, GamePath, ProductId,
      procedure(const Msg: string)
      begin
        ConLn(Msg);
      end,
      procedure(Cur, Total: Integer; const FileName: string)
      var
        Line: string;
        H: THandle;
        N: DWORD;
      begin
        if Total > 0 then
        begin
          Line := Format(#13'  [%d/%d] %3d%%  %s   ',
            [Cur, Total, (Cur * 100) div Total, FileName]);
          H := GetStdHandle(STD_OUTPUT_HANDLE);
          if (H <> 0) and (H <> INVALID_HANDLE_VALUE) then
            WriteConsoleW(H, PChar(Line), Length(Line), N, nil);
        end;
      end,
      '',       // OldManifestJSON: '' = always re-check against remote manifest
      ForceAll,
      nil,      // ShouldCancel
      nil,      // PauseEvent
      False,    // ScanOnly
      nil,      // NeedCount
      LoadIgnorePatterns,
      nil);     // SelectFiles (no interactive picker in CLI)

    ConWrite(sLineBreak); // newline after in-place progress bar
    ConLn('Done.');
    RunHookCmd(Hooks.AfterPatch, Prof.Name);
    Result := EXITCODE_OK;
  except
    on E: Exception do
    begin
      ConWrite(sLineBreak);
      ConErr('Patch failed: ' + E.Message);
      Result := EXITCODE_ERR;
    end;
  end;
end;

// Named helper class for OnGameExit (TNotifyEvent = procedure of object).
type
  TGameWaiter = class
    FDone: Boolean;
    procedure OnExit(Sender: TObject);
  end;

procedure TGameWaiter.OnExit(Sender: TObject);
begin
  FDone := True;
end;

function CmdLaunch: Integer;
var
  ProfileName, GamePath, Cookies: string;
  ProductId: Integer;
  Prof: TNexonProfile;
  Launcher: TGameLauncher;
  Waiter: TGameWaiter;
begin
  ProfileName := GetArg('profile');
  GamePath    := GetArg('game-path');
  ProductId   := StrToIntDef(GetArg('product-id'), 10200);

  if ProfileName = '' then ProfileName := FirstProfileName;
  if ProfileName = '' then
  begin
    ConErr('No profiles found. Create one in the GUI first.');
    Exit(EXITCODE_ERR);
  end;

  Prof := FindProfile(ProfileName);
  if Prof.Name = '' then
  begin
    ConErr('Profile not found: ' + ProfileName);
    Exit(EXITCODE_ERR);
  end;
  Cookies := LoadCookies(Prof.Name);
  if Cookies = '' then
  begin
    ConErr('No credentials for: ' + Prof.Name);
    Exit(EXITCODE_ERR);
  end;

  if GamePath = '' then GamePath := Prof.GameExe;
  if GamePath = '' then
  begin
    ConErr('--game-path required (or set a game path in Settings).');
    Exit(EXITCODE_ERR);
  end;
  if not TFile.Exists(GamePath) then
  begin
    ConErr('Game exe not found: ' + GamePath);
    Exit(EXITCODE_ERR);
  end;

  ConLn('Launching: ' + Prof.Name);
  var LaunchHooks := LoadHooks;
  RunHookCmd(LaunchHooks.BeforeLaunch, Prof.Name);
  Waiter   := TGameWaiter.Create;
  Launcher := TGameLauncher.Create;
  try
    Launcher.OnGameExit := Waiter.OnExit;
    try
      Launcher.Launch(Cookies, ProductId, GamePath);
    except
      on E: Exception do
      begin
        ConErr('Launch failed: ' + E.Message);
        Exit(EXITCODE_ERR);
      end;
    end;

    ConLn('Game running. Waiting for exit...');
    // Poll IsRunning; CheckSynchronize drains any queued TThread callbacks.
    while not Waiter.FDone do
    begin
      CheckSynchronize(200);
      Sleep(300);
    end;
    ConLn('Game exited.');
    RunHookCmd(LaunchHooks.AfterLaunch, Prof.Name);
    Result := EXITCODE_OK;
  finally
    Launcher.Free;
    Waiter.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

function IsCLIMode: Boolean;
begin
  Result := FindCmdLineSwitch('cli');
end;

function RunCLI: Integer;
var
  Cmd: string;
  I: Integer;
  FoundCLI: Boolean;
begin
  SetupConsoleIO;

  Cmd      := '';
  FoundCLI := False;
  for I := 1 to ParamCount do
  begin
    var A := ParamStr(I);
    if SameText(A, '--cli') then begin FoundCLI := True; Continue; end;
    if FoundCLI and (Length(A) > 0) and (A[1] <> '-') then
    begin
      Cmd := A.ToLower;
      Break;
    end;
  end;

  if      Cmd = 'login'        then Result := CmdLogin
  else if Cmd = 'login-otp'    then Result := CmdLoginOtp
  else if Cmd = 'check-update' then Result := CmdCheckUpdate
  else if Cmd = 'update'       then Result := CmdUpdate
  else if Cmd = 'launch'       then Result := CmdLaunch
  else
  begin
    ConLn('Rua CLI  —  Nexon Launcher replacement for Mabinogi');
    ConLn;
    ConLn('Usage:  Rua.exe --cli <command> [options]');
    ConLn;
    ConLn('Commands:');
    ConLn('  login          Check/refresh stored session, or log in with credentials');
    ConLn('  login-otp      Submit OTP after MFA challenge');
    ConLn('  check-update   Check if a game update is available  (exit 0=ok, 2=update)');
    ConLn('  update         Download and apply pending game updates');
    ConLn('  launch         Launch the game headlessly (waits for exit)');
    ConLn;
    ConLn('Common options:');
    ConLn('  --profile NAME       Profile to use  (default: first profile)');
    ConLn('  --game-path PATH     Full path to Client.exe');
    ConLn('  --product-id N       Nexon product ID  (default: 10200)');
    ConLn;
    ConLn('login:   [--email E --password P]');
    ConLn('update:  [--force-all]  [--verify]');
    Result := EXITCODE_ERR;
  end;
end;

end.
