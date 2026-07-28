unit Nexon3PAPIImpl;

interface

uses
  System.SysUtils;

const
  Nexon3PAPI_OK              =  0;
  Nexon3PAPI_MFARequired     =  1;
  Nexon3PAPI_CaptchaRequired =  2;
  Nexon3PAPI_ErrGeneric      = -1;
  Nexon3PAPI_ErrNotInit      = -2;
  Nexon3PAPI_ErrBadParam     = -3;
  Nexon3PAPI_ErrNetwork      = -4;
  Nexon3PAPI_ErrBufSmall     = -5;
  Nexon3PAPI_ErrSession      = -401;

type
  TNP_LogProc = procedure(Msg: PAnsiChar); stdcall;
  TNP_ExitProc = procedure; stdcall;
  TNP_ProgressProc = procedure(Current, Total: Integer; FileName: PAnsiChar); stdcall;

function Nexon3PAPI_Init(ConfigPath: PAnsiChar; LogFn: TNP_LogProc): Integer; stdcall;
procedure Nexon3PAPI_Shutdown; stdcall;

function Nexon3PAPI_GetDeviceId(Tag: PWideChar; OutBuf: PWideChar; OutBufLen: Integer): Integer; stdcall;

function Nexon3PAPI_LoginEmailPw(Email, Password, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_LoginOTP(MfaKey, OtpCode, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_ExchangeTpa(TpaToken, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_AutoLogin(InCookie, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_CheckSession(InCookie: PWideChar;
  out HttpStatus: Integer; out NexonCode: Integer): LongBool; stdcall;

function Nexon3PAPI_GetPassport(InCookie: PWideChar; ProductId: Integer;
  OutPassport: PWideChar; OutPassportLen: Integer): Integer; stdcall;

function Nexon3PAPI_FetchGameConfig(InCookie: PWideChar; ProductId: Integer;
  OutJson: PWideChar; OutJsonLen: Integer): Integer; stdcall;

function Nexon3PAPI_CheckPlayable(InCookie: PWideChar; ProductId: Integer;
  out HttpStatus: Integer): LongBool; stdcall;

function Nexon3PAPI_FetchManifestHash(InCookie: PWideChar; ProductId: Integer;
  OutHash: PWideChar; OutHashLen: Integer): Integer; stdcall;

function Nexon3PAPI_FetchAccess(InCookie: PWideChar; ProductId: Integer;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_FetchAccount(InCookie: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;

function Nexon3PAPI_LaunchGame(InCookie, InPassport, GameExe, UserNo: PWideChar;
  ProductId: Integer; LogFn: TNP_LogProc; ExitFn: TNP_ExitProc): Integer; stdcall;

function Nexon3PAPI_LaunchStatus: LongBool; stdcall;
// Patcher + Cookies handled by EXE's uNxlPatcher/uBrowserCookies directly.

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.JSON,
  System.Hash,
  System.NetEncoding,
  System.Threading,
  System.SyncObjs,
  uNexonAPI,
  uDeviceId,
  uGameLaunch,
  uPipeServer,
  uProtocol;

// Local ExtractCookieValue — pure string parser, no FireDAC dependency.
function ExtractCookieVal(const Cookies, Name: string): string;
var
  Part: string;
  EqPos: Integer;
begin
  Result := '';
  for Part in Cookies.Split([';']) do
  begin
    EqPos := Pos('=', Trim(Part));
    if EqPos <= 0 then Continue;
    if SameText(Trim(Copy(Trim(Part), 1, EqPos - 1)), Name) then
    begin
      Result := Trim(Copy(Trim(Part), EqPos + 1, MaxInt));
      Exit;
    end;
  end;
end;

type
  TGameExitHelper = class
    class procedure HandleGameExit(Sender: TObject);
  end;

var
  GInitOK: Boolean = False;
  GConfigPath: string = '';
  GLogFn: TNP_LogProc = nil;
  GLauncher: TGameLauncher = nil;
  GLauncherLock: TObject = nil;
  GOnGameExit: TProc = nil;

class procedure TGameExitHelper.HandleGameExit(Sender: TObject);
begin
  if Assigned(GOnGameExit) then GOnGameExit;
end;

procedure CleanupLauncher;
begin
  FreeAndNil(GLauncher);
end;

procedure Log(const Msg: string);
begin
  if Assigned(GLogFn) then
    GLogFn(PAnsiChar(AnsiString(Msg)));
end;

procedure StrToBuf(const S: string; Buf: PWideChar; BufLen: Integer);
var
  Len: Integer;
begin
  if (Buf = nil) or (BufLen <= 0) then Exit;
  Len := Length(S);
  if Len >= BufLen then Len := BufLen - 1;
  if Len > 0 then Move(PWideChar(S)^, Buf^, Len * SizeOf(WideChar));
  Buf[Len] := #0;
end;

// ============================================================================
// INIT / SHUTDOWN
// ============================================================================

function Nexon3PAPI_Init(ConfigPath: PAnsiChar; LogFn: TNP_LogProc): Integer; stdcall;
begin
  if ConfigPath = nil then Exit(Nexon3PAPI_ErrBadParam);
  GConfigPath := string(AnsiString(ConfigPath));
  GLogFn := LogFn;
  GLauncherLock := TObject.Create;
  Log('Nexon3PAPI_Init: ' + GConfigPath);
  GInitOK := True;
  Result := Nexon3PAPI_OK;
end;

procedure Nexon3PAPI_Shutdown; stdcall;
begin
  GInitOK := False;
  TMonitor.Enter(GLauncherLock);
  try
    CleanupLauncher;
  finally
    TMonitor.Exit(GLauncherLock);
  end;
  FreeAndNil(GLauncherLock);
  GLogFn := nil;
end;

// ============================================================================
// DEVICE ID
// ============================================================================

function Nexon3PAPI_GetDeviceId(Tag: PWideChar; OutBuf: PWideChar; OutBufLen: Integer): Integer; stdcall;
var
  S: string;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  if OutBuf = nil then Exit(Nexon3PAPI_ErrBadParam);
  try
    S := GetDeviceId(string(Tag));
    if Length(S) >= OutBufLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutBuf, OutBufLen);
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('GetDeviceId: ' + E.Message); Result := Nexon3PAPI_ErrGeneric; end;
  end;
end;

// ============================================================================
// LOGIN - EMAIL / PASSWORD
// ============================================================================

function Nexon3PAPI_LoginEmailPw(Email, Password, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  if (Email = nil) or (Password = nil) or (DeviceId = nil) or (OutCookie = nil) then Exit(Nexon3PAPI_ErrBadParam);
  try
    var S := LoginEmailPassword(string(Email), string(Password), string(DeviceId));
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: ELoginMfaRequired do begin
      StrToBuf(E.MfaKey, OutCookie, OutCookieLen);
      Result := Nexon3PAPI_MFARequired;
    end;
    on E: ELoginCaptchaRequired do begin
      Result := Nexon3PAPI_CaptchaRequired;
    end;
    on E: ELoginFailed do begin
      Log('LoginEmailPw failed: ' + E.Message);
      Result := Nexon3PAPI_ErrGeneric;
    end;
    on E: Exception do begin
      Log('LoginEmailPw exception: ' + E.Message);
      Result := Nexon3PAPI_ErrNetwork;
    end;
  end;
end;

function Nexon3PAPI_LoginOTP(MfaKey, OtpCode, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var S := LoginOTP(string(MfaKey), string(OtpCode), string(DeviceId));
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: ELoginFailed do begin Log('OTP failed: ' + E.Message); Result := Nexon3PAPI_ErrGeneric; end;
    on E: Exception do begin Log('OTP exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// TPA EXCHANGE
// ============================================================================

function Nexon3PAPI_ExchangeTpa(TpaToken, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
var
  HttpStatus: Integer;
  S: string;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    HttpStatus := 0;
    S := ExchangeTpaForNxLSession(string(TpaToken), string(DeviceId), HttpStatus);
    if S = '' then begin
      Log(Format('TPA exchange failed (HTTP %d)', [HttpStatus]));
      Exit(Nexon3PAPI_ErrGeneric);
    end;
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('TPA exchange exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// AUTO LOGIN REFRESH
// ============================================================================

function Nexon3PAPI_AutoLogin(InCookie, DeviceId: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
var
  NxLSession: string;
  HttpStatus: Integer;
  S: string;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    NxLSession := ExtractCookieVal(string(InCookie), 'NxLSession');
    if NxLSession = '' then begin Log('AutoLogin: no NxLSession in cookie'); Exit(Nexon3PAPI_ErrBadParam); end;
    HttpStatus := 0;
    S := AutoLoginRefresh(NxLSession, string(DeviceId), HttpStatus);
    if S = '' then begin
      Log(Format('AutoLoginRefresh failed (HTTP %d)', [HttpStatus]));
      Exit(Nexon3PAPI_ErrGeneric);
    end;
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('AutoLogin exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// SESSION CHECK
// ============================================================================

function Nexon3PAPI_CheckSession(InCookie: PWideChar;
  out HttpStatus: Integer; out NexonCode: Integer): LongBool; stdcall;
begin
  HttpStatus := 0;
  NexonCode := 0;
  if not GInitOK then begin Result := False; Exit; end;
  try
    Result := CheckSessionValid(string(InCookie), HttpStatus, NexonCode);
  except
    on E: Exception do begin Log('CheckSession exception: ' + E.Message); Result := False; end;
  end;
end;

// ============================================================================
// PASSPORT
// ============================================================================

function Nexon3PAPI_GetPassport(InCookie: PWideChar; ProductId: Integer;
  OutPassport: PWideChar; OutPassportLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var S := FetchPassport(string(InCookie), IntToStr(ProductId));
    if S = '' then Exit(Nexon3PAPI_ErrGeneric);
    if Length(S) >= OutPassportLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutPassport, OutPassportLen);
    Result := Nexon3PAPI_OK;
  except
    on E: ETicketError do begin Log('Passport ticket error: ' + E.Message); Result := Nexon3PAPI_ErrGeneric; end;
    on E: Exception do begin Log('Passport exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// GAME CONFIG
// ============================================================================

function Nexon3PAPI_FetchGameConfig(InCookie: PWideChar; ProductId: Integer;
  OutJson: PWideChar; OutJsonLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var Config := FetchGameConfig(string(InCookie), ProductId);
    var J := TJSONObject.Create;
    try
      J.AddPair('executablePath', Config.ExecutablePath);
      J.AddPair('workingDirectory', Config.WorkingDirectory);
      J.AddPair('directoryName', Config.DirectoryName);
      var Arr := TJSONArray.Create;
      for var P in Config.Parameters do Arr.Add(P);
      J.AddPair('parameters', Arr);
      var S := J.ToJSON;
      if Length(S) >= OutJsonLen then Exit(Nexon3PAPI_ErrBufSmall);
      StrToBuf(S, OutJson, OutJsonLen);
    finally
      J.Free;
    end;
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('FetchGameConfig exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// CHECK PLAYABLE
// ============================================================================

function Nexon3PAPI_CheckPlayable(InCookie: PWideChar; ProductId: Integer;
  out HttpStatus: Integer): LongBool; stdcall;
begin
  HttpStatus := 0;
  if not GInitOK then begin Result := False; Exit; end;
  try
    Result := CheckPlayable(string(InCookie), IntToStr(ProductId), HttpStatus);
  except
    on E: Exception do begin Log('CheckPlayable exception: ' + E.Message); Result := False; end;
  end;
end;

// ============================================================================
// MANIFEST HASH
// ============================================================================

function Nexon3PAPI_FetchManifestHash(InCookie: PWideChar; ProductId: Integer;
  OutHash: PWideChar; OutHashLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var S := FetchManifestHash(string(InCookie), ProductId);
    if S = '' then Exit(Nexon3PAPI_ErrGeneric);
    if Length(S) >= OutHashLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutHash, OutHashLen);
    Result := Nexon3PAPI_OK;
  except
    on E: EUpdateCheckError do begin Log('ManifestHash failed: ' + E.Message); Result := Nexon3PAPI_ErrGeneric; end;
    on E: Exception do begin Log('ManifestHash exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// FETCH ACCESS
// ============================================================================

function Nexon3PAPI_FetchAccess(InCookie: PWideChar; ProductId: Integer;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var S := FetchAccess(string(InCookie), IntToStr(ProductId));
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('FetchAccess exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// FETCH ACCOUNT (merge Set-Cookie)
// ============================================================================

function Nexon3PAPI_FetchAccount(InCookie: PWideChar;
  OutCookie: PWideChar; OutCookieLen: Integer): Integer; stdcall;
begin
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  try
    var S := FetchAccountAndMerge(string(InCookie));
    if Length(S) >= OutCookieLen then Exit(Nexon3PAPI_ErrBufSmall);
    StrToBuf(S, OutCookie, OutCookieLen);
    Result := Nexon3PAPI_OK;
  except
    on E: Exception do begin Log('FetchAccount exception: ' + E.Message); Result := Nexon3PAPI_ErrNetwork; end;
  end;
end;

// ============================================================================
// PATCHER
// ============================================================================
// LAUNCH GAME
// ============================================================================

function Nexon3PAPI_LaunchGame(InCookie, InPassport, GameExe, UserNo: PWideChar;
  ProductId: Integer; LogFn: TNP_LogProc; ExitFn: TNP_ExitProc): Integer; stdcall;
var
  Cookies, GamePath, UNo: string;
  LocalLogFn: TNP_LogProc;
  LocalExitFn: TNP_ExitProc;
  Launcher: TGameLauncher;
begin
  Result := Nexon3PAPI_ErrGeneric;
  if not GInitOK then Exit(Nexon3PAPI_ErrNotInit);
  Cookies  := string(InCookie);
  GamePath := string(GameExe);
  UNo      := string(UserNo);
  LocalLogFn := LogFn;
  LocalExitFn := ExitFn;

  TMonitor.Enter(GLauncherLock);
  try
    CleanupLauncher;
    Launcher := TGameLauncher.Create;
    GOnGameExit := procedure
    begin
      if Assigned(LocalExitFn) then LocalExitFn;
      TMonitor.Enter(GLauncherLock);
      try
        FreeAndNil(GLauncher);
      finally
        TMonitor.Exit(GLauncherLock);
      end;
    end;
    Launcher.OnGameExit := TGameExitHelper.HandleGameExit;
    try
      Launcher.Launch(Cookies, ProductId, GamePath, UNo);
      GLauncher := Launcher;
      Result := Nexon3PAPI_OK;
    except
      on E: ETicketError do begin
        Launcher.Free;
        if Pos('401', E.Message) > 0 then Result := Nexon3PAPI_ErrSession
        else Result := Nexon3PAPI_ErrGeneric;
      end;
      on E: Exception do begin
        Launcher.Free;
        Log('LaunchGame error: ' + E.Message);
        if Assigned(LocalLogFn) then LocalLogFn(PAnsiChar(AnsiString(E.Message)));
        Result := Nexon3PAPI_ErrGeneric;
      end;
    end;
  finally
    TMonitor.Exit(GLauncherLock);
  end;
end;

function Nexon3PAPI_LaunchStatus: LongBool; stdcall;
begin
  if not GInitOK then begin Result := False; Exit; end;
  TMonitor.Enter(GLauncherLock);
  try
    Result := (GLauncher <> nil) and GLauncher.IsRunning;
  finally
    TMonitor.Exit(GLauncherLock);
  end;
end;

// ============================================================================

end.
