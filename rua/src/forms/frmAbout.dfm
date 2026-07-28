object FormAbout: TFormAbout
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'About Rua'
  ClientHeight = 220
  ClientWidth = 340
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Segoe UI'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 13
  object LblTitle: TLabel
    Left = 20
    Top = 16
    Width = 76
    Height = 28
    Caption = 'Rua'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -24
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LblSubtitle: TLabel
    Left = 20
    Top = 48
    Width = 250
    Height = 13
    Caption = '3rd-party Nexon Launcher replacement for Mabinogi'
  end
  object Bevel1: TBevel
    Left = 20
    Top = 72
    Width = 300
    Height = 2
  end
  object LblCopyright: TLabel
    Left = 20
    Top = 84
    Width = 116
    Height = 13
    Caption = 'Copyright '#169' Rii / RiiStar'
  end
  object LblCredits: TLabel
    Left = 20
    Top = 112
    Width = 48
    Height = 13
    Caption = 'Thanks to:'
  end
  object LblThanks: TLabel
    Left = 20
    Top = 132
    Width = 162
    Height = 39
    Caption = 'Hydwwn project by Sven'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object BtnOK: TButton
    Left = 255
    Top = 185
    Width = 65
    Height = 23
    Caption = 'OK'
    Default = True
    TabOrder = 0
    OnClick = BtnOKClick
  end
end
