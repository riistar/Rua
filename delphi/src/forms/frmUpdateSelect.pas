unit frmUpdateSelect;

{ Lists the files an update would patch (new / changed vs. the local install)
  and lets the user choose which ones to download: Selected, All, or None. }

interface

uses
  System.SysUtils, System.Classes, System.Math,
  Winapi.Windows,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  uNxlPatcher;

type
  TFormUpdateSelect = class(TForm)
  private
    FItems:      TArray<TPatchItem>;
    FLabel:      TLabel;
    FList:       TListView;
    FLblSummary: TLabel;
    FBtnAll:     TButton;
    FBtnNone:    TButton;
    FBtnUpdSel:  TButton;
    FBtnUpdAll:  TButton;
    FBtnCancel:  TButton;
    FUpdating:   Boolean;
    procedure BtnAllClick(Sender: TObject);
    procedure BtnNoneClick(Sender: TObject);
    procedure BtnUpdAllClick(Sender: TObject);
    procedure ListItemChecked(Sender: TObject; Item: TListItem);
    procedure SetAllChecked(Value: Boolean);
    procedure UpdateSummary;
  public
    // Returns False when the user skips the update (Cancel, or nothing selected).
    class function Execute(const RootName: string; const Items: TArray<TPatchItem>;
      out Selected: TArray<string>): Boolean;
  end;

function FormatBytes(N: Int64): string;

implementation

function FormatBytes(N: Int64): string;
begin
  if N < 0 then Exit('N/A');
  if N < 1024 then Exit(Format('%d B', [N]));
  if N < 1024 * 1024 then Exit(Format('%.1f KB', [N / 1024]));
  if N < Int64(1024) * 1024 * 1024 then Exit(Format('%.1f MB', [N / (1024 * 1024)]));
  Result := Format('%.2f GB', [N / (1024.0 * 1024 * 1024)]);
end;

procedure TFormUpdateSelect.SetAllChecked(Value: Boolean);
var I: Integer;
begin
  FUpdating := True;
  FList.Items.BeginUpdate;
  try
    for I := 0 to FList.Items.Count - 1 do
      FList.Items[I].Checked := Value;
  finally
    FList.Items.EndUpdate;
    FUpdating := False;
  end;
  UpdateSummary;
end;

procedure TFormUpdateSelect.BtnAllClick(Sender: TObject);
begin
  SetAllChecked(True);
end;

procedure TFormUpdateSelect.BtnNoneClick(Sender: TObject);
begin
  SetAllChecked(False);
end;

procedure TFormUpdateSelect.BtnUpdAllClick(Sender: TObject);
begin
  SetAllChecked(True);
  ModalResult := mrOk;
end;

procedure TFormUpdateSelect.ListItemChecked(Sender: TObject; Item: TListItem);
begin
  if not FUpdating then UpdateSummary;
end;

procedure TFormUpdateSelect.UpdateSummary;
var
  I, N:  Integer;
  Bytes: Int64;
begin
  N := 0;
  Bytes := 0;
  for I := 0 to FList.Items.Count - 1 do
    if FList.Items[I].Checked then
    begin
      Inc(N);
      Inc(Bytes, FItems[NativeInt(FList.Items[I].Data)].Size);
    end;
  FLblSummary.Caption := Format('%d of %d files selected — %s',
    [N, FList.Items.Count, FormatBytes(Bytes)]);
  FBtnUpdSel.Enabled := N > 0;
end;

class function TFormUpdateSelect.Execute(const RootName: string;
  const Items: TArray<TPatchItem>; out Selected: TArray<string>): Boolean;
var
  F:     TFormUpdateSelect;
  I:     Integer;
  Total: Int64;
  LI:    TListItem;
  Col:   TListColumn;
begin
  Result   := False;
  Selected := [];
  if Length(Items) = 0 then Exit;

  F := TFormUpdateSelect.CreateNew(Application);
  try
    F.FItems       := Items;
    F.Caption      := 'Game Update — Files';
    F.BorderStyle  := bsSizeable;
    F.BorderIcons  := [biSystemMenu, biMaximize];
    F.Position     := poScreenCenter;
    F.Width        := 760;
    F.Height       := 520;
    F.Constraints.MinWidth  := 520;
    F.Constraints.MinHeight := 320;
    F.Font.Name    := 'Segoe UI';
    F.Font.Size    := 9;
    F.KeyPreview   := True;

    Total := 0;
    for I := 0 to High(Items) do
      Inc(Total, Items[I].Size);

    F.FLabel         := TLabel.Create(F);
    F.FLabel.Parent  := F;
    F.FLabel.Left    := 12;
    F.FLabel.Top     := 12;
    F.FLabel.Caption := Format('%d file(s) to update in %s (%s):',
      [Length(Items), RootName, FormatBytes(Total)]);

    F.FList                := TListView.Create(F);
    F.FList.Parent         := F;
    F.FList.Left           := 12;
    F.FList.Top            := 34;
    F.FList.Width          := F.ClientWidth - 24;
    F.FList.Height         := F.ClientHeight - 34 - 84;
    F.FList.Anchors        := [akLeft, akTop, akRight, akBottom];
    F.FList.ViewStyle      := vsReport;
    F.FList.Checkboxes     := True;
    F.FList.RowSelect      := True;
    F.FList.ReadOnly       := True;
    F.FList.HideSelection  := False;
    Col := F.FList.Columns.Add; Col.Caption := 'File';       Col.Width := 300;
    Col := F.FList.Columns.Add; Col.Caption := 'Status';     Col.Width := 100;
    Col := F.FList.Columns.Add; Col.Caption := 'New size';   Col.Width := 90; Col.Alignment := taRightJustify;
    Col := F.FList.Columns.Add; Col.Caption := 'Local size'; Col.Width := 90; Col.Alignment := taRightJustify;
    Col := F.FList.Columns.Add; Col.Caption := 'Change';     Col.Width := 90;  Col.Alignment := taRightJustify;

    F.FUpdating := True;
    F.FList.Items.BeginUpdate;
    try
      for I := 0 to High(Items) do
      begin
        LI := F.FList.Items.Add;
        LI.Caption := Items[I].Path;
        LI.SubItems.Add(Items[I].Reason);
        LI.SubItems.Add(FormatBytes(Items[I].Size));
        LI.SubItems.Add(FormatBytes(Items[I].LocalSize));
        // Size-changed files often round to the same MB -- show the delta.
        if Items[I].LocalSize >= 0 then
        begin
          var D := Items[I].Size - Items[I].LocalSize;
          if D > 0 then LI.SubItems.Add('+' + FormatBytes(D))
          else if D < 0 then LI.SubItems.Add('-' + FormatBytes(-D))
          else LI.SubItems.Add('');
        end
        else
          LI.SubItems.Add('');
        LI.Data    := Pointer(NativeInt(I));
        LI.Checked := True;
      end;
    finally
      F.FList.Items.EndUpdate;
      F.FUpdating := False;
    end;
    F.FList.OnItemChecked := F.ListItemChecked;

    F.FLblSummary         := TLabel.Create(F);
    F.FLblSummary.Parent  := F;
    F.FLblSummary.Left    := 12;
    F.FLblSummary.Top     := F.ClientHeight - 74;
    F.FLblSummary.Anchors := [akLeft, akBottom];

    F.FBtnAll            := TButton.Create(F);
    F.FBtnAll.Parent     := F;
    F.FBtnAll.Caption    := 'Select All';
    F.FBtnAll.SetBounds(12, F.ClientHeight - 44, 90, 28);
    F.FBtnAll.Anchors    := [akLeft, akBottom];
    F.FBtnAll.OnClick    := F.BtnAllClick;

    F.FBtnNone           := TButton.Create(F);
    F.FBtnNone.Parent    := F;
    F.FBtnNone.Caption   := 'Select None';
    F.FBtnNone.SetBounds(108, F.ClientHeight - 44, 90, 28);
    F.FBtnNone.Anchors   := [akLeft, akBottom];
    F.FBtnNone.OnClick   := F.BtnNoneClick;

    F.FBtnCancel             := TButton.Create(F);
    F.FBtnCancel.Parent      := F;
    F.FBtnCancel.Caption     := 'Cancel';
    F.FBtnCancel.SetBounds(F.ClientWidth - 92, F.ClientHeight - 44, 80, 28);
    F.FBtnCancel.Anchors     := [akRight, akBottom];
    F.FBtnCancel.ModalResult := mrCancel;
    F.FBtnCancel.Cancel      := True;

    F.FBtnUpdAll         := TButton.Create(F);
    F.FBtnUpdAll.Parent  := F;
    F.FBtnUpdAll.Caption := 'Update All';
    F.FBtnUpdAll.SetBounds(F.ClientWidth - 92 - 116, F.ClientHeight - 44, 110, 28);
    F.FBtnUpdAll.Anchors := [akRight, akBottom];
    F.FBtnUpdAll.OnClick := F.BtnUpdAllClick;

    F.FBtnUpdSel             := TButton.Create(F);
    F.FBtnUpdSel.Parent      := F;
    F.FBtnUpdSel.Caption     := 'Update Selected';
    F.FBtnUpdSel.SetBounds(F.ClientWidth - 92 - 232, F.ClientHeight - 44, 110, 28);
    F.FBtnUpdSel.Anchors     := [akRight, akBottom];
    F.FBtnUpdSel.ModalResult := mrOk;
    F.FBtnUpdSel.Default     := True;

    F.UpdateSummary;

    if F.ShowModal <> mrOk then Exit;

    var N := 0;
    SetLength(Selected, F.FList.Items.Count);
    for I := 0 to F.FList.Items.Count - 1 do
      if F.FList.Items[I].Checked then
      begin
        Selected[N] := Items[NativeInt(F.FList.Items[I].Data)].Path;
        Inc(N);
      end;
    SetLength(Selected, N);
    Result := N > 0;
  finally
    F.Free;
  end;
end;

end.
