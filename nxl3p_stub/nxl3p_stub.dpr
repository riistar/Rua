program nxl3p_stub;
(*
  Minimal stub deployed as nexon_client.exe so nexon_api_x64.dll's process scan
  finds a running "nexon_client.exe" and derives the nexon_x64.dll load path.
  No VCL, no GUI, no external deps beyond kernel32.dll.
*)
{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}
{$WARN UNIT_PLATFORM OFF}

uses
  Winapi.Windows;

var
  ExitEv: THandle;
begin
  ExitEv := OpenEventW(SYNCHRONIZE, False, 'NXL3P_StubExit');
  if ExitEv <> 0 then
  begin
    WaitForSingleObject(ExitEv, 120000);
    CloseHandle(ExitEv);
  end
  else
    Sleep(120000);
end.
