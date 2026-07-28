unit Nexon3PAPIImport;

interface

uses
  System.SysUtils, System.JSON, Winapi.Windows,
  uBrowserCookies;

const
  NP_OK              =  0;
  NP_MFARequired     =  1;
  NP_CaptchaRequired =  2;
  NP_ErrGeneric      = -1;
  NP_ErrNotInit      = -2;
  NP_ErrBadParam     = -3;
  NP_ErrNetwork      = -4;
  NP_ErrBufSmall     = -5;
  NP_ErrSession      = -401;

type
  ENP_LoginFailed      = class(Exception);
  ENP_CaptchaRequired  = class(Exception);
  ENP_MfaRequired      = class(Exception)
  public
    MfaKey: string;
  end;
  ENP_TicketError      = class(Exception);
  ENP_UpdateCheckError = class(Exception);

  TNP_LogProc = procedure(Msg: PAnsiChar); stdcall;
  TNP_ExitProc = procedure; stdcall;
  TNP_ProgressProc = procedure(Current, Total: Integer; FileName: PAnsiChar); stdcall;

  TNP_LogProcDelphi = reference to procedure(const Msg: string);
  TNP_ExitProcDelphi = reference to procedure;
  TNP_ProgressProcDelphi = reference to procedure(Current, Total: Integer; const FileName: string);

  TGameConfig = record
    ExecutablePath: string;
    WorkingDirectory: string;
    DirectoryName: string;
    Parameters: TArray<string>;
  end;

  TBrowserType = (btAuto, btFirefox, btChrome, btEdge, btBrave);

function NP_BrowserName(Browser: TBrowserType): string;

function NP_Init(ConfigPath: PAnsiChar; LogFn: TNP_LogProc): Integer; stdcall; external 'Nexon3PAPI.dll' name 'Nexon3PAPI_Init';
procedure NP_Shutdown; stdcall; external 'Nexon3PAPI.dll' name 'Nexon3PAPI_Shutdown';

function NP_GetDeviceId(const Tag: string): string;
function NP_LoginEmailPassword(const Email, Password, DeviceId: string): string;
function NP_LoginOTP(const MfaKey, Otp, DeviceId: string): string;
function NP_ExchangeTpa(const TpaSession, DeviceId: string): string;
function NP_AutoLoginRefresh(const Cookies, DeviceId: string): string;
function NP_CheckSession(const Cookies: string; out HttpStatus, NexonCode: Integer): Boolean; overload;
function NP_CheckSession(const Cookies: string; out HttpStatus: Integer): Boolean; overload;
function NP_GetPassport(const Cookies: string; ProductId: Integer): string;
function NP_FetchGameConfig(const Cookies: string; ProductId: Integer): TGameConfig;
function NP_CheckPlayable(const Cookies: string; ProductId: Integer; out HttpStatus: Integer): Boolean;
function NP_FetchManifestHash(const Cookies: string; ProductId: Integer): string;
function NP_FetchAccess(const Cookies: string; ProductId: Integer): string;
function NP_FetchAccount(const Cookies: string): string;
function NP_LaunchGame(const Cookies: string; ProductId: Integer; const GameExePath, UserNo: string; LogFn: TNP_LogProcDelphi; ExitFn: TNP_ExitProcDelphi): Integer;
function NP_LaunchStatus: Boolean;
function NP_RunPatcher(const ManifestHash, InstallRoot: string; ProductId: Integer; ForceAll, ScanOnly: Boolean; CancelFlag: PInteger; NeedCount: PInteger; ProgressFn: TNP_ProgressProcDelphi; LogFn: TNP_LogProcDelphi): Integer;
function NP_GetCookies(Browser: TBrowserType): string;
function NP_GetNexonCookies(out Cookies: string; out Browser: TBrowserType): Boolean;
function NP_GetFirefoxCookies(out Cookies: string): Boolean;
function NP_ExtractCookie(const CookieStr, Name: string): string;

implementation

// ============================================================================
// Low-level DLL declarations
// ============================================================================

function Nexon3PAPI_GetDeviceId(Tag: PWideChar; OutBuf: PWideChar; OutBufLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_LoginEmailPw(Email, Password, DeviceId: PWideChar; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_LoginOTP(MfaKey, OtpCode, DeviceId: PWideChar; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_ExchangeTpa(TpaToken, DeviceId: PWideChar; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_AutoLogin(InCookie, DeviceId: PWideChar; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_CheckSession(InCookie: PWideChar; out HttpStatus: Integer; out NexonCode: Integer): LongBool; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_GetPassport(InCookie: PWideChar; ProductId: Integer; OutPassport: PWideChar; OutPassportLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_FetchGameConfig(InCookie: PWideChar; ProductId: Integer; OutJson: PWideChar; OutJsonLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_CheckPlayable(InCookie: PWideChar; ProductId: Integer; out HttpStatus: Integer): LongBool; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_FetchManifestHash(InCookie: PWideChar; ProductId: Integer; OutHash: PWideChar; OutHashLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_FetchAccess(InCookie: PWideChar; ProductId: Integer; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_FetchAccount(InCookie: PWideChar; OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_LaunchGame(InCookie, InPassport, GameExe, UserNo: PWideChar; ProductId: Integer; LogFn: TNP_LogProc; ExitFn: TNP_ExitProc): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_LaunchStatus: LongBool; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_RunPatcher(ManifestHash, InstallRoot: PWideChar; ProductId: Integer; ForceAll: LongBool; CancelFlag: PInteger; ScanOnly: LongBool; NeedCount: PInteger; ProgressFn: TNP_ProgressProc; LogFn: TNP_LogProc): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_GetCookies(BrowserType: Integer; OutJson: PWideChar; OutJsonLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';
function Nexon3PAPI_ExtractCookie(CookieStr, Name: PWideChar; OutVal: PWideChar; OutValLen: Integer): Integer; stdcall; external 'Nexon3PAPI.dll';

const
  BUF_SIZE = 65536;

var
  Bridge_LogFn: TNP_LogProcDelphi;
  Bridge_ExitFn: TNP_ExitProcDelphi;
  Bridge_ProgressFn: TNP_ProgressProcDelphi;

// stdcall bridge procs — convert DLL callbacks to Delphi anonymous methods
procedure LogBridge(Msg: PAnsiChar); stdcall;
begin
  if Assigned(Bridge_LogFn) then Bridge_LogFn(string(AnsiString(Msg)));
end;

procedure ExitBridge; stdcall;
begin
  if Assigned(Bridge_ExitFn) then Bridge_ExitFn();
end;

procedure ProgressBridge(Current, Total: Integer; FileName: PAnsiChar); stdcall;
begin
  if Assigned(Bridge_ProgressFn) then Bridge_ProgressFn(Current, Total, string(AnsiString(FileName)));
end;

function StrArg(const S: string): PWideChar;
begin
  if S = '' then Result := nil
  else Result := PWideChar(S);
end;

// ============================================================================
// Delphi-friendly wrappers
// ============================================================================

function NP_GetDeviceId(const Tag: string): string;
var
  Buf: array[0..127] of WideChar;
begin
  if Nexon3PAPI_GetDeviceId(StrArg(Tag), Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    Result := '';
end;

function NP_LoginEmailPassword(const Email, Password, DeviceId: string): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
  Code: Integer;
begin
  Code := Nexon3PAPI_LoginEmailPw(StrArg(Email), StrArg(Password), StrArg(DeviceId), Buf, Length(Buf));
  case Code of
    NP_OK: Result := string(Buf);
    NP_MFARequired:
    begin
      var Ex := ENP_MfaRequired.Create('MFA required');
      Ex.MfaKey := string(Buf);
      raise Ex;
    end;
    NP_CaptchaRequired: raise ENP_CaptchaRequired.Create('Captcha required');
  else
    raise ENP_LoginFailed.Create('Login failed');
  end;
end;

function NP_LoginOTP(const MfaKey, Otp, DeviceId: string): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_LoginOTP(StrArg(MfaKey), StrArg(Otp), StrArg(DeviceId), Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    raise ENP_LoginFailed.Create('OTP failed');
end;

function NP_ExchangeTpa(const TpaSession, DeviceId: string): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_ExchangeTpa(StrArg(TpaSession), StrArg(DeviceId), Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    Result := '';
end;

function NP_AutoLoginRefresh(const Cookies, DeviceId: string): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_AutoLogin(StrArg(Cookies), StrArg(DeviceId), Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    Result := '';
end;

function NP_CheckSession(const Cookies: string; out HttpStatus, NexonCode: Integer): Boolean;
begin
  HttpStatus := 0;
  NexonCode := 0;
  Result := Nexon3PAPI_CheckSession(StrArg(Cookies), HttpStatus, NexonCode);
end;

function NP_CheckSession(const Cookies: string; out HttpStatus: Integer): Boolean;
var
  Dummy: Integer;
begin
  HttpStatus := 0;
  Dummy := 0;
  Result := Nexon3PAPI_CheckSession(StrArg(Cookies), HttpStatus, Dummy);
end;

function NP_GetPassport(const Cookies: string; ProductId: Integer): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_GetPassport(StrArg(Cookies), ProductId, Buf, Length(Buf)) <> NP_OK then
    raise ENP_TicketError.Create('Failed to get passport');
  Result := string(Buf);
end;

function NP_FetchGameConfig(const Cookies: string; ProductId: Integer): TGameConfig;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
  S: string;
  J: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Result.ExecutablePath := '';
  Result.WorkingDirectory := '';
  Result.DirectoryName := '';
  SetLength(Result.Parameters, 0);
  if Nexon3PAPI_FetchGameConfig(StrArg(Cookies), ProductId, Buf, Length(Buf)) <> NP_OK then
    raise ENP_UpdateCheckError.Create('Failed to get game config');
  S := string(Buf);
  J := TJSONObject.ParseJSONValue(S) as TJSONObject;
  if J = nil then raise ENP_UpdateCheckError.Create('Invalid game config JSON');
  try
    J.TryGetValue('executablePath', Result.ExecutablePath);
    J.TryGetValue('workingDirectory', Result.WorkingDirectory);
    J.TryGetValue('directoryName', Result.DirectoryName);
    if J.TryGetValue<TJSONArray>('parameters', Arr) then
    begin
      SetLength(Result.Parameters, Arr.Count);
      for I := 0 to Arr.Count - 1 do
        Result.Parameters[I] := Arr[I].Value;
    end;
  finally
    J.Free;
  end;
end;

function NP_CheckPlayable(const Cookies: string; ProductId: Integer; out HttpStatus: Integer): Boolean;
begin
  HttpStatus := 0;
  Result := Nexon3PAPI_CheckPlayable(StrArg(Cookies), ProductId, HttpStatus);
end;

function NP_FetchManifestHash(const Cookies: string; ProductId: Integer): string;
var
  Buf: array[0..255] of WideChar;
begin
  if Nexon3PAPI_FetchManifestHash(StrArg(Cookies), ProductId, Buf, Length(Buf)) <> NP_OK then
    raise ENP_UpdateCheckError.Create('Failed to get manifest hash');
  Result := string(Buf);
end;

function NP_FetchAccess(const Cookies: string; ProductId: Integer): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_FetchAccess(StrArg(Cookies), ProductId, Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    Result := Cookies;
end;

function NP_FetchAccount(const Cookies: string): string;
var
  Buf: array[0..BUF_SIZE - 1] of WideChar;
begin
  if Nexon3PAPI_FetchAccount(StrArg(Cookies), Buf, Length(Buf)) = NP_OK then
    Result := string(Buf)
  else
    Result := Cookies;
end;

function ExeDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  SetString(Result, Buf, GetModuleFileName(GetModuleHandle(nil), Buf, Length(Buf)));
  Result := ExtractFileDir(Result);
end;

function NP_LaunchGame(const Cookies: string; ProductId: Integer; const GameExePath, UserNo: string; LogFn: TNP_LogProcDelphi; ExitFn: TNP_ExitProcDelphi): Integer;
begin
  Bridge_LogFn := LogFn;
  Bridge_ExitFn := ExitFn;
  Result := Nexon3PAPI_LaunchGame(StrArg(Cookies), nil, StrArg(GameExePath), StrArg(UserNo), ProductId, LogBridge, ExitBridge);
end;

function NP_LaunchStatus: Boolean;
begin
  Result := Nexon3PAPI_LaunchStatus;
end;

function NP_RunPatcher(const ManifestHash, InstallRoot: string; ProductId: Integer; ForceAll, ScanOnly: Boolean; CancelFlag: PInteger; NeedCount: PInteger; ProgressFn: TNP_ProgressProcDelphi; LogFn: TNP_LogProcDelphi): Integer;
begin
  Bridge_LogFn := LogFn;
  Bridge_ProgressFn := ProgressFn;
  Result := Nexon3PAPI_RunPatcher(StrArg(ManifestHash), StrArg(InstallRoot), ProductId, ForceAll, CancelFlag, ScanOnly, NeedCount, ProgressBridge, LogBridge);
end;

function NP_GetCookies(Browser: TBrowserType): string;
var
  B: TBrowserType;
begin
  NP_GetNexonCookies(Result, B);
end;

function NP_ExtractCookie(const CookieStr, Name: string): string;
begin
  Result := uBrowserCookies.ExtractCookieValue(CookieStr, Name);
end;

function NP_GetNexonCookies(out Cookies: string; out Browser: TBrowserType): Boolean;
var
  RawBrowser: uBrowserCookies.TBrowserType;
begin
  Result := uBrowserCookies.GetNexonCookies(Cookies, RawBrowser);
  case RawBrowser of
    uBrowserCookies.btFirefox: Browser := btFirefox;
    uBrowserCookies.btChrome:  Browser := btChrome;
    uBrowserCookies.btEdge:    Browser := btEdge;
    uBrowserCookies.btBrave:   Browser := btBrave;
  else Browser := btAuto;
  end;
end;

function NP_GetFirefoxCookies(out Cookies: string): Boolean;
begin
  Result := uBrowserCookies.GetNexonCookiesFromFirefox(Cookies);
end;

function NP_BrowserName(Browser: TBrowserType): string;
begin
  case Browser of
    btFirefox: Result := 'Firefox';
    btChrome:  Result := 'Chrome';
    btEdge:    Result := 'Edge';
    btBrave:   Result := 'Brave';
  else Result := 'Browser';
  end;
end;

end.
