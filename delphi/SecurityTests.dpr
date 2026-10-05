program SecurityTests;
{$APPTYPE CONSOLE}
uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.ZLib,
  uLaunchSecurity in 'src\units\uLaunchSecurity.pas',
  uProtocol in 'src\units\uProtocol.pas',
  uPipeServer in 'src\units\uPipeServer.pas',
  uIgnoreList in 'src\units\uIgnoreList.pas',
  uNxlPatcher in 'src\units\uNxlPatcher.pas',
  uHooks in 'src\units\uHooks.pas',
  uSignature in 'src\units\uSignature.pas';

const FakeTicket = 'SYNTHETIC-TICKET-NOT-A-CREDENTIAL';
procedure Check(Condition: Boolean; const MessageText: string);
begin if not Condition then raise Exception.Create(MessageText); end;

function Connect(const PipeName: string): THandle;
var I: Integer;
begin
  Result := INVALID_HANDLE_VALUE;
  for I := 1 to 100 do begin
    Result := CreateFileW(PWideChar(PipeName), GENERIC_READ or GENERIC_WRITE,
      0, nil, OPEN_EXISTING, 0, 0);
    if Result <> INVALID_HANDLE_VALUE then Exit;
    Sleep(20);
  end;
end;

function ResponseAvailable(Handle: THandle): Boolean;
var Available: DWORD; I: Integer;
begin
  Result := False;
  for I := 1 to 100 do begin
    Available := 0;
    if not PeekNamedPipe(Handle, nil, 0, nil, @Available, nil) then Exit;
    if Available >= 4 then Exit(True);
    Sleep(20);
  end;
end;

procedure ClientMode;
var Pipe: THandle; Data: TBytes; FrameSize: Integer; Written: DWORD;
begin
  Pipe := Connect(ParamStr(2));
  Check(Pipe <> INVALID_HANDLE_VALUE, 'Client could not connect');
  try
    if ParamStr(3) = 'oversize' then begin
      FrameSize := MAX_PIPE_FRAME + 1;
      WriteFile(Pipe, FrameSize, 4, Written, nil);
      Check(not ResponseAvailable(Pipe), 'Oversized frame received a response');
    end else begin
      Data := TEncoding.UTF8.GetBytes('{"type":"getProductTicket","req":{"productId":10200}}');
      Check(WritePipeFrame(Pipe, Data), 'Authorized write failed');
      Check(ResponseAvailable(Pipe), 'Authorized response missing');
      Check(ReadPipeFrame(Pipe, Data), 'Authorized response failed');
      Check(Pos(FakeTicket, TEncoding.UTF8.GetString(Data)) > 0, 'Wrong synthetic response');
    end;
  finally CloseHandle(Pipe); end;
end;

procedure TestPipe(const Mode: string);
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  Server, DuplicateServer: TPipeServerThread;
  Id: TGUID;
  PipeName, CommandLine: string;
  Denied: THandle;
  Data: TBytes;
  ExitCode: DWORD;
  Rejected: Boolean;
begin
  CreateGUID(Id); PipeName := '\\.\pipe\Rua.SecurityTest.' + GUIDToString(Id);
  CommandLine := '"' + ParamStr(0) + '" --client "' + PipeName + '" ' + Mode;
  UniqueString(CommandLine);
  ZeroMemory(@SI, SizeOf(SI)); SI.cb := SizeOf(SI);
  ZeroMemory(@PI, SizeOf(PI));
  Check(CreateProcessW(PWideChar(ParamStr(0)), PWideChar(CommandLine), nil, nil,
    False, CREATE_SUSPENDED or CREATE_NO_WINDOW, nil, nil, SI, PI), 'Test process creation failed');
  Server := nil;
  try
    Server := TPipeServerThread.Create(FakeTicket, 'synthetic-user', 10200, PI.hProcess, PipeName);
    Server.Start;
    Rejected := False;
    try
      DuplicateServer := TPipeServerThread.Create(FakeTicket, '', 10200, PI.hProcess, PipeName);
      DuplicateServer.Free;
    except Rejected := True; end;
    Check(Rejected, 'A second server claimed the same pipe name');
    // Parent is deliberately not the authorized child process.
    Denied := Connect(PipeName);
    Check(Denied <> INVALID_HANDLE_VALUE, 'Unauthorized test connection failed');
    try
      Data := TEncoding.UTF8.GetBytes('{"type":"getProductTicket","req":{"productId":10200}}');
      WritePipeFrame(Denied, Data);
      Check(not ResponseAvailable(Denied), 'Unauthorized process received data');
    finally CloseHandle(Denied); end;
    Check(ResumeThread(PI.hThread) <> DWORD(-1), 'Test child resume failed');
    Check(WaitForSingleObject(PI.hProcess, 10000) = WAIT_OBJECT_0, 'Test child timed out');
    GetExitCodeProcess(PI.hProcess, ExitCode);
    Check(ExitCode = 0, 'Synthetic client failed');
  finally
    if WaitForSingleObject(PI.hProcess, 0) = WAIT_TIMEOUT then begin
      TerminateProcess(PI.hProcess, 1); WaitForSingleObject(PI.hProcess, 5000);
    end;
    Server.Free;
    CloseHandle(PI.hThread); CloseHandle(PI.hProcess);
  end;
  Writeln('PASS: pipe identity, name collision, and ', Mode);
end;

procedure TestMapping;
var Ticket: TPrivateTicket; Name, Value, Previous: string; Handle: THandle; Rejected: Boolean;
begin
  Previous := GetEnvironmentVariable(TICKET_ENV);
  Ticket := TPrivateTicket.Create(FakeTicket);
  Name := Ticket.Name;
  try
    SetEnvironmentVariableW(PWideChar(TICKET_ENV), PWideChar(Name));
    Check(ReadPrivateTicket(Value) and (Value = FakeTicket), 'Memory ticket roundtrip failed');
    Check(GetEnvironmentVariable(TICKET_ENV) = '', 'Child mapping identifier not cleared');
  finally
    Ticket.Free;
    if Previous = '' then SetEnvironmentVariableW(PWideChar(TICKET_ENV), nil)
    else SetEnvironmentVariableW(PWideChar(TICKET_ENV), PWideChar(Previous));
  end;
  Handle := OpenFileMappingW(FILE_MAP_READ, False, PWideChar(Name));
  if Handle <> 0 then CloseHandle(Handle);
  Check(Handle = 0, 'Mapping survived final close');
  Rejected := False;
  try Ticket := TPrivateTicket.Create(StringOfChar('x', 5000)); Ticket.Free;
  except Rejected := True; end;
  Check(Rejected, 'Oversized ticket accepted');
  Writeln('PASS: memory ticket roundtrip, cleanup, and size limit');
end;

function PathRejected(const P: string): Boolean;
begin
  Result := False;
  try SafeManifestPath(P); except Result := True; end;
end;

function TargetRejected(const Root, P: string): Boolean;
begin
  Result := False;
  try ContainedTarget(Root, P); except Result := True; end;
end;

function DecompRejected(const Data: TBytes; Limit: Int64): Boolean;
begin
  Result := False;
  try BoundedZlibDecomp(Data, Limit); except Result := True; end;
end;

function Zlib(const Data: TBytes): TBytes;
var Output: TBytesStream; Z: TCompressionStream;
begin
  Output := TBytesStream.Create;
  try
    Z := TCompressionStream.Create(clDefault, Output);
    try if Length(Data) > 0 then Z.WriteBuffer(Data[0], Length(Data)); finally Z.Free; end;
    Result := Copy(Output.Bytes, 0, Output.Size);
  finally Output.Free; end;
end;

procedure TestPatcherRules;
const
  HOSTILE: array[0..15] of string = ('..\evil.dll', 'a\..\..\evil.dll', '\Windows\evil.dll',
    'C:\evil.dll', '\\server\share\x', 'package\data.it:stream', 'CON', 'nul.txt', 'aux\x',
    'dir\file.', 'dir \x', 'a\\b', '.\x', 'a/../../b', 'a<b', 'COM1.dll');
var
  Root, Path, ActualTarget, ExpectedTarget: string;
  Data, Compressed, Back: TBytes;
begin
  Check(Sha1Hex(TEncoding.ASCII.GetBytes('abc')) = 'a9993e364706816aba3e25717850c26c9cd0d89d', 'SHA1 known answer');
  Check(IsSha1Hex('eaeb63990ab6ca7b4605c35db84fc2b29ffdad19'), 'Valid manifest id rejected');
  Check(not IsSha1Hex('EAEB63990AB6CA7B4605C35DB84FC2B29FFDAD19'), 'Uppercase id accepted');
  Check(not IsSha1Hex('../../../../evil'), 'Path accepted as id');
  Check(not IsSha1Hex(''), 'Empty id accepted');
  for Path in HOSTILE do
    Check(PathRejected(Path), 'Hostile manifest path accepted: ' + Path);
  Check(PathRejected('x' + #7), 'Control character accepted');
  Check(PathRejected(StringOfChar('a', 201)), 'Over-long path accepted');
  Check(SafeManifestPath('package\data_00906.it') = 'package\data_00906.it', 'Normal path rejected');
  Check(SafeManifestPath('mp3/Title.mp3') = 'mp3\Title.mp3', 'Forward slash not normalized');

  Root := TPath.Combine(TPath.GetTempPath, 'rua-tests-' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(TPath.Combine(Root, 'appdata'));
  try
    Check(ResolvePatchFileRoot(Root) = TPath.Combine(Root, 'appdata'), 'Nexon layout not resolved to appdata');
    Check(ResolvePatchFileRoot(TPath.Combine(Root, 'appdata')) = TPath.Combine(Root, 'appdata'), 'appdata root changed');
    TFile.WriteAllText(TPath.Combine(Root, 'Client.exe'), 'x');
    Check(ResolvePatchFileRoot(Root) = Root, 'Client.exe-beside-patchdata layout not kept');
    ActualTarget := ContainedTarget(Root, 'package\a.it');
    ExpectedTarget := TPath.Combine(Root, 'package\a.it');
    Check(SameText(ActualTarget, ExpectedTarget),
      'Contained target wrong: expected [' + ExpectedTarget + '] actual [' + ActualTarget + ']');
    Check(TargetRejected(Root, '..\outside.it'), 'Escape accepted');
  finally
    TDirectory.Delete(Root, True);
  end;

  SetLength(Data, 2 * 1024 * 1024);
  FillChar(Data[0], Length(Data), 7);
  Compressed := Zlib(Data);
  Check(DecompRejected(Compressed, 1024 * 1024), 'Decompression limit not enforced');
  Back := BoundedZlibDecomp(Compressed, 4 * 1024 * 1024);
  Check(Sha1Hex(Back) = Sha1Hex(Data), 'Part SHA1 differs after roundtrip');
  Back[0] := Back[0] xor 1;
  Check(Sha1Hex(Back) <> Sha1Hex(Data), 'Corrupted part matched');
  Writeln('PASS: patcher ids, path validation, layout, containment, size limits and part verification');
end;

procedure TestSignature(const RealClient: string);
var
  Why, Dir, Fake: string;
  H: THandle;
begin
  Check(not IsNexonSignedClient(TPath.Combine(GetEnvironmentVariable('SystemRoot'), 'System32\notepad.exe'), 0, Why),
    'Non-Client.exe name accepted');
  Dir := TPath.Combine(TPath.GetTempPath, 'rua-sig-' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(Dir);
  try
    Fake := TPath.Combine(Dir, 'Client.exe');
    TFile.Copy(TPath.Combine(GetEnvironmentVariable('SystemRoot'), 'System32\notepad.exe'), Fake);
    Check(not IsNexonSignedClient(Fake, 0, Why), 'Non-Nexon Client.exe accepted');
    Writeln('  refused as expected: ', Why);
  finally
    TDirectory.Delete(Dir, True);
  end;
  if RealClient <> '' then
  begin
    H := CreateFile(PChar(RealClient), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, 0, 0);
    Check(H <> INVALID_HANDLE_VALUE, 'Could not open ' + RealClient);
    try
      Check(IsNexonSignedClient(RealClient, H, Why), 'Real Nexon client refused: ' + Why);
    finally
      CloseHandle(H);
    end;
    Writeln('PASS: signature check accepts the installed Nexon client and refuses others');
  end
  else
    Writeln('PASS: signature check refuses non-Nexon clients (pass --nexon-client <path> to test acceptance)');
  Writeln('  this process elevated: ', BoolToStr(IsProcessElevated, True));
end;

begin
  try
    if ParamStr(1) = '--client' then ClientMode
    else begin
      TestMapping;
      TestPipe('valid');
      TestPipe('oversize');
      TestPatcherRules;
      if ParamStr(1) = '--nexon-client' then TestSignature(ParamStr(2)) else TestSignature('');
      Writeln('PASS: synthetic security tests complete. No game or login was used.');
    end;
  except
    on E: Exception do begin Writeln('FAIL: ', E.Message); Halt(1); end;
  end;
end.
