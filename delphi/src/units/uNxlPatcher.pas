unit uNxlPatcher;
(*
  NxLauncher manifest-based patcher for Mabinogi NA (product 10200).

  Flow:
    1. GET http://download2.nexon.net/Game/nxl/games/10200/<hash>
       -> zlib-decompress -> JSON manifest
    2. Parse manifest: files[base64_name] = (fsize, mtime, objects, objects_fsize)
    3. Diff against local files (size + mtime)
    4. For each outdated/missing file:
         for each part: GET .../10200/10200/<xx>/<partname> -> zlib-decompress -> bytes
         concatenate parts -> write final file -> set mtime
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

// ManifestHash  : hash string returned by FetchManifestHash
// InstallRoot   : e.g. E:\mabinogi2\  (parent of appdata\ and package\)
// ProductId     : 10200 -- used to name the local hash file
// Log           : text log callback (called from patcher thread)
// Progress      : optional progress callback (called from patcher thread)
// OldManifestJSON : cached manifest from previous update (for objects[] diff)
// ForceAll      : if True, skip all checks and re-download everything
// ScanOnly=True: download manifest and scan, but do NOT download files.
// NeedCount receives the number of files that would need updating (nil = ignore).
// IgnorePatterns: relative paths/wildcards (see uIgnoreList) always excluded --
// applies before ForceAll/verify, so ignored files are never touched by any mode.
procedure RunPatcher(const ManifestHash, InstallRoot: string;
  ProductId: Integer; const Log: TPatchLog;
  const Progress: TPatchProgress = nil;
  const OldManifestJSON: string = ''; ForceAll: Boolean = False;
  const ShouldCancel: TFunc<Boolean> = nil;
  PauseEvent: TEvent = nil;
  ScanOnly: Boolean = False;
  NeedCount: PInteger = nil;
  const IgnorePatterns: TArray<string> = nil);
function LoadCachedManifest(const Path: string): string;

implementation

const
  MANIFEST_BASE = 'http://download2.nexon.net/Game/nxl/games/10200/';
  DOWNLOAD_BASE = 'https://download2.nexon.net/Game/nxl/games/10200/10200/';
  // Global cap on simultaneous HTTP requests (manifest + all file parts across
  // all files being patched). Previously unbounded per-file part fan-out
  // combined with MAX_DL concurrent files could open 100+ connections at once,
  // which self-throttles against the CDN. This also backs a reusable
  // THTTPClient pool so parts reuse keep-alive connections instead of paying
  // a fresh TCP+TLS handshake per part.
  MAX_CONCURRENT_HTTP = 16;

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
      Result := THTTPClient.Create;
  finally
    GHttpPoolLock.Leave;
  end;
end;

procedure CheckinHttpClient(Http: THTTPClient);
begin
  GHttpPoolLock.Enter;
  try
    GHttpPool.Add(Http);
  finally
    GHttpPoolLock.Leave;
  end;
  GHttpSem.Release;
end;

function HttpGetBytes(const URL: string): TBytes;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  MS:   TMemoryStream;
begin
  Http := CheckoutHttpClient;
  MS   := TMemoryStream.Create;
  try
    Http.CookieManager := nil;
    Http.CustomHeaders['User-Agent'] := 'NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0';
    Resp := Http.Get(URL, MS);
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt('HTTP %d: %s', [Resp.StatusCode, URL]);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.Read(Result[0], MS.Size);
    end;
  finally
    MS.Free;
    CheckinHttpClient(Http);
  end;
end;

function ZlibDecomp(const Src: TBytes): TBytes;
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
        if N > 0 then OutS.Write(Buf, N);
      until N = 0;
    finally
      DS.Free;
    end;
    SetLength(Result, OutS.Size);
    if OutS.Size > 0 then
    begin
      OutS.Position := 0;
      OutS.Read(Result[0], OutS.Size);
    end;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

function GetLocalFileSize(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

// ---------------------------------------------------------------------------
// Filename decoding
// Manifest stores base64 of UTF-16LE bytes encoding the UTF-8 path with BOM.
// C# ref:
//   bytes = Convert.FromBase64String(name)      // UTF-16LE bytes
//   utf8  = Encoding.Convert(Unicode, UTF8, bytes)
//   chars = each byte cast to char
//   result = new string(chars).Substring(3)      // skip UTF-8 BOM
// ---------------------------------------------------------------------------

function DecodeFilename(const B64: string): string;
var
  UniBytes, U8: TBytes;
  I: Integer;
begin
  UniBytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
  U8       := TEncoding.UTF8.GetBytes(TEncoding.Unicode.GetString(UniBytes));
  SetLength(Result, Length(U8));
  for I := 0 to High(U8) do
    Result[I + 1] := Char(U8[I]);
  if Length(Result) >= 3 then
    Result := Copy(Result, 4, MaxInt); // skip UTF-8 BOM bytes (EF BB BF -> chars)
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
    Name: string;
    Size: Int64;
  end;

  TFileEntry = record
    Path:    string;       // decoded, relative, e.g. 'appdata\Client.exe'
    FSize:   Int64;
    MTime:   TDateTime;    // UTC
    Parts:   TArray<TFilePart>;
    IsDir:   Boolean;
    ObjHash: string;       // SHA1 of concatenated objects[] (content fingerprint)
  end;

function ParseManifest(const JSON: string): TArray<TFileEntry>;
var
  Root:  TJSONObject;
  Files: TJSONObject;
  Pair:  TJSONPair;
  FObj:  TJSONObject;
  Objs:  TJSONArray;
  OSz:   TJSONArray;
  E:     TFileEntry;
  Count, I: Integer;
  MN:    TJSONNumber;
begin
  SetLength(Result, 0);
  Root := TJSONObject.ParseJSONValue(JSON) as TJSONObject;
  if Root = nil then Exit;
  try
    Files := Root.GetValue('files') as TJSONObject;
    if Files = nil then Exit;

    Count := 0;
    SetLength(Result, Files.Count);

    for Pair in Files do
    begin
      FillChar(E, SizeOf(E), 0);
      try
        E.Path := DecodeFilename(Pair.JsonString.Value);
      except
        Continue; // skip undecodable names
      end;

      FObj := Pair.JsonValue as TJSONObject;
      if FObj = nil then Continue;

      MN := FObj.GetValue('fsize') as TJSONNumber;
      if MN <> nil then E.FSize := Trunc(MN.AsDouble);

      MN := FObj.GetValue('mtime') as TJSONNumber;
      if MN <> nil then
        E.MTime := UnixToDateTime(Trunc(MN.AsDouble), True);

      Objs := FObj.GetValue('objects') as TJSONArray;
      if (Objs = nil) or (Objs.Count = 0) then Continue;

      if Objs.Items[0].Value = '__DIR__' then
      begin
        E.IsDir := True;
        Result[Count] := E;
        Inc(Count);
        Continue;
      end;

      OSz := FObj.GetValue('objects_fsize') as TJSONArray;
      SetLength(E.Parts, Objs.Count);
      for I := 0 to Objs.Count - 1 do
      begin
        E.Parts[I].Name := Objs.Items[I].Value;
        if (OSz <> nil) and (I < OSz.Count) then
        begin
          MN := OSz.Items[I] as TJSONNumber;
          if MN <> nil then E.Parts[I].Size := Trunc(MN.AsDouble);
        end;
      end;

      if not E.IsDir and (Length(E.Parts) > 0) then
      begin
        var H := THashSHA1.Create;
        for var J := 0 to High(E.Parts) do
          H.Update(TEncoding.UTF8.GetBytes(E.Parts[J].Name));
        E.ObjHash := H.HashAsString;
      end;

      Result[Count] := E;
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Root.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Patch decision
// ---------------------------------------------------------------------------

// SHA1-verifies each assembled part of the local file against manifest objects[].
// Assumes objects_fsize = decompressed part sizes (sum = fsize) and
// objects[i] = lowercase hex SHA1 of decompressed part i.
// Returns True = hashes OK (no download needed).
// Falls back to True (skip hash) when part sizes are unavailable for multi-part
// files — we can't determine split points, so size check is the best we can do.
function VerifyFileHash(const E: TFileEntry; const FullPath: string): Boolean;
var
  FS:       TFileStream;
  Buf:      TBytes;
  I:        Integer;
  PartSize: Int64;
  H:        THashSHA1;
begin
  Result := True;
  if Length(E.Parts) = 0 then Exit;

  // Need known sizes for all but the last part to locate split points
  for I := 0 to Length(E.Parts) - 2 do
    if E.Parts[I].Size <= 0 then Exit; // unknown split → skip

  FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    Result := False;
    for I := 0 to High(E.Parts) do
    begin
      if I < High(E.Parts) then
        PartSize := E.Parts[I].Size
      else
        PartSize := FS.Size - FS.Position; // last part: take remainder

      if PartSize <= 0 then begin Result := True; Exit; end;

      SetLength(Buf, PartSize);
      FS.ReadBuffer(Buf[0], PartSize);

      H := THashSHA1.Create;
      H.Update(Buf, Length(Buf));
      if not SameText(H.HashAsString, E.Parts[I].Name) then
        Exit; // mismatch → needs download
    end;
    Result := True;
  finally
    FS.Free;
  end;
end;

// Verify a single file by computing SHA1 of each zlib-compressed part and
// comparing against the manifest objects[] hash. Uses objects_fsize for split
// points. Falls back to size-only check when part sizes are unavailable.
function VerifyFileByHash(const E: TFileEntry; const FullPath: string; const Log: TPatchLog): Boolean;
var
  FS:       TFileStream;
  Buf:      TBytes;
  CompBuf:  TBytes;
  I, PartLen: Integer;
  H:        THashSHA1;
  Hex:      string;
begin
  Result := False; // start as "needs patch"
  if Length(E.Parts) = 0 then Exit;

  // Need known compressed sizes for multi-part split
  for I := 0 to Length(E.Parts) - 2 do
    if E.Parts[I].Size <= 0 then Exit; // unknown split → skip, fall back to size

  FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyWrite);
  try
    for I := 0 to High(E.Parts) do
    begin
      if I < High(E.Parts) then
        PartLen := E.Parts[I].Size
      else
        PartLen := FS.Size - FS.Position; // last part: remainder

      if PartLen <= 0 then Exit;

      // Read raw bytes for this part
      SetLength(Buf, PartLen);
      FS.ReadBuffer(Buf[0], PartLen);

      // Compress with zlib (deflate, default level)
      var InS := TBytesStream.Create(Buf);
      var OutS := TMemoryStream.Create;
      try
        var CS := TCompressionStream.Create(clDefault, OutS);
        try
          CS.CopyFrom(InS, 0);
        finally
          CS.Free;
        end;
        SetLength(CompBuf, OutS.Size);
        if OutS.Size > 0 then
        begin
          OutS.Position := 0;
          OutS.Read(CompBuf[0], OutS.Size);
        end;
      finally
        InS.Free;
        OutS.Free;
      end;

      // SHA1 of compressed bytes
      H := THashSHA1.Create;
      H.Update(CompBuf, Length(CompBuf));
      Hex := H.HashAsString;

      if not SameText(Hex, E.Parts[I].Name) then
      begin
        Log('  hash MISMATCH part ' + IntToStr(I) + ': ' + E.Path);
        Exit(False);
      end;
    end;
    Result := True; // all parts verified
  finally
    FS.Free;
  end;
end;

function NeedsPatch(const E: TFileEntry; const InstRoot: string; const Log: TPatchLog): Boolean;
var
  FullPath: string;
begin
  Result := False;
  if E.IsDir then Exit;
  FullPath := TPath.Combine(InstRoot, E.Path);
  if not TFile.Exists(FullPath) then begin Log('  missing: ' + E.Path); Exit(True); end;

  // GATE: size-only change detection. Re-compressing every part to SHA1-verify
  // (VerifyFileByHash) hammers CPU/disk on every scan — Mabinogi's manifest
  // `fsize` is the authoritative "does this file need updating" signal.
  // Recompress-verify is only worth it for a targeted Verify/Repair, not the
  // routine startup check. If sizes match, consider the file up to date.
  if GetLocalFileSize(FullPath) <> E.FSize then
  begin
    Log('  size mismatch: ' + E.Path);
    Exit(True);
  end;
  Log('  size OK: ' + E.Path);
end;

// ---------------------------------------------------------------------------
// Download + apply one file (parts fetched in parallel)
// ---------------------------------------------------------------------------

procedure PatchFile(const E: TFileEntry; const InstRoot: string; const Log: TPatchLog);
const
  MAX_PARTS = 4;   // bound per-file part concurrency (total ≈ MAX_DL × MAX_PARTS)
var
  FinalPath, TempPath, Dir: string;
  Tasks:     TArray<ITask>;
  FS:        TFileStream;
  I:         Integer;
  PartSem:   TSemaphore;

  type
    TPartResult = record
      Decompressed: TBytes;
    end;
  var PartResults: TArray<TPartResult>;

  // Fetch + decompress a single part, throttled by PartSem. Idx/PartName by
  // value → each task gets its own captures.
  procedure FetchPart(Idx: Integer; const PartName: string);
  begin
    Tasks[Idx] := TTask.Run(procedure
    var
      URL:      string;
      RawBytes: TBytes;
    begin
      PartSem.Acquire;
      try
        URL := DOWNLOAD_BASE + Copy(PartName, 1, 2) + '/' + PartName;
        RawBytes := HttpGetBytes(URL);
        PartResults[Idx].Decompressed := ZlibDecomp(RawBytes);
      finally
        PartSem.Release;
      end;
    end);
  end;

begin
  FinalPath := TPath.Combine(InstRoot, E.Path);
  TempPath  := FinalPath + '.~nxlpatch';
  Dir       := TPath.GetDirectoryName(FinalPath);
  TDirectory.CreateDirectory(Dir);
  Log('  -> ' + FinalPath);

  SetLength(PartResults, Length(E.Parts));
  SetLength(Tasks,       Length(E.Parts));
  PartSem := TSemaphore.Create(nil, MAX_PARTS, MAX_PARTS, '');
  try
    for I := 0 to High(E.Parts) do
      FetchPart(I, E.Parts[I].Name);

    try
      TTask.WaitForAll(Tasks);
    except
      on Ex: EAggregateException do
      begin
        if Ex.Count > 0 then
          raise Exception.Create('Part download failed: ' + Ex.InnerExceptions[0].Message)
        else
          raise;
      end;
    end;

    FS := TFileStream.Create(TempPath, fmCreate);
    try
      for I := 0 to High(E.Parts) do
        if Length(PartResults[I].Decompressed) > 0 then
          FS.Write(PartResults[I].Decompressed[0], Length(PartResults[I].Decompressed));
    finally
      FS.Free;
    end;

    if TFile.Exists(FinalPath) then
      TFile.Delete(FinalPath);
    TFile.Move(TempPath, FinalPath);

    try
      TFile.SetLastWriteTimeUtc(FinalPath, E.MTime);
    except end;
  except
    if TFile.Exists(TempPath) then
      try TFile.Delete(TempPath); except end;
    raise;
  end;
  PartSem.Free;
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
    Result := TEncoding.UTF8.GetString(ZlibDecomp(Compressed));
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
      Result.Add(E.Path.ToLower, E.ObjHash);
end;

procedure RunPatcher(const ManifestHash, InstallRoot: string;
  ProductId: Integer; const Log: TPatchLog;
  const Progress: TPatchProgress = nil;
  const OldManifestJSON: string = ''; ForceAll: Boolean = False;
  const ShouldCancel: TFunc<Boolean> = nil;
  PauseEvent: TEvent = nil;
  ScanOnly: Boolean = False;
  NeedCount: PInteger = nil;
  const IgnorePatterns: TArray<string> = nil);
const
  MAX_DL = 8;
var
  Compressed, Plain: TBytes;
  JSON:     string;
  All:      TArray<TFileEntry>;
  Need:     TArray<TFileEntry>;
  E:        TFileEntry;
  NeedN:    Integer;
  Done:     Integer;
  HashFile: string;
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
          PatchFile(E, InstallRoot, Log);
        except
          on Ex: Exception do
            Log('  ERROR [' + E.Path + ']: ' + Ex.Message);
        end;
      finally
        Sem.Release;
      end;
    end);
  end;

begin
  Log('Downloading manifest...');
  Compressed := HttpGetBytes(MANIFEST_BASE + ManifestHash);
  Log(Format('  compressed: %d B', [Length(Compressed)]));

  Log('Decompressing...');
  Plain := ZlibDecomp(Compressed);
  Log(Format('  decompressed: %d B', [Length(Plain)]));

  Log('Parsing...');
  JSON := TEncoding.UTF8.GetString(Plain);
  All  := ParseManifest(JSON);
  Log(Format('  %d entries in manifest', [Length(All)]));
  for var Di := 0 to Min(4, High(All)) do
    Log(Format('  sample[%d]: "%s" (fsize=%d, parts=%d)',
      [Di, All[Di].Path, All[Di].FSize, Length(All[Di].Parts)]));

  Log('Scanning local files...');
  var OldDict: TDictionary<string, string> := nil;
  if (OldManifestJSON <> '') and not ForceAll then
  begin
    var OldEntries := ParseManifest(OldManifestJSON);
    OldDict := BuildObjHashDict(OldEntries);
    Log(Format('  loaded %d entries from cached manifest', [Length(OldEntries)]));
  end;

  NeedN := 0;
  SetLength(Need, Length(All));
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
        var D := TPath.Combine(InstallRoot, E.Path);
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
    OldDict.Free;
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

            var NeedsIt := ForceAll;
            if not NeedsIt and (OldDict <> nil) then
            begin
              var OldHash: string;
              NeedsIt := not OldDict.TryGetValue(Entry.Path.ToLower, OldHash) or (OldHash <> Entry.ObjHash);
            end;
            if not NeedsIt then
              NeedsIt := NeedsPatch(Entry, InstallRoot, Log);

            if NeedsIt then
            begin
              ScanLock.Enter;
              try
                Need[NeedN] := Entry;
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
  end;

  if Assigned(ShouldCancel) and ShouldCancel() then
  begin
    Log('Scan cancelled.');
    NeedN := 0;
  end;
  SetLength(Need, NeedN);
  Log(Format('  %d files need updating', [NeedN]));
  if NeedCount <> nil then NeedCount^ := NeedN;

  if NeedN = 0 then
  begin
    // Manifest hash changed (metadata/mtime drift) but no file sizes differ.
    // Update stored hash so future checks don't re-trigger.
    try
      HashFile := TPath.Combine(InstallRoot,
        'patchdata\' + IntToStr(ProductId) + '.manifest.hash');
      TDirectory.CreateDirectory(TPath.GetDirectoryName(HashFile));
      TFile.WriteAllText(HashFile, ManifestHash, TEncoding.UTF8);
    except end;
    Log('Already up to date.');
    Exit;
  end;

  if ScanOnly then Exit; // scan complete — caller decides whether to download

  Done     := 0;
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

  // Update local hash file so Check Update sees the new state
  try
    HashFile := TPath.Combine(InstallRoot,
      'patchdata\' + IntToStr(ProductId) + '.manifest.hash');
    TDirectory.CreateDirectory(TPath.GetDirectoryName(HashFile));
    TFile.WriteAllText(HashFile, ManifestHash, TEncoding.UTF8);
    Log('Hash file updated.');
  except
    on Ex: Exception do Log('Warning: could not update hash file: ' + Ex.Message);
  end;

  // Cache decompressed manifest for next objects[] diff
  try
    var CachePath := TPath.Combine(InstallRoot,
      'patchdata\' + ManifestHash + '.manifest.json');
    TFile.WriteAllText(CachePath, JSON, TEncoding.UTF8);
    Log('Manifest cached.');
  except
    on Ex: Exception do Log('Warning: could not cache manifest: ' + Ex.Message);
  end;

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
