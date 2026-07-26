# NexonLauncher3P — Project Plan

3rd-party replacement for Nexon Launcher. No official launcher required.  
Windows: Delphi VCL. Linux: Python + PySide6.  
RE basis: `targets/nexon-launcher/TARGET.md`

---

## Goals

- Store multiple Nexon accounts (profiles), switch instantly
- Login via embedded browser (no credential scraping)
- Fetch per-game auth ticket → pass to game at launch
- Check for game updates (manifest hash comparison)
- Launch Mabinogi (product 10000) and other installed Nexon games
- Windows: native Delphi exe, VCL Styles
- Linux: Python exe (Nuitka), PySide6, game runs under Wine/Lutris

---

## Architecture

```
Windows
  NexonLauncher3P.exe  (Delphi VCL)
    ├─ TEdgeBrowser login → Windows Credential Manager
    ├─ HTTPS ticket fetch → game-auth/v2/ticket
    ├─ named pipe server (inline, no helper needed)
    └─ ShellExecuteW game launch

Linux
  nexon-launcher  (Python + Nuitka)
    ├─ pywebview login → keyring (libsecret)
    ├─ HTTPS ticket fetch → game-auth/v2/ticket
    ├─ writes ticket to temp file in Wine prefix
    ├─ spawns ticket_server.exe inside Wine
    └─ spawns game via wine/Lutris

ticket_server.exe  (Delphi, Windows target)
  runs inside Wine prefix on Linux
  creates named pipe, serves ticket to game SDK
  ships pre-built inside Linux package
```

---

## Known Protocol (from RE)

### Named pipe — game ↔ launcher
```
Pipe:    \\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}
Frame:   [4-byte int32LE length][UTF-8 JSON body]

Requests game sends:
  getProductTicket    {"type":"getProductTicket","req":{"productId":10000},"id":"x"}
  getSDKConfiguration {"type":"getSDKConfiguration","req":{"productId":10000}}
  productActive       {"type":"productActive","req":{"productId":10000}}
  productClosed       {"type":"productClosed","req":{"productId":10000}}

Responses:
  getProductTicket    {"code":0,"reqType":"getProductTicket","res":{"productId":10000,"ticket":"<tok>"}}
  getSDKConfiguration {"code":0,"res":{"ccuServerName":"ccu-edge.nexon.io","ccuServerPort":8913,
                        "hashedUserNo":"<base64-sha256>","productId":10000}}
  productActive/Closed {"code":0}

Error codes: 0=OK -30000001=parse -30000002=network -30000004=malformed -30000005=unsupported
```

### Auth ticket API
```
GET https://www.nexon.com/game-auth/v2/ticket?product_id={id}
Headers: Cookie: <nexon.com session cookies>
         User-Agent: Mozilla/5.0
Response: {"ticket": "<opaque string>"}
```

### Update check
```
GET https://download2.nexon.net/Game/nxl/patch/{productId}.manifest.hash
Response: <40-char SHA1 hex>
Compare vs local: {installPath}/../patchdata/*.manifest.hash
```

### Known product IDs
```
10000 = Mabinogi
others: read from %APPDATA%\Nexon Launcher\appconfig.json → "installedApps"
        or nxl:// shortcuts → nxl://launch/{productId}
```

### Session cookies (nexon.com)
```
id_token          — primary session token (critical)
nx_ssl            — secondary session cookie
nexon_pass_token  — may be required
Capture ALL cookies from nexon.com domain after login.
```

### CCU heartbeat (optional, for future)
```
TCP → ccu-edge.nexon.io:8913
→ "regs:10000:{sha256base64(userNo)}\n"  ← "regs\n"
→ "ping\n" every 50s                      ← "pong\n"
```

---

## Credential storage

```
Windows: Windows Credential Manager
  CredWriteW / CredReadW / CredDeleteW
  Target: "NexonLauncher3P\{ProfileName}"
  Blob:   UTF-8 JSON {"cookies":"...","captured_at":"..."}
  Persist: CRED_PERSIST_LOCAL_MACHINE

Linux: keyring (libsecret / GNOME Keyring / KWallet)
  keyring.set_password("NexonLauncher3P", profile_name, cookies_json)
  keyring.get_password("NexonLauncher3P", profile_name)
```

Non-sensitive profile index (plain JSON, both platforms):
```
Windows: %APPDATA%\NexonLauncher3P\profiles.json
Linux:   ~/.config/nexon3p/profiles.json
Fields:  name, user_no, device_id, products[], last_used
```

---

## Phases

### Phase 1 — ticket_server.exe  [WINDOWS FIRST]

Delphi console app. Minimal Windows named pipe server.

```
Input:  ticket via stdin line OR temp file path as argv[1]
Output: serves named pipe until productClosed received
        exits cleanly after game closes
```

Units:
- `uPipeServer.pas`  — CreateNamedPipe, ConnectNamedPipe, read/write frames
- `uProtocol.pas`    — JSON request parse, response build
- `Main.dpr`         — read ticket, start pipe server loop

Build: `ticket_server.dproj` → `ticket_server.exe`

---

### Phase 2 — Delphi Windows Launcher

VCL Styles application. Forms + logic units.

**Units (logic):**

| Unit | Responsibility |
|---|---|
| `uCredStore.pas` | CredWriteW/CredReadW/CredDeleteW wrapper |
| `uProfiles.pas` | Profile CRUD, JSON index, list |
| `uNexonAPI.pas` | FetchTicket, CheckUpdate, GetInstalledProducts |
| `uDeviceId.pas` | SHA256(WMIC UUID + MachineGuid) |
| `uGameLaunch.pas` | Spawn ticket_server + ShellExecuteW game |
| `uPipeServer.pas` | Same as ticket_server but inline in launcher |

**Forms:**

| Form | Controls |
|---|---|
| `frmMain` | Profile TListView, game TComboBox, Launch/Add/Delete buttons, status bar |
| `frmLogin` | TEdgeBrowser (nexon.com), cookie capture on navigation, "Done" button |
| `frmProfile` | Profile name TEdit, product ID list, OK/Cancel |

**Login flow:**
1. Open frmLogin → TEdgeBrowser navigates `https://www.nexon.com/`
2. User logs in (MFA/CAPTCHA handled by browser)
3. `OnNavigationCompleted`: poll `CookieManager.GetCookies('https://www.nexon.com', ...)`
4. When `id_token` present → capture all cookies → close form
5. Prompt profile name → save to Credential Manager

**Game launch flow:**
1. Select profile → load cookies from Credential Manager
2. Select game (product ID from appconfig.json or manual)
3. `FetchTicket(cookies, product_id)` → THTTPClient GET
4. Spawn named pipe server (uPipeServer in background thread)
5. `ShellExecuteW(game_exe)` → game connects pipe → gets ticket → plays

---

### Phase 3 — Python Linux Launcher

PySide6 app. Same logic as Delphi but Python.

**Modules:**

| Module | Responsibility |
|---|---|
| `core/api.py` | fetch_ticket, check_update |
| `core/profiles.py` | keyring + JSON index CRUD |
| `core/device_id.py` | sha256(dmidecode UUID + /etc/machine-id) |
| `core/lutris.py` | parse ~/.config/lutris/games/*.yml for prefix + wine binary |
| `core/game_launch.py` | write temp ticket, spawn wine ticket_server.exe, spawn game |
| `ui/main_window.py` | PySide6 main window |
| `ui/login_window.py` | pywebview webkit2gtk login, cookie extraction |

**ticket_server.exe on Linux:**
- Pre-built binary in `python/assets/ticket_server.exe`
- First run: copy to `{wine_prefix}/drive_c/nexon3p/ticket_server.exe`
- Launch: `wine {wine_prefix}/drive_c/nexon3p/ticket_server.exe {ticket_temp_path}`

**Build:**
```bash
python -m nuitka --onefile --enable-plugin=pyside6 \
  --include-data-dir=assets=assets \
  --output-filename=nexon-launcher \
  nexon_launcher.py
```

---

### Phase 4 — Game Patcher (future, blocked on productUrl)

Needed: capture `productUrl` from launcher network traffic (one Fiddler session).  
Then: call `nexon_runtime.exe` via ZeroMQ (ports 5575/5577) for `nrt_patch`.  
Or: reimplement download+verify using contenttools manifest format (once captured).

---

## Repo layout

```
src/NexonLauncher3P/
├── PLAN.md                        ← this file
├── delphi/
│   ├── NexonLauncher3P.dproj
│   ├── ticket_server.dproj
│   └── src/
│       ├── forms/
│       │   ├── frmMain.pas + .dfm
│       │   ├── frmLogin.pas + .dfm
│       │   └── frmProfile.pas + .dfm
│       └── units/
│           ├── uCredStore.pas
│           ├── uProfiles.pas
│           ├── uNexonAPI.pas
│           ├── uDeviceId.pas
│           ├── uGameLaunch.pas
│           ├── uPipeServer.pas
│           └── uProtocol.pas
├── python/
│   ├── nexon_launcher.py
│   ├── build.sh
│   ├── requirements.txt
│   ├── assets/
│   │   └── ticket_server.exe      ← pre-built from delphi/
│   ├── core/
│   │   ├── api.py
│   │   ├── profiles.py
│   │   ├── device_id.py
│   │   ├── lutris.py
│   │   └── game_launch.py
│   └── ui/
│       ├── main_window.py
│       └── login_window.py
└── docs/
    └── screenshots/
```

---

## Build targets summary

| Target | Tool | Output | Platform |
|---|---|---|---|
| ticket_server | Delphi | `ticket_server.exe` | Windows (runs native or Wine) |
| NexonLauncher3P | Delphi | `NexonLauncher3P.exe` | Windows only |
| nexon-launcher | Nuitka | `nexon-launcher` | Linux only |

---

## Open questions / gaps

| Item | Status | Notes |
|---|---|---|
| Cookie TTL (id_token expiry) | Unknown | Test: how long before 401 returned |
| Required cookie names beyond id_token | Unknown | Capture all, test which are needed |
| User-Agent sensitivity on nexon.com | Unknown | Test with/without browser UA |
| productUrl CDN base (for patching) | Missing | Need Fiddler capture of launcher traffic |
| Other game product IDs | Partial | 10000=Mabinogi confirmed; others from appconfig.json |
| ticket TTL | Unknown | Likely minutes; test by delaying launch |
| getSDKConfiguration hashedUserNo source | Known | base64(sha256(userNo)) but userNo from cookie/profile |
