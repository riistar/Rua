unit frmSettings;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.Themes, uIgnoreList, uLoginBrowser, uHooks;

type
  TFormSettings = class(TForm)
    LblGameExe:    TLabel;
    LblTheme:      TLabel;
    LblThemeNote:  TLabel;
    EdtGameExe:    TEdit;
    BtnBrowseExe:  TButton;
    CmbTheme:      TComboBox;
    ChkVerbose:     TCheckBox;
    ChkAutoCheck:   TCheckBox;
    ChkAutoUpdate:  TCheckBox;
    ChkAutoStart:   TCheckBox;
    ChkStartMinimized: TCheckBox;
    ChkTrayOnLaunch: TCheckBox;
    ChkRememberLastProfile: TCheckBox;
    ChkSortAlpha: TCheckBox;
    LblIgnore:      TLabel;
    MemoIgnore:     TMemo;
    LblHooks:       TLabel;
    LblBeforePatch: TLabel;
    EdtBeforePatch: TEdit;
    LblAfterPatch:  TLabel;
    EdtAfterPatch:  TEdit;
    LblBeforeLaunch: TLabel;
    EdtBeforeLaunch: TEdit;
    LblAfterLaunch: TLabel;
    EdtAfterLaunch: TEdit;
    PnlBottom:      TPanel;
    BtnOK:          TButton;
    BtnCancel:      TButton;
    procedure FormCreate(Sender: TObject);
    procedure BtnBrowseExeClick(Sender: TObject);
    procedure CmbThemeChange(Sender: TObject);
  private
    FOriginalTheme: string;
    procedure LoadStyleNames;
  public
    class function Execute(
      var GameExe:       string;
      var Theme:         string;
      var Verbose:       Boolean;
      var AutoCheck:     Boolean;
      var AutoUpdate:    Boolean;
      var AutoStart:     Boolean;
      var StartMinimized: Boolean;
      var TrayOnLaunch:  Boolean;
      var RememberLastProfile: Boolean;
      var SortAlpha:     Boolean
    ): Boolean;
  end;

implementation

{$R *.dfm}

class function TFormSettings.Execute(
  var GameExe:       string;
  var Theme:         string;
  var Verbose:       Boolean;
  var AutoCheck:     Boolean;
  var AutoUpdate:    Boolean;
  var AutoStart:     Boolean;
  var StartMinimized: Boolean;
  var TrayOnLaunch:  Boolean;
  var RememberLastProfile: Boolean;
  var SortAlpha:     Boolean
): Boolean;
var
  F: TFormSettings;
  H: TRuaHooks;
begin
  var OrigTheme := TStyleManager.ActiveStyle.Name;
  H := LoadHooks;
  F := TFormSettings.Create(nil);
  try
    F.FOriginalTheme           := OrigTheme;
    F.EdtGameExe.Text          := GameExe;
    F.ChkVerbose.Checked       := Verbose;
    F.ChkAutoCheck.Checked     := AutoCheck;
    F.ChkAutoUpdate.Checked    := AutoUpdate;
    F.ChkAutoStart.Checked     := AutoStart;
    F.ChkStartMinimized.Checked := StartMinimized;
    F.ChkTrayOnLaunch.Checked  := TrayOnLaunch;
    F.ChkRememberLastProfile.Checked := RememberLastProfile;
    F.ChkSortAlpha.Checked     := SortAlpha;
    F.MemoIgnore.Lines.Text    := string.Join(sLineBreak, LoadIgnorePatterns);
    F.EdtBeforePatch.Text      := H.BeforePatch;
    F.EdtAfterPatch.Text       := H.AfterPatch;
    F.EdtBeforeLaunch.Text     := H.BeforeLaunch;
    F.EdtAfterLaunch.Text      := H.AfterLaunch;

    var Idx := F.CmbTheme.Items.IndexOf(Theme);
    if Idx >= 0 then F.CmbTheme.ItemIndex := Idx;

    Result := F.ShowModal = mrOK;
    if Result then
    begin
      GameExe       := Trim(F.EdtGameExe.Text);
      Verbose       := F.ChkVerbose.Checked;
      AutoCheck     := F.ChkAutoCheck.Checked;
      AutoUpdate    := F.ChkAutoUpdate.Checked;
      AutoStart     := F.ChkAutoStart.Checked;
      StartMinimized := F.ChkStartMinimized.Checked;
      TrayOnLaunch  := F.ChkTrayOnLaunch.Checked;
      RememberLastProfile := F.ChkRememberLastProfile.Checked;
      SortAlpha     := F.ChkSortAlpha.Checked;
      if F.CmbTheme.ItemIndex >= 0 then
        Theme := F.CmbTheme.Items[F.CmbTheme.ItemIndex];
      SaveIgnorePatterns(F.MemoIgnore.Lines.ToStringArray);
      H.BeforePatch  := Trim(F.EdtBeforePatch.Text);
      H.AfterPatch   := Trim(F.EdtAfterPatch.Text);
      H.BeforeLaunch := Trim(F.EdtBeforeLaunch.Text);
      H.AfterLaunch  := Trim(F.EdtAfterLaunch.Text);
      SaveHooks(H);
    end
    else
      TStyleManager.TrySetStyle(OrigTheme);
  finally
    F.Free;
  end;
end;

procedure TFormSettings.FormCreate(Sender: TObject);
begin
  LoadStyleNames;
end;

procedure TFormSettings.LoadStyleNames;
var
  StyleDir, CurTheme, S: string;
  List: TStringList;
begin
  // Under Wine only the system theme renders correctly, so it is the only choice.
  if IsRunningUnderWine then
  begin
    CmbTheme.Items.Text := WINE_THEME;
    CmbTheme.ItemIndex := 0;
    CmbTheme.Enabled := False;
    CmbTheme.Hint := 'Other themes do not render correctly under Wine';
    CmbTheme.ShowHint := True;
    Exit;
  end;

  StyleDir := ExtractFilePath(ParamStr(0)) + 'styles';
  if TDirectory.Exists(StyleDir) then
    for var SF in TDirectory.GetFiles(StyleDir, '*.vsf') do
    try
      TStyleManager.LoadFromFile(SF);
    except
    end;

  CurTheme := TStyleManager.ActiveStyle.Name;
  List := TStringList.Create;
  try
    for S in TStyleManager.StyleNames do
      List.Add(S);
    List.Sort;
    // Move current theme to top
    var Idx := List.IndexOf(CurTheme);
    if Idx > 0 then
      List.Move(Idx, 0);
    CmbTheme.Items.Assign(List);
  finally
    List.Free;
  end;
  CmbTheme.ItemIndex := 0;
end;

procedure TFormSettings.CmbThemeChange(Sender: TObject);
begin
  if CmbTheme.ItemIndex >= 0 then
    TStyleManager.TrySetStyle(CmbTheme.Items[CmbTheme.ItemIndex]);
end;

procedure TFormSettings.BtnBrowseExeClick(Sender: TObject);
var
  OD: TOpenDialog;
begin
  OD := TOpenDialog.Create(Self);
  try
    OD.Filter      := 'Executable files (*.exe)|*.exe';
    OD.FilterIndex := 1;
    if EdtGameExe.Text <> '' then
      OD.InitialDir := ExtractFileDir(EdtGameExe.Text);
    if OD.Execute then
      EdtGameExe.Text := OD.FileName;
  finally
    OD.Free;
  end;
end;

end.
