object FormProfileEdit: TFormProfileEdit
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Profile'
  ClientHeight = 232
  ClientWidth = 430
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poOwnerFormCenter
  TextHeight = 15
  object LblName: TLabel
    Left = 12
    Top = 18
    Width = 74
    Height = 15
    Caption = 'Profile &Name:'
    FocusControl = EdtName
  end
  object LblGameExe: TLabel
    Left = 12
    Top = 50
    Width = 84
    Height = 15
    Caption = 'Game &Exe path:'
    FocusControl = EdtGameExe
  end
  object LblEmail: TLabel
    Left = 12
    Top = 86
    Width = 34
    Height = 15
    Caption = 'Account:'
  end
  object LblEmailVal: TLabel
    Left = 70
    Top = 86
    Width = 120
    Height = 15
    Caption = ''
  end
  object LblSession: TLabel
    Left = 12
    Top = 108
    Width = 47
    Height = 15
    Caption = 'Session:'
  end
  object LblSessionVal: TLabel
    Left = 65
    Top = 108
    Width = 120
    Height = 15
    Caption = 'Checking...'
  end
  object LblLastUsed: TLabel
    Left = 12
    Top = 130
    Width = 52
    Height = 15
    Caption = 'Last Used:'
  end
  object LblLastUsedVal: TLabel
    Left = 70
    Top = 130
    Width = 120
    Height = 15
    Caption = ''
  end
  object EdtName: TEdit
    Left = 104
    Top = 14
    Width = 314
    Height = 23
    MaxLength = 64
    TabOrder = 0
    OnChange = EdtNameChange
  end
  object EdtGameExe: TEdit
    Left = 104
    Top = 46
    Width = 254
    Height = 23
    TabOrder = 1
  end
  object BtnBrowseExe: TButton
    Left = 366
    Top = 46
    Width = 52
    Height = 23
    Caption = '...'
    TabOrder = 2
    OnClick = BtnBrowseExeClick
  end
  object LblLaunchArgs: TLabel
    Left = 12
    Top = 155
    Width = 80
    Height = 15
    Caption = '&Launch Args:'
    FocusControl = EdtLaunchArgs
  end
  object LblLaunchArgsHint: TLabel
    Left = 104
    Top = 155
    Width = 314
    Height = 15
    AutoSize = False
    Caption = 'Extra flags appended to Client.exe (e.g. -ChannelCode KR)'
    Font.Color = clGrayText
    Font.Height = -11
    ParentFont = False
  end
  object EdtLaunchArgs: TEdit
    Left = 104
    Top = 172
    Width = 314
    Height = 23
    TabOrder = 3
  end
  object PnlBottom: TPanel
    Left = 0
    Top = 192
    Width = 430
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 4
    object BtnRefreshLogin: TButton
      Left = 12
      Top = 8
      Width = 105
      Height = 25
      Caption = 'Refresh Login'
      TabOrder = 0
      OnClick = BtnRefreshLoginClick
    end
    object BtnOK: TButton
      Left = 244
      Top = 8
      Width = 75
      Height = 25
      Caption = 'OK'
      Default = True
      ModalResult = 1
      TabOrder = 1
    end
    object BtnCancel: TButton
      Left = 338
      Top = 8
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 2
    end
  end
end
