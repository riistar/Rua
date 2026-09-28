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
procedure RunHookCmd(const Cmd: string; const ProfileName: string = '');

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils, IniFiles;

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

procedure RunHookCmd(const Cmd: string; const ProfileName: string = '');
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  C:  string;
begin
  C := Trim(Cmd);
  if C = '' then Exit;
  C := StringReplace(C, '%PROFILE%', ProfileName, [rfReplaceAll, rfIgnoreCase]);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  FillChar(PI, SizeOf(PI), 0);
  if CreateProcessW(nil, PChar(C), nil, nil, False,
       CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess); // fire-and-forget
  end;
end;

end.
