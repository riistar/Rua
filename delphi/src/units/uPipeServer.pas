unit uPipeServer;

interface

uses Winapi.Windows, System.Classes, System.SysUtils, uProtocol;

const
  NEXON_PIPE_NAME = '\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}';
  MAX_PIPE_FRAME = 65536;

type
  TPipeServerThread = class(TThread)
  private
    FPipe, FStopEvent, FGameProcess: THandle;
    FGamePid: DWORD;
    FTicket, FHashedUserNo: string;
    FProductId: Integer;
    function AuthorizedClient: Boolean;
    function Transfer(Buffer: Pointer; Count: DWORD; Writing: Boolean): Boolean;
    function PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
    function PipeWrite(const Data: TBytes): Boolean;
    procedure ServeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(const Ticket, HashedUserNo: string; ProductId: Integer;
      GameProcess: THandle; const PipeName: string = NEXON_PIPE_NAME);
    destructor Destroy; override;
    procedure StopServer;
  end;

implementation

uses uLaunchSecurity;

constructor TPipeServerThread.Create(const Ticket, HashedUserNo: string;
  ProductId: Integer; GameProcess: THandle; const PipeName: string);
var SA: TSecurityAttributes;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPipe := INVALID_HANDLE_VALUE;
  FStopEvent := CreateEvent(nil, True, False, nil);
  if FStopEvent = 0 then RaiseLastOSError;
  if not DuplicateHandle(GetCurrentProcess, GameProcess, GetCurrentProcess,
    @FGameProcess, 0, False, DUPLICATE_SAME_ACCESS) then RaiseLastOSError;
  FGamePid := GetProcessId(FGameProcess);
  if (FGamePid = 0) or (WaitForSingleObject(FGameProcess, 0) <> WAIT_TIMEOUT) then
    raise Exception.Create('Game process is unavailable');
  FTicket := Ticket;
  FHashedUserNo := HashedUserNo;
  FProductId := ProductId;
  ZeroMemory(@SA, SizeOf(SA));
  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := UserOnlyDescriptor;
  try
    // $8 = PIPE_REJECT_REMOTE_CLIENTS. Never attach to an existing server.
    FPipe := CreateNamedPipeW(PWideChar(PipeName),
      PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED or FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or $8,
      1, 4096, 4096, 5000, @SA);
    if FPipe = INVALID_HANDLE_VALUE then RaiseLastOSError;
  finally
    LocalFree(HLOCAL(SA.lpSecurityDescriptor));
  end;
end;

destructor TPipeServerThread.Destroy;
begin
  StopServer;
  Terminate;
  if Suspended then Start;
  WaitFor;
  if (FPipe <> 0) and (FPipe <> INVALID_HANDLE_VALUE) then CloseHandle(FPipe);
  if FGameProcess <> 0 then CloseHandle(FGameProcess);
  if FStopEvent <> 0 then CloseHandle(FStopEvent);
  FTicket := '';
  inherited;
end;

procedure TPipeServerThread.StopServer;
begin
  if FStopEvent <> 0 then SetEvent(FStopEvent);
  if (FPipe <> 0) and (FPipe <> INVALID_HANDLE_VALUE) then CancelIoEx(FPipe, nil);
end;

function TPipeServerThread.AuthorizedClient: Boolean;
var Pid: ULONG;
begin
  Pid := 0;
  Result := (FGameProcess <> 0) and
    (WaitForSingleObject(FGameProcess, 0) = WAIT_TIMEOUT) and
    GetNamedPipeClientProcessId(FPipe, Pid) and (Pid = FGamePid);
end;

function TPipeServerThread.Transfer(Buffer: Pointer; Count: DWORD;
  Writing: Boolean): Boolean;
var
  Ov: TOverlapped;
  Events: array[0..2] of THandle;
  Done, Got, ErrorCode: DWORD;
  Immediate: BOOL;
begin
  Result := False;
  if (Count = 0) or (Count > MAX_PIPE_FRAME) then Exit;
  Done := 0;
  while Done < Count do begin
    if Terminated or (WaitForSingleObject(FStopEvent, 0) <> WAIT_TIMEOUT) then Exit;
    ZeroMemory(@Ov, SizeOf(Ov));
    Ov.hEvent := CreateEvent(nil, True, False, nil);
    if Ov.hEvent = 0 then Exit;
    try
      Got := 0;
      if Writing then
        Immediate := WriteFile(FPipe, PByte(NativeUInt(Buffer)+Done)^, Count-Done, Got, @Ov)
      else
        Immediate := ReadFile(FPipe, PByte(NativeUInt(Buffer)+Done)^, Count-Done, Got, @Ov);
      if not Immediate then begin
        ErrorCode := GetLastError;
        if ErrorCode <> ERROR_IO_PENDING then Exit;
        Events[0] := Ov.hEvent; Events[1] := FStopEvent; Events[2] := FGameProcess;
        if WaitForMultipleObjects(3, @Events[0], False, 30000) <> WAIT_OBJECT_0 then begin
          CancelIoEx(FPipe, @Ov);
          // Keep OVERLAPPED storage alive until cancellation finishes.
          GetOverlappedResult(FPipe, Ov, Got, True);
          Exit;
        end;
        if not GetOverlappedResult(FPipe, Ov, Got, False) then Exit;
      end;
      if Got = 0 then Exit;
      Inc(Done, Got);
    finally
      CloseHandle(Ov.hEvent);
    end;
  end;
  Result := True;
end;

function TPipeServerThread.PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
begin
  Result := False;
  if (DataLen = 0) or (DataLen > MAX_PIPE_FRAME) then Exit;
  SetLength(Data, DataLen);
  Result := Transfer(@Data[0], DataLen, False);
end;

function TPipeServerThread.PipeWrite(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) > 0) and (Length(Data) <= MAX_PIPE_FRAME);
  if Result then Result := Transfer(@Data[0], Length(Data), True);
end;

procedure TPipeServerThread.Execute;
var
  Ov: TOverlapped;
  Events: array[0..2] of THandle;
  Connected: Boolean;
  ErrorCode, Ignored: DWORD;
begin
  if Terminated then Exit;
  while not Terminated and (WaitForSingleObject(FStopEvent, 0) = WAIT_TIMEOUT)
    and (WaitForSingleObject(FGameProcess, 0) = WAIT_TIMEOUT) do begin
    ZeroMemory(@Ov, SizeOf(Ov));
    Ov.hEvent := CreateEvent(nil, True, False, nil);
    if Ov.hEvent = 0 then Exit;
    try
      Connected := ConnectNamedPipe(FPipe, @Ov);
      if not Connected then begin
        ErrorCode := GetLastError;
        if ErrorCode = ERROR_PIPE_CONNECTED then Connected := True
        else if ErrorCode = ERROR_IO_PENDING then begin
          Events[0] := Ov.hEvent; Events[1] := FStopEvent; Events[2] := FGameProcess;
          if WaitForMultipleObjects(3, @Events[0], False, 30000) = WAIT_OBJECT_0 then
            Connected := GetOverlappedResult(FPipe, Ov, Ignored, False)
          else begin
            CancelIoEx(FPipe, @Ov);
            GetOverlappedResult(FPipe, Ov, Ignored, True);
          end;
        end;
      end;
      if Connected and AuthorizedClient then begin
        try ServeClient; except { malformed input closes this connection } end;
      end;
      DisconnectNamedPipe(FPipe);
    finally
      CloseHandle(Ov.hEvent);
    end;
  end;
end;

procedure TPipeServerThread.ServeClient;
var
  Header, Body, Response: TBytes;
  Size: Integer;
  Request: TNexonRequest;
begin
  while not Terminated and AuthorizedClient do begin
    if not PipeRead(Header, SizeOf(Integer)) then Exit;
    Move(Header[0], Size, SizeOf(Integer));
    if (Size <= 0) or (Size > MAX_PIPE_FRAME) then Exit;
    if not PipeRead(Body, Size) then Exit;
    Request := ParseRequest(Body);
    if not AuthorizedClient then Exit;
    if (Request.ProductId <> 0) and (Request.ProductId <> FProductId) then Exit;
    case Request.ReqType of
      rtGetProductTicket: Response := BuildTicketResponse(Request, FTicket);
      rtGetSDKConfiguration: Response := BuildSDKConfigResponse(Request, FHashedUserNo);
      rtProductActive, rtGetClientToken, rtProductClosed: Response := BuildAckResponse(Request);
    else
      Response := BuildErrorResponse(Request, -30000005);
    end;
    Size := Length(Response);
    SetLength(Header, SizeOf(Integer)); Move(Size, Header[0], SizeOf(Integer));
    if not PipeWrite(Header) or not PipeWrite(Response) then Exit;
    if Request.ReqType = rtProductClosed then Exit;
  end;
end;

end.
