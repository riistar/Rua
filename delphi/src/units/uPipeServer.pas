unit uPipeServer;
{ Ticket pipe for the game client(s).

  The game hardcodes one pipe name, so every concurrent session shares it. One
  per-process acceptor owns the name (first instance created with
  FILE_FLAG_FIRST_PIPE_INSTANCE, so Rua never attaches to someone else's
  server). Each connection is bound to the session whose game process owns the
  connecting PID and is served on its own thread with that session's ticket.

  A session registers its game with TPipeRegistration and frees it when done.
  Freeing a registration only ends that session's connections; other sessions
  keep their pipe. The acceptor starts with the first registration and stops
  with the last. }

interface

uses Winapi.Windows, System.Classes, System.SysUtils, uProtocol;

const
  NEXON_PIPE_NAME = '\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}';
  MAX_PIPE_FRAME = 65536;

type
  // Ticket data for one game process plus the exact PID allowed to read it.
  TPipeGame = class
  private
    FRefs: Integer;
    FActive: Integer;
    FProcess, FStopEvent: THandle;
    FPid: DWORD;
    FTicket, FHashedUserNo: string;
    FProductId: Integer;
    procedure AddRef;
    procedure Release;
    function IsActive: Boolean;
  public
    constructor Create(const Ticket, HashedUserNo: string; ProductId: Integer;
      GameProcess: THandle);
    destructor Destroy; override;
  end;

  // Session-owned handle on the shared pipe server.
  TPipeRegistration = class
  private
    FGame: TPipeGame;
  public
    constructor Create(const Ticket, HashedUserNo: string; ProductId: Integer;
      GameProcess: THandle);
    destructor Destroy; override; // ends only this session's connections
    procedure StopServer;
  end;

implementation

uses System.SyncObjs, System.Generics.Collections, uLaunchSecurity;

type
  TPipeClientThread = class(TThread)
  private
    FPipe: THandle;
    FGame: TPipeGame;
    FFinished: Integer;
    function AuthorizedClient: Boolean;
    function Transfer(Buffer: Pointer; Count: DWORD; Writing: Boolean): Boolean;
    function PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
    function PipeWrite(const Data: TBytes): Boolean;
    procedure ServeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(Pipe: THandle; Game: TPipeGame);
    function Finished: Boolean;
  end;

  TPipeAcceptor = class(TThread)
  private
    FPipe: THandle;
    FStopEvent: THandle;
    class function CreatePipeInstance(First: Boolean): THandle;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Shutdown;
  end;

var
  GLife: TCriticalSection;   // serializes register / unregister (incl. thread joins)
  GLock: TCriticalSection;   // guards GGames and GHandlers
  GGames: TList<TPipeGame>;
  GHandlers: TList<TPipeClientThread>;
  GAcceptor: TPipeAcceptor;

{ TPipeGame }

constructor TPipeGame.Create(const Ticket, HashedUserNo: string;
  ProductId: Integer; GameProcess: THandle);
begin
  inherited Create;
  FRefs := 1;
  FActive := 1;
  FStopEvent := CreateEvent(nil, True, False, nil);
  if FStopEvent = 0 then RaiseLastOSError;
  if not DuplicateHandle(GetCurrentProcess, GameProcess, GetCurrentProcess,
    @FProcess, 0, False, DUPLICATE_SAME_ACCESS) then RaiseLastOSError;
  FPid := GetProcessId(FProcess);
  if (FPid = 0) or (WaitForSingleObject(FProcess, 0) <> WAIT_TIMEOUT) then
    raise Exception.Create('Game process is unavailable');
  FTicket := Ticket;
  FHashedUserNo := HashedUserNo;
  FProductId := ProductId;
end;

destructor TPipeGame.Destroy;
begin
  if FProcess <> 0 then CloseHandle(FProcess);
  if FStopEvent <> 0 then CloseHandle(FStopEvent);
  FTicket := '';
  inherited;
end;

procedure TPipeGame.AddRef;
begin
  TInterlocked.Increment(FRefs);
end;

procedure TPipeGame.Release;
begin
  if TInterlocked.Decrement(FRefs) = 0 then Free;
end;

function TPipeGame.IsActive: Boolean;
begin
  Result := (TInterlocked.CompareExchange(FActive, 0, 0) = 1) and
    (WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT);
end;

{ TPipeClientThread }

constructor TPipeClientThread.Create(Pipe: THandle; Game: TPipeGame);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPipe := Pipe;
  FGame := Game; // caller already took a reference for this thread
end;

function TPipeClientThread.Finished: Boolean;
begin
  Result := TInterlocked.CompareExchange(FFinished, 0, 0) = 1;
end;

function TPipeClientThread.AuthorizedClient: Boolean;
var Pid: ULONG;
begin
  Pid := 0;
  Result := FGame.IsActive and
    GetNamedPipeClientProcessId(FPipe, Pid) and (Pid = FGame.FPid);
end;

function TPipeClientThread.Transfer(Buffer: Pointer; Count: DWORD;
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
    if Terminated or (WaitForSingleObject(FGame.FStopEvent, 0) <> WAIT_TIMEOUT) then Exit;
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
        Events[0] := Ov.hEvent; Events[1] := FGame.FStopEvent; Events[2] := FGame.FProcess;
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

function TPipeClientThread.PipeRead(out Data: TBytes; DataLen: DWORD): Boolean;
begin
  Result := False;
  if (DataLen = 0) or (DataLen > MAX_PIPE_FRAME) then Exit;
  SetLength(Data, DataLen);
  Result := Transfer(@Data[0], DataLen, False);
end;

function TPipeClientThread.PipeWrite(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) > 0) and (Length(Data) <= MAX_PIPE_FRAME);
  if Result then Result := Transfer(@Data[0], Length(Data), True);
end;

procedure TPipeClientThread.ServeClient;
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
    if (Request.ProductId <> 0) and (Request.ProductId <> FGame.FProductId) then Exit;
    case Request.ReqType of
      rtGetProductTicket: Response := BuildTicketResponse(Request, FGame.FTicket);
      rtGetSDKConfiguration: Response := BuildSDKConfigResponse(Request, FGame.FHashedUserNo);
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

procedure TPipeClientThread.Execute;
begin
  try
    try ServeClient; except { malformed input closes this connection } end;
  finally
    DisconnectNamedPipe(FPipe);
    CloseHandle(FPipe);
    FPipe := 0;
    FGame.Release;
    TInterlocked.Exchange(FFinished, 1);
  end;
end;

{ TPipeAcceptor }

class function TPipeAcceptor.CreatePipeInstance(First: Boolean): THandle;
var
  SA: TSecurityAttributes;
  Mode: DWORD;
begin
  ZeroMemory(@SA, SizeOf(SA));
  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := UserOnlyDescriptor;
  try
    Mode := PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED;
    // Only the first instance claims the name; $8 = PIPE_REJECT_REMOTE_CLIENTS.
    // Never attach to an existing server.
    if First then Mode := Mode or FILE_FLAG_FIRST_PIPE_INSTANCE;
    Result := CreateNamedPipeW(PWideChar(NEXON_PIPE_NAME), Mode,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or $8,
      PIPE_UNLIMITED_INSTANCES, 4096, 4096, 5000, @SA);
    if Result = INVALID_HANDLE_VALUE then RaiseLastOSError;
  finally
    LocalFree(HLOCAL(SA.lpSecurityDescriptor));
  end;
end;

constructor TPipeAcceptor.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPipe := INVALID_HANDLE_VALUE;
  FStopEvent := CreateEvent(nil, True, False, nil);
  if FStopEvent = 0 then RaiseLastOSError;
  FPipe := CreatePipeInstance(True);
end;

destructor TPipeAcceptor.Destroy;
begin
  if (FPipe <> 0) and (FPipe <> INVALID_HANDLE_VALUE) then CloseHandle(FPipe);
  if FStopEvent <> 0 then CloseHandle(FStopEvent);
  inherited;
end;

procedure TPipeAcceptor.Shutdown;
begin
  Terminate;
  SetEvent(FStopEvent);
  if (FPipe <> 0) and (FPipe <> INVALID_HANDLE_VALUE) then CancelIoEx(FPipe, nil);
  if Suspended then Start;
  WaitFor;
end;

procedure TPipeAcceptor.Execute;
var
  Ov: TOverlapped;
  Events: array[0..1] of THandle;
  Connected: Boolean;
  ErrorCode, Ignored: DWORD;
  Pid: ULONG;
  Game: TPipeGame;
  Handler: TPipeClientThread;
  Served: THandle;
  I: Integer;
begin
  while not Terminated do begin
    ZeroMemory(@Ov, SizeOf(Ov));
    Ov.hEvent := CreateEvent(nil, True, False, nil);
    if Ov.hEvent = 0 then Exit;
    try
      Connected := ConnectNamedPipe(FPipe, @Ov);
      if not Connected then begin
        ErrorCode := GetLastError;
        if ErrorCode = ERROR_PIPE_CONNECTED then Connected := True
        else if ErrorCode = ERROR_IO_PENDING then begin
          Events[0] := Ov.hEvent; Events[1] := FStopEvent;
          if WaitForMultipleObjects(2, @Events[0], False, INFINITE) = WAIT_OBJECT_0 then
            Connected := GetOverlappedResult(FPipe, Ov, Ignored, False)
          else begin
            CancelIoEx(FPipe, @Ov);
            GetOverlappedResult(FPipe, Ov, Ignored, True);
          end;
        end;
      end;
    finally
      CloseHandle(Ov.hEvent);
    end;
    if Terminated then Break;
    if not Connected then begin
      DisconnectNamedPipe(FPipe);
      Continue;
    end;

    // Bind the connection to the session that owns the connecting PID.
    Game := nil;
    Pid := 0;
    if GetNamedPipeClientProcessId(FPipe, Pid) then begin
      GLock.Enter;
      try
        for I := 0 to GGames.Count - 1 do
          if (GGames[I].FPid = Pid) and GGames[I].IsActive then begin
            Game := GGames[I];
            Game.AddRef;
            Break;
          end;
        // Reap finished client threads.
        for I := GHandlers.Count - 1 downto 0 do
          if GHandlers[I].Finished then begin
            GHandlers[I].WaitFor;
            GHandlers[I].Free;
            GHandlers.Delete(I);
          end;
      finally
        GLock.Leave;
      end;
    end;

    Served := FPipe;
    if Game = nil then begin
      // Not one of our games: drop the connection.
      DisconnectNamedPipe(Served);
      CloseHandle(Served);
    end else begin
      Handler := TPipeClientThread.Create(Served, Game);
      GLock.Enter;
      try GHandlers.Add(Handler); finally GLock.Leave; end;
      Handler.Start;
    end;

    // The connected instance now belongs to the client thread; listen on a new one.
    FPipe := INVALID_HANDLE_VALUE;
    try
      FPipe := CreatePipeInstance(False);
    except
      Exit; // cannot listen any more; existing connections keep working
    end;
  end;
end;

{ TPipeRegistration }

constructor TPipeRegistration.Create(const Ticket, HashedUserNo: string;
  ProductId: Integer; GameProcess: THandle);
var
  Acceptor: TPipeAcceptor;
begin
  inherited Create;
  FGame := TPipeGame.Create(Ticket, HashedUserNo, ProductId, GameProcess);
  GLife.Enter;
  try
    try
      if GAcceptor = nil then begin
        Acceptor := TPipeAcceptor.Create; // raises if the pipe name is owned elsewhere
        GAcceptor := Acceptor;
      end;
      GLock.Enter;
      try GGames.Add(FGame); finally GLock.Leave; end;
      if GAcceptor.Suspended then GAcceptor.Start;
    except
      GLock.Enter;
      try GGames.Remove(FGame); finally GLock.Leave; end;
      if (GAcceptor <> nil) and (GGames.Count = 0) then begin
        GAcceptor.Shutdown;
        FreeAndNil(GAcceptor);
      end;
      FGame.Release;
      FGame := nil;
      raise;
    end;
  finally
    GLife.Leave;
  end;
end;

procedure TPipeRegistration.StopServer;
begin
  if FGame <> nil then begin
    TInterlocked.Exchange(FGame.FActive, 0);
    SetEvent(FGame.FStopEvent);
  end;
end;

destructor TPipeRegistration.Destroy;
var
  Last: Boolean;
  Handlers: TArray<TPipeClientThread>;
  H: TPipeClientThread;
begin
  if FGame <> nil then begin
    StopServer;
    GLife.Enter;
    try
      GLock.Enter;
      try
        GGames.Remove(FGame);
        Last := GGames.Count = 0;
      finally
        GLock.Leave;
      end;
      if Last and (GAcceptor <> nil) then begin
        GAcceptor.Shutdown;
        FreeAndNil(GAcceptor);
        // Every game is stopped, so remaining client threads are ending.
        GLock.Enter;
        try
          Handlers := GHandlers.ToArray;
          GHandlers.Clear;
        finally
          GLock.Leave;
        end;
        for H in Handlers do begin
          H.WaitFor;
          H.Free;
        end;
      end;
    finally
      GLife.Leave;
    end;
    FGame.Release;
    FGame := nil;
  end;
  inherited;
end;

initialization
  GLife := TCriticalSection.Create;
  GLock := TCriticalSection.Create;
  GGames := TList<TPipeGame>.Create;
  GHandlers := TList<TPipeClientThread>.Create;

finalization
  GHandlers.Free;
  GGames.Free;
  GLock.Free;
  GLife.Free;

end.
