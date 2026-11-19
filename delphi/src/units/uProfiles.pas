unit uProfiles;
{
  Profile management. Non-sensitive index stored as plain JSON.
  Cookies/secrets stored in Windows Credential Manager via uCredStore.
}

interface

uses
  System.SysUtils, System.IOUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.SyncObjs, Winapi.Windows, uCredStore;

type
  TNexonProfile = record
    Name:          string;
    UserNo:        string;
    DeviceId:      string;
    Email:         string; // cached from account API, populated on re-login or profile edit
    Products:      TArray<Integer>;
    LastUsed:      TDateTime;
    NxLExpiry:     TDateTime; // NxLSession expiry (0 = unknown)
    GameExe:       string;    // per-profile override for Client.exe path ('' = use global)
    TotalPlaytime: Int64;     // accumulated play seconds
    SessionCount:  Integer;   // lifetime game sessions launched
    LaunchArgs:    string;    // extra args appended to Client.exe command line
  end;

  TProfileList = TObjectList<TObject>; // use generic list of records via helpers below

function  ProfileIndexPath: string;
function  LoadProfiles: TArray<TNexonProfile>;
procedure SaveProfiles(const Profiles: TArray<TNexonProfile>);
procedure AddOrUpdateProfile(const Profile: TNexonProfile; const Cookies: string);
procedure DeleteProfile(const Name: string);
function  LoadCookies(const ProfileName: string): string;
procedure UpdateLastUsed(const ProfileName: string);
procedure UpdateNxLExpiry(const ProfileName: string; Expiry: TDateTime);
procedure UpdatePlaytime(const ProfileName: string; SessionSecs: Int64);

implementation

var
  // Every read-modify-write of profiles.json runs under this lock. Startup
  // session checks, token refresh, the 60 s ticker and game-exit handling all
  // touch the index from different threads; without it they overwrite each
  // other's updates (lost token expiry / playtime) or read a half-written file.
  GProfLock: TCriticalSection;

function ProfileIndexPath: string;
begin
  Result := TPath.Combine(
    GetEnvironmentVariable('APPDATA'),
    'Rua\profiles.json');
end;

function LoadProfilesRaw: TArray<TNexonProfile>;
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
        P.Name          := Obj.GetValue<string>('name',      '');
        P.UserNo        := Obj.GetValue<string>('user_no',   '');
        P.DeviceId      := Obj.GetValue<string>('device_id', '');
        P.Email         := Obj.GetValue<string>('email',     '');
        P.GameExe       := Obj.GetValue<string>('game_exe',  '');
        P.LaunchArgs    := Obj.GetValue<string>('launch_args', '');
        P.TotalPlaytime := Obj.GetValue<Int64>('total_playtime', 0);
        P.SessionCount  := Obj.GetValue<Integer>('session_count', 0);
        P.LastUsed  := 0;
        P.NxLExpiry := 0;
        P.Products  := [];
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
        var XP := Obj.GetValue<string>('nxl_expiry', '');
        if XP <> '' then
          try P.NxLExpiry := ISO8601ToDate(XP); except end;
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

function LoadProfiles: TArray<TNexonProfile>;
begin
  GProfLock.Enter;
  try
    Result := LoadProfilesRaw;
  finally
    GProfLock.Leave;
  end;
end;

procedure SaveProfilesRaw(const Profiles: TArray<TNexonProfile>);
var
  Path, Dir, Tmp: string;
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
      if P.LaunchArgs <> '' then
        Obj.AddPair('launch_args', P.LaunchArgs);
      if P.TotalPlaytime > 0 then
        Obj.AddPair('total_playtime', TJSONNumber.Create(P.TotalPlaytime));
      if P.SessionCount > 0 then
        Obj.AddPair('session_count', TJSONNumber.Create(P.SessionCount));
      if P.LastUsed > 0 then
        Obj.AddPair('last_used', DateToISO8601(P.LastUsed));
      if P.NxLExpiry > 0 then
        Obj.AddPair('nxl_expiry', DateToISO8601(P.NxLExpiry));
      PA := TJSONArray.Create;
      for ProdId in P.Products do
        PA.Add(ProdId);
      Obj.AddPair('products', PA);
      Arr.Add(Obj);
    end;
    // Write beside, then swap in: readers never see a truncated index.
    Tmp := Path + '.tmp';
    TFile.WriteAllText(Tmp, Arr.Format(2), TEncoding.UTF8);
    if not MoveFileEx(PChar(Tmp), PChar(Path), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      // Fallback (e.g. share without atomic replace): plain overwrite.
      TFile.WriteAllText(Path, Arr.Format(2), TEncoding.UTF8);
      TFile.Delete(Tmp);
    end;
  finally
    Arr.Free;
  end;
end;

procedure SaveProfiles(const Profiles: TArray<TNexonProfile>);
begin
  GProfLock.Enter;
  try
    SaveProfilesRaw(Profiles);
  finally
    GProfLock.Leave;
  end;
end;

procedure AddOrUpdateProfile(const Profile: TNexonProfile; const Cookies: string);
var
  Profiles: TArray<TNexonProfile>;
  i:        Integer;
  Found:    Boolean;
begin
  GProfLock.Enter;
  try
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
  finally
    GProfLock.Leave;
  end;
  CredSave(Profile.Name, Cookies);
end;

procedure DeleteProfile(const Name: string);
var
  Profiles: TArray<TNexonProfile>;
  New:      TArray<TNexonProfile>;
  P:        TNexonProfile;
begin
  GProfLock.Enter;
  try
    Profiles := LoadProfiles;
    New      := [];
    for P in Profiles do
      if P.Name <> Name then
      begin
        SetLength(New, Length(New) + 1);
        New[High(New)] := P;
      end;
    SaveProfiles(New);
  finally
    GProfLock.Leave;
  end;
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
  GProfLock.Enter;
  try
    Profiles := LoadProfiles;
    for i := 0 to High(Profiles) do
      if Profiles[i].Name = ProfileName then
      begin
        Profiles[i].LastUsed := Now;
        Break;
      end;
    SaveProfiles(Profiles);
  finally
    GProfLock.Leave;
  end;
end;

procedure UpdateNxLExpiry(const ProfileName: string; Expiry: TDateTime);
var
  Profiles: TArray<TNexonProfile>;
  i:        Integer;
begin
  GProfLock.Enter;
  try
    Profiles := LoadProfiles;
    for i := 0 to High(Profiles) do
      if Profiles[i].Name = ProfileName then
      begin
        Profiles[i].NxLExpiry := Expiry;
        Break;
      end;
    SaveProfiles(Profiles);
  finally
    GProfLock.Leave;
  end;
end;

procedure UpdatePlaytime(const ProfileName: string; SessionSecs: Int64);
var
  Profiles: TArray<TNexonProfile>;
  i:        Integer;
begin
  if SessionSecs <= 0 then Exit;
  GProfLock.Enter;
  try
    Profiles := LoadProfiles;
    for i := 0 to High(Profiles) do
      if Profiles[i].Name = ProfileName then
      begin
        Inc(Profiles[i].TotalPlaytime, SessionSecs);
        Inc(Profiles[i].SessionCount);
        Break;
      end;
    SaveProfiles(Profiles);
  finally
    GProfLock.Leave;
  end;
end;

initialization
  GProfLock := TCriticalSection.Create;

finalization
  GProfLock.Free;

end.
