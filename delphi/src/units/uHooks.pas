unit uHooks;
{
  Fire-and-forget shell hook execution from [Hooks] in config.ini.
  Supports %PROFILE% substitution.
}
interface

procedure RunHookCmd(const Cmd: string; const ProfileName: string = '');

implementation

uses
  Winapi.Windows, System.SysUtils;

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
