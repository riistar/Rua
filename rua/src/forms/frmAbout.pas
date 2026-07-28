unit frmAbout;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls;

type
  TFormAbout = class(TForm)
    LblTitle: TLabel;
    LblSubtitle: TLabel;
    LblCopyright: TLabel;
    LblCredits: TLabel;
    LblThanks: TLabel;
    BtnOK: TButton;
    Bevel1: TBevel;
    procedure FormCreate(Sender: TObject);
    procedure BtnOKClick(Sender: TObject);
  end;

implementation

{$R *.dfm}

procedure TFormAbout.FormCreate(Sender: TObject);
begin
  LblTitle.Caption    := 'Rua';
  LblSubtitle.Caption := '3rd-party Nexon Launcher replacement';
  LblCopyright.Caption := 'Copyright '#169' Rii / RiiStar';
  LblCredits.Caption  := 'Thanks to:';
  LblThanks.Caption   :=
    'Hydwwn project by Sven'#13#10+
    'Cursey'#13#10+
    'Xcelled194';
end;

procedure TFormAbout.BtnOKClick(Sender: TObject);
begin
  Close;
end;

end.
