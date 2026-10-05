unit uRuaAPI;
{
  Rua DLL API — exported functions for RuaAPI.dll.

  All strings use UTF-16 (PChar = PWideChar).
  All functions are stdcall for C compatibility.

  Return codes:
    RUA_OK        (0)  success
    RUA_ERR       (1)  generic error  — call RuaGetLastError for details
    RUA_MFA       (2)  MFA required   — mfa_key/mfa_type buffers filled  (RuaLogin only)
    RUA_CAPTCHA   (3)  CAPTCHA block  — use browser login                (RuaLogin only)
    RUA_UPDATE    (4)  update available                                   (RuaCheckUpdate only)
    RUA_EXPIRED   (5)  session expired

  See RuaAPI.h for the C header.
}
interface

const
  RUA_OK      = 0;
  RUA_ERR     = 1;
  RUA_MFA     = 2;
  RUA_CAPTCHA = 3;
  RUA_UPDATE  = 4;
  RUA_EXPIRED = 5;

// Progress callback: invoked from the patcher thread.
type
  TRuaProgressCb = procedure(current, total: Integer; filename: PChar); stdcall;
  TRuaCancelCb   = function: Integer; stdcall;  // return non-zero to cancel

// Log in with email + password.
// On success:  cookies_out filled, returns RUA_OK.
// On MFA:      mfa_key_out/mfa_type_out filled, returns RUA_MFA.
// On CAPTCHA:  returns RUA_CAPTCHA.
// On error:    returns RUA_ERR; call RuaGetLastError.
// device_id:   pass nil/'' to auto-derive from machine hardware.
function RuaLogin(
  email:         PChar;
  password:      PChar;
  device_id:     PChar;
  cookies_out:   PChar;
  cookies_size:  Integer;
  mfa_key_out:   PChar;
  mfa_key_size:  Integer;
  mfa_type_out:  PChar;
  mfa_type_size: Integer): Integer; stdcall;

// Submit OTP after RuaLogin returned RUA_MFA.
function RuaLoginOTP(
  mfa_key:      PChar;
  otp:          PChar;
  device_id:    PChar;
  cookies_out:  PChar;
  cookies_size: Integer): Integer; stdcall;

// Check if a session cookie string is still valid.
// Returns RUA_OK (valid) or RUA_EXPIRED.
// http_status receives the HTTP response code.
function RuaSessionCheck(
  cookies:     PChar;
  http_status: PInteger): Integer; stdcall;

// Check if an update is available for product_id.
// install_root: path containing the patchdata\ folder (pass nil to skip local check).
// manifest_hash_out: receives the remote hash string.
// Returns RUA_OK (up to date) or RUA_UPDATE (update available).
function RuaCheckUpdate(
  cookies:              PChar;
  product_id:           Integer;
  install_root:         PChar;
  manifest_hash_out:    PChar;
  manifest_hash_size:   Integer): Integer; stdcall;

// Download and apply pending updates for install_root.
// force_all: 1 = re-download every file; 0 = patch changed files only.
// progress_cb / cancel_cb: may be nil.
function RuaRunPatcher(
  manifest_hash: PChar;
  install_root:  PChar;
  product_id:    Integer;
  force_all:     Integer;
  progress_cb:   TRuaProgressCb;
  cancel_cb:     TRuaCancelCb): Integer; stdcall;

// Launch the game. Synchronous — returns when the game process exits.
function RuaLaunch(
  cookies:    PChar;
  product_id: Integer;
  game_exe:   PChar): Integer; stdcall;

// Retrieve the last error message (up to buf_size wide chars including NUL).
procedure RuaGetLastError(buf: PChar; buf_size: Integer); stdcall;

implementation

uses
  System.SysUtils, System.IOUtils, System.Math, System.Classes, System.SyncObjs,
  uNexonAPI, uNxlPatcher, uGameLaunch, uDeviceId;

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

var
  GLastError: string;

procedure SetLastError(const Msg: string);
begin
  GLastError := Msg;
end;

procedure CopyStr(const Src: string; Dst: PChar; DstSize: Integer);
begin
  if (Dst = nil) or (DstSize <= 0) then Exit;
  var Len := Min(Length(Src), DstSize - 1);
  if Len > 0 then Move(PChar(Src)^, Dst^, Len * SizeOf(Char));
  Dst[Len] := #0;
end;

// ---------------------------------------------------------------------------
// Exported functions
// ---------------------------------------------------------------------------

function RuaLogin(email, password, device_id,
  cookies_out: PChar; cookies_size: Integer;
  mfa_key_out: PChar; mfa_key_size: Integer;
  mfa_type_out: PChar; mfa_type_size: Integer): Integer; stdcall;
var
  DevId, Cookies: string;
begin
  try
    DevId := '';
    if (device_id <> nil) and (device_id^ <> #0) then DevId := device_id;
    if DevId = '' then DevId := GetDeviceId;

    Cookies := LoginEmailPassword(email, password, DevId);
    CopyStr(Cookies, cookies_out, cookies_size);
    Result  := RUA_OK;
  except
    on E: ELoginMfaRequired do
    begin
      CopyStr(E.MfaKey,  mfa_key_out,  mfa_key_size);
      CopyStr(E.MfaType, mfa_type_out, mfa_type_size);
      SetLastError('MFA required');
      Result := RUA_MFA;
    end;
    on E: ELoginCaptchaRequired do
    begin
      SetLastError(E.Message);
      Result := RUA_CAPTCHA;
    end;
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := RUA_ERR;
    end;
  end;
end;

function RuaLoginOTP(mfa_key, otp, device_id, cookies_out: PChar;
  cookies_size: Integer): Integer; stdcall;
var
  DevId, Cookies: string;
begin
  try
    DevId := '';
    if (device_id <> nil) and (device_id^ <> #0) then DevId := device_id;
    if DevId = '' then DevId := GetDeviceId;

    Cookies := LoginOTP(mfa_key, otp, DevId);
    CopyStr(Cookies, cookies_out, cookies_size);
    Result  := RUA_OK;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := RUA_ERR;
    end;
  end;
end;

function RuaSessionCheck(cookies: PChar; http_status: PInteger): Integer; stdcall;
var
  Status, NexonCode: Integer;
begin
  try
    Status := 0;
    if CheckSessionValid(cookies, Status, NexonCode) then
      Result := RUA_OK
    else
    begin
      SetLastError(Format('Session invalid (HTTP %d)', [Status]));
      Result := RUA_EXPIRED;
    end;
    if http_status <> nil then http_status^ := Status;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      if http_status <> nil then http_status^ := 0;
      Result := RUA_ERR;
    end;
  end;
end;

function RuaCheckUpdate(cookies: PChar; product_id: Integer;
  install_root: PChar;
  manifest_hash_out: PChar; manifest_hash_size: Integer): Integer; stdcall;
var
  CookieStr, RemoteHash, LocalHash, HashFile, Root: string;
begin
  try
    CookieStr  := cookies;
    RemoteHash := FetchManifestHash(CookieStr, product_id);
    CopyStr(RemoteHash, manifest_hash_out, manifest_hash_size);

    Root := '';
    if (install_root <> nil) and (install_root^ <> #0) then Root := install_root;

    if Root = '' then
    begin
      Result := RUA_UPDATE; // can't compare locally, assume needed
      Exit;
    end;

    HashFile  := TPath.Combine(Root, 'patchdata\' + IntToStr(product_id) + '.manifest.hash');
    LocalHash := '';
    if TFile.Exists(HashFile) then LocalHash := Trim(TFile.ReadAllText(HashFile));

    if LocalHash = RemoteHash then Result := RUA_OK
    else                           Result := RUA_UPDATE;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := RUA_ERR;
    end;
  end;
end;

function RuaRunPatcher(manifest_hash, install_root: PChar; product_id: Integer;
  force_all: Integer; progress_cb: TRuaProgressCb;
  cancel_cb: TRuaCancelCb): Integer; stdcall;
begin
  try
    RunPatcher(manifest_hash, install_root, product_id,
      procedure(const Msg: string) begin end, // no text log in DLL mode — caller uses progress_cb; RunPatcher always calls Log
      procedure(Cur, Total: Integer; const FileName: string)
      begin
        if Assigned(progress_cb) then
          progress_cb(Cur, Total, PChar(FileName));
      end,
      '',               // OldManifestJSON
      force_all <> 0,   // ForceAll
      function: Boolean // ShouldCancel
      begin
        if Assigned(cancel_cb) then Result := cancel_cb <> 0
        else Result := False;
      end,
      nil,              // PauseEvent
      False,            // ScanOnly
      nil,              // NeedCount
      nil,              // IgnorePatterns
      nil);             // SelectFiles
    Result := RUA_OK;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := RUA_ERR;
    end;
  end;
end;

// Helper for RuaLaunch: OnGameExit is TNotifyEvent (needs an object).
type
  TLaunchWaiter = class
    FDone: Boolean;
    procedure OnExit(Sender: TObject);
  end;

procedure TLaunchWaiter.OnExit(Sender: TObject);
begin
  FDone := True;
end;

function RuaLaunch(cookies: PChar; product_id: Integer;
  game_exe: PChar): Integer; stdcall;
var
  Launcher: TGameLauncher;
  Waiter:   TLaunchWaiter;
begin
  try
    Waiter   := TLaunchWaiter.Create;
    Launcher := TGameLauncher.Create;
    try
      Launcher.OnGameExit := Waiter.OnExit;
      Launcher.Launch(cookies, product_id, game_exe);
      while not Waiter.FDone do
      begin
        CheckSynchronize(200);
        Sleep(300);
      end;
      Result := RUA_OK;
    finally
      Launcher.Free;
      Waiter.Free;
    end;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := RUA_ERR;
    end;
  end;
end;

procedure RuaGetLastError(buf: PChar; buf_size: Integer); stdcall;
begin
  CopyStr(GLastError, buf, buf_size);
end;

initialization
  GLastError := '';

end.
