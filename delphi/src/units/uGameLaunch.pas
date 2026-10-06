unit uGameLaunch;
{ Uses a per-launch, user-restricted memory mapping for ticket handoff.
  Starts the game suspended so its exact process can be authorized by the pipe
  before it runs. No ticket file is written. The mapping is cleared on failure
  or after shim initialization (at most 30 seconds). }

interface

uses
  System.SysUtils, System.Classes,
  uProtocol, uPipeServer, uNexonAPI;

type
  TGameLauncher = class
  private
    FPipeThread:    TPipeServerThread;
    FShimPath:      string;   // deployed real nexon_x64.dll
    FStubPath:      string;   // nexon_client.exe stub copy
    FStubProcess:   THandle;
    FStubExitEvent: THandle;
    // Held for the whole session: the deployed copies deny writes/deletes and
    // the folders deny deletes/renames, so nothing can be swapped after checks.
    FStubFile:      THandle;
    FShimFile:      THandle;
    FOurDirLock:    THandle;
    FBinDirLock:    THandle;
    FGameRunning:   Boolean;
    FOnGameExit:    TNotifyEvent;
    procedure StopPipe;
    procedure CleanupStub;
  public
    destructor Destroy; override;
    procedure Launch(const Cookies: string; ProductId: Integer;
      const GameExePath: string; const UserNo: string = '');
    function IsRunning: Boolean;
    property OnGameExit: TNotifyEvent read FOnGameExit write FOnGameExit;
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI,
  System.Hash, System.NetEncoding,
  System.IOUtils, uLaunchSecurity, uHooks, uSignature;

var
  GElevated: Integer = -1; // -1 unknown, 0 no, 1 yes

function Elevated: Boolean;
begin
  if GElevated < 0 then
    GElevated := Ord(IsProcessElevated);
  Result := GElevated = 1;
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

// Copies Src to Dst without following an existing link at Dst, then reopens the
// copy denying writes/deletes and confirms it is byte-identical to Src. The
// returned handle keeps it that way until closed; it still allows the reads and
// image loads the stub/game need.
function DeployVerified(const Src, Dst: string): THandle;
var
  SrcHandle: THandle;
  SrcHash:   string;
begin
  SrcHandle := CreateFile(PChar(Src), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if SrcHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    RefuseLink(SrcHandle, Src);
    SrcHash := Sha256OfHandle(SrcHandle);
    // DeleteFile removes a link itself, never its target. CopyFile then refuses
    // to overwrite anything that reappears, so a race fails closed.
    if (GetFileAttributes(PChar(Dst)) <> INVALID_FILE_ATTRIBUTES) and not DeleteFile(PChar(Dst)) then
      RaiseLastOSError;
    if not CopyFile(PChar(Src), PChar(Dst), True) then RaiseLastOSError;
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

{ TGameLauncher }

procedure TGameLauncher.StopPipe;
begin
  if FPipeThread <> nil then
  begin
    FPipeThread.StopServer;
    FPipeThread.Terminate;
    FPipeThread.WaitFor;
    FreeAndNil(FPipeThread);
  end;
end;

procedure TGameLauncher.CleanupStub;
begin
  if FStubExitEvent <> 0 then
  begin
    SetEvent(FStubExitEvent);
    CloseHandle(FStubExitEvent);
    FStubExitEvent := 0;
  end;
  if FStubProcess <> 0 then
  begin
    if WaitForSingleObject(FStubProcess, 2000) = WAIT_TIMEOUT then
      TerminateProcess(FStubProcess, 0);
    WaitForSingleObject(FStubProcess, 2000);
    CloseHandle(FStubProcess);
    FStubProcess := 0;
  end;
  CloseIfOpen(FStubFile);
  CloseIfOpen(FShimFile);
  if FShimPath <> '' then
  begin
    try TFile.Delete(FShimPath); except end;
    FShimPath := '';
  end;
  if FStubPath <> '' then
  begin
    try TFile.Delete(FStubPath); except end;
    FStubPath := '';
  end;
  CloseIfOpen(FBinDirLock);
  CloseIfOpen(FOurDirLock);
end;

destructor TGameLauncher.Destroy;
begin
  StopPipe;
  CleanupStub;
  inherited;
end;

function TGameLauncher.IsRunning: Boolean;
begin
  Result := FGameRunning;
end;

procedure TGameLauncher.Launch(const Cookies: string; ProductId: Integer;
  const GameExePath: string; const UserNo: string = '');
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
begin
  PidStr  := IntToStr(ProductId);
  GameDir := ExtractFileDir(GameExePath);
  OurDir  := ExtractFileDir(GetModuleName(0));

  // 1. Clean up previous deployment
  CleanupStub;

  // Validate deployment before requesting an authentication ticket.
  if not TFile.Exists(OurDir + '\nxl3p_stub.exe') or
     not TFile.Exists(OurDir + '\nxl3p_shim.dll') then
    raise Exception.Create('Rua launch helpers are missing. Repair the installation before signing in.');

  // Only Nexon's signed Client.exe receives the launch ticket (and, elevated,
  // administrator rights). The handle denies writes until the game has started,
  // so the verified file is the one that runs.
  ClientFile := CreateFile(PChar(GameExePath), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if ClientFile = INVALID_HANDLE_VALUE then
    raise Exception.Create('Mabinogi Client.exe could not be opened: ' + SysErrorMessage(GetLastError));
  PrivateTicket := nil;
  ShimReadyEv := 0;
  ZeroMemory(@GamePI, SizeOf(GamePI));
  try
  RefuseLink(ClientFile, GameExePath);
  if not IsNexonSignedClient(GameExePath, ClientFile, Refusal) then
    raise Exception.Create('Launch refused: ' + Refusal + '. Repair the game through Nexon Launcher.');

  // 2. Auth: /account → /access → /playable → /passport (official launcher sequence).
  // /account returns Set-Cookie headers that establish the server-side session scope.
  var AuthCookies := FetchAccountAndMerge(Cookies);
  // Strip loopback if account returned set-cookie with refreshed tokens
  if AuthCookies = Cookies then
    LaunchLog('FetchAccount: no new cookies')
  else
    LaunchLog('FetchAccount: Set-Cookie merged');
  AuthCookies := FetchAccess(AuthCookies, PidStr, AccessInfo);
  LaunchLog('FetchAccess: HTTP=' + IntToStr(AccessInfo.HttpStatus) + ' isPlayable=' +
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
  LaunchLog('CheckPlayable: HTTP=' + IntToStr(PlayableStatus) + ' OK');

  Ticket := FetchTicket(AuthCookies, ProductId);
  Hashed := HashUserNo(UserNo);
  LaunchLog('Launch ticket received');

  try
  PrivateTicket := TPrivateTicket.Create(Ticket);

  // 4. Deploy stub as nexon_client.exe in our dir (verified copy, held locked)
  FOurDirLock := LockFolder(OurDir);
  StubSrc := OurDir + '\nxl3p_stub.exe';
  StubDst := OurDir + '\nexon_client.exe';
  if not TFile.Exists(StubSrc) then
    raise Exception.CreateFmt('nxl3p_stub.exe not found: %s', [StubSrc]);
  FStubFile := DeployVerified(StubSrc, StubDst);
  FStubPath := StubDst;
  LaunchLog('Stub deployed: ' + StubDst);

  // 5. Create named events BEFORE spawning stub/game.
  if FStubExitEvent <> 0 then begin CloseHandle(FStubExitEvent); FStubExitEvent := 0; end;
  ZeroMemory(@SA, SizeOf(SA));
  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := UserOnlyDescriptor;
  try
    if CreateGUID(StubGuid) <> 0 then
      raise Exception.Create('Could not create launch event identifier');
    StubEventName := 'Local\Rua.Stub.' + GUIDToString(StubGuid);
    FStubExitEvent := CreateEventW(@SA, True, False, PWideChar(StubEventName));
    ErrorCode := GetLastError;
    if FStubExitEvent = 0 then RaiseLastOSError(ErrorCode);
    if ErrorCode = ERROR_ALREADY_EXISTS then begin
      CloseHandle(FStubExitEvent); FStubExitEvent := 0;
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

  // 6. Spawn stub
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
    FStubProcess := PI.hProcess;
    LaunchLog('Stub spawned PID=' + IntToStr(PI.dwProcessId));
    if WaitForSingleObject(FStubProcess, 300) <> WAIT_TIMEOUT then
      raise Exception.Create('Rua compatibility helper exited during setup');
  end
  else
    raise Exception.CreateFmt('Stub spawn failed err=%d', [GetLastError]);

  // 7. Deploy nxl3p_shim.dll → {our_dir}\bin\nexon_x64.dll
  ShimSrc := OurDir + '\nxl3p_shim.dll';
  BinDir  := OurDir + '\bin';
  ShimDst := BinDir + '\nexon_x64.dll';
  if not TFile.Exists(ShimSrc) then
    raise Exception.Create('nxl3p_shim.dll not found next to launcher. Rebuild the shim.');
  TDirectory.CreateDirectory(BinDir);
  FBinDirLock := LockFolder(BinDir); // refuses a junction in place of bin\
  FShimFile := DeployVerified(ShimSrc, ShimDst);
  FShimPath := ShimDst;
  LaunchLog('Shim deployed: ' + ShimDst);

  // 8. Game params
  Config := FetchGameConfig(AuthCookies, ProductId);
  Params := Copy(Config.Parameters, 0, Length(Config.Parameters));
  SubstitutePassport(Params, Ticket);
  CL       := BuildCommandLine(GameExePath, Params);
  ParamStr := Trim(Copy(CL, Length('"' + GameExePath + '"') + 1, MaxInt));
  LaunchLog('Starting game client');

  // Bind authentication to the exact new process before any game code runs.
  ChildEnvironment := TicketEnvironment(PrivateTicket.Name);
  ZeroMemory(@SI, SizeOf(SI)); SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW; SI.wShowWindow := SW_SHOWNORMAL;
  UniqueString(CL);
  if not CreateProcessW(PWideChar(GameExePath), PWideChar(CL), nil, nil, False,
    CREATE_SUSPENDED or CREATE_UNICODE_ENVIRONMENT, PWideChar(ChildEnvironment),
    PWideChar(GameDir), SI, GamePI) then RaiseLastOSError;
  StopPipe;
  FPipeThread := TPipeServerThread.Create(Ticket, Hashed, ProductId, GamePI.hProcess);
  FPipeThread.Start;
  if ResumeThread(GamePI.hThread) = DWORD(-1) then RaiseLastOSError;
  CloseHandle(GamePI.hThread); GamePI.hThread := 0;
  if WaitForSingleObject(ShimReadyEv, 30000) <> WAIT_OBJECT_0 then
    raise Exception.Create('Secure game initialization timed out');
  FreeAndNil(PrivateTicket);
  CloseHandle(ShimReadyEv); ShimReadyEv := 0;
  FGameRunning := True;

  // 11. Background thread: wait game exit → cleanup
  var TKillProc    := FStubProcess;   FStubProcess   := 0;
  var TKillEvent   := FStubExitEvent; FStubExitEvent := 0;
  var TKillPath    := FStubPath;      FStubPath      := '';
  var TKillShim    := FShimPath;      FShimPath      := '';
  var TStubFile    := FStubFile;      FStubFile      := 0;
  var TShimFile    := FShimFile;      FShimFile      := 0;
  var TBinLock     := FBinDirLock;    FBinDirLock    := 0;
  var TDirLock     := FOurDirLock;    FOurDirLock    := 0;
  var TGameProc    := GamePI.hProcess;

  TThread.CreateAnonymousThread(procedure
  var Code: DWORD;
  begin
    if TGameProc <> 0 then
    begin
      WaitForSingleObject(TGameProc, INFINITE);
      Code := 0;
      GetExitCodeProcess(TGameProc, Code);
      CloseHandle(TGameProc);
      LaunchLog('Client.exe exited code=' + IntToStr(Code));
    end;

    if TKillEvent <> 0 then begin SetEvent(TKillEvent); Sleep(200); CloseHandle(TKillEvent); end;
    if TKillProc <> 0 then begin if WaitForSingleObject(TKillProc, 2000) = WAIT_TIMEOUT then TerminateProcess(TKillProc, 0); WaitForSingleObject(TKillProc, 2000); CloseHandle(TKillProc); end;
    // Release the locks only now, after the game and stub have finished with them.
    CloseIfOpen(TStubFile);
    CloseIfOpen(TShimFile);
    try if TKillPath <> '' then TFile.Delete(TKillPath); except end;
    try if TKillShim <> '' then TFile.Delete(TKillShim); except end;
    CloseIfOpen(TBinLock);
    CloseIfOpen(TDirLock);
    LaunchLog('Cleanup done');

    FGameRunning := False;
    var ExitCB := FOnGameExit;
    if Assigned(ExitCB) then
      TThread.Queue(nil, procedure begin ExitCB(Self); end);
  end).Start;
  GamePI.hProcess := 0; // session monitor owns this handle now
  except
    FGameRunning := False;
    if GamePI.hProcess <> 0 then begin
      TerminateProcess(GamePI.hProcess, 1);
      WaitForSingleObject(GamePI.hProcess, 5000);
      CloseHandle(GamePI.hProcess);
    end;
    if GamePI.hThread <> 0 then CloseHandle(GamePI.hThread);
    StopPipe;
    CleanupStub;
    raise;
  end;
  finally
    PrivateTicket.Free;
    if ShimReadyEv <> 0 then CloseHandle(ShimReadyEv);
    CloseIfOpen(ClientFile); // the started game holds its own image mapping
  end;
end;

end.
