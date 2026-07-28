library nxl3p_shim;
(*
  Shim replacement for nexon_x64.dll deployed by NexonLauncher3P at game launch.

  nexon_api_x64.dll (game dir) calls LoadLibraryW("nexon_x64.dll") and then
  GetProcAddress(..."nxapi_get_func_addr").  It dispatches 6 function codes:

    0xbeef0001  init(UInt64 param)         -> Int  (0 = success)
    0xbeef0002  close()                    -> void (no args)
    0xbeef0003  getProductId(buf, size)    -> Int  (fills WCHAR buf)
    0xbeef0004  getProductTicket(buf, size)-> Int  (fills WCHAR buf) <- critical
    0xbeef0005  getClientToken(buf, size)  -> Int  (fills WCHAR buf)
    0xbeef0006  stub(buf, size)            -> Int

  Ticket IPC: launcher writes UTF-8 ticket to %TEMP%\nxl3p_ticket.txt before
  launching Client.exe. ShimInit (0xbeef0001) reads it on first call.
*)

{$WARN SYMBOL_PLATFORM OFF}
{$WARN UNIT_PLATFORM OFF}

uses
  Winapi.Windows;

var
  GTicket:       array[0..1023] of WideChar;
  GProductIdStr: array[0..31]   of WideChar;
  GInitOK:       Boolean = False;

// --------------------------------------------------------------------------

procedure ShimLog(const Msg: PAnsiChar);
var
  TempDir: array[0..MAX_PATH] of WideChar;
  LogPath: array[0..MAX_PATH + 32] of WideChar;
  hFile:   THandle;
  Written: DWORD;
  Len:     DWORD;
begin
  GetTempPathW(MAX_PATH, @TempDir[0]);
  lstrcpyW(@LogPath[0], @TempDir[0]);
  lstrcatW(@LogPath[0], 'nxl3p_shim_debug.txt');
  hFile := CreateFileW(@LogPath[0], GENERIC_WRITE, FILE_SHARE_READ, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if hFile = INVALID_HANDLE_VALUE then Exit;
  SetFilePointer(hFile, 0, nil, FILE_END);
  Len := lstrlenA(Msg);
  WriteFile(hFile, Msg^, Len, Written, nil);
  WriteFile(hFile, PAnsiChar(#13#10)^, 2, Written, nil);
  CloseHandle(hFile);
end;

// --------------------------------------------------------------------------

procedure WideAssign(Dst: PWideChar; DstCap: Integer; Src: PWideChar);
var
  Len: Integer;
begin
  Len := lstrlenW(Src);
  if Len >= DstCap then Len := DstCap - 1;
  MoveMemory(Dst, Src, Len * SizeOf(WideChar));
  Dst[Len] := #0;
end;

procedure UInt64ToWide(V: UInt64; Dst: PWideChar; DstCap: Integer);
var
  Tmp: array[0..31] of WideChar;
  P, Len, I: Integer;
begin
  if V = 0 then begin
    if DstCap > 1 then begin Dst[0] := '0'; Dst[1] := #0; end;
    Exit;
  end;
  P := 32;
  while (V > 0) and (P > 0) do begin
    Dec(P);
    Tmp[P] := WideChar(Ord('0') + Integer(V mod 10));
    V := V div 10;
  end;
  Len := 32 - P;
  if Len >= DstCap then Len := DstCap - 1;
  for I := 0 to Len - 1 do Dst[I] := Tmp[P + I];
  Dst[Len] := #0;
end;

procedure TrimRight(Buf: PWideChar);
var
  Len: Integer;
begin
  Len := lstrlenW(Buf);
  while (Len > 0) and (Word(Buf[Len - 1]) <= 32) do begin
    Buf[Len - 1] := #0;
    Dec(Len);
  end;
end;

// --------------------------------------------------------------------------

// 0xbeef0001  called from nxapi2_init(*param_1) during game startup
function ShimInit(Param: UInt64): Integer; stdcall;
var
  TempDir:  array[0..MAX_PATH]       of WideChar;
  FilePath: array[0..MAX_PATH + 32]  of WideChar;
  hFile:    THandle;
  Buf:      array[0..4095]           of Byte;
  Read:     DWORD;
  ReadyEv:  THandle;
begin
  ShimLog('ShimInit called');
  Result   := 0; // 0 = success per nxapi2_init convention
  GInitOK  := False;
  FillMemory(@GTicket[0], SizeOf(GTicket), 0);

  UInt64ToWide(Param, @GProductIdStr[0], Length(GProductIdStr));
  // If param looks like a pointer (> max reasonable product ID), default to 10200
  if (GProductIdStr[0] = #0) or (Param > $FFFF) then
    UInt64ToWide(10200, @GProductIdStr[0], Length(GProductIdStr));

  // Read ticket from %TEMP%\nxl3p_ticket.txt, delete immediately after read
  // to minimise exposure window (file only needs to exist for seconds)
  GetTempPathW(MAX_PATH, @TempDir[0]);
  lstrcpyW(@FilePath[0], @TempDir[0]);
  lstrcatW(@FilePath[0], 'nxl3p_ticket.txt');

  hFile := CreateFileW(@FilePath[0], GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if hFile = INVALID_HANDLE_VALUE then
    ShimLog('ShimInit: ticket file not found')
  else
  begin
    FillMemory(@Buf[0], SizeOf(Buf), 0);
    ReadFile(hFile, Buf[0], SizeOf(Buf) - 2, Read, nil);
    CloseHandle(hFile);
    DeleteFileW(@FilePath[0]); // remove immediately — ticket is sensitive
    if Read > 0 then begin
      MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@Buf[0]), -1,
        @GTicket[0], Length(GTicket));
      TrimRight(@GTicket[0]);
      GInitOK := lstrlenW(@GTicket[0]) > 0;
      if GInitOK then ShimLog('ShimInit: ticket loaded, file deleted')
      else ShimLog('ShimInit: ticket empty after read');
    end else
      ShimLog('ShimInit: ReadFile returned 0 bytes');
  end;

  // Signal launcher that shim init is done — stub can be killed now
  ReadyEv := OpenEventW(EVENT_MODIFY_STATE, False, 'NXL3P_ShimReady');
  if ReadyEv <> 0 then begin
    SetEvent(ReadyEv);
    CloseHandle(ReadyEv);
    ShimLog('ShimInit: NXL3P_ShimReady signalled');
  end;
end;

// 0xbeef0002  called with NO args from nxapi2_close
procedure ShimClose; stdcall;
begin
  FillMemory(@GTicket[0], SizeOf(GTicket), 0);
  GInitOK := False;
end;

// 0xbeef0003  getProductId(buf: PWideChar; size: DWORD): Int
function ShimGetProductId(Buf: PWideChar; BufSize: DWORD): Integer; stdcall;
begin
  if (Buf = nil) or (BufSize = 0) then begin Result := -1; Exit; end;
  lstrcpynW(Buf, @GProductIdStr[0], BufSize);
  Result := 0;
end;

// 0xbeef0004  getProductTicket(buf: PWideChar; size: DWORD): Int  <- key
function ShimGetProductTicket(Buf: PWideChar; BufSize: DWORD): Integer; stdcall;
var
  LogBuf: array[0..127] of AnsiChar;
  TicketLen: Integer;
begin
  TicketLen := lstrlenW(@GTicket[0]);
  wsprintfA(@LogBuf[0], 'ShimGetProductTicket: initOK=%d ticketLen=%d', [Byte(GInitOK), TicketLen]);
  ShimLog(@LogBuf[0]);
  if (Buf = nil) or (BufSize = 0) then begin Result := -1; Exit; end;
  if not GInitOK then begin ShimLog('ShimGetProductTicket: not init -> -2'); Result := -2; Exit; end;
  lstrcpynW(Buf, @GTicket[0], BufSize);
  ShimLog('ShimGetProductTicket: ticket copied OK');
  Result := 0;
end;

// 0xbeef0005  getClientToken(buf: PWideChar; size: DWORD): Int
function ShimGetClientToken(Buf: PWideChar; BufSize: DWORD): Integer; stdcall;
begin
  ShimLog('ShimGetClientToken called');
  if (Buf <> nil) and (BufSize > 0) then Buf[0] := #0;
  Result := 0;
end;

// 0xbeef0006 / fallback
function ShimStub(Buf: PWideChar; BufSize: DWORD): Integer; stdcall;
begin
  ShimLog('ShimStub called');
  if (Buf <> nil) and (BufSize > 0) then Buf[0] := #0;
  Result := 0;
end;

// --------------------------------------------------------------------------

// GetDLLInterface — second export of the real nexon_x64.dll.
// nexon_api_x64.dll calls GetProcAddress("GetDLLInterface") on us.
// Return NULL: indicates we do not support the v2 interface.
// nexon_api_x64.dll must fall back to nxapi_get_func_addr BEEF codes (V1 path).
// Returning NULL vs missing-export differs: GetProcAddress(NULL) = 0 regardless,
// but having the export ensures the caller's code flow reaches the NULL check
// rather than crashing on an indirect call through a NULL proc pointer.
function GetDLLInterface: Pointer; stdcall;
begin
  ShimLog('GetDLLInterface called');
  Result := nil;
end;

function nxapi_get_func_addr(Code: DWORD): Pointer; stdcall;
var
  LogBuf: array[0..63] of AnsiChar;
begin
  wsprintfA(@LogBuf[0], 'nxapi_get_func_addr: 0x%08X', [Code]);
  ShimLog(@LogBuf[0]);
  case Code of
    $BEEF0001: Result := @ShimInit;
    $BEEF0002: Result := @ShimClose;
    $BEEF0003: Result := @ShimGetProductId;
    $BEEF0004: Result := @ShimGetProductTicket;
    $BEEF0005: Result := @ShimGetClientToken;
    $BEEF0006: Result := @ShimStub;
  else
    Result := @ShimStub;
  end;
end;

exports
  nxapi_get_func_addr,
  GetDLLInterface;

begin
end.
