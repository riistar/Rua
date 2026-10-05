library RuaAPI;
{
  RuaAPI.dll — DLL interface for Rua launcher functions.

  Exposes login, session check, manifest check, patch download, and game
  launch as C-compatible stdcall exports.  See docs/DLL-API.md for the full
  API reference and the RuaAPI.h C header.
}

uses
  System.SysUtils,
  uRuaAPI   in 'src\units\uRuaAPI.pas',
  uNexonAPI in 'src\units\uNexonAPI.pas',
  uNxlPatcher in 'src\units\uNxlPatcher.pas',
  uGameLaunch in 'src\units\uGameLaunch.pas',
  uPipeServer in 'src\units\uPipeServer.pas',
  uProtocol   in 'src\units\uProtocol.pas',
  uDeviceId   in 'src\units\uDeviceId.pas',
  uIgnoreList in 'src\units\uIgnoreList.pas';

{$R *.res}

exports
  RuaLogin,
  RuaLoginOTP,
  RuaSessionCheck,
  RuaCheckUpdate,
  RuaRunPatcher,
  RuaLaunch,
  RuaGetLastError;

begin
end.
