unit uCookieUtil;
{
  Parsing helper for 'Name=Value; Name2=Value2' cookie strings that Rua itself
  obtained through its sign-in browser or credential store. Rua no longer reads
  other browsers' cookie stores or process memory.
}

interface

function ExtractCookieValue(const CookieStr, Name: string): string;

implementation

uses
  System.SysUtils;

function ExtractCookieValue(const CookieStr, Name: string): string;
var
  Parts:   TArray<string>;
  Part:    string;
  Trimmed: string;
  EqPos:   Integer;
begin
  Result := '';
  Parts  := CookieStr.Split([';']);
  for Part in Parts do
  begin
    Trimmed := Trim(Part);
    EqPos   := Pos('=', Trimmed);
    if EqPos <= 0 then Continue;
    if SameText(Copy(Trimmed, 1, EqPos - 1), Name) then
    begin
      Result := Copy(Trimmed, EqPos + 1, MaxInt);
      Exit;
    end;
  end;
end;

end.
