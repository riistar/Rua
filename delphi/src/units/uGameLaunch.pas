unit uGameLaunch;
{ Uses a per-launch, user-restricted memory mapping for ticket handoff.
  Starts the game suspended so its exact process can be authorized by the pipe
  before it runs. No ticket file is written. The mapping is cleared on failure
  or after shim initialization (at most 30 seconds).

  One launcher, many sessions: every Launch creates its own TGameSession that
  owns that client's stub process, events, verified handles and pipe
  registration. The deployed stub/shim files are shared and reused (see
  TDeployedFiles and DeployVerified); a session never touches another
  session's resources. See docs/MULTI_CLIENT.md. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  uProtocol, uPipeServer, uNexonAPI;

type
  // The deployed nexon_client.exe / bin\nexon_x64.dll copies. Identical signed
  // binaries for every session, so they are created at most once and reused.
  TDeployedFiles = class
  private
    FLock:     TCriticalSection;
    FRefs:     Integer;   // sessions currently using the files
    FStubPath: string;
    FShimPath: string;
    FOwned:    Boolean;   // this process created at least one of them
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enter;
    procedure Leave;
    procedure Attach;
    procedure NoteCreated(const Path: string; IsStub: Boolean);
    procedure Detach; // last session out removes files this process created
  end;

  TGameSession = class
  public
    Id:          Integer;
    Shared:      TDeployedFiles;
    Attached:    Boolean;
    Pipe:        TPipeRegistration;
    StubProcess: THandle;
    StubExitEvent: THandle;
    // Held for the whole session: the deployed files deny writes/deletes and
    // the folders deny deletes/renames, so nothing can be swapped after checks.
    StubFile:    THandle;
    ShimFile:    THandle;
    OurDirLock:  THandle;
    BinDirLock:  THandle;
    StubCreated: Boolean; // this session created the deployed stub (else reused)
    ShimCreated: Boolean;
    constructor Create(AShared: TDeployedFiles; AId: Integer);
    destructor Destroy; override;
    procedure Log(const Msg: string);
    procedure StopPipe;
    procedure Cleanup; // session-owned resources only
  end;

  TGameLauncher = class
  private
    FShared:   TDeployedFiles;
    FSessions: TList<TGameSession>; // sessions whose game is running
    FLock:     TCriticalSection;
    FNextId:   Integer;
    FOnGameExit: TNotifyEvent;
    FLastLaunchedPid: Cardinal;
    FLastExitedPid:   Cardinal;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Launch(const Cookies: string; ProductId: Integer;
      const GameExePath: string; const UserNo: string = '';
      const ExtraArgs: string = '');
    function IsRunning: Boolean;
    function RunningCount: Integer;
    property OnGameExit: TNotifyEvent read FOnGameExit write FOnGameExit;
    // Game PID of the newest launch / of the session whose exit is being reported.
    property LastLaunchedPid: Cardinal read FLastLaunchedPid;
    property LastExitedPid: Cardinal read FLastExitedPid;
  end;

// True when started with --multi: a second launcher process is not refused.
function MultiClientMode: Boolean;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI,
  System.Hash, System.NetEncoding,
  System.IOUtils, uLaunchSecurity, uHooks, uSignature;

const
  ERROR_ELEVATION_REQUIRED = 740; // not in Winapi.Windows

var
  GElevated: Integer = -1; // -1 unknown, 0 no, 1 yes

function Elevated: Boolean;
begin
  if GElevated < 0 then
    GElevated := Ord(IsProcessElevated);
  Result := GElevated = 1;
end;

function MultiClientMode: Boolean;
var
  I: Integer;
  P: string;
begin
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if SameText(P, '--multi') or SameText(P, '-multi') or SameText(P, '/multi') then
      Exit(True);
  end;
  Result := False;
end;

procedure LaunchLog(const Msg: string);
begin
  // Diagnostic only, never secrets. An elevated process must not write to a
  // fixed name in the user-writable %TEMP% (a planted link could redirect it).
  if Elevated then Exit;
  try
    TFile.AppendAllText(
      GetEnvironmentVariable('TEMP') + '\nxl_launch_debug.txt',
      FormatDateTime('[hh:nn:ss.zzz] ', Now) + Msg + sLineBreak,
      TEncoding.UTF8);
  except end;
end;

function HashUserNo(const UserNo: string): string;
var
  Bytes: TBytes;
begin
  if UserNo = '' then begin Result := ''; Exit; end;
  Bytes  := THashSHA2.GetHashBytes(UserNo);
  Result := TNetEncoding.Base64.EncodeBytesToString(Bytes);
end;

procedure SubstitutePassport(var Params: TArray<string>; const Passport: string);
var
  I: Integer;
begin
  for I := 0 to High(Params) do
    if Pos('${passport}', Params[I]) > 0 then
      Params[I] := StringReplace(Params[I], '${passport}', Passport, [rfReplaceAll]);
end;

function BuildCommandLine(const ExePath: string; const Params: TArray<string>): string;
var
  I: Integer;
begin
  Result := '"' + ExePath + '"';
  for I := 0 to High(Params) do
    if Pos(' ', Params[I]) > 0
      then Result := Result + ' "' + Params[I] + '"'
      else Result := Result + ' ' + Params[I];
end;

procedure CloseIfOpen(var H: THandle);
begin
  if (H <> 0) and (H <> INVALID_HANDLE_VALUE) then CloseHandle(H);
  H := 0;
end;

procedure RefuseLink(H: THandle; const Path: string);
var
  Info: TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(H, Info) then RaiseLastOSError;
  if (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
    raise Exception.CreateFmt('Refusing a linked path during launch: %s', [Path]);
end;

// Opens a folder so it cannot be deleted, renamed or replaced by a junction
// while the handle is held. The folder itself must not be a link.
function LockFolder(const Dir: string): THandle;
begin
  Result := CreateFile(PChar(Dir), FILE_READ_ATTRIBUTES, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if Result = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    RefuseLink(Result, Dir);
  except
    CloseHandle(Result);
    raise;
  end;
end;

function Sha256OfHandle(H: THandle): string;
var
  Stream: THandleStream;
  Hash:   THashSHA2;
  Buf:    TBytes;
  N:      Integer;
begin
  Stream := THandleStream.Create(H);
  try
    Stream.Position := 0;
    Hash := THashSHA2.Create; // SHA-256 by default
    SetLength(Buf, 65536);
    repeat
      N := Stream.Read(Buf[0], Length(Buf));
      if N > 0 then Hash.Update(Buf[0], N);
    until N <= 0;
    Result := Hash.HashAsString;
  finally
    Stream.Free;
  end;
end;

// Reuse rule: an existing, non-link Dst whose SHA-256 equals SrcHash is opened
// read-only (denying writes/deletes) and returned as-is; nothing is deleted or
// copied, so a file another session is running or has mapped is never touched.
// Returns INVALID_HANDLE_VALUE when Dst is missing, a link, or different (the
// caller then replaces it; if that is impossible because it is in use, the
// replace fails closed). An in-use Dst that cannot even be opened raises.
function TryReuseDeployed(const Dst, SrcHash: string): THandle;
var
  Info: TByHandleFileInformation;
  Err:  DWORD;
begin
  Result := INVALID_HANDLE_VALUE;
  if GetFileAttributes(PChar(Dst)) = INVALID_FILE_ATTRIBUTES then Exit;
  Result := CreateFile(PChar(Dst), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if Result = INVALID_HANDLE_VALUE then
  begin
    Err := GetLastError;
    if (Err = ERROR_FILE_NOT_FOUND) or (Err = ERROR_PATH_NOT_FOUND) then Exit;
    RaiseLastOSError(Err);
  end;
  try
    if not GetFileInformationByHandle(Result, Info) then RaiseLastOSError;
    // A link is replaced, never reused (DeleteFile removes the link itself).
    if ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0) and
       SameText(Sha256OfHandle(Result), SrcHash) then
      Exit;
  except
    CloseHandle(Result);
    raise;
  end;
  CloseHandle(Result);
  Result := INVALID_HANDLE_VALUE;
end;

// Makes Dst a verified copy of Src and returns a handle that keeps it that way
// until closed (still allows the reads and image loads the stub/game need).
// Created = False when an identical existing file was reused.
function DeployVerified(const Src, Dst: string; out Created: Boolean): THandle;
var
  SrcHandle: THandle;
  SrcHash:   string;
begin
  Created := False;
  SrcHandle := CreateFile(PChar(Src), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if SrcHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    RefuseLink(SrcHandle, Src);
    SrcHash := Sha256OfHandle(SrcHandle);
    Result := TryReuseDeployed(Dst, SrcHash);
    if Result <> INVALID_HANDLE_VALUE then Exit;
    // Missing or different: replace. DeleteFile removes a link itself, never its
    // target, and fails (closed) while a different file is still in use. CopyFile
    // then refuses to overwrite anything that reappears, so a race fails closed.
    if (GetFileAttributes(PChar(Dst)) <> INVALID_FILE_ATTRIBUTES) and not DeleteFile(PChar(Dst)) then
      RaiseLastOSError;
    if not CopyFile(PChar(Src), PChar(Dst), True) then RaiseLastOSError;
    Created := True;
  finally
    CloseHandle(SrcHandle);
  end;
  Result := CreateFile(PChar(Dst), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if Result = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    RefuseLink(Result, Dst);
    if not SameText(Sha256OfHandle(Result), SrcHash) then
      raise Exception.CreateFmt('Launch helper copy failed verification: %s', [Dst]);
  except
    CloseHandle(Result);
    DeleteFile(PChar(Dst));
    raise;
  end;
end;

{ TDeployedFiles }

constructor TDeployedFiles.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
end;

destructor TDeployedFiles.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TDeployedFiles.Enter;
begin
  FLock.Enter;
end;

procedure TDeployedFiles.Leave;
begin
  FLock.Leave;
end;

procedure TDeployedFiles.Attach;
begin
  FLock.Enter;
  try Inc(FRefs); finally FLock.Leave; end;
end;

procedure TDeployedFiles.NoteCreated(const Path: string; IsStub: Boolean);
begin
  FLock.Enter;
  try
    FOwned := True;
    if IsStub then FStubPath := Path else FShimPath := Path;
  finally
    FLock.Leave;
  end;
end;

procedure TDeployedFiles.Detach;
begin
  FLock.Enter;
  try
    if FRefs > 0 then Dec(FRefs);
    if FRefs = 0 then
    begin
      // Last session out. Files still held by another process (its verified
      // handles deny deletes) simply fail to delete and stay for that process.
      if FOwned then
      begin
        if FShimPath <> '' then try TFile.Delete(FShimPath); except end;
        if FStubPath <> '' then try TFile.Delete(FStubPath); except end;
      end;
      FOwned := False;
      FShimPath := '';
      FStubPath := '';
    end;
  finally
    FLock.Leave;
  end;
end;

{ TGameSession }

constructor TGameSession.Create(AShared: TDeployedFiles; AId: Integer);
begin
  inherited Create;
  Shared := AShared;
  Id := AId;
end;

destructor TGameSession.Destroy;
begin
  StopPipe;
  Cleanup;
  inherited;
end;

procedure TGameSession.Log(const Msg: string);
begin
  LaunchLog('[s' + IntToStr(Id) + '] ' + Msg);
end;

procedure TGameSession.StopPipe;
begin
  FreeAndNil(Pipe); // ends only this session's connections
end;

procedure TGameSession.Cleanup;
begin
  if StubExitEvent <> 0 then
  begin
    SetEvent(StubExitEvent);
    CloseHandle(StubExitEvent);
    StubExitEvent := 0;
  end;
  if StubProcess <> 0 then
  begin
    if WaitForSingleObject(StubProcess, 2000) = WAIT_TIMEOUT then
      TerminateProcess(StubProcess, 0);
    WaitForSingleObject(StubProcess, 2000);
    CloseHandle(StubProcess);
    StubProcess := 0;
  end;
  // Release this session's handles first; the shared files are removed only when
  // no session uses them any more (Detach), never while another session runs.
  CloseIfOpen(StubFile);
  CloseIfOpen(ShimFile);
  if Attached then
  begin
    Attached := False;
    Shared.Detach;
  end;
  CloseIfOpen(BinDirLock);
  CloseIfOpen(OurDirLock);
end;

{ TGameLauncher }

constructor TGameLauncher.Create;
begin
  inherited;
  FShared   := TDeployedFiles.Create;
  FSessions := TList<TGameSession>.Create;
  FLock     := TCriticalSection.Create;
end;

destructor TGameLauncher.Destroy;
begin
  // Running sessions are owned by their monitor threads; nothing of theirs is
  // torn down here (a launcher never touches a live session).
  FLock.Free;
  FSessions.Free;
  FShared.Free;
  inherited;
end;

function TGameLauncher.RunningCount: Integer;
begin
  FLock.Enter;
  try Result := FSessions.Count; finally FLock.Leave; end;
end;

function TGameLauncher.IsRunning: Boolean;
begin
  Result := RunningCount > 0;
end;

procedure TGameLauncher.Launch(const Cookies: string; ProductId: Integer;
  const GameExePath: string; const UserNo: string = '';
  const ExtraArgs: string = '');
var
  Ticket, Hashed, GameDir, ParamStr, PidStr: string;
  Config: TGameConfig;
  Params: TArray<string>;
  OurDir, StubSrc, StubDst, BinDir, ShimSrc, ShimDst, CL, CmdLine: string;
  SI: TStartupInfo;
  PI: TProcessInformation;
  PlayableStatus: Integer;
  AccessInfo: TAccessInfo;
  GamePI: TProcessInformation;
  PrivateTicket: TPrivateTicket;
  ChildEnvironment: string;
  SA: TSecurityAttributes;
  ErrorCode: DWORD;
  ShimReadyEv: THandle;
  StubEventName: string;
  StubGuid: TGUID;
  ClientFile: THandle;
  Refusal: string;
  SEI: TShellExecuteInfo;
  S: TGameSession;
  Created: Boolean;
  SessionId: Integer;
begin
  PidStr  := IntToStr(ProductId);
  GameDir := ExtractFileDir(GameExePath);
  OurDir  := ExtractFileDir(GetModuleName(0));

  FLock.Enter;
  try
    Inc(FNextId);
    SessionId := FNextId;
  finally
    FLock.Leave;
  end;
  // This session's own state. Nothing of any other running session is touched.
  S := TGameSession.Create(FShared, SessionId);
  S.Log('Session start');

  // Validate deployment before requesting an authentication ticket.
  if not TFile.Exists(OurDir + '\nxl3p_stub.exe') or
     not TFile.Exists(OurDir + '\nxl3p_shim.dll') then
  begin
    S.Free;
    raise Exception.Create('Rua launch helpers are missing. Repair the installation before signing in.');
  end;

  // Only Nexon's signed Client.exe receives the launch ticket (and, elevated,
  // administrator rights). The handle denies writes until the game has started,
  // so the verified file is the one that runs.
  ClientFile := CreateFile(PChar(GameExePath), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if ClientFile = INVALID_HANDLE_VALUE then
  begin
    ErrorCode := GetLastError;
    S.Free;
    raise Exception.Create('Mabinogi Client.exe could not be opened: ' + SysErrorMessage(ErrorCode));
  end;
  PrivateTicket := nil;
  ShimReadyEv := 0;
  ZeroMemory(@GamePI, SizeOf(GamePI));
  try
  try
  RefuseLink(ClientFile, GameExePath);
  if not IsNexonSignedClient(GameExePath, ClientFile, Refusal) then
    raise Exception.Create('Launch refused: ' + Refusal + '. Repair the game through Nexon Launcher.');

  // 2. Auth: /account → /access → /playable → /passport (official launcher sequence).
  // /account returns Set-Cookie headers that establish the server-side session scope.
  var AuthCookies := FetchAccountAndMerge(Cookies);
  // Strip loopback if account returned set-cookie with refreshed tokens
  if AuthCookies = Cookies then
    S.Log('FetchAccount: no new cookies')
  else
    S.Log('FetchAccount: Set-Cookie merged');
  AuthCookies := FetchAccess(AuthCookies, PidStr, AccessInfo);
  S.Log('FetchAccess: HTTP=' + IntToStr(AccessInfo.HttpStatus) + ' isPlayable=' +
    BoolToStr(AccessInfo.IsPlayable, True));
  if AccessInfo.HttpStatus = 401 then
    raise ETicketError.Create('Session expired (401). Re-login and try again.')
  else if AccessInfo.IpBlocked then
    raise EGamePlayableFailed.Create(
      'Access blocked from your region/IP. The official launcher denies this game to your location.')
  else if not AccessInfo.IsPlayable then
    raise EGamePlayableFailed.Create(
      'Mabinogi is currently unavailable (under maintenance or not yet open). Please try again later.');

  PlayableStatus := 0;
  if not CheckPlayable(AuthCookies, PidStr, PlayableStatus) then
  begin
    if PlayableStatus = 401 then
      raise ETicketError.Create('Session expired (401). Re-login and try again.')
    else
      raise ETicketError.CreateFmt('Product not playable (HTTP %d)', [PlayableStatus]);
  end;
  S.Log('CheckPlayable: HTTP=' + IntToStr(PlayableStatus) + ' OK');

  Ticket := FetchTicket(AuthCookies, ProductId);
  Hashed := HashUserNo(UserNo);
  S.Log('Launch ticket received');

  PrivateTicket := TPrivateTicket.Create(Ticket);
  S.Log('Ticket mapping: ' + PrivateTicket.Name);

  // 4. Deploy stub as nexon_client.exe in our dir: create-or-reuse a verified
  // copy, held locked by this session's own handle.
  S.OurDirLock := LockFolder(OurDir);
  StubSrc := OurDir + '\nxl3p_stub.exe';
  StubDst := OurDir + '\nexon_client.exe';
  if not TFile.Exists(StubSrc) then
    raise Exception.CreateFmt('nxl3p_stub.exe not found: %s', [StubSrc]);
  FShared.Enter; // serialize create-or-reuse across concurrent launches
  try
    FShared.Attach;
    S.Attached := True;
    S.StubFile := DeployVerified(StubSrc, StubDst, Created);
    S.StubCreated := Created;
    if Created then FShared.NoteCreated(StubDst, True);
  finally
    FShared.Leave;
  end;
  if S.StubCreated then
    S.Log('Stub deployed (created): ' + StubDst)
  else
    S.Log('Stub reused (identical, verified): ' + StubDst);

  // 5. Create named events BEFORE spawning stub/game.
  ZeroMemory(@SA, SizeOf(SA));
  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := UserOnlyDescriptor;
  try
    if CreateGUID(StubGuid) <> 0 then
      raise Exception.Create('Could not create launch event identifier');
    StubEventName := 'Local\Rua.Stub.' + GUIDToString(StubGuid);
    S.StubExitEvent := CreateEventW(@SA, True, False, PWideChar(StubEventName));
    ErrorCode := GetLastError;
    if S.StubExitEvent = 0 then RaiseLastOSError(ErrorCode);
    if ErrorCode = ERROR_ALREADY_EXISTS then begin
      CloseHandle(S.StubExitEvent); S.StubExitEvent := 0;
      raise Exception.Create('Another launcher owns the stub event');
    end;
    ShimReadyEv := CreateEventW(@SA, True, False, PWideChar(PrivateTicket.Name + '.Ready'));
    ErrorCode := GetLastError;
    if ShimReadyEv = 0 then RaiseLastOSError(ErrorCode);
    if ErrorCode = ERROR_ALREADY_EXISTS then
      raise Exception.Create('Launch initialization event collision');
  finally
    LocalFree(HLOCAL(SA.lpSecurityDescriptor));
  end;
  S.Log('Stub event: ' + StubEventName);

  // 6. Spawn this session's own stub process from the shared file. The stub is
  // the signed parent the game expects; each session has its own.
  ZeroMemory(@SI, SizeOf(SI));
  SI.cb := SizeOf(SI);
  CmdLine := '"' + StubDst + '" --exit-event "' + StubEventName +
    '" --parent-pid ' + UIntToStr(GetCurrentProcessId);
  UniqueString(CmdLine);
  ZeroMemory(@PI, SizeOf(PI));
  if CreateProcessW(PWideChar(StubDst), PWideChar(CmdLine), nil, nil, False,
      CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(PI.hThread);
    S.StubProcess := PI.hProcess;
    S.Log('Stub spawned PID=' + IntToStr(PI.dwProcessId));
    if WaitForSingleObject(S.StubProcess, 300) <> WAIT_TIMEOUT then
      raise Exception.Create('Rua compatibility helper exited during setup');
  end
  else
    raise Exception.CreateFmt('Stub spawn failed err=%d', [GetLastError]);

  // 7. Deploy nxl3p_shim.dll → {our_dir}\bin\nexon_x64.dll (create-or-reuse).
  ShimSrc := OurDir + '\nxl3p_shim.dll';
  BinDir  := OurDir + '\bin';
  ShimDst := BinDir + '\nexon_x64.dll';
  if not TFile.Exists(ShimSrc) then
    raise Exception.Create('nxl3p_shim.dll not found next to launcher. Rebuild the shim.');
  TDirectory.CreateDirectory(BinDir);
  S.BinDirLock := LockFolder(BinDir); // refuses a junction in place of bin\
  FShared.Enter;
  try
    S.ShimFile := DeployVerified(ShimSrc, ShimDst, Created);
    S.ShimCreated := Created;
    if Created then FShared.NoteCreated(ShimDst, False);
  finally
    FShared.Leave;
  end;
  if S.ShimCreated then
    S.Log('Shim deployed (created): ' + ShimDst)
  else
    S.Log('Shim reused (identical, verified): ' + ShimDst);

  // 8. Game params
  Config := FetchGameConfig(AuthCookies, ProductId);
  Params := Copy(Config.Parameters, 0, Length(Config.Parameters));
  SubstitutePassport(Params, Ticket);
  CL       := BuildCommandLine(GameExePath, Params);
  ParamStr := Trim(Copy(CL, Length('"' + GameExePath + '"') + 1, MaxInt));
  if ExtraArgs <> '' then
  begin
    if ParamStr <> '' then ParamStr := ParamStr + ' ' + ExtraArgs
    else                   ParamStr := ExtraArgs;
    CL := '"' + GameExePath + '" ' + ParamStr;
  end;
  S.Log('Starting game client');

  // Bind authentication to the exact new process before any game code runs.
  ChildEnvironment := TicketEnvironment(PrivateTicket.Name);
  ZeroMemory(@SI, SizeOf(SI)); SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW; SI.wShowWindow := SW_SHOWNORMAL;
  UniqueString(CL);
  if not CreateProcessW(PWideChar(GameExePath), PWideChar(CL), nil, nil, False,
    CREATE_SUSPENDED or CREATE_UNICODE_ENVIRONMENT, PWideChar(ChildEnvironment),
    PWideChar(GameDir), SI, GamePI) then
  begin
    ErrorCode := GetLastError;
    if ErrorCode <> ERROR_ELEVATION_REQUIRED then RaiseLastOSError(ErrorCode);
    // Client.exe has a highestAvailable manifest. ShellExecuteEx handles the UAC
    // prompt; the child is spawned by AppInfo and does NOT inherit our env block,
    // so pass the mapping name via --rua-map on the command line instead.
    S.Log('CreateProcessW: ERROR_ELEVATION_REQUIRED, falling back to ShellExecuteEx');
    ParamStr := ParamStr + ' --rua-map ' + PrivateTicket.Name;
    ZeroMemory(@SEI, SizeOf(SEI));
    SEI.cbSize       := SizeOf(SEI);
    SEI.fMask        := SEE_MASK_NOCLOSEPROCESS;
    SEI.lpFile       := PChar(GameExePath);
    SEI.lpParameters := PChar(ParamStr);
    SEI.lpDirectory  := PChar(GameDir);
    SEI.nShow        := SW_SHOWNORMAL;
    if not ShellExecuteExW(@SEI) then RaiseLastOSError;
    GamePI.hProcess := SEI.hProcess;
    GamePI.hThread  := 0;
    S.StopPipe;
    S.Pipe := TPipeRegistration.Create(Ticket, Hashed, ProductId, GamePI.hProcess);
  end
  else
  begin
    // Suspended path: pipe authorized to the exact PID before first game instruction.
    S.StopPipe;
    S.Pipe := TPipeRegistration.Create(Ticket, Hashed, ProductId, GamePI.hProcess);
    if ResumeThread(GamePI.hThread) = DWORD(-1) then RaiseLastOSError;
    CloseHandle(GamePI.hThread); GamePI.hThread := 0;
  end;
  S.Log('Game pid=' + IntToStr(GetProcessId(GamePI.hProcess)) + ' registered on ticket pipe');
  // Wait for the shim, but also watch the game process: if Client.exe dies during
  // startup (error dialog / crash) fail immediately instead of blocking 120s.
  var WaitHandles: array[0..1] of THandle;
  var WaitCount: DWORD := 1;
  WaitHandles[0] := ShimReadyEv;
  if GamePI.hProcess <> 0 then
  begin
    WaitHandles[1] := GamePI.hProcess;
    WaitCount := 2;
  end;
  var WaitRes := WaitForMultipleObjects(WaitCount, @WaitHandles[0], False, 120000);
  if WaitRes = WAIT_OBJECT_0 + 1 then
  begin
    var EarlyCode: DWORD := 0;
    GetExitCodeProcess(GamePI.hProcess, EarlyCode);
    raise Exception.CreateFmt('Game client exited during startup (code %d)', [EarlyCode]);
  end;
  if WaitRes <> WAIT_OBJECT_0 then
    raise Exception.Create('Secure game initialization timed out');
  FreeAndNil(PrivateTicket);
  CloseHandle(ShimReadyEv); ShimReadyEv := 0;

  FLock.Enter;
  try FSessions.Add(S); finally FLock.Leave; end;

  // 11. Background thread: wait game exit → clean up THIS session only. It owns
  // S and the game handle from here on.
  var TGameProc := GamePI.hProcess;
  var TGamePid  := GamePI.dwProcessId;
  FLastLaunchedPid := TGamePid;
  GamePI.hProcess := 0;
  var TSession := S;
  S := nil;
  TThread.CreateAnonymousThread(procedure
  var Code: DWORD;
  begin
    if TGameProc <> 0 then
    begin
      WaitForSingleObject(TGameProc, INFINITE);
      Code := 0;
      GetExitCodeProcess(TGameProc, Code);
      CloseHandle(TGameProc);
      TSession.Log('Client.exe exited code=' + IntToStr(Code));
    end;

    TSession.StopPipe;
    // Stub, events and handles of this session only; shared files are removed
    // only if no other session still uses them.
    TSession.Cleanup;
    TSession.Log('Cleanup done');

    FLock.Enter;
    try FSessions.Remove(TSession); finally FLock.Leave; end;
    TSession.Free;

    var ExitCB := FOnGameExit;
    if Assigned(ExitCB) then
      TThread.Queue(nil, procedure
      begin
        FLastExitedPid := TGamePid;
        ExitCB(Self);
      end);
  end).Start;
  except
    if GamePI.hProcess <> 0 then begin
      TerminateProcess(GamePI.hProcess, 1);
      WaitForSingleObject(GamePI.hProcess, 5000);
      CloseHandle(GamePI.hProcess);
    end;
    if GamePI.hThread <> 0 then CloseHandle(GamePI.hThread);
    if S <> nil then
    begin
      S.Log('Launch failed; cleaning up this session');
      S.StopPipe;
      S.Cleanup;
      FreeAndNil(S);
    end;
    raise;
  end;
  finally
    PrivateTicket.Free;
    if ShimReadyEv <> 0 then CloseHandle(ShimReadyEv);
    CloseIfOpen(ClientFile); // the started game holds its own image mapping
  end;
end;

end.
