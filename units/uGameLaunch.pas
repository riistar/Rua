unit uGameLaunch;
(*
  Orchestrates game launch.

  ARCHITECTURE (Ghidra RE of nexon_api_x64.dll — nxapi2_init):
    1. Scans process list for "nexon_client.exe" via CreateToolhelp32Snapshot
    2. Gets its full path via K32GetModuleFileNameExW
    3. Strips filename → directory, appends "bin\nexon_x64.dll" → DLL path
    4. LoadLibraryW(that path) → GetProcAddress("nxapi_get_func_addr")
    5. Dispatches BEEF codes for init/close/getProductId/getProductTicket/etc.

  STRATEGY:
    - Write passport ticket to %TEMP%\nxl3p_ticket.txt (shim reads it on ShimInit)
    - Run nxl3p_stub.exe (renamed nexon_client.exe) so nxapi2_init finds it
    - Deploy nxl3p_shim.dll as {our_dir}\bin\nexon_x64.dll (fake SDK)
    - nxapi2_init → finds stub → derives {our_dir}\bin\ path → loads shim
    - Shim reads ticket, fills GTicket, signals NXL3P_ShimReady
    - Kill stub after ShimReady (or 30s timeout), game already has ticket

  LAUNCH SEQUENCE:
    1. CleanupStub      — kill any previous stub, delete deployed files
    2. FetchAccess + CheckPlayable + FetchPassport
    3. WriteTicketFile  — %TEMP%\nxl3p_ticket.txt
    4. Deploy stub as nexon_client.exe in our dir
    5. Create NXL3P_StubExit + NXL3P_ShimReady events
    6. Spawn nexon_client.exe
    7. Deploy nxl3p_shim.dll → {our_dir}\bin\nexon_x64.dll
    8. FetchGameConfig
    9. Start pipe server
   10. ShellExecuteEx Client.exe
   11. Background: wait ShimReady (30s) → kill stub → wait game exit → cleanup
*)

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
    FGameRunning:   Boolean;
    FOnGameExit:    TNotifyEvent;
    FLauncherDir:   string;   // directory containing nxl3p_stub.exe + nxl3p_shim.dll
    procedure StopPipe;
    procedure CleanupStub;
  public
    constructor Create(const ALauncherDir: string = '');
    destructor Destroy; override;
    procedure Launch(const Cookies: string; ProductId: Integer;
      const GameExePath: string; const UserNo: string = '');
    function IsRunning: Boolean;
    property OnGameExit: TNotifyEvent read FOnGameExit write FOnGameExit;
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, Winapi.TlHelp32,
  System.Hash, System.NetEncoding,
  System.IOUtils;

procedure LaunchLog(const Msg: string);
begin
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

constructor TGameLauncher.Create(const ALauncherDir: string = '');
begin
  inherited Create;
  FLauncherDir := ALauncherDir;
end;

{ TGameLauncher }

procedure WriteTicketFile(const Ticket: string);
var
  Path:  string;
  Bytes: TBytes;
begin
  Path  := GetEnvironmentVariable('TEMP') + '\nxl3p_ticket.txt';
  Bytes := TEncoding.UTF8.GetBytes(Ticket);
  TFile.WriteAllBytes(Path, Bytes);
end;

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

procedure KillAllStubs;
var
  Snap: THandle;
  PE:   TProcessEntry32;
  hProc: THandle;
begin
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    PE.dwSize := SizeOf(PE);
    if Process32First(Snap, PE) then
      repeat
        if SameText(string(PE.szExeFile), 'nexon_client.exe') then
        begin
          hProc := OpenProcess(PROCESS_TERMINATE, False, PE.th32ProcessID);
          if hProc <> 0 then
          begin
            TerminateProcess(hProc, 0);
            CloseHandle(hProc);
          end;
        end;
      until not Process32Next(Snap, PE);
  finally
    CloseHandle(Snap);
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
    TerminateProcess(FStubProcess, 0);
    WaitForSingleObject(FStubProcess, 2000);
    CloseHandle(FStubProcess);
    FStubProcess := 0;
  end;
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
  SEI: TShellExecuteInfo;
  ShimReadyEv: THandle;
begin
  PidStr  := IntToStr(ProductId);
  GameDir := ExtractFileDir(GameExePath);
  if FLauncherDir <> '' then
    OurDir := FLauncherDir
  else
    OurDir := ExtractFileDir(GetModuleName(0));

  // 1. Clean up previous deployment
  CleanupStub;

  // 2. Auth: /account → /access → /playable → /passport (official launcher sequence).
  // /account returns Set-Cookie headers that establish the server-side session scope.
  var AuthCookies := FetchAccountAndMerge(Cookies);
  // Strip loopback if account returned set-cookie with refreshed tokens
  if AuthCookies = Cookies then
    LaunchLog('FetchAccount: no new cookies')
  else
    LaunchLog('FetchAccount: Set-Cookie merged');
  AuthCookies := FetchAccess(AuthCookies, PidStr);
  LaunchLog('FetchAccess: OK');

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
  LaunchLog('Ticket: ' + Copy(Ticket, 1, 40) + '...');

  // 3. Write passport ticket to temp file — shim reads it in ShimInit
  WriteTicketFile(Ticket);
  LaunchLog('Ticket file written');

  // 4. Deploy stub as nexon_client.exe in our dir
  StubSrc := OurDir + '\nxl3p_stub.exe';
  StubDst := OurDir + '\nexon_client.exe';
  if not TFile.Exists(StubSrc) then
    raise Exception.CreateFmt('nxl3p_stub.exe not found: %s', [StubSrc]);
  TFile.Copy(StubSrc, StubDst, True);
  FStubPath := StubDst;
  LaunchLog('Stub deployed: ' + StubDst);

  // 5. Create named events BEFORE spawning stub/game.
  //    Reset both explicitly — CreateEventW reuses existing kernel objects
  //    whose state may be signaled from a prior run.
  if FStubExitEvent <> 0 then begin CloseHandle(FStubExitEvent); FStubExitEvent := 0; end;
  FStubExitEvent := CreateEventW(nil, True, False, 'NXL3P_StubExit');
  ResetEvent(FStubExitEvent);
  ShimReadyEv    := CreateEventW(nil, True, False, 'NXL3P_ShimReady');
  ResetEvent(ShimReadyEv);

  // 6. Spawn stub
  ZeroMemory(@SI, SizeOf(SI));
  SI.cb := SizeOf(SI);
  CmdLine := '"' + StubDst + '"';
  UniqueString(CmdLine);
  ZeroMemory(@PI, SizeOf(PI));
  if CreateProcessW(nil, PWideChar(CmdLine), nil, nil, False,
      CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(PI.hThread);
    FStubProcess := PI.hProcess;
    LaunchLog('Stub spawned PID=' + IntToStr(PI.dwProcessId));
    Sleep(300);
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
  TFile.Copy(ShimSrc, ShimDst, True);
  FShimPath := ShimDst;
  LaunchLog('Shim deployed: ' + ShimDst);

  // 8. Game params
  Config := FetchGameConfig(AuthCookies, ProductId);
  Params := Copy(Config.Parameters, 0, Length(Config.Parameters));
  SubstitutePassport(Params, Ticket);
  CL       := BuildCommandLine(GameExePath, Params);
  ParamStr := Trim(Copy(CL, Length('"' + GameExePath + '"') + 1, MaxInt));
  {$IFDEF DEBUG}LaunchLog('Launch params: ' + ParamStr);{$ENDIF}

  // 9. Pipe server (handles getProductTicket / getSDKConfiguration callbacks)
  StopPipe;
  FPipeThread := TPipeServerThread.Create(Ticket, Hashed, ProductId);
  FPipeThread.Start;
  Sleep(100);

  // 10. Launch game
  ZeroMemory(@SEI, SizeOf(SEI));
  SEI.cbSize       := SizeOf(SEI);
  SEI.fMask        := SEE_MASK_NOCLOSEPROCESS;
  SEI.lpFile       := PChar(GameExePath);
  SEI.lpParameters := PChar(ParamStr);
  SEI.lpDirectory  := PChar(GameDir);
  SEI.nShow        := SW_SHOWNORMAL;
  FGameRunning := True;
  if not ShellExecuteEx(@SEI) then
  begin
    FGameRunning := False;
    CloseHandle(ShimReadyEv);
    raise Exception.CreateFmt('ShellExecuteEx failed (%d): %s', [GetLastError, GameExePath]);
  end;
  LaunchLog('Client.exe launched PID=' + IntToStr(GetProcessId(SEI.hProcess)));

  // 11. Background thread: wait game exit → cleanup
  // CAPTURE ALL needed values by value — TGameLauncher may be freed before
  // the thread finishes if user launches again while game still runs.
  var TStubProc    := FStubProcess;   FStubProcess   := 0;
  var TStubEvent   := FStubExitEvent; FStubExitEvent := 0;
  var TStubPath    := FStubPath;      FStubPath      := '';
  var TShimPath    := FShimPath;      FShimPath      := '';
  var TReadyEv     := ShimReadyEv;
  var TGameProc    := SEI.hProcess;
  var TOnGameExit  := FOnGameExit;    FOnGameExit    := nil;

  TThread.CreateAnonymousThread(procedure
  var Code: DWORD;
  begin
    if TReadyEv <> 0 then
    begin
      WaitForSingleObject(TReadyEv, 30000);
      CloseHandle(TReadyEv);
    end;
    LaunchLog('ShimReady or timeout — stub alive until game exit');

    if TGameProc <> 0 then
    begin
      WaitForSingleObject(TGameProc, INFINITE);
      Code := 0;
      GetExitCodeProcess(TGameProc, Code);
      CloseHandle(TGameProc);
      LaunchLog('Client.exe exited code=' + IntToStr(Code));
    end;

    if TStubEvent <> 0 then begin SetEvent(TStubEvent); Sleep(200); CloseHandle(TStubEvent); end;
    if TStubProc  <> 0 then begin TerminateProcess(TStubProc, 0); WaitForSingleObject(TStubProc, 2000); CloseHandle(TStubProc); end;
    try if TStubPath <> '' then TFile.Delete(TStubPath); except end;
    try if TShimPath <> '' then TFile.Delete(TShimPath); except end;
    LaunchLog('Cleanup done');

    if Assigned(TOnGameExit) then
      TThread.Queue(nil, procedure begin TOnGameExit(nil); end);
  end).Start;
end;

end.
