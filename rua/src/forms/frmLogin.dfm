object FormLogin: TFormLogin
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Nexon Account'
  ClientHeight = 424
  ClientWidth = 500
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  OnCreate = FormCreate
  TextHeight = 15
  object PnlMain: TPanel
    Left = 0
    Top = 0
    Width = 500
    Height = 384
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 0
    object LblEPHeader: TLabel
      Left = 24
      Top = 14
      Width = 452
      Height = 18
      AutoSize = False
      Caption = 'Email / Password Login'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -13
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LblEmailAddr: TLabel
      Left = 24
      Top = 40
      Width = 32
      Height = 15
      Caption = '&Email:'
      FocusControl = EdtEmail
    end
    object LblEmailPwd: TLabel
      Left = 24
      Top = 68
      Width = 53
      Height = 15
      Caption = '&Password:'
      FocusControl = EdtPassword
    end
    object LblOrBrowser: TLabel
      Left = 24
      Top = 103
      Width = 452
      Height = 15
      Alignment = taCenter
      AutoSize = False
      Caption = '-- or, use browser login --'
    end
    object LblStep1: TLabel
      Left = 24
      Top = 132
      Width = 452
      Height = 18
      AutoSize = False
      Caption = 'Step 1 - Open Nexon in your browser'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -13
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LblStep1Desc: TLabel
      Left = 24
      Top = 156
      Width = 452
      Height = 30
      AutoSize = False
      Caption = 
        'Click below to open nexon.com. Log in.'#13#10'If already logged in, lo' +
        'g OUT first, then log back in.'
      WordWrap = True
    end
    object Bevel2: TBevel
      Left = 24
      Top = 97
      Width = 452
      Height = 2
      Shape = bsTopLine
    end
    object Bevel3: TBevel
      Left = 24
      Top = 122
      Width = 452
      Height = 2
      Shape = bsTopLine
    end
    object Bevel1: TBevel
      Left = 24
      Top = 244
      Width = 452
      Height = 2
      Shape = bsTopLine
    end
    object LblStep2: TLabel
      Left = 24
      Top = 252
      Width = 452
      Height = 18
      AutoSize = False
      Caption = 'Step 2 - Import cookies when done'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -13
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LblStep2Desc: TLabel
      Left = 24
      Top = 276
      Width = 452
      Height = 15
      AutoSize = False
      Caption = 'After logging in, click Import.'
    end
    object LblStatus: TLabel
      Left = 24
      Top = 346
      Width = 452
      Height = 30
      AutoSize = False
      Caption = 'Click "Open nexon.com" to begin, or sign in above.'
      WordWrap = True
    end
    object EdtEmail: TEdit
      Left = 90
      Top = 37
      Width = 386
      Height = 23
      TabOrder = 0
    end
    object EdtPassword: TEdit
      Left = 90
      Top = 65
      Width = 230
      Height = 23
      PasswordChar = '*'
      TabOrder = 1
    end
    object BtnEmailLogin: TButton
      Left = 328
      Top = 65
      Width = 148
      Height = 23
      Caption = 'Sign In'
      TabOrder = 2
      OnClick = BtnEmailLoginClick
    end
    object BtnCancelOtp: TButton
      Left = 90
      Top = 65
      Width = 110
      Height = 23
      Caption = 'Cancel OTP'
      TabOrder = 3
      TabStop = False
      Visible = False
      OnClick = BtnCancelOtpClick
    end
    object BtnOpenBrowser: TButton
      Left = 24
      Top = 197
      Width = 452
      Height = 38
      Caption = 'Open nexon.com'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
      TabOrder = 4
      OnClick = BtnOpenBrowserClick
    end
    object BtnImport: TButton
      Left = 24
      Top = 300
      Width = 155
      Height = 28
      Caption = 'Import Cookies'
      TabOrder = 5
      OnClick = BtnImportClick
    end
    object BtnManual: TButton
      Left = 191
      Top = 300
      Width = 155
      Height = 28
      Caption = 'Manual entry...'
      TabOrder = 6
      OnClick = BtnManualClick
    end
  end
  object PnlButtons: TPanel
    Left = 0
    Top = 384
    Width = 500
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 1
    object BtnCancel: TButton
      Left = 412
      Top = 8
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      TabOrder = 0
      OnClick = BtnCancelClick
    end
  end
  object TimerPoll: TTimer
    Enabled = False
    OnTimer = TimerPollTimer
    Left = 400
    Top = 272
  end
end
