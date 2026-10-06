unit uNexonAPI;
(*
  Nexon HTTP API calls (NXL launcher 2024+).
  All REST endpoints at https://www.nexon.com/api/

  Passport : POST /api/passport/v2/passport   body: productId string
             -> data.passport  (substituted into /P: arg + named pipe)
  Config   : GET  /api/game-build/v1/configuration/games/[id]
             -> executablePath, parameter array with ${passport} template
  Branch   : GET  /api/game-build/v1/branch/games/[id]/public
             -> manifestUrl
  Access   : POST /api/game-auth2/v1/access   body: productId string
             -> isPlayable bool
*)

interface

uses
  System.SysUtils, System.Classes, System.DateUtils,
  System.StrUtils, System.Net.HttpClient, System.Net.URLClient, System.JSON,
  Winapi.Windows;

type
  ETicketError          = class(Exception);
  EUpdateCheckError     = class(Exception);
  ELoginFailed          = class(Exception);
  ELoginCaptchaRequired = class(Exception);
  ELoginMfaRequired     = class(Exception)
  public
    MfaKey:  string;
    MfaType: string;
  end;

  // Game not playable / under maintenance (from /game-auth2/v1/access isPlayable).
  EGamePlayableFailed = class(Exception);

  TGameConfig = record
    ExecutablePath:   string;
    WorkingDirectory: string;
    DirectoryName:    string;
    Parameters:       TArray<string>;
  end;

  TBranchInfo = record
    BranchName:  string;
    ManifestUrl: string;
    ReleaseDate: string;
    ServiceId:   string;
  end;

  // Parsed from POST /api/game-auth2/v1/access response body.
  // isPlayable=False is the official launcher's verdict for "under maintenance".
  TAccessInfo = record
    HttpStatus:  Integer;    // HTTP status of the /access call (0 = no response)
    IsPlayable:  Boolean;
    IsDeveloper: Boolean;
    IpBlocked:   Boolean;
    IsMinor:     Boolean;
    IsUnder13:   Boolean;
    Required2FA: Boolean;
  end;

function FetchPassport(const Cookies: string; const ProductId: string): string;
function FetchGameConfig(const Cookies: string; ProductId: Integer): TGameConfig;
function CheckPlayable(const Cookies: string; const ProductId: string; out HttpStatus: Integer): Boolean;
function FetchBranchInfo(const Cookies: string; ProductId: Integer): TBranchInfo;
function FetchManifestHash(const Cookies: string; ProductId: Integer): string;
function FetchTicket(const Cookies: string; ProductId: Integer): string; // alias

// Exchange TpaSession cookie (set by browser login page) for NxLSession + AToken.
// Returns 'NxLSession=...; AToken=...; NexonUserID=...' cookie string on success, '' on failure.
// HttpStatus receives the HTTP response code (0 if no response received).
// NexonCode receives the x-arena-web-errorcode header value on failure (0 if none/not applicable).
function ExchangeTpaForNxLSession(const TpaSession, DeviceId: string;
  out HttpStatus: Integer; out NexonCode: Integer): string;

// Check if stored NxLSession is still valid via GET /api/account/v1/account.
// Returns True if HTTP 200 (session valid), False if 401/403/other (expired).
// HttpStatus receives the HTTP response code.
// NexonCode receives the x-arena-web-errorcode header value (0 if absent).
function ExtractNexonErrorCode(const Resp: IHTTPResponse): Integer;
function CheckSessionValid(const Cookies: string; out HttpStatus: Integer; out NexonCode: Integer): Boolean; overload;
function CheckSessionValid(const Cookies: string; out HttpStatus: Integer): Boolean; overload;

// Call /api/game-auth2/v1/access before CheckPlayable/FetchPassport (official launcher order).
// Returns the original Cookies string merged with any Set-Cookie headers from the response.
function FetchAccess(const Cookies: string; const ProductId: string): string; overload;

// Same, but also parses the access verdict (isPlayable etc.) into AccessInfo.
// isPlayable=False means the game is down/under maintenance — surface it before launching.
// Raises EGamePlayableFailed when the game is not playable.
function FetchAccess(const Cookies: string; const ProductId: string;
  out AccessInfo: TAccessInfo): string; overload;

// Call GET /api/account/v1/account and merge Set-Cookie headers.
// Official launcher calls this BEFORE access to establish session state.
function FetchAccountAndMerge(const Cookies: string): string;

// Email/password login. Returns NxLSession cookie string on success.
// Raises ELoginMfaRequired (HTTP 206), ELoginCaptchaRequired, or ELoginFailed.
function LoginEmailPassword(const Email, Password, DeviceId: string): string;

// Submit OTP after MFA challenge. Returns NxLSession cookie string on success.
// Raises ELoginFailed on bad OTP.
function LoginOTP(const MfaKey, Otp, DeviceId: string): string;

// Refresh session via autologin (email/password accounts only — TPA returns error 20182).
// Returns new cookie string on success, '' on failure.
// NxLExpiry receives the NxLSession Max-Age as a TDateTime (0 if unknown).
function AutoLoginRefresh(const NxLSession, DeviceId: string;
  out HttpStatus: Integer; out NxLExpiry: TDateTime): string;

// Returns the NxLSession expiry TDateTime captured by the most recent login call.
// 0 if the last login did not return a Max-Age (browser-captured sessions, unknown).
function LastNxLExpiry: TDateTime;

// Set the expected NxLSession expiry manually (for browser-direct paths that skip
// the exchange endpoint and therefore have no loginSessionExpiresIn in the response).
// Pass 0 to clear.
procedure SetLastNxLExpiry(Expiry: TDateTime);

implementation

const
  BASE_URL    = 'https://www.nexon.com/api';
  UA          = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) NexonLauncher/4.7.9 Chrome/108.0.5359.215 Electron/22.3.27 Safari/537.36';
  ARENA_VER   = 'nxl-v2.71.0-c228c50d';

var
  GSessionId:    string;
  GLastNxLExpiry: TDateTime;

// Extract a single value from a 'Name=Value; Name2=Value2' cookie string.
function ExtractCookieVal(const Cookies, Name: string): string;
var
  Part:  string;
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

// Returns Max-Age seconds for CookieName from CookieManager or raw Set-Cookie header.
// Returns 0 if not found or cookie has no Max-Age.
function ParseCookieMaxAge(const Resp: IHTTPResponse; const Http: THTTPClient;
  const CookieName: string): Int64;
var
  H:     TNameValuePair;
  Parts: TArray<string>;
  Part:  string;
  MA:    Int64;
  NV:    string;
  EqPos: Integer;
  I:     Integer;
  Secs:  Int64;
begin
  Result := 0;

  if (Http <> nil) and (Http.CookieManager <> nil) then
    for var C in Http.CookieManager.Cookies do
      if SameText(C.Name, CookieName) and (C.Expires > 2) then
      begin
        Secs := Round((C.Expires - Now) * SecsPerDay);
        if Secs > 0 then Exit(Secs) else Exit(0);
      end;

  for H in Resp.Headers do
  begin
    if not SameText(H.Name, 'Set-Cookie') then Continue;
    Parts := H.Value.Split([';']);
    if Length(Parts) = 0 then Continue;
    NV    := Trim(Parts[0]);
    EqPos := Pos('=', NV);
    if (EqPos <= 0) or not SameText(Trim(Copy(NV, 1, EqPos - 1)), CookieName) then Continue;
    for I := 1 to High(Parts) do
    begin
      Part := Trim(Parts[I]);
      if SameText(Copy(Part, 1, 8), 'Max-Age=') then
        if TryStrToInt64(Trim(Copy(Part, 9, MaxInt)), MA) and (MA > 0) then
          Exit(MA);
    end;
    Break;
  end;
end;

function MakeHttp(const Cookies: string): THTTPClient;
begin
  Result := THTTPClient.Create;
  Result.CookieManager := nil;
  Result.CustomHeaders['User-Agent']         := UA;
  Result.CustomHeaders['Accept']             := 'application/json, text/plain, */*';
  Result.CustomHeaders['Content-Type']       := 'application/json';
  Result.CustomHeaders['x-arena-fe-version'] := ARENA_VER;
  Result.CustomHeaders['x-nxl-session-id']  := GSessionId;
  Result.CustomHeaders['Accept-Language']    := 'en-GB';
  if Cookies <> '' then
    Result.CustomHeaders['Cookie'] := Cookies;
end;

// Game-auth endpoints require game-scoped AToken (g_AToken).
// Falls back to AToken if g_AToken absent (email/password sessions).
function GameToken(const Cookies: string): string;
begin
  Result := ExtractCookieVal(Cookies, 'g_AToken');
  if Result = '' then
    Result := ExtractCookieVal(Cookies, 'AToken');
end;

function JsonBody(const S: string): TStringStream;
begin
  Result := TStringStream.Create(S, TEncoding.UTF8, False);
end;

// ---------------------------------------------------------------------------

function FetchPassport(const Cookies: string; const ProductId: string): string;
var
  Http:   THTTPClient;
  Body:   TStringStream;
  Resp:   IHTTPResponse;
  J:      TJSONObject;
begin
  Http   := MakeHttp(Cookies);
  var GToken := GameToken(Cookies);
  if GToken <> '' then
    Http.CustomHeaders['Authorization'] := 'Bearer ' + GToken;
  Body := JsonBody(Format('{"productId":"%s"}', [ProductId]));
  try
    Resp := Http.Post(BASE_URL + '/passport/v2/passport', Body);
  finally
    Body.Free;
    Http.Free;
  end;

  if Resp.StatusCode = 401 then
    raise ETicketError.Create('Passport HTTP 401: authentication required');
  if Resp.StatusCode <> 200 then
    raise ETicketError.CreateFmt('Passport HTTP %d', [Resp.StatusCode]);

  J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
  if J = nil then raise ETicketError.Create('Invalid passport JSON');
  try
    if not J.TryGetValue<string>('passport', Result) or (Result = '') then
      raise ETicketError.Create('Passport response did not contain a passport');
  finally
    J.Free;
  end;
end;

function FetchGameConfig(const Cookies: string; ProductId: Integer): TGameConfig;
var
  Http:   THTTPClient;
  Resp:   IHTTPResponse;
  J:      TJSONObject;
  JArr:   TJSONArray;
  I:      Integer;
  AToken: string;
begin
  Http   := MakeHttp(Cookies);
  AToken := ExtractCookieVal(Cookies, 'AToken');
  if AToken <> '' then
    Http.CustomHeaders['Authorization'] := 'Bearer ' + AToken;
  try
    Resp := Http.Get(Format(BASE_URL + '/game-build/v1/configuration/games/%d', [ProductId]));
  finally
    Http.Free;
  end;

  if Resp.StatusCode <> 200 then
    raise EUpdateCheckError.CreateFmt('HTTP %d fetching game config', [Resp.StatusCode]);

  J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
  if J = nil then raise EUpdateCheckError.Create('Invalid game config JSON');
  try
    Result.ExecutablePath   := J.GetValue<string>('executablePath',   'client.exe');
    Result.WorkingDirectory := J.GetValue<string>('workingDirectory', '');
    Result.DirectoryName    := J.GetValue<string>('directoryName',    '');
    JArr := J.GetValue('parameter') as TJSONArray;
    if JArr <> nil then
    begin
      SetLength(Result.Parameters, JArr.Count);
      for I := 0 to JArr.Count - 1 do
        Result.Parameters[I] := JArr.Items[I].Value;
    end;
  finally
    J.Free;
  end;
end;

function CheckPlayable(const Cookies: string; const ProductId: string; out HttpStatus: Integer): Boolean;
var
  Http: THTTPClient;
  Body: TStringStream;
  Resp: IHTTPResponse;
begin
  HttpStatus := 0;
  Http   := MakeHttp(Cookies);
  // /playable is Cookie-only per NEXON_AUTH — no Bearer header.
  Body := JsonBody(Format('{"productId":"%s"}', [ProductId]));
  try
    Resp       := Http.Post(BASE_URL + '/game-auth2/v1/playable', Body);
    HttpStatus := Resp.StatusCode;
  finally
    Body.Free;
    Http.Free;
  end;
  Result := Resp.StatusCode <> 400;
end;

function FetchBranchInfo(const Cookies: string; ProductId: Integer): TBranchInfo;
var
  Http:   THTTPClient;
  Resp:   IHTTPResponse;
  J:      TJSONObject;
  AToken: string;
begin
  Http   := MakeHttp(Cookies);
  AToken := ExtractCookieVal(Cookies, 'AToken');
  if AToken <> '' then
    Http.CustomHeaders['Authorization'] := 'Bearer ' + AToken;
  try
    Resp := Http.Get(
      Format(BASE_URL + '/game-build/v1/branch/games/%d/public', [ProductId]));
  finally
    Http.Free;
  end;

  if Resp.StatusCode <> 200 then
    raise EUpdateCheckError.CreateFmt('HTTP %d fetching branch info', [Resp.StatusCode]);

  J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
  if J = nil then raise EUpdateCheckError.Create('Invalid branch JSON');
  try
    Result.BranchName  := J.GetValue<string>('branchName',  '');
    Result.ManifestUrl := J.GetValue<string>('manifestUrl', '');
    Result.ReleaseDate := J.GetValue<string>('releaseDate', '');
    Result.ServiceId   := J.GetValue<string>('serviceId',   '');
  finally
    J.Free;
  end;
end;

// The game version id must arrive over authenticated HTTPS from Nexon. If that
// is not possible, updating is refused with an explanation rather than falling
// back to plain HTTP. The id names a content-addressed manifest that the patcher
// verifies by SHA1, so a valid id is enough to authenticate the whole update.
function SecureManifestUrl(const Url: string): string;
const
  DISABLED = 'Secure game updating is unavailable: Nexon returned a version address that is not an HTTPS Nexon server (%s). ' +
             'Updating through Rua is disabled; use Nexon Launcher to update the game.';
var
  U:    TURI;
  Host: string;
begin
  try
    U := TURI.Create(Trim(Url));
  except
    raise EUpdateCheckError.CreateFmt(DISABLED, [Url]);
  end;
  // Nexon publishes this address as http://; request the same resource over TLS.
  if SameText(U.Scheme, 'http') then U.Scheme := 'https';
  Host := LowerCase(U.Host);
  if not SameText(U.Scheme, 'https') or (U.Username <> '') or
     not ((Host = 'nexon.net') or Host.EndsWith('.nexon.net') or
          (Host = 'nexon.com') or Host.EndsWith('.nexon.com')) then
    raise EUpdateCheckError.CreateFmt(DISABLED, [Url]);
  if (U.Port <> 443) and (U.Port <> 80) and (U.Port <> 0) and (U.Port <> -1) then
    raise EUpdateCheckError.CreateFmt(DISABLED, [Url]);
  U.Port := 443;
  Result := U.ToString;
end;

function FetchManifestHash(const Cookies: string; ProductId: Integer): string;
const
  UNAVAILABLE = 'Secure game updating is unavailable: Nexon''s version file could not be retrieved over HTTPS (%s). ' +
                'Updating through Rua is disabled until it can be; use Nexon Launcher to update the game.';
var
  Branch: TBranchInfo;
  Http:   THTTPClient;
  Resp:   IHTTPResponse;
  Url:    string;
begin
  Branch := FetchBranchInfo(Cookies, ProductId);
  if Branch.ManifestUrl = '' then
    raise EUpdateCheckError.Create('Nexon did not return a game version for this account. Use Nexon Launcher to update the game.');
  Url := SecureManifestUrl(Branch.ManifestUrl);

  // Manifest hash URL contains the actual PAK manifest filename — fetch it.
  Http := THTTPClient.Create;
  try
    Http.SecureProtocols := [THTTPSecureProtocol.TLS12, THTTPSecureProtocol.TLS13];
    // Follow redirects here, revalidating each hop, so none can leave HTTPS Nexon hosts.
    Http.HandleRedirects := False;
    for var Hop := 0 to 3 do
    begin
      try
        Resp := Http.Get(Url);
      except
        on E: Exception do
          raise EUpdateCheckError.CreateFmt(UNAVAILABLE, [E.Message]);
      end;
      case Resp.StatusCode of
        301, 302, 303, 307, 308:
          if Hop < 3 then
          begin
            var Location := Resp.HeaderValue['Location'];
            if Location = '' then
              raise EUpdateCheckError.CreateFmt(UNAVAILABLE, ['redirect without a location']);
            if Pos('://', Location) = 0 then
              Location := TURI.PathRelativeToAbs(Location, TURI.Create(Url));
            Url := SecureManifestUrl(Location);
            Continue;
          end;
      end;
      Break;
    end;
    if Resp.StatusCode <> 200 then
      raise EUpdateCheckError.CreateFmt(UNAVAILABLE, ['HTTP ' + IntToStr(Resp.StatusCode)]);
    Result := LowerCase(Trim(Resp.ContentAsString));
  finally
    Http.Free;
  end;
  var ValidId := Length(Result) = 40;
  for var C in Result do
    if not CharInSet(C, ['0'..'9', 'a'..'f']) then ValidId := False;
  if not ValidId then
    raise EUpdateCheckError.Create('Nexon returned an invalid game version id. Game updating through Rua is disabled; use Nexon Launcher.');
end;

function ParseAuthCookies(const Resp: IHTTPResponse;
  const Http: THTTPClient; const AllowedNames: array of string): string;
var
  SB:    TStringBuilder;
  H:     TNameValuePair;
  NV:    string;
  EqPos: Integer;
  CName: string;

  function Allowed(const N: string): Boolean;
  var S: string;
  begin
    for S in AllowedNames do
      if SameText(N, S) then Exit(True);
    Result := False;
  end;

begin
  SB := TStringBuilder.Create;
  try
    // Primary: Delphi CookieManager (captures Set-Cookie when WinHTTP cookie handling is disabled)
    if (Http <> nil) and (Http.CookieManager <> nil) then
      for var C in Http.CookieManager.Cookies do
      begin
        if not Allowed(C.Name) then Continue;
        if SB.Length > 0 then SB.Append('; ');
        SB.Append(C.Name + '=' + C.Value);
      end;

    // Fallback: raw Set-Cookie headers (some Delphi backends expose these)
    if SB.Length = 0 then
      for H in Resp.Headers do
      begin
        if not SameText(H.Name, 'Set-Cookie') then Continue;
        NV    := Trim(H.Value.Split([';'])[0]);
        EqPos := Pos('=', NV);
        if EqPos <= 0 then Continue;
        CName := Trim(Copy(NV, 1, EqPos - 1));
        if not Allowed(CName) then Continue;
        if SB.Length > 0 then SB.Append('; ');
        SB.Append(NV);
      end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function ExchangeTpaForNxLSession(const TpaSession, DeviceId: string;
  out HttpStatus: Integer; out NexonCode: Integer): string;
const
  NXL_CLIENT_ID = '7853644408';
  KEEP: array[0..5] of string = ('NxLSession','AToken','NxGUN','g_AToken','NexonUserID','id_token');
var
  Http:      THTTPClient;
  Body:      TStringStream;
  Resp:      IHTTPResponse;
  TZ:        TIME_ZONE_INFORMATION;
  LocalTime: Int64;
  TimeOff:   Integer;
  J:         TJSONObject;
  Hashed:    string;
begin
  Result     := '';
  HttpStatus := 0;
  NexonCode  := 0;
  if TpaSession = '' then Exit;

  GetTimeZoneInformation(TZ);
  LocalTime := DateTimeToUnix(TDateTime(Now), False) * 1000;
  TimeOff   := TZ.Bias;

  Http := THTTPClient.Create; // CookieManager stays active — captures Set-Cookie from response
  // Inject TpaSession via CookieManager so it generates the Cookie header without conflict
  Http.CookieManager.AddServerCookie(
    'TpaSession=' + TpaSession + '; path=/; domain=.nexon.com',
    'https://www.nexon.com/');
  Body := TStringStream.Create(
    Format('{"clientId":"%s","deviceId":"%s","localTime":%d,"timeOffset":%d,"autoLogin":true}',
      [NXL_CLIENT_ID, DeviceId, LocalTime, TimeOff]),
    TEncoding.UTF8, False);
  try
    Http.CustomHeaders['User-Agent']   := UA;
    Http.CustomHeaders['Content-Type'] := 'application/json';
    Http.CustomHeaders['Accept']       := 'application/json';
    Resp := Http.Post(BASE_URL + '/account/v1/no-auth/login/tpa/launcher', Body);

    HttpStatus := Resp.StatusCode;
    if Resp.StatusCode <> 200 then
    begin
      NexonCode := ExtractNexonErrorCode(Resp);
      Exit;
    end;

    Result := ParseAuthCookies(Resp, Http, KEEP);

    // hashedUserNo from JSON body if NexonUserID not already captured
    if Pos('NexonUserID', Result) = 0 then
    begin
      J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
      if J <> nil then try
        if J.TryGetValue<string>('hashedUserNo', Hashed) and (Hashed <> '') then
        begin
          if Result <> '' then Result := Result + '; ';
          Result := Result + 'NexonUserID=' + Hashed;
        end;
      finally J.Free; end;
    end;

  finally
    Body.Free;
    Http.Free;
  end;
end;

function ExtractNexonErrorCode(const Resp: IHTTPResponse): Integer;
var
  H: TNameValuePair;
begin
  Result := 0;
  for H in Resp.Headers do
    if SameText(H.Name, 'x-arena-web-errorcode') then
      try Result := StrToInt(Trim(H.Value)); except end;
end;

function CheckSessionValid(const Cookies: string; out HttpStatus: Integer; out NexonCode: Integer): Boolean;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
begin
  Result     := False;
  HttpStatus := 0;
  NexonCode  := 0;
  Http := MakeHttp(Cookies);
  var AToken := ExtractCookieVal(Cookies, 'AToken');
  if AToken <> '' then
    Http.CustomHeaders['Authorization'] := 'Bearer ' + AToken;
  try
    Resp       := Http.Get(BASE_URL + '/account/v1/account');
    HttpStatus := Resp.StatusCode;
    NexonCode  := ExtractNexonErrorCode(Resp);
    Result     := Resp.StatusCode = 200;
  finally
    Http.Free;
  end;
end;

function CheckSessionValid(const Cookies: string; out HttpStatus: Integer): Boolean;
var
  Dummy: Integer;
begin
  Result := CheckSessionValid(Cookies, HttpStatus, Dummy);
end;

// Calls GET /api/account/v1/account and merges Set-Cookie headers.
// Official launcher calls this BEFORE game-auth2/access to establish session state.
// Set-Cookie may contain refreshed AToken / g_AToken.
function FetchAccountAndMerge(const Cookies: string): string;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  H:    TNameValuePair;
  CV:   string;
  SP:   Integer;
begin
  Result := Cookies;
  Http := MakeHttp(Cookies);
  var GToken := GameToken(Cookies);
  if GToken <> '' then
    Http.CustomHeaders['Authorization'] := 'Bearer ' + GToken;
  try
    Resp := Http.Get(BASE_URL + '/account/v1/account');
    for H in Resp.Headers do
      if SameText(H.Name, 'Set-Cookie') then
      begin
        CV := H.Value;
        SP := Pos(';', CV);
        if SP > 0 then CV := Trim(Copy(CV, 1, SP - 1));
        if CV <> '' then
        begin
          Result := Result + '; ' + CV;
        end;
      end;
  finally
    Http.Free;
  end;
end;

function FetchAccess(const Cookies: string; const ProductId: string): string;
var
  Dummy: TAccessInfo;
begin
  Result := FetchAccess(Cookies, ProductId, Dummy);
end;

function FetchAccess(const Cookies: string; const ProductId: string;
  out AccessInfo: TAccessInfo): string;
var
  Http:     THTTPClient;
  Body:     TStringStream;
  Resp:     IHTTPResponse;
  H:        TNameValuePair;
  CookVal:  string;
  SemiPos:  Integer;
  J:        TJSONObject;
begin
  Result     := Cookies;
  AccessInfo.HttpStatus   := 0;
  AccessInfo.IsPlayable  := False;
  AccessInfo.IsDeveloper := False;
  AccessInfo.IpBlocked   := False;
  AccessInfo.IsMinor     := False;
  AccessInfo.IsUnder13   := False;
  AccessInfo.Required2FA := False;
  Http   := MakeHttp(Cookies);
  // Official launcher calls /game-auth2/v1/access with cookie-only auth (no Bearer).
  // Sending AToken Bearer here causes 401 when AToken is the wrong scope, which
  // prevents the server from returning refreshed Set-Cookie headers.
  Body := JsonBody(Format('{"productId":"%s"}', [ProductId]));
  try
    Resp   := Http.Post(BASE_URL + '/game-auth2/v1/access', Body);
    AccessInfo.HttpStatus := Resp.StatusCode;
    for H in Resp.Headers do
      if SameText(H.Name, 'Set-Cookie') then
      begin
        CookVal := H.Value;
        SemiPos := Pos(';', CookVal);
        if SemiPos > 0 then CookVal := Trim(Copy(CookVal, 1, SemiPos - 1));
        if CookVal <> '' then
        begin
          Result := Result + '; ' + CookVal;
        end;
      end;

    // Parse the access verdict. isPlayable=False => game down / under maintenance.
    // We must NOT require HTTP 200 here: the launcher gates on the body flag.
    if Resp.StatusCode = 200 then
    begin
      J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
      if J <> nil then
      try
        AccessInfo.IsPlayable  := J.GetValue<Boolean>('isPlayable',  False);
        AccessInfo.IsDeveloper := J.GetValue<Boolean>('isDeveloper', False);
        AccessInfo.IpBlocked   := J.GetValue<Boolean>('ipBlocked',   False);
        AccessInfo.IsMinor     := J.GetValue<Boolean>('isMinor',     False);
        AccessInfo.IsUnder13   := J.GetValue<Boolean>('isUnder13',   False);
        AccessInfo.Required2FA := J.GetValue<Boolean>('required2FA', False);
      finally
        J.Free;
      end;
    end;
  finally
    Body.Free;
    Http.Free;
  end;
end;

function FetchTicket(const Cookies: string; ProductId: Integer): string;
begin
  // Nexon migrated away from game-auth/v2/ticket (returns HTML 200 — dead).
  // Passport is the correct token for both named-pipe getProductTicket and /P: arg.
  // Requires CheckPlayable to have been called first (session flag set by Launch).
  Result := FetchPassport(Cookies, IntToStr(ProductId));
end;

// Build a JSON body string from a TJSONObject then free it.
function BuildJson(const Obj: TJSONObject): TStringStream;
var S: string;
begin
  S := Obj.ToJSON;
  Obj.Free;
  Result := TStringStream.Create(S, TEncoding.UTF8, False);
end;

// Collect NxLSession + related cookies from response, append hashedUserNo if present.
function CollectAuthCookies(const Resp: IHTTPResponse; const Http: THTTPClient;
  const BodyStr: string): string;
const
  KEEP: array[0..5] of string =
    ('NxLSession', 'AToken', 'NxGUN', 'g_AToken', 'NexonUserID', 'id_token');
var
  J:      TJSONObject;
  Hashed: string;
  MA:     Int64;
begin
  GLastNxLExpiry := 0;
  Result := ParseAuthCookies(Resp, Http, KEEP);
  if Pos('NexonUserID', Result) = 0 then
  begin
    J := TJSONObject.ParseJSONValue(BodyStr) as TJSONObject;
    if J <> nil then
    try
      if J.TryGetValue<string>('hashedUserNo', Hashed) and (Hashed <> '') then
      begin
        if Result <> '' then Result := Result + '; ';
        Result := Result + 'NexonUserID=' + Hashed;
      end;
    finally
      J.Free;
    end;
  end;
  if Pos('NxLSession', Result) > 0 then
  begin
    // Try body field first (Nexon always returns loginSessionExpiresIn in seconds).
    // Fall back to Set-Cookie Max-Age if body field absent.
    J := TJSONObject.ParseJSONValue(BodyStr) as TJSONObject;
    if J <> nil then
    try
      if J.TryGetValue<Int64>('loginSessionExpiresIn', MA) and (MA > 0) then
        GLastNxLExpiry := Now + MA / SecsPerDay;
    finally
      J.Free;
    end;
    if GLastNxLExpiry = 0 then
    begin
      MA := ParseCookieMaxAge(Resp, Http, 'NxLSession');
      if MA > 0 then
        GLastNxLExpiry := Now + MA / SecsPerDay;
    end;
  end;
end;

function LastNxLExpiry: TDateTime;
begin
  Result := GLastNxLExpiry;
end;

procedure SetLastNxLExpiry(Expiry: TDateTime);
begin
  GLastNxLExpiry := Expiry;
end;

function LoginEmailPassword(const Email, Password, DeviceId: string): string;
const
  CAPTCHA_CODES: array[0..2] of Integer = (1013, 70018, 70019);
var
  Http:      THTTPClient;
  Body:      TStringStream;
  Resp:      IHTTPResponse;
  BodyStr:   string;
  J:         TJSONObject;
  ErrCode:   Integer;
  MfaEx:     ELoginMfaRequired;
  JObj:      TJSONObject;
  IsCaptcha: Boolean;
  I:         Integer;
begin
  Result := '';
  JObj := TJSONObject.Create;
  JObj.AddPair('id',         Email);
  JObj.AddPair('password',   Password);
  JObj.AddPair('deviceId',   DeviceId);
  JObj.AddPair('deviceType', 'PC');
  JObj.AddPair('locale',     'en');
  Body := BuildJson(JObj);

  Http := THTTPClient.Create;
  try
    Http.CustomHeaders['User-Agent']   := UA;
    Http.CustomHeaders['Content-Type'] := 'application/json';
    Http.CustomHeaders['Accept']       := 'application/json';
    Resp    := Http.Post(BASE_URL + '/account/v1/no-auth/login/launcher', Body);
    BodyStr := Resp.ContentAsString;

    case Resp.StatusCode of
      200:
      begin
        Result := CollectAuthCookies(Resp, Http, BodyStr);
      end;
      206:
      begin
        // MFA required
        MfaEx := ELoginMfaRequired.Create('MFA required');
        J := TJSONObject.ParseJSONValue(BodyStr) as TJSONObject;
        if J <> nil then
        try
          J.TryGetValue<string>('mfaKey',  MfaEx.MfaKey);
          J.TryGetValue<string>('mfaType', MfaEx.MfaType);
        finally
          J.Free;
        end;
        raise MfaEx;
      end;
    else
      ErrCode := 0;
      J := TJSONObject.ParseJSONValue(BodyStr) as TJSONObject;
      if J <> nil then
      try
        J.TryGetValue<Integer>('code', ErrCode);
      finally
        J.Free;
      end;
      IsCaptcha := False;
      for I := 0 to High(CAPTCHA_CODES) do
        if ErrCode = CAPTCHA_CODES[I] then
        begin
          IsCaptcha := True;
          Break;
        end;
      if IsCaptcha or (Pos('captchaToken', BodyStr) > 0) then
        raise ELoginCaptchaRequired.CreateFmt('Captcha required (code %d)', [ErrCode])
      else
        raise ELoginFailed.CreateFmt('Login HTTP %d (code %d)', [Resp.StatusCode, ErrCode]);
    end;
  finally
    Body.Free;
    Http.Free;
  end;
end;

function LoginOTP(const MfaKey, Otp, DeviceId: string): string;
var
  Http:    THTTPClient;
  Body:    TStringStream;
  Resp:    IHTTPResponse;
  BodyStr: string;
  JObj:    TJSONObject;
begin
  Result := '';
  JObj := TJSONObject.Create;
  JObj.AddPair('mfaKey',     MfaKey);
  JObj.AddPair('otp',        Otp);
  JObj.AddPair('deviceId',   DeviceId);
  JObj.AddPair('deviceType', 'PC');
  JObj.AddPair('locale',     'en');
  Body := BuildJson(JObj);

  Http := THTTPClient.Create;
  try
    Http.CustomHeaders['User-Agent']   := UA;
    Http.CustomHeaders['Content-Type'] := 'application/json';
    Http.CustomHeaders['Accept']       := 'application/json';
    Resp    := Http.Post(BASE_URL + '/account/v1/no-auth/login/launcher/otp', Body);
    BodyStr := Resp.ContentAsString;

    if Resp.StatusCode <> 200 then
      raise ELoginFailed.CreateFmt('OTP HTTP %d', [Resp.StatusCode]);

    Result := CollectAuthCookies(Resp, Http, BodyStr);
  finally
    Body.Free;
    Http.Free;
  end;
end;

function AutoLoginRefresh(const NxLSession, DeviceId: string;
  out HttpStatus: Integer; out NxLExpiry: TDateTime): string;
var
  Http:    THTTPClient;
  Body:    TStringStream;
  Resp:    IHTTPResponse;
  JObj:    TJSONObject;
begin
  Result     := '';
  HttpStatus := 0;
  NxLExpiry  := 0;

  JObj := TJSONObject.Create;
  JObj.AddPair('deviceId',   DeviceId);
  JObj.AddPair('deviceType', 'PC');
  JObj.AddPair('locale',     'en');
  Body := BuildJson(JObj);

  Http := THTTPClient.Create;
  Http.CookieManager.AddServerCookie(
    'NxLSession=' + NxLSession + '; path=/; domain=.nexon.com',
    'https://www.nexon.com/');
  try
    Http.CustomHeaders['User-Agent']   := UA;
    Http.CustomHeaders['Content-Type'] := 'application/json';
    Http.CustomHeaders['Accept']       := 'application/json';
    // Autologin endpoint moved to regional-auth prefix (2024 reorg).
    // Old /account/v1/... returns 404.
    Resp := Http.Post(BASE_URL + '/regional-auth/v1.0/no-auth/login/launcher/autologin', Body);
    HttpStatus := Resp.StatusCode;
    if Resp.StatusCode = 200 then
    begin
      Result    := CollectAuthCookies(Resp, Http, Resp.ContentAsString);
      NxLExpiry := LastNxLExpiry;
    end;
  finally
    Body.Free;
    Http.Free;
  end;
end;

initialization
  var G: TGUID;
  if CreateGUID(G) = S_OK then
  begin
    // Strip hyphens: "e4aebe0ef94049fda6273848dffb3a37" style
    GSessionId := StringReplace(GUIDToString(G), '-', '', [rfReplaceAll]);
    GSessionId := StringReplace(GSessionId, '{', '', [rfReplaceAll]);
    GSessionId := StringReplace(GSessionId, '}', '', [rfReplaceAll]);
    GSessionId := LowerCase(GSessionId);
  end;

end.
