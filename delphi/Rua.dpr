program Rua;

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Forms,
  uCLI           in 'src\units\uCLI.pas',
  frmMain        in 'src\forms\frmMain.pas'        {FormMain},
  frmLogin          in 'src\forms\frmLogin.pas'          {FormLogin},
  frmLoginWebView   in 'src\forms\frmLoginWebView.pas'  {FormLoginWebView},
  frmProfile     in 'src\forms\frmProfile.pas'     {FormProfile},
  frmProfileEdit in 'src\forms\frmProfileEdit.pas' {FormProfileEdit},
  frmSettings    in 'src\forms\frmSettings.pas'    {FormSettings},
  uProtocol     in 'src\units\uProtocol.pas',
  uPipeServer   in 'src\units\uPipeServer.pas',
  uCredStore    in 'src\units\uCredStore.pas',
  uProfiles     in 'src\units\uProfiles.pas',
  uNexonAPI     in 'src\units\uNexonAPI.pas',
  uDeviceId     in 'src\units\uDeviceId.pas',
  uGameLaunch   in 'src\units\uGameLaunch.pas',
  uBrowserCookies in 'src\units\uBrowserCookies.pas',
  uNxlPatcher     in 'src\units\uNxlPatcher.pas',
  uHooks          in 'src\units\uHooks.pas',
  uLoginBrowser    in 'src\units\uLoginBrowser.pas',
  uLoginBrowserWV  in 'src\units\uLoginBrowserWV.pas',
  uLoginBrowserCEF in 'src\units\uLoginBrowserCEF.pas',
  uCefRuntime      in 'src\units\uCefRuntime.pas',
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}

function ConnectMooncrestAccount: Integer;
var
  Profiles: TArray<TNexonProfile>;
  Profile: TNexonProfile;
  Cookies, Name: string;
  Number: Integer;
  Exists: Boolean;
begin
  Result := 2; // Cancellation does not save a profile.
  Profiles := LoadProfiles;
  Number := 1;
  repeat
    Name := 'Nexon account ' + IntToStr(Number);
    Exists := False;
    for var Existing in Profiles do
      if SameText(Existing.Name, Name) then
        Exists := True;
    Inc(Number);
  until not Exists;
  if not TFormLoginWebView.Execute(Cookies, Name, True) then
    Exit;
  if Cookies = '' then
    Exit(1);
  Profile := Default(TNexonProfile);
  Profile.Name := Name;
  Profile.UserNo := ExtractCookieValue(Cookies, 'NexonUserID');
  Profile.DeviceId := GetDeviceId(Name);
  Profile.Products := [10200];
  if not CredSave(Name, Cookies) then
    raise Exception.Create('Windows could not save the Nexon session.');
  try
    SetLength(Profiles, Length(Profiles) + 1);
    Profiles[High(Profiles)] := Profile;
    SaveProfiles(Profiles);
  except
    CredDelete(Name);
    raise;
  end;
  Result := 0;
end;

begin
  // CEF subprocess mode: Chromium relaunches Rua.exe with --type=renderer|gpu-process|...
  // for its helper processes (login browser under Wine). Must run before anything else.
  if IsCefSubProcess then
  begin
    RunCefSubProcess;
    Halt(0);
  end;

  // Headless CLI mode: Rua.exe --cli <command> [options]
  if IsCLIMode then
    Halt(RunCLI);

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
  // Apply the saved theme BEFORE the main form is created, so no control ever
  // paints with the default style. Falls back to Sky only if no theme is saved.
  var ThemeFromCfg := ReadThemeFromConfig;
  if ThemeFromCfg <> '' then
    TStyleManager.TrySetStyle(ThemeFromCfg)
  else
    TStyleManager.TrySetStyle('Sky');
  Application.Title := 'Rua';
  // Sign-in only: omit the main window, startup updates and profile-name prompt.
  if FindCmdLineSwitch('mooncrest-connect') then
  begin
    var ConnectResult := 1;
    try
      ConnectResult := ConnectMooncrestAccount;
    except
      on E: Exception do
        Application.ShowException(E);
    end;
    ShutdownCefRuntime;
    Halt(ConnectResult);
  end;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
  ShutdownCefRuntime; // no-op unless the CEF login browser was used
end.
