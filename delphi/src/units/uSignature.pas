unit uSignature;
{
  Trust checks for elevated sessions.

  IsNexonSignedClient: the elevated launch shows a UAC prompt naming Rua, not
  the program Rua then starts, so an elevated launch only runs a Client.exe
  whose Authenticode signature is valid and issued to NEXON (Organization
  "NEXON Korea Corporation" on current builds).

  RestrictDllSearchForElevation: an elevated Rua loads system DLLs only from
  System32 and its own DLLs only from its application folder, never from the
  current directory or PATH.

  WinTrust/Crypt32 are delay-loaded so the elevated process resolves them after
  the restricted search order is in place.
}

interface

uses
  Winapi.Windows;

// FileHandle: an open handle to Path (0 = let WinTrust open it by name).
function IsNexonSignedClient(const Path: string; FileHandle: THandle; out Reason: string): Boolean;
procedure RestrictDllSearchForElevation;

implementation

uses
  System.SysUtils;

const
  WINTRUST_ACTION_GENERIC_VERIFY_V2: TGUID = '{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}';
  WTD_UI_NONE              = 2;
  WTD_REVOKE_WHOLECHAIN    = 1;
  WTD_CHOICE_FILE          = 1;
  WTD_STATEACTION_VERIFY   = 1;
  WTD_STATEACTION_CLOSE    = 2;
  CERT_NAME_ATTR_TYPE      = 3;
  OID_ORGANIZATION_NAME: AnsiString = '2.5.4.10';
  LOAD_LIBRARY_SEARCH_APPLICATION_DIR = $00000200;
  LOAD_LIBRARY_SEARCH_SYSTEM32        = $00000800;

type
  TWinTrustFileInfo = record
    cbStruct:       DWORD;
    pcwszFilePath:  PWideChar;
    hFile:          THandle;
    pgKnownSubject: PGUID;
  end;

  TWinTrustData = record
    cbStruct:            DWORD;
    pPolicyCallbackData: Pointer;
    pSIPClientData:      Pointer;
    dwUIChoice:          DWORD;
    fdwRevocationChecks: DWORD;
    dwUnionChoice:       DWORD;
    pFile:               ^TWinTrustFileInfo;
    dwStateAction:       DWORD;
    hWVTStateData:       THandle;
    pwszURLReference:    PWideChar;
    dwProvFlags:         DWORD;
    dwUIContext:         DWORD;
    pSignatureSettings:  Pointer;
  end;

  // Leading fields of CRYPT_PROVIDER_CERT; only pCert is read.
  TCryptProviderCert = record
    cbStruct: DWORD;
    pCert:    Pointer;
  end;
  PCryptProviderCert = ^TCryptProviderCert;

function WinVerifyTrust(hwnd: HWND; pgActionID: PGUID; pWVTData: Pointer): Longint; stdcall;
  external 'wintrust.dll' name 'WinVerifyTrust' delayed;
function WTHelperProvDataFromStateData(hStateData: THandle): Pointer; stdcall;
  external 'wintrust.dll' name 'WTHelperProvDataFromStateData' delayed;
function WTHelperGetProvSignerFromChain(pProvData: Pointer; idxSigner: DWORD;
  fCounterSigner: BOOL; idxCounterSigner: DWORD): Pointer; stdcall;
  external 'wintrust.dll' name 'WTHelperGetProvSignerFromChain' delayed;
function WTHelperGetProvCertFromChain(pSgnr: Pointer; idxCert: DWORD): PCryptProviderCert; stdcall;
  external 'wintrust.dll' name 'WTHelperGetProvCertFromChain' delayed;
function CertGetNameStringW(pCertContext: Pointer; dwType, dwFlags: DWORD;
  pvTypePara: Pointer; pszNameString: PWideChar; cchNameString: DWORD): DWORD; stdcall;
  external 'crypt32.dll' name 'CertGetNameStringW' delayed;
function SetDefaultDllDirectories(DirectoryFlags: DWORD): BOOL; stdcall;
  external kernel32 name 'SetDefaultDllDirectories';

procedure RestrictDllSearchForElevation;
begin
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR or LOAD_LIBRARY_SEARCH_SYSTEM32);
end;

function IsNexonSignedClient(const Path: string; FileHandle: THandle; out Reason: string): Boolean;
var
  FileInfo: TWinTrustFileInfo;
  Data:     TWinTrustData;
  Action:   TGUID;
  Status:   Longint;
  Signer:   Pointer;
  Cert:     PCryptProviderCert;
  Org:      array[0..255] of WideChar;
begin
  Result := False;
  Reason := '';
  if not SameText(ExtractFileName(Path), 'Client.exe') then
  begin
    Reason := 'only Mabinogi Client.exe can be launched';
    Exit;
  end;

  FillChar(FileInfo, SizeOf(FileInfo), 0);
  FileInfo.cbStruct      := SizeOf(FileInfo);
  FileInfo.pcwszFilePath := PWideChar(Path);
  // Verify through the caller's open handle, which denies writes, so the file
  // that was checked is the file that runs.
  FileInfo.hFile         := FileHandle;
  FillChar(Data, SizeOf(Data), 0);
  Data.cbStruct            := SizeOf(Data);
  Data.dwUIChoice          := WTD_UI_NONE;
  Data.fdwRevocationChecks := WTD_REVOKE_WHOLECHAIN;
  Data.dwUnionChoice       := WTD_CHOICE_FILE;
  Data.pFile               := @FileInfo;
  Data.dwStateAction       := WTD_STATEACTION_VERIFY;
  Action := WINTRUST_ACTION_GENERIC_VERIFY_V2;

  Status := WinVerifyTrust(INVALID_HANDLE_VALUE, @Action, @Data);
  try
    if Status <> 0 then
    begin
      Reason := Format('Client.exe does not have a valid signature (0x%.8x)', [Cardinal(Status)]);
      Exit;
    end;
    Signer := WTHelperGetProvSignerFromChain(WTHelperProvDataFromStateData(Data.hWVTStateData), 0, False, 0);
    Cert := nil;
    if Signer <> nil then Cert := WTHelperGetProvCertFromChain(Signer, 0);
    if (Cert = nil) or (Cert.pCert = nil) then
    begin
      Reason := 'Client.exe signer could not be read';
      Exit;
    end;
    FillChar(Org, SizeOf(Org), 0);
    CertGetNameStringW(Cert.pCert, CERT_NAME_ATTR_TYPE, 0, PAnsiChar(OID_ORGANIZATION_NAME), @Org[0], Length(Org));
    if not string(PWideChar(@Org[0])).StartsWith('NEXON ', True) then
    begin
      Reason := 'Client.exe is signed by "' + string(PWideChar(@Org[0])) + '", not NEXON';
      Exit;
    end;
    Result := True;
  finally
    Data.dwStateAction := WTD_STATEACTION_CLOSE;
    WinVerifyTrust(INVALID_HANDLE_VALUE, @Action, @Data);
  end;
end;

end.
