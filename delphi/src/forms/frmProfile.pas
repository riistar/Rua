unit frmProfile;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls;

type
  TFormProfile = class(TForm)
    LblName:   TLabel;
    EdtName:   TEdit;
    PnlBottom: TPanel;
    BtnOK:     TButton;
    BtnCancel: TButton;
    procedure BtnOKClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure EdtNameChange(Sender: TObject);
  private
    function GetProfileName: string;
  public
    class function Execute(out ProfileName: string): Boolean;
    property ProfileName: string read GetProfileName;
  end;

implementation

{$R *.dfm}

class function TFormProfile.Execute(out ProfileName: string): Boolean;
var
  F: TFormProfile;
begin
  F := TFormProfile.Create(nil);
  try
    Result := F.ShowModal = mrOK;
    if Result then
      ProfileName := F.ProfileName;
  finally
    F.Free;
  end;
end;

function TFormProfile.GetProfileName: string;
begin
  Result := Trim(EdtName.Text);
end;

procedure TFormProfile.EdtNameChange(Sender: TObject);
begin
  BtnOK.Enabled := Trim(EdtName.Text) <> '';
end;

procedure TFormProfile.BtnOKClick(Sender: TObject);
begin
  if Trim(EdtName.Text) = '' then Exit;
  ModalResult := mrOK;
end;

procedure TFormProfile.BtnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

end.
