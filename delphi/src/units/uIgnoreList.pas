unit uIgnoreList;
(*
  User-maintained ignore list for the patcher: relative paths (exact) or
  wildcard masks (*, ?) that are always excluded from update/repair/
  re-download-all, so user-modded/local files are never touched or
  reported as missing/outdated. Shared by frmSettings, frmFolderSelect and
  RunPatcher (uNxlPatcher). Stored in the same config.ini as other settings.
*)

interface

uses
  System.SysUtils, System.IOUtils, System.Masks, IniFiles;

function IgnoreConfigPath: string;
function LoadIgnorePatterns: TArray<string>;
procedure SaveIgnorePatterns(const Patterns: TArray<string>);

// RelPath uses the manifest's '\'-separated relative path. Matches are
// case-insensitive; a pattern with no wildcard chars is an exact-path match.
function IsIgnored(const RelPath: string; const Patterns: TArray<string>): Boolean;

implementation

function IgnoreConfigPath: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Rua\config.ini');
end;

function LoadIgnorePatterns: TArray<string>;
var
  INI: TIniFile;
  N, I: Integer;
begin
  SetLength(Result, 0);
  if not TFile.Exists(IgnoreConfigPath) then Exit;
  INI := TIniFile.Create(IgnoreConfigPath);
  try
    N := INI.ReadInteger('Ignore', 'Count', 0);
    SetLength(Result, N);
    for I := 0 to N - 1 do
      Result[I] := INI.ReadString('Ignore', 'Item' + IntToStr(I), '');
  finally
    INI.Free;
  end;
end;

procedure SaveIgnorePatterns(const Patterns: TArray<string>);
var
  INI: TIniFile;
  I, OldN: Integer;
begin
  TDirectory.CreateDirectory(ExtractFileDir(IgnoreConfigPath));
  INI := TIniFile.Create(IgnoreConfigPath);
  try
    OldN := INI.ReadInteger('Ignore', 'Count', 0);
    for I := 0 to OldN - 1 do
      INI.DeleteKey('Ignore', 'Item' + IntToStr(I));
    INI.WriteInteger('Ignore', 'Count', Length(Patterns));
    for I := 0 to High(Patterns) do
      INI.WriteString('Ignore', 'Item' + IntToStr(I), Patterns[I]);
  finally
    INI.Free;
  end;
end;

function IsIgnored(const RelPath: string; const Patterns: TArray<string>): Boolean;
var
  P: string;
begin
  Result := False;
  for P in Patterns do
  begin
    if Trim(P) = '' then Continue;
    if MatchesMask(RelPath, P) then Exit(True);
  end;
end;

end.
