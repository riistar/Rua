unit uDeviceId;
{
  Derives device ID matching Nexon Launcher's algorithm:
    sha256(wmic_uuid + MachineGuid).hexdigest()
  WMIC UUID: from "wmic csproduct get uuid"
  MachineGuid: HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid
}

interface

function GetDeviceId(const Tag: string = ''): string;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Hash, System.Win.Registry;

function RunCommandOutput(const Cmd: string): string;
var
  SA:         TSecurityAttributes;
  hRead,
  hWrite:     THandle;
  SI:         TStartupInfoW;
  PI:         TProcessInformation;
  CmdBuf:     array[0..511] of WideChar;
  Buf:        array[0..4095] of AnsiChar;
  BytesRead:  DWORD;
begin
  Result := '';
  SA.nLength              := SizeOf(SA);
  SA.bInheritHandle       := True;
  SA.lpSecurityDescriptor := nil;

  if not CreatePipe(hRead, hWrite, @SA, 0) then Exit;
  try
    SetHandleInformation(hRead, HANDLE_FLAG_INHERIT, 0);
    ZeroMemory(@SI, SizeOf(SI));
    SI.cb          := SizeOf(SI);
    SI.dwFlags     := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.hStdOutput  := hWrite;
    SI.hStdError   := hWrite;
    SI.wShowWindow := SW_HIDE;

    StringToWideChar(Cmd, CmdBuf, Length(CmdBuf));
    if CreateProcessW(nil, CmdBuf, nil, nil, True,
      CREATE_NO_WINDOW, nil, nil, SI, PI) then
    begin
      CloseHandle(hWrite); hWrite := 0;
      WaitForSingleObject(PI.hProcess, 5000);
      ReadFile(hRead, Buf[0], SizeOf(Buf) - 1, BytesRead, nil);
      Buf[BytesRead] := #0;
      Result := string(AnsiString(Buf));
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  finally
    CloseHandle(hRead);
    if hWrite <> 0 then CloseHandle(hWrite);
  end;
end;

function GetWMICUUID: string;
var
  Output: string;
  i:      Integer;
begin
  Result := '';
  Output := RunCommandOutput('wmic csproduct get uuid');
  // Find 8-4-4-4-12 hex UUID pattern
  for i := 1 to Length(Output) - 35 do
    if (Length(Output) >= i + 35) and
       (Output[i + 8]  = '-') and
       (Output[i + 13] = '-') and
       (Output[i + 18] = '-') and
       (Output[i + 23] = '-') then
    begin
      Result := Copy(Output, i, 36);
      Break;
    end;
end;

function GetMachineGuid: string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ or $0100 {KEY_WOW64_64KEY});
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if Reg.OpenKeyReadOnly('SOFTWARE\Microsoft\Cryptography') then
    begin
      Result := Reg.ReadString('MachineGuid');
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

function GetDeviceId(const Tag: string = ''): string;
begin
  Result := LowerCase(THashSHA2.GetHashString(GetWMICUUID + GetMachineGuid + Tag, SHA256));
end;

end.
