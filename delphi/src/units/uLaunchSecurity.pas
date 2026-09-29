unit uLaunchSecurity;

interface

uses Winapi.Windows, System.SysUtils;

const
  TICKET_ENV = 'MOONCREST_RUA_TICKET_MAP';
  TICKET_CAPACITY = 4096;

type
  TPrivateTicket = class
  private
    FHandle: THandle;
    FView: Pointer;
    FName: string;
  public
    constructor Create(const Ticket: string);
    destructor Destroy; override;
    property Name: string read FName;
  end;

procedure SecureZeroMemory(Buffer: Pointer; Count: NativeUInt);
function UserOnlyDescriptor: Pointer;
function TicketEnvironment(const MappingName: string): string;
function ReadPrivateTicket(out Ticket: string): Boolean;

implementation

uses System.Classes, System.StrUtils;
{$O-}
procedure SecureZeroMemory(Buffer: Pointer; Count: NativeUInt);
var P: PByte;
begin
  P := Buffer;
  while Count > 0 do begin P^ := 0; Inc(P); Dec(Count); end;
end;
{$O+}

function ConvertStringSecurityDescriptorToSecurityDescriptorW(Text: PWideChar;
  Revision: DWORD; out Descriptor: Pointer; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll';
function ConvertSidToStringSidW(Sid: Pointer; out Text: PWideChar): BOOL; stdcall;
  external 'advapi32.dll';

function UserOnlyDescriptor: Pointer;
var
  Token: THandle;
  Needed: DWORD;
  Buffer: TBytes;
  SidText: PWideChar;
  Sddl: string;
begin
  Result := nil;
  Token := 0;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then RaiseLastOSError;
  try
    Needed := 0;
    GetTokenInformation(Token, TokenUser, nil, 0, Needed);
    if Needed = 0 then RaiseLastOSError;
    SetLength(Buffer, Needed);
    if not GetTokenInformation(Token, TokenUser, @Buffer[0], Needed, Needed) then RaiseLastOSError;
    SidText := nil;
    if not ConvertSidToStringSidW(PSIDAndAttributes(@Buffer[0])^.Sid, SidText) then RaiseLastOSError;
    try
      Sddl := 'D:P(A;;GA;;;SY)(A;;GA;;;' + string(SidText) + ')';
      if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(Sddl), 1, Result, nil) then RaiseLastOSError;
    finally
      LocalFree(HLOCAL(SidText));
    end;
  finally
    CloseHandle(Token);
  end;
end;

constructor TPrivateTicket.Create(const Ticket: string);
var
  SA: TSecurityAttributes;
  Id: TGUID;
  Bytes: TBytes;
  LastError: DWORD;
begin
  inherited Create;
  Bytes := TEncoding.UTF8.GetBytes(Ticket);
  try
    if (Length(Bytes) = 0) or (Length(Bytes) > TICKET_CAPACITY - 8) or
       (Length(Ticket) > 1023) or (Pos(#0, Ticket) > 0) then
      raise Exception.Create('Invalid launch ticket length');
    if CreateGUID(Id) <> 0 then raise Exception.Create('Could not allocate ticket identifier');
    FName := 'Local\Rua.Ticket.' + GUIDToString(Id);
    ZeroMemory(@SA, SizeOf(SA));
    SA.nLength := SizeOf(SA);
    SA.lpSecurityDescriptor := UserOnlyDescriptor;
    try
      FHandle := CreateFileMappingW(INVALID_HANDLE_VALUE, @SA, PAGE_READWRITE, 0,
        TICKET_CAPACITY, PWideChar(FName));
      LastError := GetLastError;
      if FHandle = 0 then RaiseLastOSError(LastError);
      if LastError = ERROR_ALREADY_EXISTS then raise Exception.Create('Ticket mapping collision');
    finally
      LocalFree(HLOCAL(SA.lpSecurityDescriptor));
    end;
    FView := MapViewOfFile(FHandle, FILE_MAP_WRITE, 0, 0, TICKET_CAPACITY);
    if FView = nil then RaiseLastOSError;
    ZeroMemory(FView, TICKET_CAPACITY);
    PDWORD(FView)^ := $4D435431;
    PDWORD(NativeUInt(FView) + 4)^ := Length(Bytes);
    Move(Bytes[0], PByte(NativeUInt(FView) + 8)^, Length(Bytes));
  finally
    if Length(Bytes) > 0 then SecureZeroMemory(@Bytes[0], Length(Bytes));
  end;
end;

destructor TPrivateTicket.Destroy;
begin
  if FView <> nil then begin
    SecureZeroMemory(FView, TICKET_CAPACITY);
    UnmapViewOfFile(FView);
  end;
  if FHandle <> 0 then CloseHandle(FHandle);
  inherited;
end;

function TicketEnvironment(const MappingName: string): string;
var
  Block, Cursor: PWideChar;
  Values: TStringList;
  Line: string;
  I: Integer;
begin
  Values := TStringList.Create;
  try
    Block := GetEnvironmentStringsW;
    if Block = nil then RaiseLastOSError;
    try
      Cursor := Block;
      while Cursor^ <> #0 do begin
        Line := string(Cursor);
        if not StartsText(TICKET_ENV + '=', Line) then Values.Add(Line);
        Inc(Cursor, Length(Line) + 1);
      end;
    finally
      FreeEnvironmentStringsW(Block);
    end;
    Values.Add(TICKET_ENV + '=' + MappingName);
    Values.Sort;
    Result := '';
    for I := 0 to Values.Count - 1 do Result := Result + Values[I] + #0;
    Result := Result + #0;
  finally
    Values.Free;
  end;
end;

function ReadPrivateTicket(out Ticket: string): Boolean;
var
  Name: string;
  Handle: THandle;
  View: Pointer;
  Count: DWORD;
  Bytes: TBytes;
begin
  Result := False;
  Ticket := '';
  Name := GetEnvironmentVariable(TICKET_ENV);
  SetEnvironmentVariableW(PWideChar(TICKET_ENV), nil);
  if not StartsStr('Local\Rua.Ticket.{', Name) or (Length(Name) > 100) then Exit;
  Handle := OpenFileMappingW(FILE_MAP_READ, False, PWideChar(Name));
  if Handle = 0 then Exit;
  try
    View := MapViewOfFile(Handle, FILE_MAP_READ, 0, 0, TICKET_CAPACITY);
    if View = nil then Exit;
    try
      if PDWORD(View)^ <> $4D435431 then Exit;
      Count := PDWORD(NativeUInt(View) + 4)^;
      if (Count = 0) or (Count > TICKET_CAPACITY - 8) then Exit;
      SetLength(Bytes, Count);
      try
        Move(PByte(NativeUInt(View) + 8)^, Bytes[0], Count);
        if MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[0]), Count, nil, 0) = 0 then Exit;
        Ticket := TEncoding.UTF8.GetString(Bytes);
        Result := (Length(Ticket) > 0) and (Length(Ticket) <= 1023) and (Pos(#0, Ticket) = 0);
        if not Result then Ticket := '';
      finally
        if Length(Bytes) > 0 then SecureZeroMemory(@Bytes[0], Length(Bytes));
      end;
    finally
      UnmapViewOfFile(View);
    end;
  finally
    CloseHandle(Handle);
  end;
end;

end.
