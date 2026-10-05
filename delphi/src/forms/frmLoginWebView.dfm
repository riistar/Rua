object FormLoginWebView: TFormLoginWebView
  Left = 0
  Top = 0
  Caption = 'Log in to Nexon'
  ClientHeight = 650
  ClientWidth = 900
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnShow = FormShow
  TextHeight = 15
  object PnlStatus: TPanel
    Left = 0
    Top = 0
    Width = 900
    Height = 36
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object LblStatus: TLabel
      Left = 8
      Top = 10
      Width = 788
      Height = 15
      AutoSize = False
      Caption = 'Initializing browser...'
    end
    object BtnCancel: TButton
      Left = 817
      Top = 6
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      TabOrder = 0
      OnClick = BtnCancelClick
    end
  end
  object PnlUrl: TPanel
    Left = 0
    Top = 614
    Width = 900
    Height = 20
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 1
    object LblUrl: TLabel
      Left = 4
      Top = 2
      Width = 892
      Height = 15
      AutoSize = False
      Caption = ''
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
  end
  object PnlBrowser: TPanel
    Left = 0
    Top = 36
    Width = 900
    Height = 578
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 2
  end
  object TimerInit: TTimer
    Enabled = False
    Interval = 250
    OnTimer = TimerInitTimer
  end
  object TimerCookies: TTimer
    Enabled = False
    Interval = 1500
    OnTimer = TimerCookiesTimer
  end
end
