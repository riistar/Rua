unit uBrowserCookies;
{
  Read Nexon session cookies from installed browsers without embedding one.
  Firefox : plaintext SQLite (moz_cookies).
  Chrome/Edge/Brave : AES-256-GCM + DPAPI encrypted SQLite.
  Priority: Firefox > Chrome > Edge > Brave.
}

interface

type
  TBrowserType = (btNone, btFirefox, btChrome, btEdge, btBrave);

function GetNexonCookies(out Cookies: string; out Browser: TBrowserType): Boolean;
function GetNexonCookiesFromFirefox(out Cookies: string): Boolean;
function GetNexonCookiesFromChrome(out Cookies: string): Boolean;
function GetNexonCookiesFromEdge(out Cookies: string): Boolean;
function GetNexonCookiesFromBrave(out Cookies: string): Boolean;
function BrowserName(Browser: TBrowserType): string;
function ExtractCookieValue(const CookieStr, Name: string): string;

// Exposed for diagnostics in the UI layer.
function FindFirefoxProfile: string;
// Returns True if Chrome's cookie DB exists and has nexon.com rows (even if encrypted).
function ChromeHasNexonCookiesEncrypted: Boolean;

var
  // Populated by GetNexonCookiesFromBrowserRVM on each call; read by UI for diagnostics.
  ChromeRVMLastDiag: string;

implementation

uses
  Winapi.Windows,
  System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.IniFiles, System.JSON,
  System.NetEncoding,
  Winapi.TlHelp32,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error,
  FireDAC.UI.Intf, FireDAC.Phys.Intf, FireDAC.Stan.Def,
  FireDAC.Stan.Pool, FireDAC.Stan.Async, FireDAC.Phys,
  FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.VCLUI.Wait,  // registers VCL wait cursor factory (required)
  FireDAC.DApt,        // registers object factories (required)
  FireDAC.Comp.Client;

{ ------------------------------------------------------------------ }
{  DPAPI                                                              }
{ ------------------------------------------------------------------ }

type
  _DATA_BLOB = record
    cbData: DWORD;
    pbData: PByte;
  end;
  DATA_BLOB  = _DATA_BLOB;
  PDATA_BLOB = ^DATA_BLOB;

function CryptUnprotectData(pDataIn: PDATA_BLOB; ppszDataDescr: Pointer;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL;
  stdcall; external 'crypt32.dll';

function DPAPIDecrypt(const Cipher: TBytes): TBytes;
var
  InBlob, OutBlob: DATA_BLOB;
begin
  SetLength(Result, 0);
  if Length(Cipher) = 0 then Exit;
  InBlob.cbData := Length(Cipher);
  InBlob.pbData := @Cipher[0];
  FillChar(OutBlob, SizeOf(OutBlob), 0);
  if CryptUnprotectData(@InBlob, nil, nil, nil, nil, 0, @OutBlob) then
  begin
    SetLength(Result, OutBlob.cbData);
    if OutBlob.cbData > 0 then
      Move(OutBlob.pbData^, Result[0], OutBlob.cbData);
    LocalFree(HLOCAL(OutBlob.pbData));
  end;
end;

{ ------------------------------------------------------------------ }
{  BCrypt AES-256-GCM                                                 }
{ ------------------------------------------------------------------ }

type
  BCRYPT_ALG_HANDLE = THandle;
  BCRYPT_KEY_HANDLE = THandle;
  NTSTATUS = Integer;

  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = packed record
    cbSize:        ULONG;
    dwInfoVersion: ULONG;
    pbNonce:       PByte;
    cbNonce:       ULONG;
    pbAuthData:    PByte;
    cbAuthData:    ULONG;
    pbTag:         PByte;
    cbTag:         ULONG;
    pbMacContext:  PByte;
    cbMacContext:  ULONG;
    cbAAD:         ULONG;
    cbData:        UInt64;
    dwFlags:       ULONG;
  end;

const
  STATUS_SUCCESS = NTSTATUS(0);
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION = 1;

function BCryptOpenAlgorithmProvider(out phAlg: BCRYPT_ALG_HANDLE;
  pszAlgId, pszImpl: PWideChar; dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptSetProperty(hObj: THandle; pszProp: PWideChar;
  pbIn: PByte; cbIn, dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptGetProperty(hObj: THandle; pszProp: PWideChar;
  pbOut: PByte; cbOut: ULONG; out pcbResult: ULONG; dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptGenerateSymmetricKey(hAlg: BCRYPT_ALG_HANDLE;
  out phKey: BCRYPT_KEY_HANDLE; pbKeyObj: PByte; cbKeyObj: ULONG;
  pbSecret: PByte; cbSecret, dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptDecrypt(hKey: BCRYPT_KEY_HANDLE; pbIn: PByte; cbIn: ULONG;
  pPaddingInfo: Pointer; pbIV: PByte; cbIV: ULONG; pbOut: PByte; cbOut: ULONG;
  out pcbResult: ULONG; dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptDestroyKey(hKey: BCRYPT_KEY_HANDLE): NTSTATUS;
  stdcall; external 'bcrypt.dll';
function BCryptCloseAlgorithmProvider(hAlg: BCRYPT_ALG_HANDLE;
  dwFlags: ULONG): NTSTATUS;
  stdcall; external 'bcrypt.dll';

function AESGCMDecrypt(const Key, Enc: TBytes): TBytes;
const
  IV_LEN  = 12;
  TAG_LEN = 16;
  PREFIX  = 3; // 'v10'
var
  hAlg:       BCRYPT_ALG_HANDLE;
  hKey:       BCRYPT_KEY_HANDLE;
  KeyObjLen, Got: ULONG;
  KeyObj, IV, Tag, Cipher, Plain: TBytes;
  AuthInfo:   BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
  CipherLen:  Integer;
  ChainMode:  string;
begin
  SetLength(Result, 0);
  if Length(Enc) < PREFIX + IV_LEN + TAG_LEN + 1 then Exit;
  if (Enc[0] <> Ord('v')) or (Enc[1] <> Ord('1')) or (Enc[2] <> Ord('0')) then Exit;

  SetLength(IV, IV_LEN);
  Move(Enc[PREFIX], IV[0], IV_LEN);

  CipherLen := Length(Enc) - PREFIX - IV_LEN - TAG_LEN;
  SetLength(Cipher, CipherLen);
  Move(Enc[PREFIX + IV_LEN], Cipher[0], CipherLen);

  SetLength(Tag, TAG_LEN);
  Move(Enc[Length(Enc) - TAG_LEN], Tag[0], TAG_LEN);

  hAlg := 0; hKey := 0;
  if BCryptOpenAlgorithmProvider(hAlg, 'AES', nil, 0) <> STATUS_SUCCESS then Exit;
  try
    ChainMode := 'ChainingModeGCM';
    BCryptSetProperty(hAlg, 'ChainingMode',
      PByte(PWideChar(ChainMode)), (Length(ChainMode) + 1) * 2, 0);

    BCryptGetProperty(hAlg, 'KeyObjectLength', PByte(@KeyObjLen), SizeOf(ULONG), Got, 0);
    SetLength(KeyObj, KeyObjLen);

    if BCryptGenerateSymmetricKey(hAlg, hKey, PByte(KeyObj), KeyObjLen,
         PByte(Key), Length(Key), 0) <> STATUS_SUCCESS then Exit;
    try
      FillChar(AuthInfo, SizeOf(AuthInfo), 0);
      AuthInfo.cbSize        := SizeOf(AuthInfo);
      AuthInfo.dwInfoVersion := BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION;
      AuthInfo.pbNonce       := PByte(IV);
      AuthInfo.cbNonce       := IV_LEN;
      AuthInfo.pbTag         := PByte(Tag);
      AuthInfo.cbTag         := TAG_LEN;

      SetLength(Plain, CipherLen);
      if BCryptDecrypt(hKey, PByte(Cipher), CipherLen, @AuthInfo,
           nil, 0, PByte(Plain), CipherLen, Got, 0) = STATUS_SUCCESS then
      begin
        SetLength(Plain, Got);
        Result := Plain;
      end;
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

{ ------------------------------------------------------------------ }
{  Chrome-family master key                                           }
{ ------------------------------------------------------------------ }

function GetChromeMasterKey(const LocalStatePath: string): TBytes;
var
  JSON:    string;
  Root:    TJSONObject;
  OsCrypt: TJSONObject;
  B64:     string;
  Raw:     TBytes;
begin
  SetLength(Result, 0);
  if not FileExists(LocalStatePath) then Exit;
  try
    JSON    := TFile.ReadAllText(LocalStatePath);
    Root    := TJSONObject.ParseJSONValue(JSON) as TJSONObject;
    if Root = nil then Exit;
    try
      OsCrypt := Root.GetValue<TJSONObject>('os_crypt');
      if OsCrypt = nil then Exit;
      B64 := OsCrypt.GetValue<string>('encrypted_key');
      if B64 = '' then Exit;

      Raw := TNetEncoding.Base64.DecodeStringToBytes(B64);
      // First 5 bytes are literal "DPAPI" prefix
      if Length(Raw) <= 5 then Exit;

      var DPAPIBytes: TBytes;
      SetLength(DPAPIBytes, Length(Raw) - 5);
      Move(Raw[5], DPAPIBytes[0], Length(DPAPIBytes));

      Result := DPAPIDecrypt(DPAPIBytes);
    finally
      Root.Free;
    end;
  except
    SetLength(Result, 0);
  end;
end;

{ ------------------------------------------------------------------ }
{  SQLite helpers                                                     }
{ ------------------------------------------------------------------ }

function CopyDBToTemp(const Src, Dest: string): Boolean;
begin
  Result := CopyFile(PChar(Src), PChar(Dest), False);
  // Copy WAL/SHM sidecar files so reads are consistent
  if FileExists(Src + '-wal') then
    CopyFile(PChar(Src + '-wal'), PChar(Dest + '-wal'), False);
  if FileExists(Src + '-shm') then
    CopyFile(PChar(Src + '-shm'), PChar(Dest + '-shm'), False);
end;

procedure DeleteTempDB(const Path: string);
begin
  if FileExists(Path)       then DeleteFile(Path);
  if FileExists(Path+'-wal') then DeleteFile(Path+'-wal');
  if FileExists(Path+'-shm') then DeleteFile(Path+'-shm');
end;

function OpenReadOnlySQLite(const DBPath: string): TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  Result.Params.DriverID  := 'SQLite';
  Result.Params.Database  := DBPath;
  Result.LoginPrompt      := False;
  Result.Params.Add('OpenMode=ReadOnly');
  Result.Connected := True;
end;

function BuildCookieString(const Pairs: TArray<string>): string;
var
  SB: TStringBuilder;
  S:  string;
begin
  SB := TStringBuilder.Create;
  try
    for S in Pairs do
    begin
      if SB.Length > 0 then SB.Append('; ');
      SB.Append(S);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{  Firefox                                                            }
{ ------------------------------------------------------------------ }

function FindFirefoxProfile: string;
var
  BaseDir, IniPath, RelPath, CandPath: string;
  Ini:      TIniFile;
  Sections: TStringList;
  I:        Integer;

  function ResolveProfile(const Rel: string): string;
  var S: string;
  begin
    S := StringReplace(Rel, '/', '\', [rfReplaceAll]);
    if TPath.IsPathRooted(S) then Result := S
    else                          Result := BaseDir + S;
  end;

begin
  Result  := '';
  BaseDir := GetEnvironmentVariable('APPDATA') + '\Mozilla\Firefox\';
  if not DirectoryExists(BaseDir) then Exit;

  IniPath := BaseDir + 'profiles.ini';
  if not FileExists(IniPath) then Exit;

  Ini      := TIniFile.Create(IniPath);
  Sections := TStringList.Create;
  try
    Ini.ReadSections(Sections);

    // 1st priority: [Install...] Default= (points to the currently-installed Firefox's profile)
    for I := 0 to Sections.Count - 1 do
      if StartsText('Install', Sections[I]) then
      begin
        RelPath := Ini.ReadString(Sections[I], 'Default', '');
        if RelPath <> '' then
        begin
          CandPath := ResolveProfile(RelPath);
          if DirectoryExists(CandPath) then
            begin Result := CandPath; Exit; end;
        end;
      end;

    // 2nd priority: Profile section marked Default=1
    for I := 0 to Sections.Count - 1 do
      if StartsText('Profile', Sections[I]) then
        if Ini.ReadInteger(Sections[I], 'Default', 0) = 1 then
        begin
          RelPath := Ini.ReadString(Sections[I], 'Path', '');
          if RelPath <> '' then
          begin
            CandPath := ResolveProfile(RelPath);
            if DirectoryExists(CandPath) then
              begin Result := CandPath; Exit; end;
          end;
        end;

    // 3rd priority: any Profile that actually has cookies.sqlite
    for I := 0 to Sections.Count - 1 do
      if StartsText('Profile', Sections[I]) then
      begin
        RelPath := Ini.ReadString(Sections[I], 'Path', '');
        if RelPath <> '' then
        begin
          CandPath := ResolveProfile(RelPath);
          if FileExists(CandPath + '\cookies.sqlite') then
            begin Result := CandPath; Exit; end;
        end;
      end;
  finally
    Sections.Free;
    Ini.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Firefox RVM (ReadProcessMemory) cookie extraction
// Scans Firefox's heap for "Name=Value" patterns — bypasses SQLite write delay.
// ---------------------------------------------------------------------------

function FindFirefoxPID: DWORD;
var
  Snap: THandle;
  PE:   TProcessEntry32;
begin
  Result := 0;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    PE.dwSize := SizeOf(PE);
    if Process32First(Snap, PE) then
    repeat
      if SameText(string(AnsiString(PE.szExeFile)), 'firefox.exe') then
      begin
        Result := PE.th32ProcessID;
        Exit;
      end;
    until not Process32Next(Snap, PE);
  finally
    CloseHandle(Snap);
  end;
end;

// Scan Buf for "Name=Value" in ASCII, then UTF-16LE.
// Stops value at ';', CR, LF, '"', NUL, or 512 chars.
function ScanCookieInMem(const Buf: TBytes; const Name: string;
  out Value: string): Boolean;
var
  Pattern:    TBytes;
  BufLen, PLen, I, J, VS, VE: Integer;
  Match:      Boolean;
begin
  Result := False; Value := '';
  BufLen := Length(Buf);

  // Pass 1 — ASCII
  Pattern := TEncoding.ASCII.GetBytes(Name + '=');
  PLen    := Length(Pattern);
  if BufLen >= PLen then
  begin
    I := 0;
    while I <= BufLen - PLen do
    begin
      if Buf[I] = Pattern[0] then
      begin
        Match := True;
        for J := 1 to PLen - 1 do
          if Buf[I + J] <> Pattern[J] then begin Match := False; Break; end;
        if Match then
        begin
          VS := I + PLen; VE := VS;
          while (VE < BufLen) and (Buf[VE] >= 32) and (Buf[VE] <> Ord(';')) and
                (Buf[VE] <> Ord('"')) and (Buf[VE] <> 13) and (Buf[VE] <> 10) and
                (VE - VS < 512) do Inc(VE);
          if VE > VS then
          begin
            Value  := TEncoding.ASCII.GetString(Buf, VS, VE - VS);
            Result := True; Exit;
          end;
        end;
      end;
      Inc(I);
    end;
  end;

  // Pass 2 — UTF-16LE (Chrome's base::string16 / std::wstring internal storage)
  Pattern := TEncoding.Unicode.GetBytes(Name + '=');
  PLen    := Length(Pattern);
  if BufLen < PLen + 2 then Exit;
  I := 0;
  while I <= BufLen - PLen do
  begin
    if Buf[I] = Pattern[0] then
    begin
      Match := True;
      for J := 1 to PLen - 1 do
        if Buf[I + J] <> Pattern[J] then begin Match := False; Break; end;
      if Match then
      begin
        VS := I + PLen; VE := VS;
        // UTF-16LE value: low byte = char, high byte = 0 for ASCII range
        while (VE + 1 < BufLen) and
              (Buf[VE + 1] = 0) and
              (Buf[VE] >= 32) and
              (Buf[VE] <> Ord(';')) and
              (Buf[VE] <> Ord('"')) and
              (Buf[VE] <> 13) and
              (Buf[VE] <> 10) and
              ((VE - VS) < 1024) do   // 512 chars × 2 bytes
          Inc(VE, 2);
        if VE > VS then
        begin
          Value  := TEncoding.Unicode.GetString(Buf, VS, VE - VS);
          Result := True; Exit;
        end;
      end;
    end;
    Inc(I);
  end;
end;

function GetNexonCookiesFromFirefoxRVM(out Cookies: string): Boolean;
const
  NAMES: array[0..6] of string = (
    'TpaSession', 'NxLSession', 'AToken', 'g_AToken', 'NxGUN', 'NexonUserID', 'id_token');
var
  PID:       DWORD;
  hProc:     THandle;
  MBI:       TMemoryBasicInformation;
  Addr:      NativeUInt;
  Buf:       TBytes;
  BytesRead: NativeUInt;
  SB:        TStringBuilder;
  Value:     string;
  Found:     array[0..6] of Boolean;
  N:         Integer;
  AllFound:  Boolean;
begin
  Result := False; Cookies := '';

  PID := FindFirefoxPID;
  if PID = 0 then Exit;
  hProc := OpenProcess(PROCESS_VM_READ or PROCESS_QUERY_INFORMATION, False, PID);
  if hProc = 0 then Exit;

  FillChar(Found, SizeOf(Found), 0);
  SB := TStringBuilder.Create;
  try
    Addr := 0;
    repeat
      if VirtualQueryEx(hProc, Pointer(Addr), MBI, SizeOf(MBI)) <> SizeOf(MBI) then Break;
      if MBI.RegionSize = 0 then Break;

      if (MBI.State = MEM_COMMIT) and
         (MBI.Type_9 = MEM_PRIVATE) and // heap only; skip MEM_IMAGE DLLs
         (MBI.Protect and (PAGE_READONLY or PAGE_READWRITE or
            PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_READ) <> 0) and
         (MBI.Protect and PAGE_GUARD = 0) and
         (MBI.RegionSize <= 64 * 1024 * 1024) then
      begin
        SetLength(Buf, MBI.RegionSize);
        if ReadProcessMemory(hProc, MBI.BaseAddress, @Buf[0],
             MBI.RegionSize, BytesRead) and (BytesRead > 11) then
        begin
          SetLength(Buf, BytesRead);
          for N := 0 to High(NAMES) do
          begin
            if Found[N] then Continue;
            if ScanCookieInMem(Buf, NAMES[N], Value) then
            begin
              if SB.Length > 0 then SB.Append('; ');
              SB.Append(NAMES[N] + '=' + Value);
              Found[N] := True;
            end;
          end;
        end;
      end;

      Inc(Addr, MBI.RegionSize);
      if Addr = 0 then Break; // address wrapped

      AllFound := True;
      for N := 0 to High(Found) do
        if not Found[N] then begin AllFound := False; Break; end;
    until AllFound;

    Cookies := SB.ToString;
  finally
    SB.Free;
    CloseHandle(hProc);
  end;

  Result := (Pos('TpaSession', Cookies) > 0) or (Pos('NxLSession', Cookies) > 0);
end;

{ ------------------------------------------------------------------ }
{  Generic browser process memory scan (Chrome-family RVM)           }
{  Used when SQLite decrypt fails (Chrome 127+ v20 App-Bound Enc.)   }
{ ------------------------------------------------------------------ }

function FindBrowserPIDs(const ExeName: string): TArray<DWORD>;
var
  Snap:  THandle;
  PE:    TProcessEntry32;
  Count: Integer;
begin
  SetLength(Result, 0);
  Count := 0;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    PE.dwSize := SizeOf(PE);
    if Process32First(Snap, PE) then
    repeat
      if SameText(string(AnsiString(PE.szExeFile)), ExeName) then
      begin
        SetLength(Result, Count + 1);
        Result[Count] := PE.th32ProcessID;
        Inc(Count);
      end;
    until not Process32Next(Snap, PE);
  finally
    CloseHandle(Snap);
  end;
end;

function GetNexonCookiesFromBrowserRVM(const ExeName: string;
  out Cookies: string): Boolean;
const
  NAMES: array[0..5] of string = (
    'NxLSession', 'AToken', 'g_AToken', 'NexonUserID', 'id_token', 'TpaSession');
var
  PIDs:       TArray<DWORD>;
  PID:        DWORD;
  hProc:      THandle;
  MBI:        TMemoryBasicInformation;
  Buf:        TBytes;
  Addr:       NativeUInt;
  BytesRead:  NativeUInt;
  Found:      array[0..5] of Boolean;
  Value:      string;
  SB, Diag:  TStringBuilder;
  N:          Integer;
  AllFound:   Boolean;
  Pages, OpenOK: Integer;
  FoundHere:  string;
begin
  Result := False; Cookies := '';

  PIDs  := FindBrowserPIDs(ExeName);
  Diag  := TStringBuilder.Create;
  try
    Diag.AppendFormat('[RVM %s] %d process(es)'#10, [ExeName, Length(PIDs)]);

    if Length(PIDs) = 0 then
    begin
      ChromeRVMLastDiag := Diag.ToString;
      Exit;
    end;

    OpenOK := 0;
    FillChar(Found, SizeOf(Found), 0);
    SB := TStringBuilder.Create;
    try
      for PID in PIDs do
      begin
        hProc := OpenProcess(PROCESS_VM_READ or PROCESS_QUERY_INFORMATION, False, PID);
        if hProc = 0 then
        begin
          Diag.AppendFormat('  PID %-6d open FAILED err=%d'#10, [PID, GetLastError]);
          Continue;
        end;
        Inc(OpenOK);
        Pages := 0;
        try
          Addr := 0;
          repeat
            if VirtualQueryEx(hProc, Pointer(Addr), MBI, SizeOf(MBI)) <> SizeOf(MBI) then Break;
            if MBI.RegionSize = 0 then Break;

            // No Type_9 filter — scan MEM_PRIVATE heap AND MEM_MAPPED IPC shared mem.
            // MEM_IMAGE (DLL code) is excluded via EXECUTE_WRITECOPY check being absent,
            // but we allow PAGE_READONLY so we catch response-header buffers too.
            if (MBI.State = MEM_COMMIT) and
               (MBI.Protect and (PAGE_READONLY or PAGE_READWRITE or
                  PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_READ) <> 0) and
               (MBI.Protect and PAGE_GUARD = 0) and
               (MBI.RegionSize <= 64 * 1024 * 1024) then
            begin
              Inc(Pages);
              SetLength(Buf, MBI.RegionSize);
              if ReadProcessMemory(hProc, MBI.BaseAddress, @Buf[0],
                   MBI.RegionSize, BytesRead) and (BytesRead > 11) then
              begin
                SetLength(Buf, BytesRead);
                for N := 0 to High(NAMES) do
                begin
                  if Found[N] then Continue;
                  if ScanCookieInMem(Buf, NAMES[N], Value) then
                  begin
                    if SB.Length > 0 then SB.Append('; ');
                    SB.Append(NAMES[N] + '=' + Value);
                    Found[N] := True;
                  end;
                end;
              end;
            end;

            Inc(Addr, MBI.RegionSize);
            if Addr = 0 then Break;

            AllFound := True;
            for N := 0 to High(Found) do
              if not Found[N] then begin AllFound := False; Break; end;
          until AllFound;
        finally
          FoundHere := '';
          for N := 0 to High(NAMES) do
            if Found[N] then FoundHere := FoundHere + ' ' + NAMES[N];
          Diag.AppendFormat('  PID %-6d pages=%d found=[%s]'#10, [PID, Pages, Trim(FoundHere)]);
          CloseHandle(hProc);
        end;

        if Found[0] or Found[5] then Break; // NxLSession or TpaSession — done
      end;

      Cookies := SB.ToString;
    finally
      SB.Free;
    end;

    Diag.AppendFormat('opened=%d/%d cookies=[%s]'#10, [OpenOK, Length(PIDs), Cookies]);
  finally
    ChromeRVMLastDiag := Diag.ToString;
    Diag.Free;
  end;

  Result := (Pos('TpaSession', Cookies) > 0) or (Pos('NxLSession', Cookies) > 0);
end;

// Read nexon.com cookie rows from a SQLite path (live or temp copy).
// Returns True if query succeeded (even if 0 rows).
function ReadFirefoxCookies(const DBPath: string; out Pairs: TArray<string>): Boolean;
var
  Conn: TFDConnection;
  Q:    TFDQuery;
  I:    Integer;
begin
  Result := False;
  SetLength(Pairs, 0);
  I := 0;
  try
    Conn := OpenReadOnlySQLite(DBPath);
    Q    := TFDQuery.Create(nil);
    try
      Q.Connection := Conn;
      Q.SQL.Text   :=
        'SELECT name, value FROM moz_cookies ' +
        'WHERE host LIKE ''%nexon.com''';
      Q.Open;
      while not Q.Eof do
      begin
        SetLength(Pairs, I + 1);
        Pairs[I] := Q.FieldByName('name').AsString + '=' +
                    Q.FieldByName('value').AsString;
        Inc(I);
        Q.Next;
      end;
      Result := True;
    finally
      Q.Free;
      Conn.Free;
    end;
  except
    SetLength(Pairs, 0);
  end;
end;

function GetNexonCookiesFromFirefox(out Cookies: string): Boolean;
var
  Profile, DBPath, TmpDB: string;
  Pairs: TArray<string>;
begin
  Result  := False;
  Cookies := '';

  Profile := FindFirefoxProfile;
  if Profile = '' then Exit;
  DBPath := Profile + '\cookies.sqlite';
  if not FileExists(DBPath) then Exit;

  // Primary: open the LIVE database directly. In SQLite WAL mode multiple readers
  // are allowed concurrently with Firefox, and WAL-committed frames are visible
  // immediately — no copy-timing race with deferred Firefox writes.
  if not ReadFirefoxCookies(DBPath, Pairs) then
  begin
    // Fallback: copy snapshot (handles the rare case where FireDAC can't open live)
    TmpDB := TPath.Combine(TPath.GetTempPath, 'nlp_ff_cookies.sqlite');
    try
      if not CopyDBToTemp(DBPath, TmpDB) then Exit;
      ReadFirefoxCookies(TmpDB, Pairs);
    finally
      DeleteTempDB(TmpDB);
    end;
  end;

  // SQLite had 0 nexon.com rows: async storage thread hasn't committed yet.
  // Fall back to reading the live Firefox process memory directly.
  if Length(Pairs) = 0 then
  begin
    if GetNexonCookiesFromFirefoxRVM(Cookies) then
    begin
      Result := (Pos('TpaSession', Cookies) > 0) or (Pos('NxLSession', Cookies) > 0);
      Exit;
    end;
  end;

  Cookies := BuildCookieString(Pairs);
  Result  := (Pos('TpaSession', Cookies) > 0) or (Pos('NxLSession', Cookies) > 0);
end;

{ ------------------------------------------------------------------ }
{  Chrome-family (Chrome / Edge / Brave)                              }
{ ------------------------------------------------------------------ }

function GetNexonCookiesChromium(const CookieDB, LocalState: string;
  out Cookies: string): Boolean;
var
  MasterKey: TBytes;
  TmpDB:     string;
  Conn:      TFDConnection;
  Q:         TFDQuery;
  EncVal, DecVal: TBytes;
  Pairs:     TArray<string>;
  I:         Integer;
  CookieName, CookieValue: string;
begin
  Result  := False;
  Cookies := '';

  if not FileExists(CookieDB) then Exit;

  MasterKey := GetChromeMasterKey(LocalState);
  if Length(MasterKey) = 0 then Exit;

  TmpDB := TPath.Combine(TPath.GetTempPath, 'nlp_cr_cookies.sqlite');
  try
    if not CopyDBToTemp(CookieDB, TmpDB) then Exit;

    Conn := OpenReadOnlySQLite(TmpDB);
    Q    := TFDQuery.Create(nil);
    try
      Q.Connection := Conn;
      Q.SQL.Text   :=
        'SELECT name, encrypted_value FROM cookies ' +
        'WHERE host_key LIKE ''%nexon.com''';
      Q.Open;

      I := 0;
      while not Q.Eof do
      begin
        CookieName := Q.FieldByName('name').AsString;
        EncVal     := Q.FieldByName('encrypted_value').AsBytes;

        if (Length(EncVal) >= 3) and (EncVal[0] = Ord('v')) then
        begin
          if (EncVal[1] = Ord('1')) and (EncVal[2] = Ord('0')) then
            DecVal := AESGCMDecrypt(MasterKey, EncVal)  // Chrome 80-126 DPAPI+GCM
          else
          begin
            // v20 = Chrome 127+ App-Bound Encryption — cannot decrypt from outside Chrome.
            // Skip this cookie; cookie string will lack NxLSession/TpaSession -> False returned.
            SetLength(DecVal, 0);
          end;
        end
        else
          DecVal := DPAPIDecrypt(EncVal); // legacy pre-v80 format

        if Length(DecVal) > 0 then
        begin
          CookieValue := TEncoding.UTF8.GetString(DecVal);
          SetLength(Pairs, I + 1);
          Pairs[I] := CookieName + '=' + CookieValue;
          Inc(I);
        end;

        Q.Next;
      end;
    finally
      Q.Free;
      Conn.Free;
    end;
  finally
    DeleteTempDB(TmpDB);
  end;

  Cookies := BuildCookieString(Pairs);
  Result  := (Pos('TpaSession', Cookies) > 0) or (Pos('NxLSession', Cookies) > 0);
end;

function GetNexonCookiesFromChrome(out Cookies: string): Boolean;
var
  Base: string;
begin
  Base := GetEnvironmentVariable('LOCALAPPDATA') + '\Google\Chrome\User Data\';
  Result := GetNexonCookiesChromium(
    Base + 'Default\Network\Cookies',
    Base + 'Local State',
    Cookies);
  // Chrome 127+ v20 App-Bound Encryption: SQLite path returns nothing.
  // Fall back to scanning live process memory for cookie strings.
  if not Result then
    Result := GetNexonCookiesFromBrowserRVM('chrome.exe', Cookies);
end;

function GetNexonCookiesFromEdge(out Cookies: string): Boolean;
var
  Base: string;
begin
  Base := GetEnvironmentVariable('LOCALAPPDATA') + '\Microsoft\Edge\User Data\';
  Result := GetNexonCookiesChromium(
    Base + 'Default\Network\Cookies',
    Base + 'Local State',
    Cookies);
  if not Result then
    Result := GetNexonCookiesFromBrowserRVM('msedge.exe', Cookies);
end;

function GetNexonCookiesFromBrave(out Cookies: string): Boolean;
var
  Base: string;
begin
  Base := GetEnvironmentVariable('LOCALAPPDATA') + '\BraveSoftware\Brave-Browser\User Data\';
  Result := GetNexonCookiesChromium(
    Base + 'Default\Network\Cookies',
    Base + 'Local State',
    Cookies);
  if not Result then
    Result := GetNexonCookiesFromBrowserRVM('brave.exe', Cookies);
end;

function ChromeHasNexonCookiesEncrypted: Boolean;
var
  Base, CookieDB, TmpDB: string;
  Conn: TFDConnection;
  Q:    TFDQuery;
begin
  Result  := False;
  Base    := GetEnvironmentVariable('LOCALAPPDATA') + '\Google\Chrome\User Data\';
  CookieDB := Base + 'Default\Network\Cookies';
  if not FileExists(CookieDB) then Exit;

  TmpDB := TPath.Combine(TPath.GetTempPath, 'nlp_cr_diag.sqlite');
  try
    if not CopyDBToTemp(CookieDB, TmpDB) then Exit;
    Conn := OpenReadOnlySQLite(TmpDB);
    Q    := TFDQuery.Create(nil);
    try
      Q.Connection := Conn;
      Q.SQL.Text   :=
        'SELECT COUNT(*) AS n FROM cookies WHERE host_key LIKE ''%nexon.com''';
      Q.Open;
      Result := Q.FieldByName('n').AsInteger > 0;
    finally
      Q.Free;
      Conn.Free;
    end;
  finally
    DeleteTempDB(TmpDB);
  end;
end;

{ ------------------------------------------------------------------ }
{  Public API                                                         }
{ ------------------------------------------------------------------ }

function GetNexonCookies(out Cookies: string; out Browser: TBrowserType): Boolean;
begin
  Browser := btNone;

  if GetNexonCookiesFromFirefox(Cookies) then
    begin Browser := btFirefox; Result := True; Exit; end;

  if GetNexonCookiesFromChrome(Cookies) then
    begin Browser := btChrome;  Result := True; Exit; end;

  if GetNexonCookiesFromEdge(Cookies) then
    begin Browser := btEdge;    Result := True; Exit; end;

  if GetNexonCookiesFromBrave(Cookies) then
    begin Browser := btBrave;   Result := True; Exit; end;

  Result := False;
end;

function BrowserName(Browser: TBrowserType): string;
begin
  case Browser of
    btFirefox: Result := 'Firefox';
    btChrome:  Result := 'Chrome';
    btEdge:    Result := 'Edge';
    btBrave:   Result := 'Brave';
    else       Result := 'Unknown';
  end;
end;

function ExtractCookieValue(const CookieStr, Name: string): string;
var
  Parts:   TArray<string>;
  Part:    string;
  Trimmed: string;
  EqPos:   Integer;
begin
  Result := '';
  Parts  := CookieStr.Split([';']);
  for Part in Parts do
  begin
    Trimmed := Trim(Part);
    EqPos   := Pos('=', Trimmed);
    if EqPos <= 0 then Continue;
    if SameText(Copy(Trimmed, 1, EqPos - 1), Name) then
    begin
      Result := Copy(Trimmed, EqPos + 1, MaxInt);
      Exit;
    end;
  end;
end;

end.
