# Nexon NXL Patcher Protocol

Mabinogi NA (product 10200) uses the NXL manifest-based patcher system served from Nexon's CDN.

---

## Update check flow

```
1. GET /api/game-build/v1/branch/games/{productId}/public
   → { manifestUrl: "http://download2.nexon.net/Game/nxl/games/{productId}/<40-char-hex>" }

2. GET <manifestUrl>   (plain HTTP, no auth)
   → raw body = 40-char hex hash string

3. Compare against local: {installRoot}\patchdata\{productId}.manifest.hash
   Equal → up to date
   Different → download new manifest
```

The branch endpoint requires the session cookie (Bearer optional, cookie works).

---

## Manifest format

```
GET http://download2.nexon.net/Game/nxl/games/{productId}/<hash>
→ zlib-compressed JSON
```

Decompressed JSON:

```json
{
  "files": {
    "<base64_encoded_filename>": {
      "fsize":        123456,       // decompressed file size
      "mtime":        1700000000,   // unix timestamp (unreliable)
      "objects":      ["<part_hash>", ...],  // CDN part identifiers
      "objects_fsize":[12345, ...]           // CDN part sizes (compressed)
    }
  }
}
```

### Filename decode

```
1. Base64Decode(key)             → UTF-16LE bytes
2. TEncoding.Unicode.GetString   → Delphi string
3. TEncoding.UTF8.GetBytes       → UTF-8 bytes
4. Each byte cast to Char        → skip first 3 (EF BB BF = UTF-8 BOM)
5. TrimRight(control chars + space)
```

### objects[] hash algorithm

Unconfirmed. Probably SHA1 of the compressed CDN part. Local verification is not feasible without re-compressing the downloaded data. Currently using size-only change detection.

### objects_fsize

Likely compressed part sizes. Sum does not equal `fsize`.

---

## Part download

```
GET https://download2.nexon.net/Game/nxl/games/{productId}/{productId}/{hash[0:2]}/{hash}
→ zlib-compressed raw bytes
```

Each part is downloaded and decompressed independently. Parts within a file are concatenated in `objects[]` order after decompression.

---

## Install path

Manifest file paths are relative to the game's install root (appdata folder, NOT the game's program files directory):

```
GameExe  = E:\mabinogi\appdata\Client.exe
InstRoot = TPath.GetDirectoryName(GameExe)
         = E:\mabinogi\appdata\

Final path = InstRoot + manifest_path
Hash file  = InstRoot\patchdata\{productId}.manifest.hash
```

---

## Change detection

**Size-only comparison** (`fsize` vs local file size). mtime was unreliable (caused full re-download on fresh install) and is now ignored.

Force mode (`ForceAll = True`, "Verify / Repair Files"): re-downloads every file regardless of size match.

---

## Concurrency

| Setting | Value |
|---------|-------|
| Max concurrent file downloads | 8 (`MAX_DL = 8`) |
| Part parallelism | All parts within a file fetched simultaneously |
| Temp files | `{dest}.~nxlpatch`, cleaned up on error/cancel |

### Cancellation

A `ShouldCancel: TFunc<Boolean>` lambda is checked before each file/part download.

### Pause/Resume

A manual-reset `TEvent` blocks task threads via `WaitFor(INFINITE)` when paused.

---

## File listing in manifest

Only files that need updating (size mismatch or missing) are downloaded. The manifest lists ALL game files, not just updates. The diff is done client-side.

---

## API endpoints

| Endpoint | Purpose | Auth |
|----------|---------|------|
| `GET /api/game-build/v1/branch/games/{id}/public` | Get branch info + manifest URL | Cookie / Bearer |
| `GET <manifestUrl>` (plain HTTP CDN) | Download manifest hash | None |
| `GET http://download2.nexon.net/Game/nxl/games/{id}/<hash>` | Download compressed manifest | None |
| `GET https://download2.nexon.net/Game/nxl/games/{id}/{id}/{xx}/{hash}` | Download file part | None |

---

## Known issues

- Part boundary unknown without decompressing — chunks are concatenated sequentially
- mtime values unreliable for change detection
