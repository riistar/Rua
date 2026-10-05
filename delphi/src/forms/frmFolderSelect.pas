unit frmFolderSelect;

interface

uses
  System.SysUtils, System.Types, System.UITypes,
  Winapi.Windows,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.CheckLst,
  Vcl.ExtCtrls, Vcl.Dialogs, uIgnoreList;

type
  // What the user asked for in the folder dialog.
  TUpdateMode = (umUpdate,     // patch new/changed files (per-file list shown after scan)
                 umRepair,     // re-check every file on disk, fix bad/missing ones
                 umForceAll);  // re-download everything

  TFormFolderSelect = class(TForm)
  private
    FLabel:      TLabel;
    FList:       TCheckListBox;
    FLblIgnore:  TLabel;
    FMemoIgnore: TMemo;
    FBtnAll:     TButton;
    FBtnNone:    TButton;
    FBtnUpdSel:  TButton;
    FBtnUpdAll:  TButton;
    FBtnRepair:  TButton;
    FBtnForce:   TButton;
    FBtnCancel:  TButton;
    procedure BtnAllClick(Sender: TObject);
    procedure BtnNoneClick(Sender: TObject);
    procedure BtnUpdAllClick(Sender: TObject);
  public
    // AllRoots: every configured game folder. Checked: pre-checked folders.
    // Outdated: folders with a newer version available (marked in the list).
    // On OK, Roots = the folders left checked.
    class function Execute(const AllRoots, Checked, Outdated: TArray<string>;
      out Roots: TArray<string>; out Mode: TUpdateMode): Boolean;
  end;

implementation

const
  mrUpdate = mrOk;
  mrRepair = mrYes;
  mrForce  = mrNo;

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

procedure TFormFolderSelect.BtnUpdAllClick(Sender: TObject);
begin
  BtnAllClick(Sender);
  ModalResult := mrUpdate;
end;

class function TFormFolderSelect.Execute(const AllRoots, Checked, Outdated: TArray<string>;
  out Roots: TArray<string>; out Mode: TUpdateMode): Boolean;
var
  F:   TFormFolderSelect;
  I:   Integer;
  Sel: TArray<string>;
  Res: Integer;

  function InList(const R: string; const L: TArray<string>): Boolean;
  begin
    for var O in L do
      if SameText(O, R) then Exit(True);
    Result := False;
  end;

  function MakeButton(const Cap: string; X, Y, W: Integer; MR: Integer): TButton;
  begin
    Result := TButton.Create(F);
    Result.Parent      := F;
    Result.Caption     := Cap;
    Result.SetBounds(X, Y, W, 26);
    Result.ModalResult := MR;
  end;

begin
  Result := False;
  Roots  := [];
  Mode   := umUpdate;
  if Length(AllRoots) = 0 then Exit;

  F := TFormFolderSelect.CreateNew(Application);
  try
    F.Caption      := 'Select Folders to Update';
    F.BorderStyle  := bsDialog;
    F.Position     := poScreenCenter;
    F.Width        := 600;
    F.Height       := 420;
    F.Font.Name    := 'Segoe UI';
    F.Font.Size    := 9;
    F.KeyPreview   := True;

    F.FLabel            := TLabel.Create(F);
    F.FLabel.Parent     := F;
    F.FLabel.Left       := 12;
    F.FLabel.Top        := 12;
    F.FLabel.Caption    := 'Choose which game folders to update:';

    // Item text carries a status suffix; the real path is AllRoots[index].
    F.FList             := TCheckListBox.Create(F);
    F.FList.Parent      := F;
    F.FList.Left        := 12;
    F.FList.Top         := 34;
    F.FList.Width       := F.ClientWidth - 24;
    F.FList.Height      := 140;
    F.FList.ItemHeight  := 20;
    for var R in AllRoots do
    begin
      var Idx: Integer;
      if InList(R, Outdated) then
        Idx := F.FList.Items.Add(R + '   (update available)')
      else
        Idx := F.FList.Items.Add(R + '   (up to date)');
      F.FList.Checked[Idx] := InList(R, Checked);
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

    // Row 1: selection helpers.
    F.FBtnAll          := MakeButton('All', 12, 281, 60, mrNone);
    F.FBtnAll.OnClick  := F.BtnAllClick;
    F.FBtnNone         := MakeButton('None', 78, 281, 60, mrNone);
    F.FBtnNone.OnClick := F.BtnNoneClick;

    // Row 2: actions.
    F.FBtnUpdSel := MakeButton('Update Selected', 12, 318, 112, mrUpdate);
    F.FBtnUpdSel.Default := True;
    F.FBtnUpdAll := MakeButton('Update All', 130, 318, 90, mrNone);
    F.FBtnUpdAll.OnClick := F.BtnUpdAllClick;
    F.FBtnRepair := MakeButton('Repair Bad Files', 226, 318, 112, mrRepair);
    F.FBtnForce  := MakeButton('Re-download All', 344, 318, 112, mrForce);
    F.FBtnCancel := MakeButton('Cancel', F.ClientWidth - 84, 318, 72, mrCancel);
    F.FBtnCancel.Cancel := True;

    Res := F.ShowModal;
    // Ignore list is a persisted setting, not part of the update decision --
    // save it regardless of which button closed the dialog.
    SaveIgnorePatterns(F.FMemoIgnore.Lines.ToStringArray);
    case Res of
      mrUpdate: Mode := umUpdate;
      mrRepair: Mode := umRepair;
      mrForce:
        begin
          if MessageDlg('Re-download every game file in the selected folders? ' +
               'This can take a long time.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
            Exit;
          Mode := umForceAll;
        end;
    else
      Exit;
    end;

    Sel := [];
    for I := 0 to F.FList.Count - 1 do
      if F.FList.Checked[I] then
        Sel := Sel + [AllRoots[I]];

    if Length(Sel) = 0 then Exit;
    Roots  := Sel;
    Result := True;
  finally
    F.Free;
  end;
end;

end.
