unit uCredStore;
{
  Windows Credential Manager wrapper.
  Stores sensitive profile data (cookies) encrypted by the OS, per-user.
  Target key: "Rua\[ProfileName]"
}

interface

uses
  Winapi.Windows, System.SysUtils;

function CredSave(const ProfileName, Secret: string): Boolean;
function CredLoad(const ProfileName: string): string;
procedure CredDelete(const ProfileName: string);

// Migrate credentials stored under OldPrefix to current CRED_PREFIX.
// Returns number of entries migrated.
function CredMigrateFrom(const OldPrefix: string;
  const ProfileNames: TArray<string>): Integer;

implementation

const
  CRED_TYPE_GENERIC          = 1;
  CRED_PERSIST_LOCAL_MACHINE = 2;
  CRED_PREFIX                = 'Rua\';

type
  _CREDENTIALW = record
    Flags:              DWORD;
    Type_:              DWORD;
    TargetName:         LPWSTR;
    Comment:            LPWSTR;
    LastWritten:        TFileTime;
    CredentialBlobSize: DWORD;
    CredentialBlob:     LPBYTE;
    Persist:            DWORD;
    AttributeCount:     DWORD;
    Attributes:         Pointer;
    TargetAlias:        LPWSTR;
    UserName:           LPWSTR;
  end;
  PCREDENTIALW = ^_CREDENTIALW;

function CredWriteW(Credential: PCREDENTIALW; Flags: DWORD): BOOL;
  stdcall; external 'advapi32.dll' name 'CredWriteW';
function CredReadW(TargetName: LPWSTR; Type_, Flags: DWORD;
  out Credential: PCREDENTIALW): BOOL;
  stdcall; external 'advapi32.dll' name 'CredReadW';
function CredDeleteW(TargetName: LPWSTR; Type_, Flags: DWORD): BOOL;
  stdcall; external 'advapi32.dll' name 'CredDeleteW';
procedure CredFree(Buffer: Pointer);
  stdcall; external 'advapi32.dll' name 'CredFree';

function CredSave(const ProfileName, Secret: string): Boolean;
var
  Cred:   _CREDENTIALW;
  Target: WideString;
  Blob:   TBytes;
begin
  Target := CRED_PREFIX + ProfileName;
  Blob   := TEncoding.UTF8.GetBytes(Secret);

  ZeroMemory(@Cred, SizeOf(Cred));
  Cred.Type_              := CRED_TYPE_GENERIC;
  Cred.TargetName         := PWideChar(Target);
  Cred.CredentialBlob     := @Blob[0];
  Cred.CredentialBlobSize := Length(Blob);
  Cred.Persist            := CRED_PERSIST_LOCAL_MACHINE;

  Result := CredWriteW(@Cred, 0);
end;

function CredLoad(const ProfileName: string): string;
var
  Target: WideString;
  pCred:  PCREDENTIALW;
  Blob:   TBytes;
begin
  Result := '';
  Target := CRED_PREFIX + ProfileName;
  if CredReadW(PWideChar(Target), CRED_TYPE_GENERIC, 0, pCred) then
  try
    SetLength(Blob, pCred^.CredentialBlobSize);
    if pCred^.CredentialBlobSize > 0 then
      Move(pCred^.CredentialBlob^, Blob[0], pCred^.CredentialBlobSize);
    Result := TEncoding.UTF8.GetString(Blob);
  finally
    CredFree(pCred);
  end;
end;

procedure CredDelete(const ProfileName: string);
var
  Target: WideString;
begin
  Target := CRED_PREFIX + ProfileName;
  CredDeleteW(PWideChar(Target), CRED_TYPE_GENERIC, 0);
end;

function CredMigrateFrom(const OldPrefix: string;
  const ProfileNames: TArray<string>): Integer;
var
  OldTarget, NewTarget: WideString;
  pCred: PCREDENTIALW;
  Blob:  TBytes;
  Cred:  _CREDENTIALW;
  Secret: string;
begin
  Result := 0;
  for var Name in ProfileNames do
  begin
    OldTarget := OldPrefix + Name;
    if not CredReadW(PWideChar(OldTarget), CRED_TYPE_GENERIC, 0, pCred) then
      Continue;
    try
      SetLength(Blob, pCred^.CredentialBlobSize);
      if pCred^.CredentialBlobSize > 0 then
        Move(pCred^.CredentialBlob^, Blob[0], pCred^.CredentialBlobSize);
      Secret := TEncoding.UTF8.GetString(Blob);
    finally
      CredFree(pCred);
    end;
    if Secret = '' then Continue;
    // Save under new prefix
    NewTarget := CRED_PREFIX + Name;
    ZeroMemory(@Cred, SizeOf(Cred));
    Cred.Type_              := CRED_TYPE_GENERIC;
    Cred.TargetName         := PWideChar(NewTarget);
    Cred.CredentialBlob     := @Blob[0];
    Cred.CredentialBlobSize := Length(Blob);
    Cred.Persist            := CRED_PERSIST_LOCAL_MACHINE;
    if CredWriteW(@Cred, 0) then
    begin
      CredDeleteW(PWideChar(OldTarget), CRED_TYPE_GENERIC, 0);
      Inc(Result);
    end;
  end;
end;

end.
