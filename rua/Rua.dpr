program Rua;

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Forms,
   frmMain        in 'src\forms\frmMain.pas'        {FormMain},
   frmLogin          in 'src\forms\frmLogin.pas'          {FormLogin},
   frmLoginWebView   in 'src\forms\frmLoginWebView.pas'  {FormLoginWebView},
   frmProfile     in 'src\forms\frmProfile.pas'     {FormProfile},
   frmProfileEdit in 'src\forms\frmProfileEdit.pas' {FormProfileEdit},
   frmSettings    in 'src\forms\frmSettings.pas'    {FormSettings},
   frmAbout       in 'src\forms\frmAbout.pas'       {FormAbout},
   uCredStore    in '..\units\uCredStore.pas',
   uProfiles     in '..\units\uProfiles.pas',
   uNexonAPI     in '..\units\uNexonAPI.pas',
   uDeviceId     in '..\units\uDeviceId.pas',
   uBrowserCookies in '..\units\uBrowserCookies.pas',
   uNxlPatcher     in '..\units\uNxlPatcher.pas',
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}

begin
  // Stub mode: we are running as a copy named nexon_client.exe.
  // nexon_api_x64.dll scans for nexon_client.exe by process name before
  // touching the named pipe. We satisfy that check without running the
  // real Nexon Launcher. Just wait until signalled then exit.
  if FindCmdLineSwitch('pipe-stub') then
  begin
    var ExitEv := OpenEventW(SYNCHRONIZE, False, 'NXL3P_StubExit');
    if ExitEv = 0 then
      Sleep(120000) // fallback: 2 min
    else
    begin
      WaitForSingleObject(ExitEv, 120000);
      CloseHandle(ExitEv);
    end;
    Halt(0);
  end;

  var Mutex := CreateMutex(nil, True, 'Global\RuaLauncher_SingleInstance');
  if (Mutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    if Mutex <> 0 then CloseHandle(Mutex);
    Halt(0);
  end;

  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  TStyleManager.TrySetStyle('Sky');
  Application.Title := 'Rua';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
