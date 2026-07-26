object FormProfile: TFormProfile
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Nexon Account'
  ClientHeight = 110
  ClientWidth = 320
  Position = poMainFormCenter
  object LblName: TLabel
    Left = 12
    Top = 16
    Width = 72
    Height = 13
    Caption = 'Profile &name:'
    FocusControl = EdtName
  end
  object EdtName: TEdit
    Left = 12
    Top = 34
    Width = 296
    Height = 21
    MaxLength = 64
    TabOrder = 0
    OnChange = EdtNameChange
  end
  object PnlBottom: TPanel
    Left = 0
    Top = 72
    Width = 320
    Height = 38
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 1
    object BtnOK: TButton
      Left = 152
      Top = 8
      Width = 75
      Height = 25
      Caption = 'OK'
      Default = True
      Enabled = False
      ModalResult = 1
      TabOrder = 0
      OnClick = BtnOKClick
    end
    object BtnCancel: TButton
      Left = 233
      Top = 8
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 1
      OnClick = BtnCancelClick
    end
  end
end
