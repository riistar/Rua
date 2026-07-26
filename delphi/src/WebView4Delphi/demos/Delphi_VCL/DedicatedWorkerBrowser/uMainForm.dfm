object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'VirtualHostBrowser - Initializing...'
  ClientHeight = 701
  ClientWidth = 1040
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnCreate = FormCreate
  OnShow = FormShow
  TextHeight = 15
  object WVWindowParent1: TWVWindowParent
    Left = 0
    Top = 24
    Width = 855
    Height = 677
    Align = alClient
    TabOrder = 1
    Browser = WVBrowser1
    ExplicitTop = 29
    ExplicitWidth = 617
    ExplicitHeight = 489
  end
  object AddressPnl: TPanel
    Left = 0
    Top = 0
    Width = 1040
    Height = 24
    Align = alTop
    BevelOuter = bvNone
    Enabled = False
    TabOrder = 0
    ExplicitWidth = 995
    DesignSize = (
      1040
      24)
    object AddressCb: TComboBox
      Left = 0
      Top = 0
      Width = 988
      Height = 23
      Anchors = [akLeft, akTop, akRight]
      ItemIndex = 0
      TabOrder = 0
      Text = 
        'https://appassets.example/ScenarioDedicatedWorkerPostMessage.htm' +
        'l'
      Items.Strings = (
        
          'https://appassets.example/ScenarioDedicatedWorkerPostMessage.htm' +
          'l'
        'https://www.bing.com'
        'https://www.google.com'
        
          'https://www.whatismybrowser.com/detect/what-http-headers-is-my-b' +
          'rowser-sending'
        'https://www.w3schools.com/js/tryit.asp?filename=tryjs_win_close'
        'https://www.w3schools.com/js/tryit.asp?filename=tryjs_alert'
        'https://www.w3schools.com/js/tryit.asp?filename=tryjs_loc_assign'
        
          'https://www.w3schools.com/jsref/tryit.asp?filename=tryjsref_styl' +
          'e_backgroundcolor'
        
          'https://www.w3schools.com/Tags/tryit.asp?filename=tryhtml_iframe' +
          '_name'
        'https://www.w3schools.com/html/html5_video.asp'
        'http://html5test.com/'
        
          'https://webrtc.github.io/samples/src/content/devices/input-outpu' +
          't/'
        'https://test.webrtc.org/'
        'https://www.browserleaks.com/webrtc'
        'https://shaka-player-demo.appspot.com/demo/'
        'http://webglsamples.org/'
        'https://get.webgl.org/'
        'https://www.briskbard.com'
        'https://www.youtube.com'
        'https://html5demos.com/drag/'
        'https://frames-per-second.appspot.com/')
      ExplicitWidth = 943
    end
    object GoBtn: TButton
      Left = 991
      Top = 0
      Width = 49
      Height = 24
      Align = alRight
      Caption = 'Go'
      TabOrder = 1
      OnClick = GoBtnClick
      ExplicitLeft = 946
    end
  end
  object Panel1: TPanel
    Left = 855
    Top = 24
    Width = 185
    Height = 677
    Align = alRight
    BevelOuter = bvNone
    TabOrder = 2
    ExplicitTop = 29
    object Memo1: TMemo
      Left = 0
      Top = 227
      Width = 185
      Height = 450
      Align = alClient
      ReadOnly = True
      ScrollBars = ssBoth
      TabOrder = 0
    end
    object RadioGroup1: TRadioGroup
      Left = 0
      Top = 0
      Width = 185
      Height = 113
      Align = alTop
      Caption = ' Operation '
      TabOrder = 1
      ExplicitLeft = 6
      ExplicitTop = 5
    end
    object AddRbt: TRadioButton
      Left = 6
      Top = 19
      Width = 113
      Height = 17
      Caption = 'Add'
      Checked = True
      TabOrder = 2
      TabStop = True
    end
    object SubRbt: TRadioButton
      Left = 6
      Top = 42
      Width = 113
      Height = 17
      Caption = 'Sub'
      TabOrder = 3
    end
    object MulRbt: TRadioButton
      Left = 6
      Top = 65
      Width = 113
      Height = 17
      Caption = 'Mul'
      TabOrder = 4
    end
    object DivRbt: TRadioButton
      Left = 6
      Top = 88
      Width = 113
      Height = 17
      Caption = 'Div'
      TabOrder = 5
    end
    object Panel2: TPanel
      Left = 0
      Top = 113
      Width = 185
      Height = 114
      Align = alTop
      BevelOuter = bvNone
      TabOrder = 6
      object Label1: TLabel
        Left = 6
        Top = 14
        Width = 37
        Height = 15
        Caption = 'Value 1'
      end
      object Label2: TLabel
        Left = 6
        Top = 50
        Width = 37
        Height = 15
        Caption = 'Value 2'
      end
      object Value1Edt: TSpinEdit
        Left = 80
        Top = 11
        Width = 97
        Height = 24
        MaxValue = 10
        MinValue = 1
        TabOrder = 0
        Value = 2
      end
      object Value2Edt: TSpinEdit
        Left = 80
        Top = 47
        Width = 97
        Height = 24
        MaxValue = 10
        MinValue = 1
        TabOrder = 1
        Value = 2
      end
      object PostBtn: TButton
        Left = 6
        Top = 80
        Width = 171
        Height = 25
        Caption = 'Post to web worker'
        TabOrder = 2
        OnClick = PostBtnClick
      end
    end
  end
  object Timer1: TTimer
    Enabled = False
    Interval = 300
    OnTimer = Timer1Timer
    Left = 312
    Top = 160
  end
  object WVBrowser1: TWVBrowser
    DefaultURL = 
      'https://appassets.example/ScenarioDedicatedWorkerPostMessage.htm' +
      'l'
    TargetCompatibleBrowserVersion = '95.0.1020.44'
    AllowSingleSignOnUsingOSPrimaryAccount = False
    OnInitializationError = WVBrowser1InitializationError
    OnAfterCreated = WVBrowser1AfterCreated
    OnDocumentTitleChanged = WVBrowser1DocumentTitleChanged
    OnDedicatedWorkerCreated = WVBrowser1DedicatedWorkerCreated
    OnDedicatedWorkerWebMessageReceived = WVBrowser1DedicatedWorkerWebMessageReceived
    Left = 200
    Top = 160
  end
end
