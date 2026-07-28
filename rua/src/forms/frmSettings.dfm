object FormSettings: TFormSettings
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Settings'
  ClientHeight = 280
  ClientWidth = 450
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poOwnerFormCenter
  OnCreate = FormCreate
  TextHeight = 15
  object LblGameExe: TLabel
    Left = 12
    Top = 14
    Width = 101
    Height = 15
    Caption = 'Default &game path:'
    FocusControl = EdtGameExe
  end
  object LblTheme: TLabel
    Left = 12
    Top = 62
    Width = 54
    Height = 15
    Caption = 'UI &Theme:'
    FocusControl = CmbTheme
  end
  object LblThemeNote: TLabel
    Left = 8
    Top = 112
    Width = 420
    Height = 30
    AutoSize = False
    Caption = 
      'Drop .vsf VCL style files into a "styles" folder next to the exe' +
      ' to add more themes.'
    Visible = False
    WordWrap = True
  end
  object EdtGameExe: TEdit
    Left = 12
    Top = 33
    Width = 368
    Height = 23
    TabOrder = 0
  end
  object BtnBrowseExe: TButton
    Left = 388
    Top = 33
    Width = 50
    Height = 23
    Caption = '...'
    TabOrder = 1
    OnClick = BtnBrowseExeClick
  end
  object CmbTheme: TComboBox
    Left = 12
    Top = 83
    Width = 220
    Height = 23
    Style = csDropDownList
    TabOrder = 2
    OnChange = CmbThemeChange
  end
  object ChkVerbose: TCheckBox
    Left = 262
    Top = 85
    Width = 162
    Height = 19
    Caption = 'Verbose &log output'
    TabOrder = 4
  end
  object ChkAutoCheck: TCheckBox
    Left = 12
    Top = 115
    Width = 200
    Height = 19
    Caption = 'Check for updates on &start'
    TabOrder = 5
  end
  object ChkAutoUpdate: TCheckBox
    Left = 12
    Top = 140
    Width = 200
    Height = 19
    Caption = '&Auto-update if available'
    TabOrder = 6
  end
  object ChkAutoStart: TCheckBox
    Left = 262
    Top = 115
    Width = 170
    Height = 19
    Caption = 'Start with &Windows'
    TabOrder = 7
  end
  object ChkStartMinimized: TCheckBox
    Left = 262
    Top = 140
    Width = 170
    Height = 19
    Caption = 'Start &minimized to tray'
    TabOrder = 8
  end
  object ChkTrayOnLaunch: TCheckBox
    Left = 12
    Top = 165
    Width = 220
    Height = 19
    Caption = 'Minimize to tray on game &launch'
    TabOrder = 9
  end
  object ChkRememberLastProfile: TCheckBox
    Left = 12
    Top = 195
    Width = 220
    Height = 19
    Caption = 'Remember last &selected profile'
    TabOrder = 10
  end
  object ChkSortAlpha: TCheckBox
    Left = 12
    Top = 220
    Width = 150
    Height = 19
    Caption = 'Sort profiles &A-Z'
    TabOrder = 11
  end
  object PnlBottom: TPanel
    Left = 0
    Top = 185
    Width = 450
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 3
    object BtnOK: TButton
      Left = 262
      Top = 8
      Width = 75
      Height = 25
      Caption = 'OK'
      Default = True
      ModalResult = 1
      TabOrder = 0
    end
    object BtnCancel: TButton
      Left = 356
      Top = 8
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 1
    end
  end
end
