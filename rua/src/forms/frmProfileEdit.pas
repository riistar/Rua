unit frmProfileEdit;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls,
  uProfiles;

type
  TFormProfileEdit = class(TForm)
    LblName:          TLabel;
    LblGameExe:       TLabel;
    LblEmail:         TLabel;
    LblEmailVal:      TLabel;
    LblSession:       TLabel;
    LblSessionVal:    TLabel;
    LblLastUsed:      TLabel;
    LblLastUsedVal:   TLabel;
    EdtName:          TEdit;
    EdtGameExe:       TEdit;
    BtnBrowseExe:     TButton;
    PnlBottom:        TPanel;
    BtnRefreshLogin:  TButton;
    BtnOK:            TButton;
    BtnCancel:        TButton;
    procedure EdtNameChange(Sender: TObject);
    procedure BtnBrowseExeClick(Sender: TObject);
    procedure BtnRefreshLoginClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FProfileName:    string;
    FNewCookies:     string;
    FRefreshed:      Boolean;
  public
    class function Execute(
      var P:          TNexonProfile;
      out NewCookies: string;
      out Refreshed:  Boolean;
      const SessionStatus: string = ''
    ): Boolean;
  end;

implementation

{$R *.dfm}

uses
  frmLoginWebView, Nexon3PAPIImport, System.DateUtils, System.JSON,
  System.Net.HttpClient, System.Net.URLClient;

class function TFormProfileEdit.Execute(
  var P:          TNexonProfile;
  out NewCookies: string;
  out Refreshed:  Boolean;
  const SessionStatus: string
): Boolean;
var
  F: TFormProfileEdit;
begin
  NewCookies := '';
  Refreshed  := False;
  F := TFormProfileEdit.Create(nil);
  try
    F.FNewCookies   := '';
    F.FRefreshed    := False;
    F.FProfileName  := P.Name;
    F.EdtName.Text    := P.Name;
    F.EdtGameExe.Text := P.GameExe;
    if P.Email <> '' then
      F.LblEmailVal.Caption := P.Email
    else
      F.LblEmailVal.Caption := '(unknown)';
    if SessionStatus <> '' then
      F.LblSessionVal.Caption := SessionStatus;
    if P.LastUsed > 0 then
      F.LblLastUsedVal.Caption := DateTimeToStr(P.LastUsed)
    else
      F.LblLastUsedVal.Caption := 'Never';
    Result := F.ShowModal = mrOK;
    if Result then
    begin
      P.Name    := Trim(F.EdtName.Text);
      P.GameExe := Trim(F.EdtGameExe.Text);
      NewCookies := F.FNewCookies;
      Refreshed  := F.FRefreshed;
    end;
  finally
    F.Free;
  end;
end;

procedure TFormProfileEdit.FormShow(Sender: TObject);
var
  Cookies: string;
  J: TJSONObject;
  Email: string;
  Http: THTTPClient;
  Resp: IHTTPResponse;
  AToken: string;
begin
  // Session status is passed in from main form's cache — no API call needed.
  // Only fetch account email if we don't have it stored yet.
  if LblEmailVal.Caption = '(unknown)' then
  begin
    Cookies := LoadCookies(FProfileName);
    if Cookies <> '' then
    try
      Http := THTTPClient.Create;
      Http.CustomHeaders['User-Agent'] := 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) NexonLauncher/4.7.9 Chrome/108.0.5359.215 Electron/22.3.27 Safari/537.36';
      Http.CustomHeaders['Accept'] := 'application/json';
      Http.CookieManager := nil;
      Http.CustomHeaders['Cookie'] := Cookies;
      AToken := NP_ExtractCookie(Cookies, 'AToken');
      if AToken <> '' then
        Http.CustomHeaders['Authorization'] := 'Bearer ' + AToken;
      Resp := Http.Get('https://www.nexon.com/api/account/v1/account');
      if Resp.StatusCode = 200 then
      begin
        J := TJSONObject.ParseJSONValue(Resp.ContentAsString) as TJSONObject;
        if J <> nil then
        try
          if J.TryGetValue<string>('email', Email) and (Email <> '') then
          begin
            LblEmailVal.Caption := Email;
            var AllProfs := LoadProfiles;
            for var I := 0 to High(AllProfs) do
              if AllProfs[I].Name = FProfileName then
              begin
                AllProfs[I].Email := Email;
                SaveProfiles(AllProfs);
                Break;
              end;
          end;
        finally
          J.Free;
        end;
      end;
      Http.Free;
    except end;
  end;
end;

procedure TFormProfileEdit.EdtNameChange(Sender: TObject);
begin
  BtnOK.Enabled := Trim(EdtName.Text) <> '';
end;

procedure TFormProfileEdit.BtnBrowseExeClick(Sender: TObject);
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

procedure TFormProfileEdit.BtnRefreshLoginClick(Sender: TObject);
var
  Cookies: string;
begin
  LblSessionVal.Caption := 'Opening browser...';
  LblSessionVal.Update;
  if TFormLoginWebView.Execute(Cookies, FProfileName, True) then
  begin
    FNewCookies := Cookies;
    FRefreshed  := True;
    LblSessionVal.Caption := 'Login refreshed OK.';
  end
  else
    LblSessionVal.Caption := 'Login cancelled.';
end;

end.
