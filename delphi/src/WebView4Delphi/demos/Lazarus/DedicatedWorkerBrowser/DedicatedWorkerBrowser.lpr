program DedicatedWorkerBrowser;

{$MODE Delphi}

uses
  Forms, Interfaces,
  uMainForm in 'uMainForm.pas' {MainForm};



begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;   
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
