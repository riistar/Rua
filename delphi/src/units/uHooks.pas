unit uHooks;
{
  Hook system for Rua. Reads/writes [Hooks] in config.ini.
  Works in GUI mode, CLI mode, and DLL callers alike.
  %PROFILE% in a command string is replaced with the active profile name.
}
interface

type
  TRuaHooks = record
    BeforePatch:  string;
    AfterPatch:   string;
    BeforeLaunch: string;
    AfterLaunch:  string;
  end;

function  LoadHooks: TRuaHooks;
procedure SaveHooks(const H: TRuaHooks);
function RunHookCmd(const Cmd: string; const ProfileName: string = ''): Boolean;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.IOUtils, IniFiles;

function HooksConfigPath: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Rua\config.ini');
end;

function LoadHooks: TRuaHooks;
var
  INI: TIniFile;
begin
  INI := TIniFile.Create(HooksConfigPath);
  try
    Result.BeforePatch  := INI.ReadString('Hooks', 'BeforePatch',  '');
    Result.AfterPatch   := INI.ReadString('Hooks', 'AfterPatch',   '');
    Result.BeforeLaunch := INI.ReadString('Hooks', 'BeforeLaunch', '');
    Result.AfterLaunch  := INI.ReadString('Hooks', 'AfterLaunch',  '');
  finally
    INI.Free;
  end;
end;

procedure SaveHooks(const H: TRuaHooks);
var
  INI: TIniFile;
begin
  TDirectory.CreateDirectory(ExtractFileDir(HooksConfigPath));
  INI := TIniFile.Create(HooksConfigPath);
  try
    INI.WriteString('Hooks', 'BeforePatch',  H.BeforePatch);
    INI.WriteString('Hooks', 'AfterPatch',   H.AfterPatch);
    INI.WriteString('Hooks', 'BeforeLaunch', H.BeforeLaunch);
    INI.WriteString('Hooks', 'AfterLaunch',  H.AfterLaunch);
  finally
    INI.Free;
  end;
end;

procedure SplitCmd(const C: string; out ExePath, Params: string);
var
  P: Integer;
begin
  if (Length(C) > 0) and (C[1] = '"') then
  begin
    P := Pos('"', C, 2);
    if P > 0 then
    begin
      ExePath := Copy(C, 2, P - 2);
      Params  := Trim(Copy(C, P + 1, MaxInt));
    end
    else
      ExePath := C;
  end
  else
  begin
    P := Pos(' ', C);
    if P > 0 then
    begin
      ExePath := Copy(C, 1, P - 1);
      Params  := Trim(Copy(C, P + 1, MaxInt));
    end
    else
      ExePath := C;
  end;
end;

function RunHookCmd(const Cmd: string; const ProfileName: string = ''): Boolean;
var
  C, ExePath, Params: string;
  Info: TShellExecuteInfo;
begin
  Result := False;
  C := Trim(Cmd);
  if C = '' then Exit;
  C := StringReplace(C, '%PROFILE%', ProfileName, [rfReplaceAll, rfIgnoreCase]);
  SplitCmd(C, ExePath, Params);
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize       := SizeOf(Info);
  Info.fMask        := SEE_MASK_NOCLOSEPROCESS;
  Info.lpFile       := PChar(ExePath);
  Info.lpParameters := PChar(Params);
  Info.nShow        := SW_SHOWNORMAL;
  Result := ShellExecuteExW(@Info);
  if Result and (Info.hProcess <> 0) then
    CloseHandle(Info.hProcess); // fire-and-forget
end;

end.
