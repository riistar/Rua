library Nexon3PAPI;

uses
  System.SysUtils,
  System.Classes,
  Nexon3PAPIImpl in 'src\core_api\Nexon3PAPIImpl.pas',
  uProtocol     in '..\units\uProtocol.pas',
  uPipeServer   in '..\units\uPipeServer.pas',
  uGameLaunch   in '..\units\uGameLaunch.pas',
  uNexonAPI     in '..\units\uNexonAPI.pas',
  uDeviceId     in '..\units\uDeviceId.pas';

exports
  Nexon3PAPI_Init,
  Nexon3PAPI_Shutdown,
  Nexon3PAPI_GetDeviceId,
  Nexon3PAPI_LoginEmailPw,
  Nexon3PAPI_LoginOTP,
  Nexon3PAPI_ExchangeTpa,
  Nexon3PAPI_AutoLogin,
  Nexon3PAPI_CheckSession,
  Nexon3PAPI_GetPassport,
  Nexon3PAPI_FetchGameConfig,
  Nexon3PAPI_CheckPlayable,
  Nexon3PAPI_FetchManifestHash,
  Nexon3PAPI_FetchAccess,
  Nexon3PAPI_FetchAccount,
  Nexon3PAPI_LaunchGame,
  Nexon3PAPI_LaunchStatus;

begin
end.
