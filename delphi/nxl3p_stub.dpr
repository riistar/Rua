program nxl3p_stub;
{ Compatibility process for the Nexon SDK. No network or credential handling.
  Requires a per-launch exit event and a live launcher process. }
{$APPTYPE CONSOLE}
uses
  Winapi.Windows, System.SysUtils;

function Run: Integer;
const
  Prefix = 'Local\Mooncrest.Rua.Stub.';
var
  EventName, Suffix: string;
  Id: TGUID;
  ParentId: UInt64;
  Handles: array[0..1] of THandle;
  WaitResult: DWORD;
begin
  Result := 2;
  if (ParamCount <> 4) or (ParamStr(1) <> '--exit-event') or
     (ParamStr(3) <> '--parent-pid') then Exit;
  EventName := ParamStr(2);
  if Copy(EventName, 1, Length(Prefix)) <> Prefix then Exit;
  Suffix := Copy(EventName, Length(Prefix) + 1, MaxInt);
  if Length(Suffix) <> 38 then Exit;
  try
    Id := StringToGUID(Suffix);
  except
    Exit;
  end;
  if not TryStrToUInt64(ParamStr(4), ParentId) then Exit;
  if (ParentId = 0) or (ParentId > High(DWORD)) or
     (ParentId = GetCurrentProcessId) then Exit;
  Handles[0] := OpenEventW(SYNCHRONIZE, False, PWideChar(EventName));
  if Handles[0] = 0 then Exit;
  try
    Handles[1] := OpenProcess(SYNCHRONIZE, False, DWORD(ParentId));
    if Handles[1] = 0 then Exit;
    try
      WaitResult := WaitForMultipleObjects(2, @Handles[0], False, 120000);
      if (WaitResult = WAIT_OBJECT_0) or
         (WaitResult = WAIT_OBJECT_0 + 1) then Result := 0
      else if WaitResult = WAIT_TIMEOUT then Result := 3;
    finally
      CloseHandle(Handles[1]);
    end;
  finally
    CloseHandle(Handles[0]);
  end;
end;

begin
  ExitCode := Run;
end.
