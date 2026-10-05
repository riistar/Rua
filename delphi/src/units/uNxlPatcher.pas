unit uNxlPatcher;
(*
  NxLauncher manifest-based patcher for Mabinogi NA (product 10200).

  Flow:
    1. GET https://download2.nexon.net/Game/nxl/games/10200/<hash>
       -> zlib-decompress -> JSON manifest; SHA1(decompressed) must equal <hash>
    2. Parse manifest: files[base64_name] = (fsize, mtime, objects, objects_fsize)
       Every path is validated as a plain relative path; every object id must be
       a 40-hex SHA1. Any invalid entry stops the update before files change.
    3. Diff against local files (size + mtime)
    4. For each outdated/missing file:
         for each part: GET https://.../10200/10200/<xx>/<partname> -> zlib-decompress
         SHA1(decompressed part) must equal <partname>; the assembled size must
         equal fsize. The verified file replaces the old one in a single move.

  Verified against Nexon's live CDN (2026-10-05): object ids are the SHA1 of the
  decompressed part. objects_fsize is NOT reliable (some entries, Client.exe
  included, list compressed sizes), so it is never used for verification.

  Layout: InstallRoot holds patchdata\ (version marker). Game files live in
  InstallRoot\appdata\ for Nexon Launcher installs, or directly in InstallRoot
  for installs that keep Client.exe beside patchdata\.
*)

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  System.NetEncoding, System.Net.HttpClient, System.ZLib,
  System.DateUtils, System.Threading, System.SyncObjs,
  System.Generics.Collections, System.Hash, System.Math, uIgnoreList;

type
  TPatchLog      = reference to procedure(const Msg: string);
  // Current, Total = file index (1-based) and total patch count; FileName = relative path
  TPatchProgress = reference to procedure(Current, Total: Integer; const FileName: string);

  // One file the scan found needing an update (shown to the user for selection).
  TPatchItem = record
    Path:      string;  // relative to the game file root
    Size:      Int64;   // manifest (new) size
    LocalSize: Int64;   // current size on disk, -1 = missing
    Reason:    string;  // 'New', 'Size changed', 'Content changed', 'Re-download'
  end;

  // Called (on the patcher thread) after the scan when files need updating.
  // Return False to skip the update entirely; otherwise Selected = paths to patch.
  TPatchSelect = reference to function(const Items: TArray<TPatchItem>;
    out Selected: TArray<string>): Boolean;

  // Raised when the update cannot be performed securely. The installed game is
  // left as it was for every file not yet replaced by a verified copy, and the
  // version marker is never advanced.
  EPatchSecurityError = class(Exception);

// ManifestHash  : hash string returned by FetchManifestHash (40 hex SHA1)
// InstallRoot   : folder containing patchdata\ (e.g. C:\Nexon\Library\mabinogi)
// ProductId     : 10200 -- used to name the local hash file
// Log           : text log callback (called from patcher thread)
// Progress      : optional progress callback (called from patcher thread)
// OldManifestJSON : cached manifest from previous update (for objects[] diff)
// ForceAll      : if True, skip all checks and re-download everything
// ScanOnly=True: download manifest and scan, but do NOT download files.
// NeedCount receives the number of files that would need updating (nil = ignore).
// IgnorePatterns: relative paths/wildcards (see uIgnoreList) always excluded --
// applies before ForceAll/verify, so ignored files are never touched by any mode.
// SelectFiles   : optional; lets the caller pick which of the needed files to patch.
// A partial selection leaves the stored manifest hash untouched, so the skipped
// files are offered again on the next check.
// Raises EPatchSecurityError (or another exception) when anything fails; the
// stored manifest hash is only written after every selected file verified.
procedure RunPatcher(const ManifestHash, InstallRoot: string;
  ProductId: Integer; const Log: TPatchLog;
  const Progress: TPatchProgress = nil;
  const OldManifestJSON: string = ''; ForceAll: Boolean = False;
  const ShouldCancel: TFunc<Boolean> = nil;
  PauseEvent: TEvent = nil;
  ScanOnly: Boolean = False;
  NeedCount: PInteger = nil;
  const IgnorePatterns: TArray<string> = nil;
  const SelectFiles: TPatchSelect = nil);
function LoadCachedManifest(const Path: string): string;

// Exposed for SecurityTests.
function IsSha1Hex(const S: string): Boolean;
function SafeManifestPath(const Raw: string): string; // raises EPatchSecurityError
function ResolvePatchFileRoot(const InstallRoot: string): string;
function ContainedTarget(const FileRoot, RelPath: string): string; // raises EPatchSecurityError
function BoundedZlibDecomp(const Src: TBytes; MaxBytes: Int64): TBytes;
function Sha1Hex(const Data: TBytes): string;

implementation

uses
  Winapi.Windows;

const
  CDN_BASE      = 'https://download2.nexon.net/Game/nxl/games/10200/';
  MANIFEST_BASE = CDN_BASE;
  DOWNLOAD_BASE = CDN_BASE + '10200/';
  // Global cap on simultaneous HTTP requests (manifest + all file parts across
  // all files being patched). Previously unbounded per-file part fan-out
  // combined with MAX_DL concurrent files could open 100+ connections at once,
  // which self-throttles against the CDN. This also backs a reusable
  // THTTPClient pool so parts reuse keep-alive connections instead of paying
  // a fresh TCP+TLS handshake per part.
  MAX_CONCURRENT_HTTP = 16;
  // Bounds well above live data (manifest 0.2 MB packed / 1.1 MB plain, parts
  // at most 4 MiB, largest file 165 MB) that stop hostile or corrupt input from
  // exhausting memory or disk.
  MAX_MANIFEST_DOWNLOAD = 64 * 1024 * 1024;
  MAX_MANIFEST_PLAIN    = 256 * 1024 * 1024;
  MAX_PART_BYTES        = 64 * 1024 * 1024;
  MAX_FILE_BYTES        = Int64(8) * 1024 * 1024 * 1024;
  MAX_MANIFEST_ENTRIES  = 200000;
  MAX_PARTS_PER_FILE    = 4096;
  MAX_RELATIVE_PATH     = 200;

var
  GHttpPool:     TList<THTTPClient>;
  GHttpPoolLock: TCriticalSection;
  GHttpSem:      TSemaphore;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function CheckoutHttpClient: THTTPClient;
begin
  GHttpSem.Acquire;
  GHttpPoolLock.Enter;
  try
    if GHttpPool.Count > 0 then
    begin
      Result := GHttpPool[GHttpPool.Count - 1];
      GHttpPool.Delete(GHttpPool.Count - 1);
    end
    else
    begin
      Result := THTTPClient.Create;
      // Authenticated TLS only: the system validates the certificate chain and
      // host name. The CDN answers directly, so any redirect is refused.
      Result.SecureProtocols := [THTTPSecureProtocol.TLS12, THTTPSecureProtocol.TLS13];
      Result.HandleRedirects := False;
    end;
  finally
    GHttpPoolLock.Leave;
  end;
end;

procedure CheckinHttpClient(Http: THTTPClient);
begin
  Http.ReceiveDataCallback := nil;
  GHttpPoolLock.Enter;
  try
    GHttpPool.Add(Http);
  finally
    GHttpPoolLock.Leave;
  end;
  GHttpSem.Release;
end;

function HttpGetBytes(const URL: string; MaxBytes: Int64): TBytes;
var
  Http:     THTTPClient;
  Resp:     IHTTPResponse;
  MS:       TMemoryStream;
  TooLarge: Boolean;
begin
  if not URL.StartsWith('https://', True) then
    raise EPatchSecurityError.Create('Refusing an unencrypted download: ' + URL);
  TooLarge := False;
  Http := CheckoutHttpClient;
  MS   := TMemoryStream.Create;
  try
    Http.CookieManager := nil;
    Http.CustomHeaders['User-Agent'] := 'NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0';
    Http.ReceiveDataCallback :=
      procedure(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean)
      begin
        if (AContentLength > MaxBytes) or (AReadCount > MaxBytes) then
        begin
          TooLarge := True;
          AAbort   := True;
        end;
      end;
    Resp := Http.Get(URL, MS);
    if TooLarge or (MS.Size > MaxBytes) then
      raise EPatchSecurityError.CreateFmt('Download exceeded its %d-byte limit: %s', [MaxBytes, URL]);
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt('HTTP %d: %s', [Resp.StatusCode, URL]);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(Result[0], MS.Size);
    end;
  finally
    MS.Free;
    CheckinHttpClient(Http);
  end;
end;

function BoundedZlibDecomp(const Src: TBytes; MaxBytes: Int64): TBytes;
var
  InS:  TBytesStream;
  OutS: TMemoryStream;
  DS:   TDecompressionStream;
  Buf:  array[0..65535] of Byte;
  N:    Integer;
begin
  InS  := TBytesStream.Create(Src);
  OutS := TMemoryStream.Create;
  try
    DS := TDecompressionStream.Create(InS); // default wbits=15 = zlib format
    try
      repeat
        N := DS.Read(Buf, SizeOf(Buf));
        if N > 0 then
        begin
          if OutS.Size + N > MaxBytes then
            raise EPatchSecurityError.CreateFmt('Decompressed data exceeded its %d-byte limit', [MaxBytes]);
          OutS.WriteBuffer(Buf, N);
        end;
      until N = 0;
    finally
      DS.Free;
    end;
    SetLength(Result, OutS.Size);
    if OutS.Size > 0 then
    begin
      OutS.Position := 0;
      OutS.ReadBuffer(Result[0], OutS.Size);
    end;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

function Sha1Hex(const Data: TBytes): string;
var
  H: THashSHA1;
begin
  H := THashSHA1.Create;
  if Length(Data) > 0 then
    H.Update(Data[0], Length(Data));
  Result := H.HashAsString.ToLower;
end;

function IsSha1Hex(const S: string): Boolean;
begin
  Result := Length(S) = 40;
  if Result then
    for var C in S do
      if not CharInSet(C, ['0'..'9', 'a'..'f']) then
        Exit(False);
end;

function GetLocalFileSize(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    System.SysUtils.FindClose(SR);
  end;
end;

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// Accepts only a plain relative path below the game folder. Rejects rooted,
// drive-qualified, UNC and device paths, '.'/'..' segments, alternate data
// streams, reserved device names and characters Windows would reinterpret.
function SafeManifestPath(const Raw: string): string;

  procedure Reject(const Why: string);
  begin
    raise EPatchSecurityError.CreateFmt('Unsafe path in game manifest (%s): "%s"', [Why, Raw]);
  end;

const
  RESERVED: array[0..23] of string = ('CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');
var
  P, Base: string;
begin
  P := StringReplace(Raw, '/', '\', [rfReplaceAll]);
  if P = '' then Reject('empty');
  if Length(P) > MAX_RELATIVE_PATH then Reject('too long');
  if P[1] = '\' then Reject('rooted');
  if Pos(':', P) > 0 then Reject('drive or stream');
  for var C in P do
    if (Ord(C) < 32) or CharInSet(C, ['<', '>', '"', '|', '?', '*']) then
      Reject('invalid character');
  for var Segment in P.Split(['\']) do
  begin
    if (Segment = '') or (Segment = '.') or (Segment = '..') then Reject('relative segment');
    if CharInSet(Segment[Length(Segment)], ['.', ' ']) then Reject('trailing dot or space');
    Base := Segment;
    if Pos('.', Base) > 0 then Base := Copy(Base, 1, Pos('.', Base) - 1);
    Base := UpperCase(Base.TrimRight);
    for var R in RESERVED do
      if Base = R then Reject('reserved name');
  end;
  Result := P;
end;

// Nexon Launcher installs keep patchdata\ beside appdata\, which holds the game.
// Older/other layouts keep Client.exe directly beside patchdata\.
function ResolvePatchFileRoot(const InstallRoot: string): string;
var
  AppData: string;
begin
  AppData := TPath.Combine(InstallRoot, 'appdata');
  if TDirectory.Exists(AppData) and not TFile.Exists(TPath.Combine(InstallRoot, 'Client.exe')) then
    Result := AppData
  else
    Result := InstallRoot;
end;

// Full target path for a validated relative path. Refuses anything resolving
// outside FileRoot and any existing junction/symlink between FileRoot and the
// target, so a planted link cannot redirect game writes elsewhere.
function ContainedTarget(const FileRoot, RelPath: string): string;
var
  RootFull, Cur: string;
  Attr: DWORD;
begin
  RootFull := IncludeTrailingPathDelimiter(TPath.GetFullPath(FileRoot));
  Result   := TPath.GetFullPath(TPath.Combine(RootFull, SafeManifestPath(RelPath)));
  if not Result.StartsWith(RootFull, True) or (Length(Result) <= Length(RootFull)) then
    raise EPatchSecurityError.CreateFmt('Manifest path escapes the game folder: "%s"', [RelPath]);
  Cur := ExcludeTrailingPathDelimiter(RootFull);
  for var Segment in Copy(Result, Length(RootFull) + 1, MaxInt).Split(['\']) do
  begin
    Cur  := Cur + '\' + Segment;
    Attr := GetFileAttributes(PChar(Cur));
    if Attr = INVALID_FILE_ATTRIBUTES then Break; // not created yet; nothing below exists
    if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      raise EPatchSecurityError.CreateFmt('Game folder contains a link at "%s". Remove it before updating.', [Cur]);
  end;
end;

// ---------------------------------------------------------------------------
// Filename decoding
// Manifest stores base64 of UTF-16LE text (with BOM) naming the relative path.
// ---------------------------------------------------------------------------

function DecodeFilename(const B64: string): string;
var
  UniBytes: TBytes;
begin
  UniBytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
  if Odd(Length(UniBytes)) then
    raise EPatchSecurityError.Create('Malformed manifest file name');
  Result := TEncoding.Unicode.GetString(UniBytes);
  if (Result <> '') and (Result[1] = #$FEFF) then
    Delete(Result, 1, 1);
  // Strip trailing null bytes and control chars -- manifest entries can embed
  // extra nulls that make identical paths compare unequal as strings.
  Result := Result.TrimRight([#0, #1, #2, #3, #4, #5, #6, #7, #8, #9,
                               #10, #11, #12, #13, #14, #15, #16, #17,
                               #18, #19, #20, #21, #22, #23, #24, #25,
                               #26, #27, #28, #29, #30, #31, ' ']);
end;

// ---------------------------------------------------------------------------
// Manifest structures and parsing
// ---------------------------------------------------------------------------

type
  TFilePart = record
    Name: string;   // SHA1 of the decompressed part
  end;

  TFileEntry = record
    Path:    string;       // validated, relative, e.g. 'package\data_00906.it'
    FSize:   Int64;
    MTime:   TDateTime;    // UTC
    Parts:   TArray<TFilePart>;
    IsDir:   Boolean;
    ObjHash: string;       // SHA1 of concatenated objects[] (content fingerprint)
  end;

// Strict=True (a freshly downloaded manifest): any malformed entry raises, so an
// update never proceeds on a partially understood manifest. Strict=False (the
// locally cached previous manifest, used only for change detection): malformed
// entries are skipped.
// Parses one manifest entry; raises EPatchSecurityError (or a JSON/conversion
// exception) when anything is missing or out of bounds.
function ParseEntry(const Pair: TJSONPair): TFileEntry;
var
  FObj: TJSONObject;
  Objs: TJSONArray;
  I:    Integer;
begin
  Result := Default(TFileEntry);
  Result.Path := SafeManifestPath(DecodeFilename(Pair.JsonString.Value));

  if not (Pair.JsonValue is TJSONObject) then
    raise EPatchSecurityError.Create('Malformed manifest entry: ' + Result.Path);
  FObj := TJSONObject(Pair.JsonValue);

  if not (FObj.GetValue('objects') is TJSONArray) then
    raise EPatchSecurityError.Create('Manifest entry has no objects: ' + Result.Path);
  Objs := TJSONArray(FObj.GetValue('objects'));
  if (Objs.Count = 0) or (Objs.Count > MAX_PARTS_PER_FILE) then
    raise EPatchSecurityError.Create('Manifest entry has an invalid part count: ' + Result.Path);

  if Objs.Items[0].Value = '__DIR__' then
  begin
    Result.IsDir := True;
    Exit;
  end;

  if not (FObj.GetValue('fsize') is TJSONNumber) then
    raise EPatchSecurityError.Create('Manifest entry has no size: ' + Result.Path);
  Result.FSize := TJSONNumber(FObj.GetValue('fsize')).AsInt64;
  if (Result.FSize < 0) or (Result.FSize > MAX_FILE_BYTES) then
    raise EPatchSecurityError.Create('Manifest entry has an invalid size: ' + Result.Path);

  if FObj.GetValue('mtime') is TJSONNumber then
    Result.MTime := UnixToDateTime(TJSONNumber(FObj.GetValue('mtime')).AsInt64, True);

  SetLength(Result.Parts, Objs.Count);
  for I := 0 to Objs.Count - 1 do
  begin
    Result.Parts[I].Name := Objs.Items[I].Value;
    if not IsSha1Hex(Result.Parts[I].Name) then
      raise EPatchSecurityError.Create('Manifest entry has an invalid part id: ' + Result.Path);
  end;

  var H := THashSHA1.Create;
  for var J := 0 to High(Result.Parts) do
    H.Update(TEncoding.UTF8.GetBytes(Result.Parts[J].Name));
  Result.ObjHash := H.HashAsString;
end;

function ParseManifest(const JSON: string; Strict: Boolean): TArray<TFileEntry>;
var
  RootValue: TJSONValue;
  Files: TJSONObject;
  Pair:  TJSONPair;
  E:     TFileEntry;
  Ok:    Boolean;
  Count: Integer;
begin
  SetLength(Result, 0);
  RootValue := TJSONObject.ParseJSONValue(JSON);
  try
    if not (RootValue is TJSONObject) then
    begin
      if Strict then raise EPatchSecurityError.Create('Game manifest is not valid JSON');
      Exit;
    end;
    if not (TJSONObject(RootValue).GetValue('files') is TJSONObject) then
    begin
      if Strict then raise EPatchSecurityError.Create('Game manifest has no file list');
      Exit;
    end;
    Files := TJSONObject(RootValue).GetValue('files') as TJSONObject;
    if Files.Count > MAX_MANIFEST_ENTRIES then
      raise EPatchSecurityError.Create('Game manifest has too many entries');

    Count := 0;
    SetLength(Result, Files.Count);

    for Pair in Files do
    begin
      Ok := False;
      try
        E  := ParseEntry(Pair);
        Ok := True;
      except
        on Ex: EPatchSecurityError do
          if Strict then raise;
        on Ex: Exception do
          if Strict then
            raise EPatchSecurityError.Create('Malformed game manifest: ' + Ex.Message);
      end;
      if Ok then
      begin
        Result[Count] := E;
        Inc(Count);
      end;
    end;
    SetLength(Result, Count);
  finally
    RootValue.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Patch decision
// ---------------------------------------------------------------------------

// Returns '' when the file is up to date, else a short reason ('New', 'Size changed').
// LocalSize receives the on-disk size (-1 = missing).
function NeedsPatch(const E: TFileEntry; const FileRoot: string; const Log: TPatchLog;
  out LocalSize: Int64): string;
var
  FullPath: string;
begin
  Result    := '';
  LocalSize := -1;
  if E.IsDir then Exit;
  FullPath := TPath.Combine(FileRoot, E.Path);
  if not TFile.Exists(FullPath) then begin Log('  missing: ' + E.Path); Exit('New'); end;
  LocalSize := GetLocalFileSize(FullPath);

  // GATE: size-only change detection. Mabinogi's manifest `fsize` is the
  // authoritative "does this file need updating" signal for the routine check;
  // the cached-manifest diff in RunPatcher catches same-size content changes.
  if LocalSize <> E.FSize then
  begin
    Log('  size mismatch: ' + E.Path);
    Exit('Size changed');
  end;
  Log('  size OK: ' + E.Path);
end;

// ---------------------------------------------------------------------------
// Download + apply one file (parts fetched in parallel)
// ---------------------------------------------------------------------------

procedure ReplaceWithVerified(const TempPath, FinalPath: string);
const
  FLAGS = MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH;
var
  Attr: DWORD;
begin
  if MoveFileEx(PChar(TempPath), PChar(FinalPath), FLAGS) then Exit;
  // Some shipped files are read-only; clear only that attribute and retry once.
  Attr := GetFileAttributes(PChar(FinalPath));
  if (Attr <> INVALID_FILE_ATTRIBUTES) and ((Attr and FILE_ATTRIBUTE_READONLY) <> 0) then
  begin
    SetFileAttributes(PChar(FinalPath), Attr and not FILE_ATTRIBUTE_READONLY);
    if MoveFileEx(PChar(TempPath), PChar(FinalPath), FLAGS) then Exit;
  end;
  RaiseLastOSError;
end;

procedure PatchFile(const E: TFileEntry; const FileRoot: string; const Log: TPatchLog);
const
  MAX_PARTS = 4;   // bound per-file part concurrency (total ≈ MAX_DL × MAX_PARTS)
var
  FinalPath, TempPath, Dir: string;
  Tasks:     TArray<ITask>;
  FS:        TFileStream;
  I:         Integer;
  PartSem:   TSemaphore;
  Total:     Int64;

  type
    TPartResult = record
      Decompressed: TBytes;
    end;
  var PartResults: TArray<TPartResult>;

  // Fetch + decompress + verify a single part, throttled by PartSem.
  // Idx/PartName by value → each task gets its own captures.
  procedure FetchPart(Idx: Integer; const PartName: string);
  begin
    Tasks[Idx] := TTask.Run(procedure
    var
      URL:      string;
      RawBytes: TBytes;
      Plain:    TBytes;
    begin
      PartSem.Acquire;
      try
        URL := DOWNLOAD_BASE + Copy(PartName, 1, 2) + '/' + PartName;
        RawBytes := HttpGetBytes(URL, MAX_PART_BYTES);
        Plain := BoundedZlibDecomp(RawBytes, MAX_PART_BYTES);
        if Sha1Hex(Plain) <> PartName then
          raise EPatchSecurityError.CreateFmt('Downloaded data failed verification (part %s)', [PartName]);
        PartResults[Idx].Decompressed := Plain;
      finally
        PartSem.Release;
      end;
    end);
  end;

begin
  FinalPath := ContainedTarget(FileRoot, E.Path);
  Dir       := TPath.GetDirectoryName(FinalPath);
  TDirectory.CreateDirectory(Dir);
  // Re-check after creating parents: a link must not have appeared meanwhile.
  FinalPath := ContainedTarget(FileRoot, E.Path);
  TempPath  := TPath.Combine(Dir, '.' + TPath.GetFileName(FinalPath) + '.' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '') + '.nxlpatch');
  Log('  -> ' + FinalPath);

  SetLength(PartResults, Length(E.Parts));
  SetLength(Tasks,       Length(E.Parts));
  PartSem := TSemaphore.Create(nil, MAX_PARTS, MAX_PARTS, '');
  try
    try
      for I := 0 to High(E.Parts) do
        FetchPart(I, E.Parts[I].Name);

      try
        TTask.WaitForAll(Tasks);
      except
        on Ex: EAggregateException do
        begin
          if Ex.Count > 0 then
            raise EPatchSecurityError.Create('Part download failed: ' + Ex.InnerExceptions[0].Message)
          else
            raise;
        end;
      end;

      Total := 0;
      for I := 0 to High(E.Parts) do
        Inc(Total, Length(PartResults[I].Decompressed));
      if Total <> E.FSize then
        raise EPatchSecurityError.CreateFmt('Assembled size %d does not match the manifest (%d): %s',
          [Total, E.FSize, E.Path]);

      FS := TFileStream.Create(TempPath, fmCreate or fmShareExclusive);
      try
        for I := 0 to High(E.Parts) do
          if Length(PartResults[I].Decompressed) > 0 then
            FS.WriteBuffer(PartResults[I].Decompressed[0], Length(PartResults[I].Decompressed));
      finally
        FS.Free;
      end;

      // One move: either the previous file or the verified replacement remains.
      ReplaceWithVerified(TempPath, FinalPath);

      try
        TFile.SetLastWriteTimeUtc(FinalPath, E.MTime);
      except end;
    except
      if TFile.Exists(TempPath) then
        try TFile.Delete(TempPath); except end;
      raise;
    end;
  finally
    PartSem.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

function LoadCachedManifest(const Path: string): string;
var
  Compressed: TBytes;
begin
  Result := '';
  if not TFile.Exists(Path) then Exit;
  try
    Result := TFile.ReadAllText(Path, TEncoding.UTF8);
    if Trim(Result).StartsWith('{') then Exit;
  except end;
  try
    Compressed := TFile.ReadAllBytes(Path);
    Result := TEncoding.UTF8.GetString(BoundedZlibDecomp(Compressed, MAX_MANIFEST_PLAIN));
  except
    Result := '';
  end;
end;

function BuildObjHashDict(const Entries: TArray<TFileEntry>): TDictionary<string, string>;
var
  E: TFileEntry;
begin
  Result := TDictionary<string, string>.Create;
  for E in Entries do
    if not E.IsDir then
      Result.AddOrSetValue(E.Path.ToLower, E.ObjHash);
end;

procedure RecordInstalledVersion(const InstallRoot, ManifestHash, JSON: string;
  ProductId: Integer; const Log: TPatchLog);
begin
  // ManifestHash was validated as 40-hex before any download.
  try
    var HashFile := TPath.Combine(InstallRoot,
      'patchdata\' + IntToStr(ProductId) + '.manifest.hash');
    TDirectory.CreateDirectory(TPath.GetDirectoryName(HashFile));
    TFile.WriteAllText(HashFile, ManifestHash, TEncoding.UTF8);
    Log('Hash file updated.');
  except
    on Ex: Exception do Log('Warning: could not update hash file: ' + Ex.Message);
  end;

  // Cache decompressed manifest for next objects[] diff
  try
    TFile.WriteAllText(TPath.Combine(InstallRoot,
      'patchdata\' + ManifestHash + '.manifest.json'), JSON, TEncoding.UTF8);
    Log('Manifest cached.');
  except
    on Ex: Exception do Log('Warning: could not cache manifest: ' + Ex.Message);
  end;
end;

procedure RunPatcher(const ManifestHash, InstallRoot: string;
  ProductId: Integer; const Log: TPatchLog;
  const Progress: TPatchProgress = nil;
  const OldManifestJSON: string = ''; ForceAll: Boolean = False;
  const ShouldCancel: TFunc<Boolean> = nil;
  PauseEvent: TEvent = nil;
  ScanOnly: Boolean = False;
  NeedCount: PInteger = nil;
  const IgnorePatterns: TArray<string> = nil;
  const SelectFiles: TPatchSelect = nil);
const
  MAX_DL = 8;
var
  Compressed, Plain: TBytes;
  JSON:     string;
  FileRoot: string;
  All:      TArray<TFileEntry>;
  Need:     TArray<TFileEntry>;
  Items:    TArray<TPatchItem>;  // parallel to Need: reason + local size for the UI
  Partial:  Boolean;
  E:        TFileEntry;
  NeedN:    Integer;
  Done:     Integer;
  Failed:   Integer;
  FirstError: string;
  Tasks:    TArray<ITask>;
  Sem:      TSemaphore;
  FileLock: TCriticalSection;
  FileDone: TDictionary<string, Boolean>;

  // E is passed by VALUE -- each call allocates a separate closure copy,
  // avoiding the Delphi loop-closure aliasing bug: inline 'var Entry' inside
  // a for-loop body shares one heap slot across all iterations, so every task
  // would read the last iteration's value by the time it executes.
  procedure SpawnOne(Idx: Integer; E: TFileEntry);
  begin
    Tasks[Idx] := TTask.Run(procedure
    begin
      if Assigned(ShouldCancel) and ShouldCancel() then Exit;
      Sem.Acquire;
      try
        if Assigned(PauseEvent) then PauseEvent.WaitFor(INFINITE);
        if Assigned(ShouldCancel) and ShouldCancel() then Exit;
        var Key:  string;
        var Skip: Boolean;
        Key := E.Path.ToLower;
        FileLock.Enter;
        try
          Skip := FileDone.ContainsKey(Key);
          if not Skip then FileDone.Add(Key, True);
        finally
          FileLock.Leave;
        end;
        if Skip then Exit;
        var Cur := TInterlocked.Increment(Done);
        Log(Format('[%d/%d] %s (%d parts)', [Cur, NeedN, E.Path, Length(E.Parts)]));
        if Assigned(Progress) then Progress(Cur, NeedN, E.Path);
        try
          PatchFile(E, FileRoot, Log);
        except
          on Ex: Exception do
          begin
            Log('  ERROR [' + E.Path + ']: ' + Ex.Message);
            FileLock.Enter;
            try
              Inc(Failed);
              if FirstError = '' then FirstError := E.Path + ': ' + Ex.Message;
            finally
              FileLock.Leave;
            end;
          end;
        end;
      finally
        Sem.Release;
      end;
    end);
  end;

begin
  if not IsSha1Hex(ManifestHash) then
    raise EPatchSecurityError.Create('Nexon returned an invalid game version id. Game updating was stopped; use Nexon Launcher.');
  FileRoot := ResolvePatchFileRoot(InstallRoot);
  Log('Game files: ' + FileRoot);

  Log('Downloading manifest...');
  Compressed := HttpGetBytes(MANIFEST_BASE + ManifestHash, MAX_MANIFEST_DOWNLOAD);
  Log(Format('  compressed: %d B', [Length(Compressed)]));

  Log('Decompressing...');
  Plain := BoundedZlibDecomp(Compressed, MAX_MANIFEST_PLAIN);
  Log(Format('  decompressed: %d B', [Length(Plain)]));
  // The manifest is content-addressed: its id is the SHA1 of these bytes.
  if Sha1Hex(Plain) <> ManifestHash then
    raise EPatchSecurityError.Create('Downloaded game manifest failed verification. No files were changed.');
  Log('  manifest verified');

  Log('Parsing...');
  JSON := TEncoding.UTF8.GetString(Plain);
  All  := ParseManifest(JSON, True);
  if Length(All) = 0 then
    raise EPatchSecurityError.Create('Game manifest lists no files. No files were changed.');
  Log(Format('  %d entries in manifest', [Length(All)]));
  for var Di := 0 to Min(4, High(All)) do
    Log(Format('  sample[%d]: "%s" (fsize=%d, parts=%d)',
      [Di, All[Di].Path, All[Di].FSize, Length(All[Di].Parts)]));

  Log('Scanning local files...');
  var OldDict: TDictionary<string, string> := nil;
  if (OldManifestJSON <> '') and not ForceAll then
  begin
    var OldEntries := ParseManifest(OldManifestJSON, False);
    OldDict := BuildObjHashDict(OldEntries);
    Log(Format('  loaded %d entries from cached manifest', [Length(OldEntries)]));
  end;

  NeedN := 0;
  SetLength(Need, Length(All));
  SetLength(Items, Length(All));
  Partial := False;
  var Seen := TDictionary<string, Boolean>.Create;
  var Candidates: TArray<TFileEntry>;
  var TotalFiles := 0;
  var IgnoredN := 0;
  try
    // First pass: collect unique non-dir entries and create dirs
    for E in All do
    begin
      if E.IsDir then
      begin
        if IsIgnored(E.Path, IgnorePatterns) then Continue;
        var D := ContainedTarget(FileRoot, E.Path);
        if not TDirectory.Exists(D) then TDirectory.CreateDirectory(D);
        Continue;
      end;
      var Key := E.Path.ToLower;
      if Seen.ContainsKey(Key) then Continue;
      Seen.Add(Key, True);
      // Ignore list wins over every mode (normal check, verify/repair,
      // force-all re-download) -- the file is treated as untouchable.
      if IsIgnored(E.Path, IgnorePatterns) then
      begin
        Inc(IgnoredN);
        Continue;
      end;
      Candidates := Candidates + [E];
      Inc(TotalFiles);
    end;
  finally
    Seen.Free;
  end;
  if IgnoredN > 0 then
    Log(Format('  %d file(s) skipped (ignore list)', [IgnoredN]));

  // Parallel verify: process files concurrently with semaphore
  var ScanLock := TCriticalSection.Create;
  var ScanTasks: TArray<ITask>;
  var ScanSem := TSemaphore.Create(nil, MAX_DL, MAX_DL, '');
  var ScanIdx := 0;
  var ScanDone := 0;
  try
    SetLength(ScanTasks, Length(Candidates));
    for var CI := 0 to High(Candidates) do
    begin
      (procedure(const Entry: TFileEntry; const Idx: Integer)
      begin
        ScanTasks[Idx] := TTask.Run(procedure
        begin
          if Assigned(ShouldCancel) and ShouldCancel() then Exit;
          ScanSem.Acquire;
          try
            if Assigned(PauseEvent) then PauseEvent.WaitFor(INFINITE);
            if Assigned(ShouldCancel) and ShouldCancel() then Exit;

            TInterlocked.Increment(ScanIdx);
            var CurScan := ScanIdx;
            if Assigned(Progress) then Progress(CurScan, TotalFiles, 'Scanning: ' + Entry.Path);

            // Disk check first (missing / size), then the cached-manifest diff, which
            // catches same-size content changes between the installed and new version.
            var LocalSize: Int64;
            var Reason := NeedsPatch(Entry, FileRoot, Log, LocalSize);
            if (Reason = '') and (OldDict <> nil) then
            begin
              var OldHash: string;
              if not OldDict.TryGetValue(Entry.Path.ToLower, OldHash) or (OldHash <> Entry.ObjHash) then
                Reason := 'Content changed';
            end;
            if (Reason = '') and ForceAll then
              Reason := 'Re-download';

            if Reason <> '' then
            begin
              ScanLock.Enter;
              try
                Need[NeedN] := Entry;
                Items[NeedN].Path      := Entry.Path;
                Items[NeedN].Size      := Entry.FSize;
                Items[NeedN].LocalSize := LocalSize;
                Items[NeedN].Reason    := Reason;
                Inc(NeedN);
              finally
                ScanLock.Leave;
              end;
            end;

            TInterlocked.Increment(ScanDone);
          finally
            ScanSem.Release;
          end;
        end);
      end)(Candidates[CI], CI);
    end;
    TTask.WaitForAll(ScanTasks);
  finally
    ScanLock.Free;
    ScanSem.Free;
    OldDict.Free; // freed only after every scan task is done with it
  end;

  if Assigned(ShouldCancel) and ShouldCancel() then
  begin
    // Must not fall through to the "up to date" branch below — that would store
    // the new manifest hash and hide the unscanned files from the next check.
    Log('Scan cancelled.');
    if NeedCount <> nil then NeedCount^ := 0;
    Exit;
  end;
  SetLength(Need, NeedN);
  SetLength(Items, NeedN);
  Log(Format('  %d files need updating', [NeedN]));
  if NeedCount <> nil then NeedCount^ := NeedN;

  if NeedN = 0 then
  begin
    // Manifest hash changed (metadata/mtime drift) but no file sizes differ.
    // Update stored hash so future checks don't re-trigger.
    RecordInstalledVersion(InstallRoot, ManifestHash, JSON, ProductId, Log);
    Log('Already up to date.');
    Exit;
  end;

  if ScanOnly then Exit; // scan complete — caller decides whether to download

  // Let the caller pick which files to patch.
  if Assigned(SelectFiles) then
  begin
    var Selected: TArray<string>;
    if not SelectFiles(Items, Selected) then
    begin
      Log('Update skipped by user.');
      Exit;
    end;
    var SelSet := TDictionary<string, Boolean>.Create;
    try
      for var P in Selected do
        SelSet.AddOrSetValue(P.ToLower, True);
      var Kept := 0;
      for var I := 0 to NeedN - 1 do
        if SelSet.ContainsKey(Need[I].Path.ToLower) then
        begin
          Need[Kept] := Need[I];
          Inc(Kept);
        end;
      Partial := Kept < NeedN;
      if Partial then
        Log(Format('  %d of %d files selected', [Kept, NeedN]));
      NeedN := Kept;
      SetLength(Need, NeedN);
    finally
      SelSet.Free;
    end;
    if NeedN = 0 then
    begin
      Log('No files selected — nothing to do.');
      Exit;
    end;
  end;

  Done       := 0;
  Failed     := 0;
  FirstError := '';
  Sem      := TSemaphore.Create(nil, MAX_DL, MAX_DL, '');
  FileLock := TCriticalSection.Create;
  FileDone := TDictionary<string, Boolean>.Create;
  SetLength(Tasks, NeedN);
  try
    for var I := 0 to NeedN - 1 do
      SpawnOne(I, Need[I]);
    TTask.WaitForAll(Tasks);
  finally
    FileDone.Free;
    FileLock.Free;
    Sem.Free;
  end;

  if Assigned(ShouldCancel) and ShouldCancel() then
  begin
    Log('Cancelled — hash not updated, will resume on next check.');
    Exit;
  end;

  // Never mark the version installed after a failed file: the next check must
  // offer the update again instead of reporting a half-patched game as current.
  if Failed > 0 then
    raise EPatchSecurityError.CreateFmt('%d file(s) could not be updated and verified, so the game was not marked as updated. ' +
      'Files already replaced were verified. Retry, or use Nexon Launcher. First error: %s', [Failed, FirstError]);

  if Partial then
  begin
    // Skipped files must be offered again next time — keep the old hash/cache.
    Log('Partial update complete — skipped files will be listed on the next check.');
    Exit;
  end;

  RecordInstalledVersion(InstallRoot, ManifestHash, JSON, ProductId, Log);
  Log('Patch complete.');
end;

initialization
  GHttpPool     := TList<THTTPClient>.Create;
  GHttpPoolLock := TCriticalSection.Create;
  GHttpSem      := TSemaphore.Create(nil, MAX_CONCURRENT_HTTP, MAX_CONCURRENT_HTTP, '');

finalization
  for var C in GHttpPool do
    C.Free;
  GHttpPool.Free;
  GHttpPoolLock.Free;
  GHttpSem.Free;

end.
