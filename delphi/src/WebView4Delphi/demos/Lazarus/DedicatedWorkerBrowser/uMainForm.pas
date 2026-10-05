unit uMainForm;

{$MODE Delphi}

interface

uses
  LCLIntf, LCLType, LMessages, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs, ExtCtrls, ComCtrls, StdCtrls,
  uWVBrowser, uWVWinControl, uWVWindowParent, uWVTypes, uWVConstants, uWVTypeLibrary,
  uWVLibFunctions, uWVLoader, uWVInterfaces, uWVCoreWebView2Args,
  uWVBrowserBase, uWVCoreWebView2DedicatedWorker;

type

  { TMainForm }

  TMainForm = class(TForm)
    UpDown1: TUpDown;
    UpDown2: TUpDown;
    Value1Edt: TEdit;
    Value2Edt: TEdit;
    WVWindowParent1: TWVWindowParent;
    Timer1: TTimer;
    WVBrowser1: TWVBrowser;
    AddressPnl: TPanel;
    AddressCb: TComboBox;
    GoBtn: TButton;
    Memo1: TMemo;
    Panel1: TPanel;
    RadioGroup1: TRadioGroup;
    AddRbt: TRadioButton;
    SubRbt: TRadioButton;
    MulRbt: TRadioButton;
    DivRbt: TRadioButton;
    Label1: TLabel;
    Label2: TLabel;
    Panel2: TPanel;
    PostBtn: TButton;

    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure Timer1Timer(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure GoBtnClick(Sender: TObject);
    procedure PostBtnClick(Sender: TObject);
    procedure UpDown1Click(Sender: TObject; Button: TUDBtnType);
    procedure UpDown2Click(Sender: TObject; Button: TUDBtnType);

    procedure WVBrowser1AfterCreated(Sender: TObject);
    procedure WVBrowser1DocumentTitleChanged(Sender: TObject);
    procedure WVBrowser1InitializationError(Sender: TObject; aErrorCode: HRESULT; const aErrorMessage: wvstring);
    procedure WVBrowser1DedicatedWorkerCreated(Sender: TObject; const aWebView: ICoreWebView2; const aArgs: ICoreWebView2DedicatedWorkerCreatedEventArgs);
    procedure WVBrowser1DedicatedWorkerWebMessageReceived(Sender: TObject; const aDedicatedWorker: ICoreWebView2DedicatedWorker; const aArgs: ICoreWebView2WebMessageReceivedEventArgs; aWorkerID: Cardinal);

  protected
    FWorker : TCoreWebView2DedicatedWorker;

    procedure WMMove(var aMessage : TWMMove); message WM_MOVE;
    procedure WMMoving(var aMessage : TMessage); message WM_MOVING;

  public
    { Public declarations }
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

// This demo loads a local HTML file loaded using a virtual host in a WebView2 browser.

// This file is located in the WebView4Delphi\assets\dedicatedworker directory.

// This demo maps the customhost.test domain to the ..\assets directory by calling
// TWVBrowser.SetVirtualHostNameToFolderMapping inside the TWVBrowser.OnAfterCreated event.

// Read this for all the details about this feature :
// https://docs.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2_3?view=webview2-1.0.1020.30#setvirtualhostnametofoldermapping

procedure TMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  if assigned(FWorker) then
    FreeAndNil(FWorker);
end;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FWorker := nil;
end;

procedure TMainForm.FormShow(Sender: TObject);
begin
  if GlobalWebView2Loader.InitializationError then
    showmessage(GlobalWebView2Loader.ErrorMessage)
   else
    if GlobalWebView2Loader.Initialized then
      WVBrowser1.CreateBrowser(WVWindowParent1.Handle)
     else
      Timer1.Enabled := True;
end;

procedure TMainForm.GoBtnClick(Sender: TObject);
begin
  WVBrowser1.Navigate(AddressCb.Text);
end;

procedure TMainForm.PostBtnClick(Sender: TObject);
var
  TempOper, TempJson : wvstring;

begin
  if not(assigned(FWorker)) then exit;

  if      AddRbt.Checked then TempOper := 'ADD'
  else if SubRbt.Checked then TempOper := 'SUB'
  else if MulRbt.Checked then TempOper := 'MUL'
  else                        TempOper := 'DIV';

  TempJson := '{"command":"' + TempOper + '","first":' + Value1Edt.Text + ',"second":' + Value2Edt.Text + '}';

  Memo1.Lines.Add('Message to worker: ' + TempJson);

  FWorker.PostWebMessageAsJson(TempJson);
end;

procedure TMainForm.UpDown1Click(Sender: TObject; Button: TUDBtnType);
begin
  Value1Edt.Text := inttostr(UpDown1.Position);
end;

procedure TMainForm.UpDown2Click(Sender: TObject; Button: TUDBtnType);
begin
  Value2Edt.Text := inttostr(UpDown2.Position);
end;

procedure TMainForm.WVBrowser1AfterCreated(Sender: TObject);
begin
  WVWindowParent1.UpdateSize;
  Caption := 'DedicatedWorkerBrowser';
  AddressPnl.Enabled := True;
  WVBrowser1.SetVirtualHostNameToFolderMapping('appassets.example', '..\assets\dedicatedworker', COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
end;

procedure TMainForm.WVBrowser1DedicatedWorkerCreated(Sender: TObject;
  const aWebView: ICoreWebView2;
  const aArgs: ICoreWebView2DedicatedWorkerCreatedEventArgs);
var
  TempArgs : TCoreWebView2DedicatedWorkerCreatedEventArgs;
begin
  TempArgs := TCoreWebView2DedicatedWorkerCreatedEventArgs.Create(aArgs);
  FWorker  := TCoreWebView2DedicatedWorker.Create(TempArgs.Worker);
  FWorker.AddAllBrowserEvents(WVBrowser1);
  Memo1.Lines.Add('Worker created.');
  TempArgs.Free;
end;

procedure TMainForm.WVBrowser1DedicatedWorkerWebMessageReceived(Sender: TObject;
  const aDedicatedWorker: ICoreWebView2DedicatedWorker;
  const aArgs: ICoreWebView2WebMessageReceivedEventArgs; aWorkerID: Cardinal);
var
  TempArgs : TCoreWebView2WebMessageReceivedEventArgs;
begin
  TempArgs := TCoreWebView2WebMessageReceivedEventArgs.Create(aArgs);
  Memo1.Lines.Add(TempArgs.WebMessageAsString);
  TempArgs.Free;
end;

procedure TMainForm.WVBrowser1DocumentTitleChanged(Sender: TObject);
begin
  Caption := 'DedicatedWorkerBrowser - ' + WVBrowser1.DocumentTitle;
end;

procedure TMainForm.WVBrowser1InitializationError(Sender: TObject;
  aErrorCode: HRESULT; const aErrorMessage: wvstring);
begin
  showmessage(aErrorMessage);
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  Timer1.Enabled := False;

  if GlobalWebView2Loader.Initialized then
    WVBrowser1.CreateBrowser(WVWindowParent1.Handle)
   else
    Timer1.Enabled := True;
end;

procedure TMainForm.WMMove(var aMessage : TWMMove);
begin
  inherited;

  if (WVBrowser1 <> nil) then
    WVBrowser1.NotifyParentWindowPositionChanged;
end;

procedure TMainForm.WMMoving(var aMessage : TMessage);
begin
  inherited;

  if (WVBrowser1 <> nil) then
    WVBrowser1.NotifyParentWindowPositionChanged;
end;

initialization
  GlobalWebView2Loader                := TWVLoader.Create(nil);
  GlobalWebView2Loader.UserDataFolder := ExtractFileDir(Application.ExeName) + '\CustomCache';
  GlobalWebView2Loader.StartWebView2;

end.
