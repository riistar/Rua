unit frmFolderSelect;

interface

uses
  System.SysUtils, System.Types,
  Winapi.Windows,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.CheckLst,
  Vcl.ExtCtrls, Vcl.Dialogs, uIgnoreList;

type
  TFormFolderSelect = class(TForm)
  private
    FLabel:      TLabel;
    FList:       TCheckListBox;
    FLblIgnore:  TLabel;
    FMemoIgnore: TMemo;
    FBtnAll:    TButton;
    FBtnNone:   TButton;
    FBtnRepair: TButton;
    FBtnForce:  TButton;
    FBtnCancel: TButton;
    procedure BtnAllClick(Sender: TObject);
    procedure BtnNoneClick(Sender: TObject);
  public
    class function Execute(var Roots: TArray<string>; out ForceAll: Boolean): Boolean;
  end;

implementation

procedure TFormFolderSelect.BtnAllClick(Sender: TObject);
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do FList.Checked[I] := True;
end;

procedure TFormFolderSelect.BtnNoneClick(Sender: TObject);
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do FList.Checked[I] := False;
end;

class function TFormFolderSelect.Execute(var Roots: TArray<string>; out ForceAll: Boolean): Boolean;
var
  F:       TFormFolderSelect;
  I:       Integer;
  Sel:     TArray<string>;
  Res:     Integer;
begin
  Result := False;
  ForceAll := False;
  if Length(Roots) = 0 then Exit;

  F := TFormFolderSelect.CreateNew(Application);
  try
    F.Caption      := 'Select Folders to Update';
    F.BorderStyle  := bsDialog;
    F.Position     := poScreenCenter;
    F.Width        := 520;
    F.Height       := 400;
    F.Font.Name    := 'Segoe UI';
    F.Font.Size    := 9;
    F.KeyPreview   := True;

    F.FLabel            := TLabel.Create(F);
    F.FLabel.Parent     := F;
    F.FLabel.Left       := 12;
    F.FLabel.Top        := 12;
    F.FLabel.Caption    := 'Choose which game folders to update:';

    F.FList             := TCheckListBox.Create(F);
    F.FList.Parent      := F;
    F.FList.Left        := 12;
    F.FList.Top         := 34;
    F.FList.Width       := F.ClientWidth - 24;
    F.FList.Height      := 140;
    F.FList.ItemHeight  := 20;
    for var R in Roots do
    begin
      var Idx := F.FList.Items.Add(R);
      F.FList.Checked[Idx] := True;
    end;

    F.FLblIgnore            := TLabel.Create(F);
    F.FLblIgnore.Parent     := F;
    F.FLblIgnore.Left       := 12;
    F.FLblIgnore.Top        := 182;
    F.FLblIgnore.Caption    := 'Ignore during update (one path or wildcard per line):';

    F.FMemoIgnore           := TMemo.Create(F);
    F.FMemoIgnore.Parent    := F;
    F.FMemoIgnore.Left      := 12;
    F.FMemoIgnore.Top       := 201;
    F.FMemoIgnore.Width     := F.ClientWidth - 24;
    F.FMemoIgnore.Height    := 70;
    F.FMemoIgnore.ScrollBars := ssVertical;
    F.FMemoIgnore.Lines.Text := string.Join(sLineBreak, LoadIgnorePatterns);

    F.FBtnAll            := TButton.Create(F);
    F.FBtnAll.Parent     := F;
    F.FBtnAll.Caption    := 'All';
    F.FBtnAll.Left       := 12;
    F.FBtnAll.Top        := 281;
    F.FBtnAll.Width      := 60;
    F.FBtnAll.OnClick    := F.BtnAllClick;

    F.FBtnNone           := TButton.Create(F);
    F.FBtnNone.Parent    := F;
    F.FBtnNone.Caption   := 'None';
    F.FBtnNone.Left      := 78;
    F.FBtnNone.Top       := 281;
    F.FBtnNone.Width     := 60;
    F.FBtnNone.OnClick   := F.BtnNoneClick;

    F.FBtnRepair         := TButton.Create(F);
    F.FBtnRepair.Parent  := F;
    F.FBtnRepair.Caption := 'Repair Bad Files';
    F.FBtnRepair.Left    := 160;
    F.FBtnRepair.Top     := 281;
    F.FBtnRepair.Width   := 130;
    F.FBtnRepair.ModalResult := mrYes;

    F.FBtnForce          := TButton.Create(F);
    F.FBtnForce.Parent   := F;
    F.FBtnForce.Caption  := 'Re-download All';
    F.FBtnForce.Left     := 300;
    F.FBtnForce.Top      := 281;
    F.FBtnForce.Width   := 130;
    F.FBtnForce.ModalResult := mrNo;

    F.FBtnCancel           := TButton.Create(F);
    F.FBtnCancel.Parent    := F;
    F.FBtnCancel.Caption   := 'Cancel';
    F.FBtnCancel.Left      := F.ClientWidth - 84;
    F.FBtnCancel.Top       := 316;
    F.FBtnCancel.Width     := 72;
    F.FBtnCancel.ModalResult := mrCancel;
    F.FBtnCancel.Cancel    := True;

    Res := F.ShowModal;
    // Ignore list is a persisted setting, not part of the update decision --
    // save it regardless of which button closed the dialog.
    SaveIgnorePatterns(F.FMemoIgnore.Lines.ToStringArray);
    if (Res <> mrYes) and (Res <> mrNo) then Exit;

    Sel := [];
    for I := 0 to F.FList.Count - 1 do
      if F.FList.Checked[I] then
        Sel := Sel + [F.FList.Items[I]];

    if Length(Sel) = 0 then Exit;
    Roots     := Sel;
    ForceAll  := (Res = mrNo);
    Result    := True;
  finally
    F.Free;
  end;
end;

end.
