# NexonLauncher3P — Claude Code Context

3rd-party Nexon Launcher replacement for Mabinogi NA (product 10200).
Delphi VCL. Replaces the official launcher entirely — no Nexon software required.
Project binary name: **Rua.exe** (project file: `Rua.dproj`).

## Build

```powershell
powershell -File build/delphi.ps1 -Project src/NexonLauncher3P/delphi/Rua.dproj
```

Run from repo root `D:\Projects\Git\REWorkbench`.

## Key Files

```
delphi/
  Rua.dproj
  src/
    forms/
      frmMain.pas + .dfm       — main window, update/launch/profile logic
      frmLogin.pas + .dfm      — two-path login (browser + email/password)
      frmProfileEdit.pas + .dfm — profile name entry dialog
      frmSettings.pas + .dfm   — settings dialog (game path, theme, checkboxes)
    units/
      uNxlPatcher.pas           — manifest patcher (main workhorse)
      uNexonAPI.pas             — all Nexon REST API calls
      uProfiles.pas             — profile CRUD (JSON index)
      uCredStore.pas            — Windows Credential Manager wrapper
      uGameLaunch.pas           — spawn pipe server + ShellExecuteW
      uPipeServer.pas           — named pipe server (inline in launcher)
      uBrowserCookies.pas       — Firefox/Chrome cookie extraction
      uDeviceId.pas             — per-machine+profile deviceId generation
```

## What Works

- **Profile management**: multiple profiles, each with own credentials in Windows Credential Manager
- **Login — Browser (TPA/Google)**: open nexon.com in Firefox, auto-detect TpaSession cookie, exchange for NxLSession
- **Login — Email/Password**: direct API login (`POST /api/account/v1/no-auth/login/launcher`), OTP/MFA support, captcha detection with browser fallback hint
- **Session refresh**: auto-retries with NxLSession on 401; autologin refresh works for email/password accounts
- **Game launch**: fetches passport token, starts named pipe server, launches Client.exe
- **Manifest patcher** (`uNxlPatcher.pas`):
  - Downloads + applies Nexon NXL manifest format
  - 8 concurrent file downloads (`MAX_DL = 8`)
  - Parts within each file downloaded in parallel
  - Size-only change detection (mtime was unreliable — caused full re-download)
  - Install root = `TPath.GetDirectoryName(GameExe)` (appdata folder, NOT two levels up)
  - Elapsed + ETA timer on line 1, current filename on line 2 of `LblProgress`
  - Temp files cleaned up on error (`.~nxlpatch`)
  - Cancel support: lambda `ShouldCancel: TFunc<Boolean>` checked before each file/part
  - Pause/resume: `TEvent` (manual-reset) blocks task threads via `WaitFor(INFINITE)` when paused
  - Force-all mode (`ForceAll = True`): re-downloads every file regardless of size match
- **UI**:
  - "Check for Updates" split button — dropdown has "Verify / Repair Files" option (force-all)
  - Pause/Resume button overlays update button during download
  - Close-during-download: `FormCloseQuery` prompts user, cancels download, waits for thread exit before closing
  - Auto-check on start checkbox (`ChkAutoCheck`); auto-update if available (`ChkAutoUpdate`)
  - Checkbox states + theme persist in `%APPDATA%\NexonLauncher3P\config.ini`
  - User No column hidden in profile list (width=0, data still there)
  - Profile + Last Used columns auto-resize (`LVSCW_AUTOSIZE_USEHEADER`)
  - Update check fully async (no longer blocks UI thread)
  - Settings theme preview: applying theme is live, reverts on Cancel
  - First profile auto-selected if none selected (update check needs cookies)

## Login Flow (frmLogin)

Two paths in one dialog:

**Email/Password section (top of dialog):**
- User types email + password → `BtnEmailLogin` → `LoginEmailPassword()`
- If 206 (MFA): OTP mode — repurposes email field as OTP input, shows "Cancel OTP" button
- If captcha error: message shown with browser-login fallback hint
- On success: `FCookies` set, `ModalResult := mrOK`

**Browser section (below separator):**
- `BtnOpenBrowser` → opens nexon.com in Firefox (or default browser)
- `TimerPoll` auto-detects new `TpaSession` or `NxLSession` every second
- `BtnImport` → manual trigger
- `TryImportCookies()`: fast path if `NxLSession` present; else exchanges `TpaSession` via `ExchangeTpaForNxLSession()`

DeviceId is per-profile: `SHA256(machine_uuid + machine_guid + ProfileName)` — prevents session invalidation between profiles.

## Manifest Format

```
Manifest URL:  http://download2.nexon.net/Game/nxl/games/10200/<hash>
Part URL:      https://download2.nexon.net/Game/nxl/games/10200/10200/<hash[0:2]>/<hash>
Encoding:      zlib-compressed JSON

JSON structure:
  {"files": {"<base64_name>": {
    "fsize": N,           // total decompressed file size
    "mtime": N,           // unix timestamp
    "objects": ["hash"],  // part hashes (SHA1 of compressed part? — unconfirmed)
    "objects_fsize": [N]  // part sizes (compressed? — unconfirmed)
  }}}

Filename decode (base64 → UTF-16LE → UTF-8 → skip 3-byte BOM → TrimRight):
  UniBytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
  U8       := TEncoding.UTF8.GetBytes(TEncoding.Unicode.GetString(UniBytes));
  // each byte cast to Char, skip first 3 (EF BB BF BOM)

Paths are RELATIVE to the appdata folder (same dir as Client.exe).
e.g. "Client.exe", "Script.wz" — NOT "appdata\Client.exe".
```

## Install Path Logic

```
GameExe  = <drive>\<gamedir>\appdata\Client.exe
InstRoot = TPath.GetDirectoryName(GameExe) = <drive>\<gamedir>\appdata\
Files    → InstRoot\<manifest_path>
HashFile → InstRoot\patchdata\10200.manifest.hash
```

## Named Pipe Protocol

```
Pipe:  \\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}
Frame: [4-byte int32LE length][UTF-8 JSON]

Game sends → launcher responds:
  getProductTicket    → {"code":0,"reqType":"getProductTicket","res":{"productId":10200,"ticket":"<tok>"}}
  getSDKConfiguration → {"code":0,"res":{"ccuServerName":"ccu-edge.nexon.io","ccuServerPort":8913,...}}
  productActive       → {"code":0}
  productClosed       → {"code":0}
```

## Auth API (uNexonAPI.pas)

See `NEXON_AUTH.md` for full protocol documentation. Summary:

```
POST /api/account/v1/no-auth/login/tpa/launcher      — TPA/Google exchange
POST /api/account/v1/no-auth/login/launcher          — email/password login
POST /api/account/v1/no-auth/login/launcher/otp      — OTP submission
POST /api/account/v1/no-auth/login/launcher/autologin — AToken refresh (email/pwd only)
POST /api/game-auth2/v1/playable                     — pre-launch check (required)
POST /api/passport/v2/passport                       — launch token (passport)
GET  /api/game-build/v1/configuration/games/10200    — launch parameters
GET  /api/game-build/v1/branch/games/10200/public    — manifest URL for update check
```

Old `/game-auth/v2/ticket` endpoint is dead. `FetchTicket` is now an alias for `FetchPassport`.

Exception types: `ETicketError`, `EUpdateCheckError`, `ELoginFailed`, `ELoginCaptchaRequired`, `ELoginMfaRequired` (has `.MfaKey` / `.MfaType` fields).

## Known Issues / Open Questions

| Issue | Notes |
|-------|-------|
| `objects[]` hash algorithm | Probably SHA1 of compressed CDN part. Local verification not feasible without re-compressing. Currently size-only. |
| `objects_fsize` meaning | Probably compressed sizes. Sum ≠ fsize. |
| Large file download speed | Many parts — parallel parts help but still network-bound |
| Autologin for TPA accounts | Returns error 20182. Must re-detect TpaSession from browser on AToken expiry. |

## Delphi Gotchas Encountered

- **Loop-closure aliasing**: anonymous proc inside `for` loop captures ONE slot. Fix: nested `procedure SpawnOne(Idx: Integer; E: TFileEntry)` — value params get own heap copy.
- **`const` record capture**: anonymous method cannot close over `const TFileEntry` param. Fix: pass needed fields as string params.
- **`THashSHA1`**: record type, use instance methods `Update(TBytes, Length)` + `HashAsString`. No `GetHashStringFromBytes` static.
- **`EAggregateException`**: use `Ex.Count` not `Length(Ex.InnerExceptions)`. Access via `Ex.InnerExceptions[0]`.
- **`TTask.Run` E2250**: usually cascades from earlier parse error. Fix the real error first.
- **`TNotifyEvent` incompatibility**: cannot assign anonymous `procedure(S: TObject)` to `TNotifyEvent` (`of object`). Use named method.
- **Inline `var` in nested `begin..end`**: can confuse parser, causing cascade E2250 on all subsequent `TThread.Queue` calls. Use traditional `var` section instead.
- **`OnCloseQuery` in DFM**: IDE may silently remove it ("method does not exist" dialog). Wire via `Self.OnCloseQuery := FormCloseQuery` in `FormCreate` code instead.
- **`string.Split` takes `array of Char`**: splits on individual chars, not substrings. Use `Pos` + `Copy` to find `#13#10` pairs.
- **`#13#10` in DFM Caption**: must be outside string quotes: `'line1' + #13#10 + 'line2'`, NOT `'line1 #13#10 line2'`.
