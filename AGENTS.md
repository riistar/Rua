# Rua — Agent Context

3rd-party Nexon Launcher replacement for Mabinogi NA (product 10200).
Delphi 64-bit VCL app. Replaces the official launcher entirely — no Nexon software.

## Build

From repo root `D:\Projects\Git\Rua`:
```powershell
powershell -File build/delphi.ps1                        # Release + collect to release/
powershell -File build/delphi.ps1 -Config Debug          # Debug only
powershell -File build/delphi.ps1 -Config All            # Debug + Release + collect
powershell -File build/delphi.ps1 -Project shim          # single project
```

Builds 3 projects. Release outputs go directly to `release/`.
Debug outputs to `delphi/build/Win{64,32}/Debug/`.

| Config | Rua | nxl3p_shim | nxl3p_stub |
|--------|-----|------------|------------|
| Platform | Win64 | Win32 | Win32 |
| Type | VCL app | Library (DLL) | Console |
| Release | `release/Rua.exe` | `release/nxl3p_shim.dll` | `release/nxl3p_stub.exe` |
| Debug | `delphi/build/Win64/Debug/` | `delphi/build/Win32/Debug/` | `delphi/build/Win32/Debug/` |

## Source Layout

```
delphi/
  Rua.dpr / Rua.dproj       — main project (dual-mode: GUI or `-pipe-stub` stub)
  nxl3p_shim.dpr             — shim DLL project
  nxl3p_stub.dpr             — stub EXE project
  src/
    forms/
      frmMain.pas + .dfm         — profile list, launch, update, settings
      frmLogin.pas + .dfm        — system-browser + cookie poll login
      frmLoginWebView.pas + .dfm — WebView2 embedded browser login
      frmProfile.pas + .dfm      — profile name dialog
      frmProfileEdit.pas + .dfm  — edit profile dialog
      frmSettings.pas + .dfm     — settings (game path, theme, checkboxes)
      frmFolderSelect.pas        — folder picker dialog
    units/
      uProtocol.pas          — pipe frame read/write + JSON
      uPipeServer.pas        — named pipe server thread
      uCredStore.pas         — Windows Credential Manager wrapper
      uProfiles.pas          — profile CRUD (JSON index)
      uNexonAPI.pas          — all Nexon REST API calls
      uDeviceId.pas          — per-profile SHA256 deviceId generation
      uGameLaunch.pas        — orchestrates stub+shim+pipe+launch
      uBrowserCookies.pas    — Firefox/Chrome cookie extraction
      uNxlPatcher.pas        — manifest-based NXL patcher
    WebView4Delphi/           — 3rd-party WebView2 VCL wrapper (vendored)

Other docs (repo root):
  PLAN.md                          — original design doc
  NEXON_AUTH.md                    — full auth protocol spec
  RE.md                            — RE findings (nexon_api_x64.dll)
  RUA_LINUX_PLAN.md                — Python/GTK Linux port plan
  SESSION.md                       — session lifecycle reference
```

## Project Identity

| Aspect | Value |
|--------|-------|
| Binary | `Rua.exe` |
| Config | `%APPDATA%\Rua\config.ini` (auto-migrates from `NexonLauncher3P` on first run) |
| Cred prefix | `Rua\` in Windows Credential Manager |
| Profile index | `%APPDATA%\Rua\profiles.json` |
| WebView2 data | `%APPDATA%\Rua\WebView2\` |

## What Works (verified)

- **Profile management**: multiple profiles, each with own credentials in Cred Manager
- **Login — Browser (TPA/Google)**: open nexon.com in Firefox, poll for TpaSession cookie, exchange for NxLSession
- **Login — Email/Password**: direct API login, OTP/MFA support, captcha detection + browser fallback hint
- **Session refresh**: auto-retries with NxLSession on 401; autologin works for email/password only (TPA returns 20182)
- **Game launch**: stub + shim bypass strategy — fetches passport, deploys fake `nexon_client.exe` + `nexon_x64.dll`, starts pipe server, launches Client.exe
- **Manifest patcher** (`uNxlPatcher.pas`): 8 concurrent files, parallel parts, size-only change detection, cancel/pause, force-all mode (Verify/Repair)
- **UI**: auto-check/auto-update checkboxes, themes, close-during-download prompt, profile auto-select

## Auth Flow (two paths)

**Path A — Browser login:**
1. Open nexon.com in system browser (or WebView2)
2. Poll cookies — detect `NxLSession` (fast path) or `TpaSession` (exchange needed)
3. Exchange: `POST /api/account/v1/no-auth/login/tpa/launcher` with `clientId="7853644408"`, `deviceId`, localTime, timeOffset
4. Store cookies
5. Autologin refresh DOES NOT WORK for TPA accounts — must re-detect browser cookies on expiry

**Path B — Email/password:**
1. `POST /api/account/v1/no-auth/login/launcher` → 200 (done) or 206 (OTP)
2. If OTP: `POST /api/account/v1/no-auth/login/launcher/otp` with mfaKey
3. Autologin refresh WORKS — `POST /api/account/v1/no-auth/login/launcher/autologin`

DeviceId: `SHA256(machine_uuid + machine_guid + ProfileName)` — per-profile tag prevents session invalidation.

## Game Launch Sequence

1. Cleanup prior stub/shim
2. `CheckPlayable` + `FetchPassport` → passport token
3. Write ticket to `%TEMP%\nxl3p_ticket.txt`
4. Copy `nxl3p_stub.exe` → `{our_dir}\nexon_client.exe` (satisfies process scan)
5. Create `NXL3P_StubExit` + `NXL3P_ShimReady` events
6. Spawn nexon_client.exe stub
7. Copy `nxl3p_shim.dll` → `{our_dir}\bin\nexon_x64.dll`
8. `FetchGameConfig` → launch params (substitute `${passport}`)
9. Start named pipe server (`TPipeServerThread`)
10. `ShellExecuteEx` Client.exe with args
11. Background: wait `ShimReady` (30s) → kill stub → cleanup artifacts

## Debug Logs

All in `%TEMP%`:
| File | Content |
|------|---------|
| `nxl_launch_debug.txt` | Launch sequence events |
| `nxl_pipe_debug.txt` | Pipe request/response |
| `nexon_tpa_debug.txt` | TPA exchange response |
| `nexon_refresh_debug.txt` | Autologin refresh response |
| `nxl3p_shim_debug.txt` | Shim init/ticket events |

## Named Pipe Protocol

```
Pipe:  \\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}
Frame: [int32LE length][UTF-8 JSON body]
```

Requests → responses: `getProductTicket` → ticket, `getSDKConfiguration` → ccu config, `productActive`/`productClosed` → `{"code":0}`. Unknown reqType → code -30000005.

## Manifest Patcher Format

```
Manifest: GET http://download2.nexon.net/Game/nxl/games/10200/<hash>
           → zlib decompress → UTF-8 JSON
Part:     GET https://download2.nexon.net/Game/nxl/games/10200/10200/<h[0:2]>/<hash>
           → zlib decompress → raw bytes → concatenate

JSON: {"files": {"<base64_name>": {"fsize":N, "mtime":N, "objects":["hash"], "objects_fsize":[N]}}}

Filename decode: base64 → UTF-16LE → UTF-8 → skip 3-byte BOM → TrimRight
Paths relative to InstRoot = TPath.GetDirectoryName(GameExe) (appdata folder)
Hash file: {InstRoot}\patchdata\10200.manifest.hash
Change detection: size-only (mtime unreliable)
```

## Delphi Gotchas (hard-earned)

1. **Loop-closure aliasing**: anonymous proc in `for` captures ONE slot. Fix: nested `procedure SpawnOne(Idx: Integer; E: TFileEntry)` with value params.
2. **`const` record capture**: anonymous method can't close over `const TFileEntry`. Pass fields as string params.
3. **`THashSHA1`** is a record. Use instance: `var H := THashSHA1.Create; H.Update(Buf, Len); Hex := H.HashAsString;` NOT `HashAsHex`.
4. **`EAggregateException`**: `Ex.Count` works; `Length(Ex.InnerExceptions)` = E2029. Access via `Ex.InnerExceptions[0]`.
5. **`TTask.Run` E2250**: almost always cascade from earlier parse error. Fix real error first.
6. **`TNotifyEvent`**: cannot assign anonymous `procedure(S: TObject)` — use named method (`of object`).
7. **Inline `var` in nested blocks**: confuses parser, cascade E2250 on `TThread.Queue`. Use traditional `var`.
8. **`OnCloseQuery` in DFM**: IDE may silently remove. Wire via code: `Self.OnCloseQuery := FormCloseQuery`.
9. **`string.Split`**: takes `array of Char` (split on chars). Use `Pos`+`Copy` for `#13#10`.
10. **`TThread.Queue`**: all UI updates from patcher thread must go through `TThread.Queue(nil, procedure ...)`.

## Known Issues

- `objects[]` hash algorithm unconfirmed (probably SHA1 of compressed CDN part). Size-only check.
- Autologin for TPA accounts returns 20182 — must re-detect browser cookies.
- Old `/game-auth/v2/ticket` endpoint dead. `FetchTicket` is alias for `FetchPassport` (uses `/api/passport/v2/passport`).
- User-Agent: `NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0`
