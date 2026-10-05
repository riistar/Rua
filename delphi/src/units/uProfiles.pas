unit uProfiles;
{
  Profile management. Non-sensitive index stored as plain JSON.
  Cookies/secrets stored in Windows Credential Manager via uCredStore.
}

interface

uses
  System.SysUtils, System.IOUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, uCredStore;

type
  TNexonProfile = record
    Name:     string;
    UserNo:   string;
    DeviceId: string;
    Email:    string; // cached from account API, populated on re-login or profile edit
    Products: TArray<Integer>;
    LastUsed: TDateTime;
    GameExe:  string; // per-profile override for Client.exe path ('' = use global)
  end;

  TProfileList = TObjectList<TObject>; // use generic list of records via helpers below

function  ProfileIndexPath: string;
function  LoadProfiles: TArray<TNexonProfile>;
procedure SaveProfiles(const Profiles: TArray<TNexonProfile>);
procedure AddOrUpdateProfile(const Profile: TNexonProfile; const Cookies: string);
procedure DeleteProfile(const Name: string);
function  LoadCookies(const ProfileName: string): string;
procedure UpdateLastUsed(const ProfileName: string);

implementation

function ProfileIndexPath: string;
begin
  Result := TPath.Combine(
    GetEnvironmentVariable('APPDATA'),
    'Rua\profiles.json');
end;

function LoadProfiles: TArray<TNexonProfile>;
var
  Path: string;
  Raw:  string;
  Arr:  TJSONArray;
  Obj:  TJSONObject;
  P:    TNexonProfile;
  PA:   TJSONArray;
  i:    Integer;
  List: TList<TNexonProfile>;
begin
  List := TList<TNexonProfile>.Create;
  try
    Path := ProfileIndexPath;
    if not TFile.Exists(Path) then
    begin
      Result := List.ToArray;
      Exit;
    end;
    Raw := TFile.ReadAllText(Path, TEncoding.UTF8);
    Arr := TJSONObject.ParseJSONValue(Raw) as TJSONArray;
    if Arr = nil then
    begin
      Result := List.ToArray;
      Exit;
    end;
    try
      for var Item in Arr do
      begin
        Obj := Item as TJSONObject;
        P.Name     := Obj.GetValue<string>('name',      '');
        P.UserNo   := Obj.GetValue<string>('user_no',   '');
        P.DeviceId := Obj.GetValue<string>('device_id', '');
        P.Email    := Obj.GetValue<string>('email',     '');
        P.GameExe  := Obj.GetValue<string>('game_exe',  '');
        P.LastUsed := 0;
        P.Products := [];
        PA := Obj.GetValue('products') as TJSONArray;
        if PA <> nil then
        begin
          SetLength(P.Products, PA.Count);
          for i := 0 to PA.Count - 1 do
            P.Products[i] := (PA.Items[i] as TJSONNumber).AsInt;
        end;
        // last_used as ISO string
        var LU := Obj.GetValue<string>('last_used', '');
        if LU <> '' then
          try P.LastUsed := ISO8601ToDate(LU); except end;
        List.Add(P);
      end;
    finally
      Arr.Free;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

procedure SaveProfiles(const Profiles: TArray<TNexonProfile>);
var
  Path, Dir: string;
  Arr:       TJSONArray;
  Obj:       TJSONObject;
  PA:        TJSONArray;
  ProdId:    Integer;
begin
  Path := ProfileIndexPath;
  Dir  := TPath.GetDirectoryName(Path);
  if not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);

  Arr := TJSONArray.Create;
  try
    for var P in Profiles do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('name',      P.Name);
      Obj.AddPair('user_no',   P.UserNo);
      Obj.AddPair('device_id', P.DeviceId);
      if P.Email <> '' then
        Obj.AddPair('email', P.Email);
      if P.GameExe <> '' then
        Obj.AddPair('game_exe', P.GameExe);
      if P.LastUsed > 0 then
        Obj.AddPair('last_used', DateToISO8601(P.LastUsed));
      PA := TJSONArray.Create;
      for ProdId in P.Products do
        PA.Add(ProdId);
      Obj.AddPair('products', PA);
      Arr.Add(Obj);
    end;
    TFile.WriteAllText(Path, Arr.Format(2), TEncoding.UTF8);
  finally
    Arr.Free;
  end;
end;

procedure AddOrUpdateProfile(const Profile: TNexonProfile; const Cookies: string);
var
  Profiles: TArray<TNexonProfile>;
  i:        Integer;
  Found:    Boolean;
begin
  Profiles := LoadProfiles;
  Found    := False;
  for i := 0 to High(Profiles) do
    if Profiles[i].Name = Profile.Name then
    begin
      Profiles[i] := Profile;
      Found       := True;
      Break;
    end;
  if not Found then
  begin
    SetLength(Profiles, Length(Profiles) + 1);
    Profiles[High(Profiles)] := Profile;
  end;
  SaveProfiles(Profiles);
  CredSave(Profile.Name, Cookies);
end;

procedure DeleteProfile(const Name: string);
var
  Profiles: TArray<TNexonProfile>;
  New:      TArray<TNexonProfile>;
  P:        TNexonProfile;
begin
  Profiles := LoadProfiles;
  New      := [];
  for P in Profiles do
    if P.Name <> Name then
    begin
      SetLength(New, Length(New) + 1);
      New[High(New)] := P;
    end;
  SaveProfiles(New);
  CredDelete(Name);
end;

function LoadCookies(const ProfileName: string): string;
begin
  Result := CredLoad(ProfileName);
end;

procedure UpdateLastUsed(const ProfileName: string);
var
  Profiles: TArray<TNexonProfile>;
  i:        Integer;
begin
  Profiles := LoadProfiles;
  for i := 0 to High(Profiles) do
    if Profiles[i].Name = ProfileName then
    begin
      Profiles[i].LastUsed := Now;
      Break;
    end;
  SaveProfiles(Profiles);
end;

end.
