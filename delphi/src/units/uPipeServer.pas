unit uPipeServer;
(*
  Named pipe server thread.
  Serves the Nexon SDK pipe that game processes connect to for auth tickets.
  Pipe: \\.\pipe\[79d303ac-af79-46c3-9ae0-6cd4ff4805ad]
  Debug log: %TEMP%\nxl_pipe_debug.txt

  Pipe MUST be created with FILE_FLAG_OVERLAPPED — otherwise ConnectNamedPipe
  with a non-NULL overlapped struct returns ERROR_OPERATION_ABORTED (995) immediately
  and the server never accepts connections.
*)

interface

uses
  Winapi.Windows, System.Classes, System.SysUtils, System.IOUtils, uProtocol;

const
  NEXON_PIPE_NAME = '\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}';

type
  TPipeServerThread = class(TThread)
  private
    FPipe:         THandle;
    FTicket:       string;
    FHashedUserNo: string;
    FProductId:    Integer;
    FStopEvent:    THandle;
    procedure ServeClient;
    function  PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
    function  PipeWrite(const Data: TBytes): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const Ticket, HashedUserNo: string; ProductId: Integer);
    destructor Destroy; override;
    procedure StopServer;
  end;

implementation

procedure PipeLog(const Msg: string);
begin
  try
    TFile.AppendAllText(
      GetEnvironmentVariable('TEMP') + '\nxl_pipe_debug.txt',
      FormatDateTime('[hh:nn:ss.zzz] ', Now) + Msg + sLineBreak,
      TEncoding.UTF8);
  except end;
end;

constructor TPipeServerThread.Create(const Ticket, HashedUserNo: string; ProductId: Integer);
begin
  inherited Create(True);
  FTicket        := Ticket;
  FHashedUserNo  := HashedUserNo;
  FProductId     := ProductId;
  FPipe          := INVALID_HANDLE_VALUE;
  FStopEvent     := CreateEvent(nil, True, False, nil);
  FreeOnTerminate := False;
end;

destructor TPipeServerThread.Destroy;
begin
  StopServer;
  CloseHandle(FStopEvent);
  inherited;
end;

procedure TPipeServerThread.StopServer;
begin
  SetEvent(FStopEvent);
  if FPipe <> INVALID_HANDLE_VALUE then
  begin
    CancelIoEx(FPipe, nil);
    DisconnectNamedPipe(FPipe);
    CloseHandle(FPipe);
    FPipe := INVALID_HANDLE_VALUE;
  end;
end;

// Overlapped read of exactly DataLen bytes; aborts on stop event or 30s timeout.
function TPipeServerThread.PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
var
  Ov:  TOverlapped;
  Got: DWORD;
  WR:  DWORD;
  H:   array[0..1] of THandle;
begin
  Result := False;
  SetLength(Data, DataLen);
  ZeroMemory(@Ov, SizeOf(Ov));
  Ov.hEvent := CreateEvent(nil, True, False, nil);
  try
    if ReadFile(FPipe, Data[0], DataLen, Got, @Ov) then
    begin
      Result := Got = DataLen;
      Exit;
    end;
    if GetLastError <> ERROR_IO_PENDING then Exit;
    H[0] := Ov.hEvent;
    H[1] := FStopEvent;
    WR := WaitForMultipleObjects(2, @H[0], False, 30000);
    if WR <> WAIT_OBJECT_0 then
    begin
      CancelIoEx(FPipe, @Ov);
      Exit;
    end;
    if GetOverlappedResult(FPipe, Ov, Got, False) then
      Result := Got = DataLen;
  finally
    CloseHandle(Ov.hEvent);
  end;
end;

// Overlapped write; waits for completion (responses are small, always fast).
function TPipeServerThread.PipeWrite(const Data: TBytes): Boolean;
var
  Ov:      TOverlapped;
  Written: DWORD;
  Len:     DWORD;
begin
  Result := False;
  Len := Length(Data);
  ZeroMemory(@Ov, SizeOf(Ov));
  Ov.hEvent := CreateEvent(nil, True, False, nil);
  try
    if WriteFile(FPipe, Data[0], Len, Written, @Ov) then
    begin
      Result := Written = Len;
      Exit;
    end;
    if GetLastError <> ERROR_IO_PENDING then Exit;
    if GetOverlappedResult(FPipe, Ov, Written, True) then
      Result := Written = Len;
  finally
    CloseHandle(Ov.hEvent);
  end;
end;

function ReadFrameLen(Thread: TPipeServerThread; out Len: Integer): Boolean;
var
  RawBytes: TBytes;
begin
  Result := False;
  Len    := 0;
  if not Thread.PipeRead(RawBytes, SizeOf(Integer)) then Exit;
  Move(RawBytes[0], Len, SizeOf(Integer));
  Result := Len > 0;
end;

procedure TPipeServerThread.Execute;
var
  Overlapped:  TOverlapped;
  WaitResult:  DWORD;
  Handles:     array[0..1] of THandle;
  ConnResult:  BOOL;
  Err:         DWORD;
begin
  // FILE_FLAG_OVERLAPPED required — ConnectNamedPipe with a non-NULL overlapped
  // struct on a non-overlapped pipe returns ERROR_OPERATION_ABORTED (995) immediately.
  FPipe := CreateNamedPipe(
    NEXON_PIPE_NAME,
    PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
    1,     // max instances — one game at a time
    4096,
    4096,
    5000,
    nil
  );

  if FPipe = INVALID_HANDLE_VALUE then
  begin
    PipeLog('CreateNamedPipe FAILED err=' + IntToStr(GetLastError));
    Exit;
  end;
  PipeLog('Pipe created: ' + NEXON_PIPE_NAME);

  ZeroMemory(@Overlapped, SizeOf(Overlapped));
  Overlapped.hEvent := CreateEvent(nil, True, False, nil);
  try
    ConnResult := ConnectNamedPipe(FPipe, @Overlapped);
    Err := GetLastError;

    if ConnResult or (Err = ERROR_PIPE_CONNECTED) then
    begin
      PipeLog('Client already connected');
      ServeClient;
    end
    else if Err = ERROR_IO_PENDING then
    begin
      Handles[0] := Overlapped.hEvent;
      Handles[1] := FStopEvent;
      WaitResult := WaitForMultipleObjects(2, @Handles[0], False, INFINITE);
      if WaitResult = WAIT_OBJECT_0 then
      begin
        PipeLog('Client connected (async)');
        ServeClient;
      end
      else
        PipeLog('Stop event — no client connected');
    end
    else
      PipeLog('ConnectNamedPipe error: ' + IntToStr(Err));
  finally
    CloseHandle(Overlapped.hEvent);
    StopServer;
  end;
end;

procedure TPipeServerThread.ServeClient;
var
  LenBytes: TBytes;
  BodyBytes: TBytes;
  Len:  Integer;
  Req:  TNexonRequest;
  Resp: TBytes;
  RespLen: Integer;
  LenBuf: array[0..3] of Byte;
begin
  while not Terminated do
  begin
    // Read 4-byte length prefix
    if not PipeRead(LenBytes, SizeOf(Integer)) then
    begin
      PipeLog('Read length failed/disconnected');
      Break;
    end;
    Move(LenBytes[0], Len, SizeOf(Integer));
    if Len <= 0 then
    begin
      PipeLog('Invalid frame length: ' + IntToStr(Len));
      Break;
    end;

    // Read JSON body
    if not PipeRead(BodyBytes, Len) then
    begin
      PipeLog('Read body failed');
      Break;
    end;

    Req := ParseRequest(BodyBytes);
    PipeLog('Request: type=' + Req.TypeStr + ' productId=' + IntToStr(Req.ProductId));

    case Req.ReqType of
      rtGetProductTicket:
        Resp := BuildTicketResponse(Req, FTicket);

      rtGetSDKConfiguration:
        Resp := BuildSDKConfigResponse(Req, FHashedUserNo);

      rtProductActive, rtGetClientToken:
        Resp := BuildAckResponse(Req);

      rtProductClosed:
      begin
        Resp := BuildAckResponse(Req);
        // Write response then exit
        RespLen := Length(Resp);
        Move(RespLen, LenBuf[0], SizeOf(Integer));
        SetLength(LenBytes, SizeOf(Integer));
        Move(LenBuf[0], LenBytes[0], SizeOf(Integer));
        PipeWrite(LenBytes);
        PipeWrite(Resp);
        PipeLog('productClosed — done');
        Break;
      end;
    else
      PipeLog('Unknown request: ' + Req.TypeStr);
      Resp := BuildErrorResponse(Req, -30000005);
    end;

    // Write [length][body]
    RespLen := Length(Resp);
    Move(RespLen, LenBuf[0], SizeOf(Integer));
    SetLength(LenBytes, SizeOf(Integer));
    Move(LenBuf[0], LenBytes[0], SizeOf(Integer));
    if not PipeWrite(LenBytes) then
    begin
      PipeLog('Write length failed');
      Break;
    end;
    if not PipeWrite(Resp) then
    begin
      PipeLog('Write body failed');
      Break;
    end;
    PipeLog('Response sent for: ' + Req.TypeStr);
  end;
end;

end.
