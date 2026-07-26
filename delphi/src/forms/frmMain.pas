unit frmMain;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.IOUtils, System.Types, System.SyncObjs,
  System.JSON, System.Generics.Collections, System.DateUtils, System.Math, IniFiles,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Menus,
  uProfiles, uGameLaunch, uNexonAPI, uDeviceId, Vcl.Imaging.pngimage,
  System.ImageList, Vcl.ImgList;

const
  SESSION_CACHE_SECS = 300; // re-check after 5 minutes max

type
  TSessionInfo = record
    Valid:     Boolean;
    HttpCode:  Integer;
    CheckedAt: TDateTime;
  end;

  TFormMain = class(TForm)
    MainMenu:     TMainMenu;
    MenuFile:         TMenuItem;
    MenuAddProfile:   TMenuItem;
    MenuEditProfile:  TMenuItem;
    MenuDeleteProfile: TMenuItem;
    MenuSep1:         TMenuItem;
    MenuRefreshToken: TMenuItem;
    MenuSettings:     TMenuItem;
    MenuExit:         TMenuItem;
    PnlTop:       TPanel;
    PnlLeft:      TPanel;
    LvProfiles:   TListView;
    PnlProfileBtns:   TPanel;
    BtnAddProfile:    TButton;
    BtnEditProfile:   TButton;
    BtnRemoveProfile: TButton;
    PopupProfile: TPopupMenu;
    PopAdd:       TMenuItem;
    PopEdit:      TMenuItem;
    PopDelete:    TMenuItem;
    PnlRight:     TPanel;
    BtnLaunch:    TButton;
    BtnCheckUpdate:  TButton;
    BtnPauseUpdate:  TButton;
    StatusBar:    TStatusBar;
    Image1: TImage;
    Panel1: TPanel;
    LblProgress: TLabel;
    PrgUpdate: TProgressBar;
    MemoLog: TMemo;
    ImageList1: TImageList;
    N1: TMenuItem;
    UpdateLogin: TMenuItem;
    Button1: TButton;
    ReLogin1: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure MenuAddProfileClick(Sender: TObject);
    procedure MenuEditProfileClick(Sender: TObject);
    procedure MenuDeleteProfileClick(Sender: TObject);
    procedure MenuRefreshTokenClick(Sender: TObject);
    procedure MenuSettingsClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure BtnAddProfileClick(Sender: TObject);
    procedure BtnEditProfileClick(Sender: TObject);
    procedure BtnRemoveProfileClick(Sender: TObject);
    procedure BtnLaunchClick(Sender: TObject);
    procedure BtnCheckUpdateClick(Sender: TObject);
    procedure BtnCheckUpdateDropDownClick(Sender: TObject);
    procedure BtnPauseUpdateClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure LvProfilesSelectItem(Sender: TObject; Item: TListItem;
      Selected: Boolean);
    procedure UpdateLoginClick(Sender: TObject);
  private
    FLauncher:       TGameLauncher;
    FDefaultGameExe: string;
    FProductId:      Integer;
    FVerbose:        Boolean;
    FTheme:          string;
    FAutoCheck:      Boolean;
    FAutoUpdate:     Boolean;
    FAutoStart:      Boolean;
    FStartMinimized: Boolean;
    FTrayOnLaunch:   Boolean;
    FRememberLastProfile: Boolean;
    FLastSelectedProfile: string;
    FSortAlpha:      Boolean;
    FSessionCache:   TDictionary<string, TSessionInfo>;
    FTrayIcon:        TTrayIcon;
    FTrayMenu:        TPopupMenu;
    FTrayProfilesSub: TMenuItem; // "Launch Profile" submenu — rebuilt on profile changes
    FUpdateMenu:      TPopupMenu;
    FPauseEvent:      TEvent;
    FCancelDownload:  Boolean;
    FDownloadActive:  Boolean;
    FCleanupOnExit:   Boolean;
    FInRefreshProfiles: Boolean; // suppress session check during auto-select
    procedure RefreshProfiles;
    procedure Log(const Msg: string);
    procedure LogV(const Msg: string);
    procedure LoadExternalStyles;
    function  SelectedProfile: string;
    function  GetProductId: Integer;
    procedure UpdateButtons;
    procedure AutoDetectGame;
    procedure LoadConfig;
    procedure SaveConfig;
    procedure SaveRefreshedCookies(const Profile, Fresh: string);
    function  TryRefreshCookies(const Profile: string; var Cookies: string;
                const LogMsg: TProc<string>): Boolean;
    procedure SetProfileIcon(const Profile: string; IconIndex: Integer);
    procedure CheckSessionCached(const Profile, Cookies: string);
    procedure StartupSessionCheck;
    procedure PromptReLogin(const Profile: string);
    procedure LaunchProfile(const Name: string);
    procedure RefreshTrayMenu;
    procedure TrayProfileClick(Sender: TObject);
    procedure TrayShowClick(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
    procedure GameExitHandler(Sender: TObject);
    procedure WMSysCommand(var Msg: TMessage); message WM_SYSCOMMAND;
    procedure DoCheckAndUpdate(AutoMode: Boolean; ForceAll: Boolean = False; VerifyMode: Boolean = False);
    procedure MenuVerifyRepairClick(Sender: TObject);
    procedure LvProfilesDblClick(Sender: TObject);
    procedure DoRefreshSession(const Profile: string);
    procedure SetAutoStart(Enable: Boolean);
    procedure MigrateLegacyData;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}
{$R ..\..\tray_icon.res}

uses
  Vcl.FileCtrl, Vcl.Themes,
  frmLogin, frmLoginWebView, frmProfile, frmProfileEdit, frmSettings, frmFolderSelect,
  uBrowserCookies, uNxlPatcher, uCredStore;

const
  DEFAULT_PRODUCT = 10200; // Mabinogi

{ Helpers }

procedure TFormMain.MigrateLegacyData;
const
  OLD_APP  = 'NexonLauncher3P';
  NEW_APP  = 'Rua';
  OLD_CRED = OLD_APP + '\';
var
  OldDir, NewDir: string;
  Profs:          TArray<TNexonProfile>;
  Names:          TArray<string>;
  I, Moved:       Integer;
  procedure TryMoveFile(const OldName, NewName: string);
  begin
    if TFile.Exists(OldName) and not TFile.Exists(NewName) then
    try
      TDirectory.CreateDirectory(TPath.GetDirectoryName(NewName));
      TFile.Move(OldName, NewName);
    except end;
  end;
begin
  OldDir := TPath.Combine(GetEnvironmentVariable('APPDATA'), OLD_APP);
  NewDir := TPath.Combine(GetEnvironmentVariable('APPDATA'), NEW_APP);
  if not TDirectory.Exists(OldDir) then Exit; // nothing to migrate

  // Move flat files
  TryMoveFile(TPath.Combine(OldDir, 'profiles.json'),
              TPath.Combine(NewDir, 'profiles.json'));
  TryMoveFile(TPath.Combine(OldDir, 'config.ini'),
              TPath.Combine(NewDir, 'config.ini'));

  // Migrate credentials: read profiles (may have just been moved), migrate each
  Profs := LoadProfiles;
  SetLength(Names, Length(Profs));
  for I := 0 to High(Profs) do Names[I] := Profs[I].Name;
  Moved := CredMigrateFrom(OLD_CRED, Names);
  if Moved > 0 then
    Log(Format('Migrated %d credential(s) from %s to %s.', [Moved, OLD_APP, NEW_APP]));
end;

procedure TFormMain.SetAutoStart(Enable: Boolean);
var
  RKey: HKEY;
begin
  if RegOpenKeyEx(HKEY_CURRENT_USER,
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 0, KEY_SET_VALUE, RKey) = ERROR_SUCCESS then
  begin
    try
      if Enable then
        RegSetValueEx(RKey, 'Rua', 0, REG_SZ, PByte(ParamStr(0)), (Length(ParamStr(0)) + 1) * 2)
      else
        RegDeleteValue(RKey, 'Rua');
    finally
      RegCloseKey(RKey);
    end;
  end;
end;

function AppConfigPath: string;
begin
  Result := TPath.Combine(
    GetEnvironmentVariable('APPDATA'),
    'Nexon Launcher\appconfig.json');
end;

function FindGameExe(ProductId: Integer): string;
var
  CfgPath, Raw: string;
  J, Apps, App: TJSONObject;
  Keys:         TArray<string>;
begin
  Result := '';
  CfgPath := AppConfigPath;
  if not TFile.Exists(CfgPath) then Exit;
  Raw := TFile.ReadAllText(CfgPath, TEncoding.UTF8);
  J := TJSONObject.ParseJSONValue(Raw) as TJSONObject;
  if J = nil then Exit;
  try
    Apps := J.GetValue('installedApps') as TJSONObject;
    if Apps = nil then Exit;
    // Try exact product ID key
    App := Apps.GetValue(IntToStr(ProductId)) as TJSONObject;
    if App = nil then Exit;
    var InstPath := App.GetValue<string>('installPath', '');
    var ExePath  := App.GetValue<string>('exePath', '');
    if (InstPath <> '') and (ExePath <> '') then
      Result := TPath.Combine(InstPath, ExePath);
  finally
    J.Free;
  end;
end;

{ TFormMain }

function ConfigPath: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'),
    'Rua\config.ini');
end;

procedure TFormMain.LoadConfig;
var
  INI: TIniFile;
begin
  if not TFile.Exists(ConfigPath) then Exit;
  INI := TIniFile.Create(ConfigPath);
  try
    var Path := INI.ReadString('Game', 'Path', '');
    if Path <> '' then FDefaultGameExe := Path;
    FProductId := INI.ReadInteger('Game', 'ProductId', DEFAULT_PRODUCT);
    FAutoCheck      := INI.ReadBool('Update', 'AutoCheck',  False);
    FAutoUpdate     := INI.ReadBool('Update', 'AutoUpdate', False);
    FAutoStart      := INI.ReadBool('Startup', 'AutoStart', False);
    FStartMinimized := INI.ReadBool('Startup', 'StartMinimized', False);
    FTrayOnLaunch   := INI.ReadBool('Startup', 'TrayOnLaunch', False);
    FRememberLastProfile := INI.ReadBool('Startup', 'RememberLastProfile', False);
    FLastSelectedProfile := INI.ReadString('Startup', 'LastProfile', '');
    FSortAlpha      := INI.ReadBool('UI', 'SortAlpha', False);
    FVerbose := INI.ReadBool('UI', 'Verbose', False);
    FTheme := INI.ReadString('UI', 'Theme', '');
    if FTheme <> '' then TStyleManager.TrySetStyle(FTheme);
  finally
    INI.Free;
  end;
end;

procedure TFormMain.SaveConfig;
var
  INI: TIniFile;
begin
  TDirectory.CreateDirectory(ExtractFileDir(ConfigPath));
  INI := TIniFile.Create(ConfigPath);
  try
    INI.WriteString('Game', 'Path',       FDefaultGameExe);
    INI.WriteInteger('Game', 'ProductId', FProductId);
    INI.WriteBool('Update', 'AutoCheck',  FAutoCheck);
    INI.WriteBool('Update', 'AutoUpdate', FAutoUpdate);
    INI.WriteBool('Startup', 'AutoStart',      FAutoStart);
    INI.WriteBool('Startup', 'StartMinimized', FStartMinimized);
    INI.WriteBool('Startup', 'TrayOnLaunch',   FTrayOnLaunch);
    INI.WriteBool('Startup', 'RememberLastProfile', FRememberLastProfile);
    INI.WriteString('Startup', 'LastProfile', FLastSelectedProfile);
    INI.WriteBool('UI', 'SortAlpha', FSortAlpha);
    INI.WriteBool('UI', 'Verbose',   FVerbose);
    INI.WriteString('UI', 'Theme',  FTheme);
  finally
    INI.Free;
  end;
end;

procedure TFormMain.LoadExternalStyles;
var
  StyleDir, F: string;
begin
  StyleDir := ExtractFilePath(ParamStr(0)) + 'styles';
  if TDirectory.Exists(StyleDir) then
    for F in TDirectory.GetFiles(StyleDir, '*.vsf') do
    try
      TStyleManager.LoadFromFile(F);
    except
    end;
end;

procedure TFormMain.FormCreate(Sender: TObject);
var
  SC: TListColumn;
begin
  FLauncher      := TGameLauncher.Create;
  FSessionCache  := TDictionary<string, TSessionInfo>.Create;
  FProductId     := DEFAULT_PRODUCT;
  FPauseEvent    := TEvent.Create(nil, True, True, ''); // manual-reset, initially signaled (not paused)
  Self.OnCloseQuery := FormCloseQuery;

  MigrateLegacyData;

  FLauncher.OnGameExit := GameExitHandler;

  // Rebuild columns: status icon | Profile | UserNo | Last Used
  LvProfiles.SmallImages := ImageList1;
  LvProfiles.Columns.Clear;
  SC := LvProfiles.Columns.Add; SC.Caption := '';          SC.Width := 24;
  SC := LvProfiles.Columns.Add; SC.Caption := 'Profile';   SC.Width := 110;
  SC := LvProfiles.Columns.Add; SC.Caption := 'User No';   SC.Width := 0;
  SC := LvProfiles.Columns.Add; SC.Caption := 'Last Used'; SC.Width := 68;

  // Tray icon + menu
  var MI: TMenuItem;
  FTrayMenu := TPopupMenu.Create(Self);
  MI := TMenuItem.Create(FTrayMenu); MI.Caption := 'Open';           MI.OnClick := TrayShowClick;   FTrayMenu.Items.Add(MI);
  MI := TMenuItem.Create(FTrayMenu); MI.Caption := '-';                                              FTrayMenu.Items.Add(MI);
  FTrayProfilesSub := TMenuItem.Create(FTrayMenu); FTrayProfilesSub.Caption := 'Launch Profile'; FTrayMenu.Items.Add(FTrayProfilesSub);
  MI := TMenuItem.Create(FTrayMenu); MI.Caption := '-';                                              FTrayMenu.Items.Add(MI);
  MI := TMenuItem.Create(FTrayMenu); MI.Caption := 'Exit';           MI.OnClick := MenuExitClick;   FTrayMenu.Items.Add(MI);

  FTrayIcon            := TTrayIcon.Create(Self);
  var HTray := LoadIcon(HInstance, 'TRAYICON');
  if HTray <> 0 then
    FTrayIcon.Icon.Handle := HTray
  else
    FTrayIcon.Icon := Application.Icon;
  FTrayIcon.Hint       := 'Rua';
  FTrayIcon.PopupMenu  := FTrayMenu;
  FTrayIcon.OnDblClick := TrayIconDblClick;
  FTrayIcon.Visible    := True;

  // Profile list: dbl-click = edit; right-click adds "Refresh Login"
  LvProfiles.OnDblClick := LvProfilesDblClick;
  var PopSep := TMenuItem.Create(PopupProfile);
  PopSep.Caption := '-';
  PopupProfile.Items.Add(PopSep);
  // Popup has static "Refresh Login" item (UpdateLogin) — no need for dynamic one.

  // Update button dropdown menu
  var MIVerify: TMenuItem;
  FUpdateMenu          := TPopupMenu.Create(Self);
  MIVerify             := TMenuItem.Create(FUpdateMenu);
  MIVerify.Caption     := 'Verify / Repair Files';
  MIVerify.OnClick     := MenuVerifyRepairClick;
  FUpdateMenu.Items.Add(MIVerify);

  LoadExternalStyles;
  RefreshProfiles;   // calls RefreshTrayMenu too
  StartupSessionCheck;
  AutoDetectGame;
  LoadConfig;
  SetAutoStart(FAutoStart);
  if FAutoCheck then
    DoCheckAndUpdate(True);
  if FStartMinimized then
  begin
    Hide;
    WindowState := wsMinimized;
  end;
  LblProgress.Caption := 'Ready...';
  UpdateButtons;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  FLauncher.Free;
  FSessionCache.Free;
  FPauseEvent.Free;
  // FTrayIcon + FTrayMenu owned by Self — freed automatically
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FDownloadActive then
  begin
    if not FCleanupOnExit then
    begin
      if MessageDlg('Download in progress. Cancel and exit?',
           mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      begin
        CanClose := False;
        Exit;
      end;
    end;
    FCancelDownload := True;
    FPauseEvent.SetEvent; // unblock if paused
    FCleanupOnExit := True;
    CanClose := False; // thread will call Close() when it finishes
  end;
end;

procedure TFormMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveConfig;
  if FLauncher.IsRunning then
  begin
    Action := caNone;
    Hide; // game still running — stay in tray
  end;
end;

procedure TFormMain.WMSysCommand(var Msg: TMessage);
begin
  if (Msg.WParam and $FFF0) = SC_MINIMIZE then
  begin
    Hide;
    Msg.Result := 0;
  end
  else
    inherited;
end;

procedure TFormMain.AutoDetectGame;
var
  Path: string;
begin
  Path := FindGameExe(DEFAULT_PRODUCT);
  if Path <> '' then
    FDefaultGameExe := Path;
end;

procedure TFormMain.RefreshProfiles;
var
  Profiles: TArray<TNexonProfile>;
  Item:     TListItem;
  Tmp:      TNexonProfile;
begin
  Profiles := LoadProfiles;

  // Sort by preference: alpha ascending or last-used descending
  var A, B: Integer;
  for A := 0 to High(Profiles) - 1 do
    for B := A + 1 to High(Profiles) do
      if (FSortAlpha and (CompareText(Profiles[B].Name, Profiles[A].Name) < 0))
         or (not FSortAlpha and (Profiles[B].LastUsed > Profiles[A].LastUsed)) then
      begin
        Tmp := Profiles[A]; Profiles[A] := Profiles[B]; Profiles[B] := Tmp;
      end;

  LvProfiles.Items.BeginUpdate;
  try
    LvProfiles.Items.Clear;
    for var P in Profiles do
    begin
      Item             := LvProfiles.Items.Add;
      Item.Caption     := '';    // col 0: status icon only
      Item.ImageIndex  := 0;    // blue = not yet checked
      Item.SubItems.Add(P.Name);   // col 1: Profile
      Item.SubItems.Add(P.UserNo); // col 2: UserNo (hidden)
      if P.LastUsed > 0 then
        Item.SubItems.Add(DateTimeToStr(P.LastUsed))
      else
        Item.SubItems.Add('Never'); // col 3: Last Used
    end;
  finally
    LvProfiles.Items.EndUpdate;
  end;
  LvProfiles.Columns[0].Width := 24; // Status: fixed narrow
  LvProfiles.Columns[1].Width := -2; // Profile: LVSCW_AUTOSIZE_USEHEADER
  LvProfiles.Columns[2].Width := 0;  // UserNo — hidden, kept in data
  LvProfiles.Columns[3].Width := -2; // Last Used: LVSCW_AUTOSIZE_USEHEADER

  // Auto-select last used profile (or top item) silently
  FInRefreshProfiles := True;
  try
    if LvProfiles.Items.Count > 0 then
    begin
      var SelIdx := 0;
      if FRememberLastProfile and (FLastSelectedProfile <> '') then
        for var PIdx := 0 to LvProfiles.Items.Count - 1 do
          if LvProfiles.Items[PIdx].SubItems[0] = FLastSelectedProfile then
          begin SelIdx := PIdx; Break; end;
      LvProfiles.Items[SelIdx].Selected := True;
    end;
  finally
    FInRefreshProfiles := False;
  end;

  UpdateButtons;
  if Assigned(FTrayMenu) then RefreshTrayMenu;
end;

procedure TFormMain.Log(const Msg: string);
begin
  MemoLog.Lines.Add(FormatDateTime('[hh:nn:ss] ', Now) + Msg);
  StatusBar.SimpleText := Msg;
end;

procedure TFormMain.LogV(const Msg: string);
begin
  if FVerbose then Log(Msg);
end;

function TFormMain.SelectedProfile: string;
begin
  Result := '';
  if (LvProfiles.Selected <> nil) and
     (LvProfiles.Selected.SubItems.Count > 0) then
    Result := LvProfiles.Selected.SubItems[0]; // col 1 = Profile (col 0 = status icon)
end;

function TFormMain.GetProductId: Integer;
begin
  Result := FProductId;
end;

procedure TFormMain.UpdateButtons;
var
  HasProfile, HasPath: Boolean;
begin
  HasProfile := SelectedProfile <> '';
  HasPath    := Trim(FDefaultGameExe) <> '';
  BtnLaunch.Enabled             := HasProfile and HasPath;
  MenuRefreshToken.Enabled      := HasProfile;
  MenuEditProfile.Enabled       := HasProfile;
  MenuDeleteProfile.Enabled := HasProfile;
  BtnEditProfile.Enabled    := HasProfile;
  BtnRemoveProfile.Enabled  := HasProfile;
  PopEdit.Enabled           := HasProfile;
  PopDelete.Enabled         := HasProfile;
end;

{procedure TFormMain.UpdateLogin1Click(Sender: TObject);
begin

end;

 Menu / buttons }

procedure TFormMain.MenuAddProfileClick(Sender: TObject);
var
  Cookies, Name: string;
  P:             TNexonProfile;
begin
  if not TFormProfile.Execute(Name) then
  begin
    Log('Profile creation cancelled.');
    Exit;
  end;

  Log('Opening WebView2 login for "' + Name + '"...');
  if not TFormLoginWebView.Execute(Cookies, Name, False) then
  begin
    Log('Login cancelled.');
    Exit;
  end;
  Log('Cookies captured.');

  P.Name     := Name;
  P.UserNo   := ExtractCookieValue(Cookies, 'NexonUserID');
  P.DeviceId := GetDeviceId(Name);
  P.Products := [GetProductId];
  P.LastUsed := 0;

  AddOrUpdateProfile(P, Cookies);
  Log('Profile saved: ' + Name);
  // Debug: show which session keys were captured
  begin
    var Keys := '';
    for var K in ['NxLSession','AToken','g_AToken','NxGUN','NexonUserID','id_token'] do
      if ExtractCookieValue(Cookies, K) <> '' then
        Keys := Keys + K + ' ';
    Log('Captured keys: [' + Trim(Keys) + ']');
  end;
  RefreshProfiles;
end;

procedure TFormMain.MenuEditProfileClick(Sender: TObject);
var
  OldName:     string;
  P:           TNexonProfile;
  Profiles:    TArray<TNexonProfile>;
  I:           Integer;
  Found:       Boolean;
  NewCookies:  string;
  Refreshed:   Boolean;
  OldCookies:  string;
begin
  OldName := SelectedProfile;
  if OldName = '' then Exit;

  Profiles := LoadProfiles;
  Found    := False;
  for I := 0 to High(Profiles) do
    if Profiles[I].Name = OldName then
    begin
      P     := Profiles[I];
      Found := True;
      Break;
    end;
  if not Found then Exit;

  var SessStatus := 'Unknown';
  var SessInfo: TSessionInfo;
  if FSessionCache.TryGetValue(OldName, SessInfo) and SessInfo.Valid then
    SessStatus := 'Valid';
  if not TFormProfileEdit.Execute(P, NewCookies, Refreshed, SessStatus) then Exit;

  if P.Name <> OldName then
  begin
    // Rename: move credential to new key
    OldCookies := LoadCookies(OldName);
    DeleteProfile(OldName);
    AddOrUpdateProfile(P, OldCookies);
    Log('Profile renamed: ' + OldName + ' → ' + P.Name);
  end
  else
  begin
    // Update GameExe (and any other fields) in place
    for I := 0 to High(Profiles) do
      if Profiles[I].Name = OldName then begin Profiles[I] := P; Break; end;
    SaveProfiles(Profiles);
  end;

  if Refreshed and (NewCookies <> '') then
  begin
    AddOrUpdateProfile(P, NewCookies);
    Log('Cookies refreshed for: ' + P.Name);
  end;

  RefreshProfiles;
  // Restore session icons — RefreshProfiles resets all to blue (unknown).
  for var K in FSessionCache.Keys do
  begin
    var CI: TSessionInfo;
    if FSessionCache.TryGetValue(K, CI) then
      SetProfileIcon(K, IfThen(CI.Valid, 1, 2));
  end;
end;

procedure TFormMain.MenuDeleteProfileClick(Sender: TObject);
var
  Name: string;
begin
  Name := SelectedProfile;
  if Name = '' then Exit;
  if MessageDlg('Delete profile "' + Name + '"?',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
  begin
    DeleteProfile(Name);
    Log('Profile deleted: ' + Name);
    RefreshProfiles;
  end;
end;

// Unified session refresh: try token refresh first, fall back to WebView2 login.
procedure TFormMain.DoRefreshSession(const Profile: string);
var
  Cookies: string;
  Keys: string;
begin
  if Profile = '' then
  begin
    Log('No profile selected.');
    Exit;
  end;

  Cookies := LoadCookies(Profile);
  if Cookies = '' then
  begin
    Log('No saved session — opening WebView2 login...');
    PromptReLogin(Profile);
    Exit;
  end;

  for var K in ['NxLSession','AToken','NxGUN','g_AToken','NexonUserID'] do
    if ExtractCookieValue(Cookies, K) <> '' then Keys := Keys + K + ' ';
  Log('Stored cookie keys: [' + Trim(Keys) + ']');
  Log('Refreshing session for: ' + Profile);

  TThread.CreateAnonymousThread(procedure
  var
    C:     string;
    Prof:  string;
  begin
    C    := Cookies;
    Prof := Profile;
    var LogFn: TProc<string> := procedure(Msg: string)
      begin TThread.Queue(nil, procedure begin Log(Msg); end); end;
    if TryRefreshCookies(Prof, C, LogFn) then
    begin
      FSessionCache.Remove(Prof);
      TThread.Queue(nil, procedure begin Log('Session valid.'); end);
    end
    else
      TThread.Synchronize(nil, procedure begin PromptReLogin(Prof); end);
  end).Start;
end;

procedure TFormMain.MenuRefreshTokenClick(Sender: TObject);
begin
  DoRefreshSession(SelectedProfile);
end;

procedure TFormMain.UpdateLoginClick(Sender: TObject);
begin
  DoRefreshSession(SelectedProfile);
end;

procedure TFormMain.MenuSettingsClick(Sender: TObject);
var
  GameExe, Theme: string;
  Verbose, AutoCheck, AutoUpdate, AutoStart, StartMinimized, TrayOnLaunch: Boolean;
begin
  GameExe   := FDefaultGameExe;
  Theme     := TStyleManager.ActiveStyle.Name;
  Verbose   := FVerbose;
  AutoCheck := FAutoCheck;
  AutoUpdate := FAutoUpdate;
  AutoStart  := FAutoStart;
  StartMinimized := FStartMinimized;
  TrayOnLaunch   := FTrayOnLaunch;
  if TFormSettings.Execute(GameExe, Theme, Verbose, AutoCheck, AutoUpdate,
     AutoStart, StartMinimized, TrayOnLaunch, FRememberLastProfile, FSortAlpha) then
  begin
    FDefaultGameExe := GameExe;
    FVerbose        := Verbose;
    FAutoCheck      := AutoCheck;
    FAutoUpdate     := AutoUpdate;
    FAutoStart      := AutoStart;
    FStartMinimized := StartMinimized;
    FTrayOnLaunch   := TrayOnLaunch;
    if Theme <> '' then begin FTheme := Theme; TStyleManager.TrySetStyle(FTheme); end;
    SetAutoStart(FAutoStart);
    SaveConfig;
    RefreshProfiles;
    // Restore session icons — RefreshProfiles resets all to blue.
    for var K in FSessionCache.Keys do
    begin
      var CI: TSessionInfo;
      if FSessionCache.TryGetValue(K, CI) then
        SetProfileIcon(K, IfThen(CI.Valid, 1, 2));
    end;
    UpdateButtons;
  end;
end;

procedure TFormMain.MenuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TFormMain.BtnAddProfileClick(Sender: TObject);
begin
  MenuAddProfileClick(Sender);
end;

procedure TFormMain.BtnEditProfileClick(Sender: TObject);
begin
  MenuEditProfileClick(Sender);
end;

procedure TFormMain.BtnRemoveProfileClick(Sender: TObject);
begin
  MenuDeleteProfileClick(Sender);
end;

procedure TFormMain.BtnLaunchClick(Sender: TObject);
begin
  LaunchProfile(SelectedProfile);
end;

procedure TFormMain.BtnCheckUpdateClick(Sender: TObject);
begin
  DoCheckAndUpdate(False);
end;

procedure TFormMain.BtnCheckUpdateDropDownClick(Sender: TObject);
var
  P: TPoint;
begin
  if FUpdateMenu = nil then Exit;
  P := BtnCheckUpdate.ClientToScreen(Point(0, BtnCheckUpdate.Height));
  FUpdateMenu.Popup(P.X, P.Y);
end;

procedure TFormMain.MenuVerifyRepairClick(Sender: TObject);
begin
  DoCheckAndUpdate(False, False, True);
end;

procedure TFormMain.LvProfilesDblClick(Sender: TObject);
begin
  if SelectedProfile <> '' then
    MenuEditProfileClick(Sender);
end;



procedure TFormMain.BtnPauseUpdateClick(Sender: TObject);
const
  PAUSE_TAG = '[PAUSED] ';
var
  Sep: Integer;
  Cap: string;
begin
  if BtnPauseUpdate.Caption = 'Pause' then
  begin
    FPauseEvent.ResetEvent;
    BtnPauseUpdate.Caption := 'Resume';
    Cap := LblProgress.Caption;
    Sep := Pos(#13#10, Cap);
    if Sep > 0 then
      LblProgress.Caption := PAUSE_TAG + Copy(Cap, 1, Sep - 1)
                           + #13#10 + Copy(Cap, Sep + 2, MaxInt)
    else
      LblProgress.Caption := PAUSE_TAG + Cap;
  end
  else
  begin
    FPauseEvent.SetEvent;
    BtnPauseUpdate.Caption := 'Pause';
    Cap := LblProgress.Caption;
    if Copy(Cap, 1, Length(PAUSE_TAG)) = PAUSE_TAG then
      LblProgress.Caption := Copy(Cap, Length(PAUSE_TAG) + 1, MaxInt);
  end;
end;

procedure TFormMain.SaveRefreshedCookies(const Profile, Fresh: string);
var
  Profs:  TArray<TNexonProfile>;
  Merged: string;
begin
  // Preserve NxLSession from old credential — some refresh sources (browser fallback)
  // may not return it. Losing it makes silent autologin impossible.
  Merged := Fresh;
  if ExtractCookieValue(Merged, 'NxLSession') = '' then
  begin
    var Old := LoadCookies(Profile);
    var OldNxL := ExtractCookieValue(Old, 'NxLSession');
    if OldNxL <> '' then Merged := Merged + '; NxLSession=' + OldNxL;
  end;

  Profs := LoadProfiles;
  for var I := 0 to High(Profs) do
    if Profs[I].Name = Profile then
    begin
      AddOrUpdateProfile(Profs[I], Merged);
      Break;
    end;
end;

function NexonCodeToStr(Code: Integer): string;
begin
  case Code of
    0:         Result := '';
    10001:     Result := 'session not found';
    20027:     Result := 'device not trusted';
    20182:     Result := 'autologin not available for this account';
    1013,70018,70019: Result := 'CAPTCHA required';
    20048:     Result := 'invalid captcha token';
  else
    Result := 'code ' + IntToStr(Code);
  end;
end;

function TFormMain.TryRefreshCookies(const Profile: string; var Cookies: string;
  const LogMsg: TProc<string>): Boolean;
var
  Status, NexonCode:  Integer;
  NxLSess, DevId:     string;
  Refreshed:          string;
  AllProfs:           TArray<TNexonProfile>;
begin
  Result := False;

  // 1. Check if session (NxLSession + AToken) still valid — fast exit if nothing expired.
  if CheckSessionValid(Cookies, Status, NexonCode) then
  begin
    LogMsg('Session still valid.');
    Exit(True);
  end;
  var Reason := NexonCodeToStr(NexonCode);
  if Reason <> '' then Reason := ' (' + Reason + ')';
  LogMsg(Format('Session expired (HTTP %d%s) — trying refresh.', [Status, Reason]));

  // 2. Autologin refresh (email/password accounts; TPA returns error 20182 → skip to step 3).
  NxLSess := ExtractCookieValue(Cookies, 'NxLSession');
  DevId   := '';
  AllProfs := LoadProfiles;
  for var P in AllProfs do
    if P.Name = Profile then begin DevId := P.DeviceId; Break; end;

  if (NxLSess <> '') and (DevId <> '') then
  begin
    LogMsg('Trying autologin refresh...');
    Status    := 0;
    Refreshed := AutoLoginRefresh(NxLSess, DevId, Status);
    if Refreshed <> '' then
    begin
      SaveRefreshedCookies(Profile, Refreshed);
      Cookies := Refreshed;
      LogMsg('AToken refreshed via autologin.');
      Exit(True);
    end;
    LogMsg(Format('Autologin failed (HTTP %d).', [Status]));
  end;

end;

procedure TFormMain.DoCheckAndUpdate(AutoMode: Boolean; ForceAll: Boolean = False; VerifyMode: Boolean = False);
var
  Cookies, Profile: string;
  ProductId:        Integer;
  InstRoots:        TArray<string>;
begin
  if FDownloadActive then Exit;

  Profile   := SelectedProfile;
  Cookies   := LoadCookies(Profile);
  ProductId := GetProductId;

  // Collect unique install roots (case-insensitive dedup via lowercase key dict).
  var SeenKeys := TDictionary<string, Boolean>.Create;
  try
    var AddRoot: TProc<string> := procedure(Exe: string)
    begin
      Exe := Trim(Exe);
      if Exe = '' then Exit;
      var Dir := TPath.GetDirectoryName(Exe);
      if Dir = '' then Exit;
      var Key := Dir.ToLower;
      if not SeenKeys.ContainsKey(Key) then
      begin
        SeenKeys.Add(Key, True);
        InstRoots := InstRoots + [Dir];
      end;
    end;
    var DefaultExe := Trim(FDefaultGameExe);
    if DefaultExe = '' then DefaultExe := FindGameExe(GetProductId);
    if DefaultExe <> '' then
      AddRoot(DefaultExe);
    for var Prof in LoadProfiles do
      if Trim(Prof.GameExe) <> '' then
        AddRoot(Prof.GameExe)
      else if DefaultExe <> '' then
        AddRoot(DefaultExe);
  finally
    SeenKeys.Free;
  end;

  // Update check uses /game-build/v1/branch/games/<id>/public — no auth required.
  // Proceed even without a profile; download is also unauthenticated CDN.

  FCancelDownload := False;
  FDownloadActive := True;
  FPauseEvent.SetEvent; // ensure not paused from a previous run
  BtnCheckUpdate.Enabled := False;
  BtnLaunch.Enabled      := False;
  LblProgress.Caption    := 'Checking...';
  PrgUpdate.Max          := Max(1, Length(InstRoots));
  PrgUpdate.Position     := 0;
  if Length(InstRoots) = 0 then
  begin
    Log('No game folder configured — set a path in Settings.');
    FDownloadActive := False;
    BtnCheckUpdate.Enabled := True;
    BtnLaunch.Enabled      := SelectedProfile <> '';
    LblProgress.Caption    := 'Ready...';
    Exit;
  end;
  Log('Checking for updates...');

  var ShouldAutoUpdate := FAutoUpdate;
  var StartTime        := Now;

  TThread.CreateAnonymousThread(procedure
  var
    RemoteHash, LocalHash, HashFile, InstRoot, Error: string;
    SkipFinalCleanup: Boolean;
    TotalScanCount, CheckIdx: Integer;
    UpdateRoots:      TArray<string>;
  begin
    Error            := '';
    SkipFinalCleanup := False;
    TotalScanCount   := 0;
    CheckIdx         := 0;
    UpdateRoots      := [];
    try
      try
        RemoteHash := FetchManifestHash(Cookies, ProductId);
      except
        on E: EUpdateCheckError do
        begin
          // Public endpoint shouldn't 401, but handle gracefully if it does
          if (Pos('401', E.Message) = 0) or (Profile = '') then raise;
          TThread.Queue(nil, procedure begin Log('Session expired — refreshing...'); end);
          var LogFn: TProc<string> := procedure(Msg: string)
            begin TThread.Queue(nil, procedure begin Log(Msg); end); end;
          if not TryRefreshCookies(Profile, Cookies, LogFn) then
          begin
            TThread.Queue(nil, procedure begin Log('Could not refresh session — re-login required.'); end);
            raise;
          end;
          RemoteHash := FetchManifestHash(Cookies, ProductId);
        end;
      end;
      TThread.Queue(nil, procedure begin LogV('Remote hash: ' + RemoteHash); end);

      // Phase 1: determine which roots need updating.
      // IIAP per iteration: R/I are value params → unique copy per call, no aliasing.
      for InstRoot in InstRoots do
      begin
        Inc(CheckIdx);
        (procedure(const R: string; I: Integer)
        begin
          TThread.Queue(nil, procedure begin
            LblProgress.Caption := 'Checking: ' + R;
            PrgUpdate.Position  := I - 1;
          end);

          LocalHash := '';
          HashFile  := TPath.Combine(R,
            'patchdata\' + IntToStr(ProductId) + '.manifest.hash');
          if TFile.Exists(HashFile) then
            LocalHash := Trim(TFile.ReadAllText(HashFile));
          if VerifyMode or ForceAll or (LocalHash <> RemoteHash) then
            UpdateRoots := UpdateRoots + [R]
          else
            TThread.Queue(nil, procedure begin Log(R + ': up to date.'); end);

          TThread.Queue(nil, procedure begin PrgUpdate.Position := I; end);
        end)(InstRoot, CheckIdx);
      end;

      // Phase 2: let user pick folders and mode (verify or force).
      if not AutoMode then
        TThread.Synchronize(nil, procedure
        var
          ChosenForce: Boolean;
        begin
          if not TFormFolderSelect.Execute(UpdateRoots, ChosenForce) then
            UpdateRoots := []
          else
            ForceAll := ChosenForce;
        end);

      for InstRoot in UpdateRoots do
      begin
        if FCancelDownload then Break;

        if AutoMode and not ShouldAutoUpdate then
        begin
          // Scan manifest to confirm files actually differ (hash can change on
          // metadata-only Nexon manifest updates). If 0 files → already up to date
          // and RunPatcher updates the stored hash. If files found → show button.
          var ScanCount: Integer := 0;
          var ScanLog: TPatchLog := procedure(const Msg: string)
            begin TThread.Queue(nil, procedure begin LogV(Msg); end); end;
          RunPatcher(RemoteHash, InstRoot, ProductId, ScanLog,
            nil, '', ForceAll, nil, nil, True, @ScanCount);
          TotalScanCount := TotalScanCount + ScanCount;
        end
        else
        begin
          // IIAP: R is value param → no aliasing if UpdateRoots has multiple entries.
          (procedure(const R: string)
          begin
            TThread.Queue(nil, procedure
            begin
              Log('Verifying: ' + R);
              LblProgress.Caption    := 'Verifying files...';
              PrgUpdate.Position     := 0;
              BtnCheckUpdate.Visible := False;
              BtnPauseUpdate.Caption := 'Pause';
              BtnPauseUpdate.Visible := True;
            end);

            RunPatcher(RemoteHash, R, ProductId,
              procedure(const Msg: string)
              begin
                TThread.Queue(nil, procedure begin LogV(Msg); end);
              end,
              procedure(Current, Total: Integer; const FileName: string)
              var
                ElapsedSec, ETASec: Double;
                ElapsedStr, ETAStr, Cap: string;
              begin
                var Elapsed := Now - StartTime;
                ElapsedSec  := Elapsed * 86400.0;
                ElapsedStr  := FormatDateTime('hh:nn:ss', Elapsed);
                if Current > 0 then
                begin
                  ETASec := ElapsedSec * (Total - Current) / Current;
                  ETAStr := FormatDateTime('hh:nn:ss', ETASec / 86400.0);
                end
                else
                  ETAStr := '--:--:--';
                var Pct := (Current * 100) div Total;
                Cap := Format('[%s / ETA %s]  (%d%%)  (%d / %d)',
                              [ElapsedStr, ETAStr, Pct, Current, Total])
                    + #13#10 + FileName;
                TThread.Queue(nil, procedure
                begin
                  LblProgress.Caption := Cap;
                  PrgUpdate.Max       := 100;
                  PrgUpdate.Position  := Pct;
                end);
              end,
              '', ForceAll,
              function: Boolean begin Result := FCancelDownload; end,
              FPauseEvent);

            TThread.Queue(nil, procedure
            begin
              Log(R + ': done. Total time: ' + FormatDateTime('hh:nn:ss', Now - StartTime));
            end);
          end)(InstRoot);
        end; // else (actual download)
      end; // for InstRoot in UpdateRoots
    except
      on E: Exception do Error := E.Message;
    end;

    if not SkipFinalCleanup then
    TThread.Queue(nil, procedure
    begin
      FDownloadActive        := False;
      LblProgress.Caption    := 'Ready...';
      PrgUpdate.Position     := 0;
      BtnPauseUpdate.Visible := False;
      BtnCheckUpdate.Visible := True;
      BtnCheckUpdate.Enabled := True;
      if TotalScanCount > 0 then
      begin
        Log(Format('Update available (%d files). Click "Update Game" to patch.', [TotalScanCount]));
        BtnCheckUpdate.Caption := 'Update Game';
      end
      else
      begin
        BtnCheckUpdate.Caption := 'Check for Updates';
        if FCancelDownload then
          Log('Download cancelled.')
        else if Error <> '' then
          Log('Update ERROR: ' + Error);
      end;
      UpdateButtons;
      if FCleanupOnExit then
      begin
        FCleanupOnExit := False;
        Close;
      end;
    end);
  end).Start;
end;

procedure TFormMain.TrayShowClick(Sender: TObject);
begin
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
end;

procedure TFormMain.TrayIconDblClick(Sender: TObject);
begin
  TrayShowClick(Sender);
end;

procedure TFormMain.RefreshTrayMenu;
var
  SubMenu: TMenuItem;
  Item:    TMenuItem;
  Profs:   TArray<TNexonProfile>;
begin
  // Find "Launch Profile" submenu by name and rebuild its children.
  SubMenu := FTrayProfilesSub;
  if SubMenu = nil then Exit;
  SubMenu.Clear;
  Profs := LoadProfiles;
  for var P in Profs do
  begin
    Item          := TMenuItem.Create(FTrayMenu);
    Item.Caption  := StringReplace(P.Name, '&', '&&', [rfReplaceAll]);
    Item.Hint     := P.Name; // real name (caption escapes & for accelerator)
    Item.OnClick  := TrayProfileClick;
    SubMenu.Add(Item);
  end;
  if Length(Profs) = 0 then
  begin
    Item         := TMenuItem.Create(FTrayMenu);
    Item.Caption := '(no profiles)';
    Item.Enabled := False;
    SubMenu.Add(Item);
  end;
end;

procedure TFormMain.TrayProfileClick(Sender: TObject);
begin
  TrayShowClick(Sender); // restore window so user can see launch progress
  LaunchProfile(TMenuItem(Sender).Hint); // Hint holds real name; Caption has && escaping
end;

procedure TFormMain.GameExitHandler(Sender: TObject);
begin
  Log('Game exited.');
  StatusBar.SimpleText := 'Game exited.';
  BtnLaunch.Enabled := True;
  UpdateButtons;
  // Restore window if it was minimized to tray on game launch
  if FTrayOnLaunch and not Visible then
  begin
    Show;
    WindowState := wsNormal;
    Application.BringToFront;
  end;
end;

procedure TFormMain.LaunchProfile(const Name: string);
var
  Cookies, GamePath: string;
  ProductId: Integer;
begin
  if Name = '' then begin ShowMessage('Select a profile.'); Exit; end;
  GamePath  := Trim(FDefaultGameExe);
  ProductId := GetProductId;

  var AllProfs := LoadProfiles;
  for var Prof in AllProfs do
    if Prof.Name = Name then
    begin
      if Trim(Prof.GameExe) <> '' then GamePath := Trim(Prof.GameExe);
      Break;
    end;

  if GamePath = '' then begin ShowMessage('Set game path in Settings.'); Exit; end;
  if not TFile.Exists(GamePath) then
  begin ShowMessage('Game exe not found: ' + GamePath); Exit; end;

  Cookies := LoadCookies(Name);
  if Cookies = '' then
  begin
    Log('No credentials for "' + Name + '" — opening login...');
    PromptReLogin(Name);
    Cookies := LoadCookies(Name);
    if Cookies = '' then Exit;
  end;

  Log('Launching ' + Name + '...');
  BtnLaunch.Enabled := False;
  StatusBar.SimpleText := 'Game running — ' + Name;
  if FTrayOnLaunch and not FStartMinimized then
  begin
    Hide;
    WindowState := wsMinimized;
  end;
  try
    try
      FLauncher.Launch(Cookies, ProductId, GamePath);
    except
      on E: ETicketError do
      begin
        if Pos('401', E.Message) > 0 then
        begin
          Log('Session expired — checking...');
          if TryRefreshCookies(Name, Cookies, procedure(Msg: string) begin Log(Msg); end) then
            FLauncher.Launch(Cookies, ProductId, GamePath)
          else
          begin
            PromptReLogin(Name);
            Cookies := LoadCookies(Name);
            if Cookies <> '' then
              FLauncher.Launch(Cookies, ProductId, GamePath)
            else
              raise;
          end;
        end
        else
          raise;
      end;
    end;
    UpdateLastUsed(Name);
    if FRememberLastProfile then
    begin
      FLastSelectedProfile := Name;
      SaveConfig;
    end;
    Log('Game launched: ' + ExtractFileName(GamePath));
    // BtnLaunch stays disabled until GameExitHandler fires
  except
    on E: Exception do
    begin
      Log('Error: ' + E.Message);
      ShowMessage('Launch failed: ' + E.Message);
      BtnLaunch.Enabled := True;
      StatusBar.SimpleText := '';
    end;
  end;
end;

procedure TFormMain.SetProfileIcon(const Profile: string; IconIndex: Integer);
var
  I: Integer;
begin
  for I := 0 to LvProfiles.Items.Count - 1 do
    if (LvProfiles.Items[I].SubItems.Count > 0) and
       (LvProfiles.Items[I].SubItems[0] = Profile) then
    begin
      LvProfiles.Items[I].ImageIndex := IconIndex;
      Break;
    end;
end;

procedure TFormMain.StartupSessionCheck;
var
  Profiles: TArray<TNexonProfile>;
  N:        Integer;
begin
  // Read profiles from JSON directly — don't rely on listview which may have
  // timing issues during app startup (e.g., CredReadW transient fails).
  Profiles := LoadProfiles;
  N := Length(Profiles);
  if N = 0 then Exit;

  // One background thread; profiles checked sequentially to avoid hammering the API.
  TThread.CreateAnonymousThread(procedure
  var
    C:     string;
    Valid: Boolean;
    Info:  TSessionInfo;
  begin
    for var I := 0 to N - 1 do
    begin
      // Capture by value: anonymous methods close over loop vars by reference,
      // causing all iterations to share the last value. Value params fix this.
      (procedure(const PName: string; const PDev: string)
      begin
        C := LoadCookies(PName);
        if C = '' then
        begin
          TThread.Queue(nil, procedure
          begin Log('Startup [' + PName + ']: no saved session — skipping.'); end);
          Exit;
        end;
        Valid := TryRefreshCookies(PName, C,
          procedure(Msg: string)
          begin
            TThread.Queue(nil, procedure begin Log('Startup [' + PName + ']: ' + Msg); end);
          end);
        Info.Valid     := Valid;
        Info.CheckedAt := Now;
        Info.HttpCode  := 0;
        TThread.Queue(nil, procedure
        begin
          FSessionCache.AddOrSetValue(PName, Info);
          SetProfileIcon(PName, IfThen(Valid, 1, 2));
        end);
      end)(Profiles[I].Name, Profiles[I].DeviceId);
    end;
  end).Start;
end;

procedure TFormMain.CheckSessionCached(const Profile, Cookies: string);
var
  Info: TSessionInfo;
begin
  // Show cached result immediately; re-check only if stale (> SESSION_CACHE_SECS).
  if FSessionCache.TryGetValue(Profile, Info) then
  begin
    var Age := SecondsBetween(Now, Info.CheckedAt);
    if Age < SESSION_CACHE_SECS then
    begin
      SetProfileIcon(Profile, IfThen(Info.Valid, 1, 2));
      if Info.Valid then
        StatusBar.SimpleText := Profile + ': session OK (checked ' + IntToStr(Age) + 's ago)'
      else
        StatusBar.SimpleText := Profile + ': session expired — Profile > Refresh Token';
      Exit;
    end;
  end;

  // Cache stale or absent — background check.
  StatusBar.SimpleText := Profile + ': checking session...';
  TThread.CreateAnonymousThread(procedure
  var
    Status, NexonCode:  Integer;
    Valid:   Boolean;
    NewInfo: TSessionInfo;
    Reason:  string;
  begin
    Valid             := CheckSessionValid(Cookies, Status, NexonCode);
    NewInfo.Valid     := Valid;
    NewInfo.HttpCode  := Status;
    NewInfo.CheckedAt := Now;
    TThread.Queue(nil, procedure
    begin
      FSessionCache.AddOrSetValue(Profile, NewInfo);
      SetProfileIcon(Profile, IfThen(Valid, 1, 2));
      if SelectedProfile = Profile then
        if Valid then
          StatusBar.SimpleText := Profile + ': session OK'
        else
        begin
          Reason := NexonCodeToStr(NexonCode);
          if Reason <> '' then Reason := ' (' + Reason + ')';
          StatusBar.SimpleText := Profile + ': session expired' + Reason;
        end;
    end);
  end).Start;
end;

procedure TFormMain.PromptReLogin(const Profile: string);
var
  NewCookies: string;
  Status: Integer;
begin
  Log('Opening WebView2 login...');
  if not TFormLoginWebView.Execute(NewCookies, Profile, True) then
  begin
    Log('Re-login cancelled.');
    Exit;
  end;

  // Validate returned cookies before saving — the page may close before
  // launcher API's Set-Cookie commits, giving us stale web-scoped tokens.
  if CheckSessionValid(NewCookies, Status) then
  begin
    SaveRefreshedCookies(Profile, NewCookies);
    FSessionCache.Remove(Profile);
    SetProfileIcon(Profile, 1);
    Log('Re-login OK — credentials updated.');
  end
  else
  begin
    Log(Format('Session validation failed (HTTP %d) — trying again...', [Status]));
    if TFormLoginWebView.Execute(NewCookies, Profile, True) then
    begin
      SaveRefreshedCookies(Profile, NewCookies);
      FSessionCache.Remove(Profile);
      SetProfileIcon(Profile, 1);
      Log('Re-login OK — credentials updated (2nd attempt).');
    end
    else
      Log('Re-login cancelled (2nd attempt).');
  end;
end;

procedure TFormMain.LvProfilesSelectItem(Sender: TObject; Item: TListItem;
  Selected: Boolean);
var
  Profile, Cookies: string;
begin
  UpdateButtons;
  if not Selected then
  begin
    StatusBar.SimpleText := '';
    Exit;
  end;
  if FInRefreshProfiles then Exit;
  Profile := SelectedProfile;
  Cookies := LoadCookies(Profile);
  if (Profile = '') or (Cookies = '') then
  begin
    StatusBar.SimpleText := Profile + ': no credentials stored';
    Exit;
  end;
  CheckSessionCached(Profile, Cookies);
end;


end.
