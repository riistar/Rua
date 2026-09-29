program SecurityTests;
{$APPTYPE CONSOLE}
uses
  Winapi.Windows, System.SysUtils, System.Classes,
  uLaunchSecurity in 'src\units\uLaunchSecurity.pas',
  uProtocol in 'src\units\uProtocol.pas',
  uPipeServer in 'src\units\uPipeServer.pas';

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
  CreateGUID(Id); PipeName := '\\.\pipe\Mooncrest.SecurityTest.' + GUIDToString(Id);
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

begin
  try
    if ParamStr(1) = '--client' then ClientMode
    else begin
      TestMapping;
      TestPipe('valid');
      TestPipe('oversize');
      Writeln('PASS: synthetic security tests complete. No game or login was used.');
    end;
  except
    on E: Exception do begin Writeln('FAIL: ', E.Message); Halt(1); end;
  end;
end.
