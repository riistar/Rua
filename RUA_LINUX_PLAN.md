# Rua — Linux Port Plan (Python + GTK4)

## Goal

Native Linux launcher for Mabinogi NA (product 10200) under Lutris / Steam Proton.
Replaces Nexon Launcher entirely. No Wine dependency for the launcher itself.
Game still runs under Proton; stub + shim remain Windows PE files invoked via `wine`.

---

## Tech Stack

| Layer | Choice | Reason |
|---|---|---|
| Language | Python 3.11+ | Fastest auth port; rich ecosystem |
| GUI | PyGObject (GTK4) | Native Linux/GNOME look; Lutris is also GTK |
| HTTP | `httpx` (sync) | Headers/cookie control; replaces `THTTPClient` |
| JSON | stdlib `json` | No dependency |
| Credentials | `secretstorage` (libsecret/KWallet) | OS keyring; replaces Windows Cred Manager |
| Profiles | JSON file in `~/.config/rua/` | Same structure as Windows version |
| Config | `configparser` INI | Same `config.ini` keys |
| Packaging | `pipx` / Flatpak | Distribution |

---

## Architecture

```
rua/
  __main__.py          — entry point, GTK app init
  auth/
    api.py             — all Nexon REST calls (port of uNexonAPI.pas)
    cookies.py         — cookie string helpers (ExtractCookieVal etc.)
    browser.py         — Firefox/Chrome cookie extraction (port of uBrowserCookies.pas)
    device_id.py       — per-profile deviceId (SHA-256, same algo as Delphi)
  profiles/
    store.py           — profiles.json CRUD (port of uProfiles.pas)
    creds.py           — libsecret wrapper (port of uCredStore.pas)
  launch/
    launcher.py        — orchestrates stub + shim + proton (port of uGameLaunch.pas)
    patcher.py         — NXL manifest download/apply (port of uNxlPatcher.pas)
    proton.py          — find Proton, build env, invoke
  ui/
    main_window.py     — main window (port of frmMain)
    login_dialog.py    — email/password + browser login (port of frmLogin)
    profile_edit.py    — edit dialog
    settings_dialog.py — settings
    tray.py            — system tray icon (GLib/AppIndicator)
  migrate.py           — one-shot import from Windows Rua appdata (optional)
```

---

## Auth Flow

Identical to Windows. `auth/api.py` is a direct port:

```python
BASE    = "https://www.nexon.com/api"
UA      = "Mozilla/5.0 ... NexonLauncher/4.7.9 ..."
ARENA   = "nxl-v2.71.0-c228c50d"

def _headers(cookies: str, token: str = "") -> dict:
    h = {"User-Agent": UA, "x-arena-fe-version": ARENA,
         "Accept": "application/json", "Content-Type": "application/json"}
    if cookies:
        h["Cookie"] = cookies
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h

def game_token(cookies: str) -> str:
    return extract_cookie(cookies, "g_AToken") or extract_cookie(cookies, "AToken")

def fetch_passport(cookies: str, product_id: str) -> str:
    r = httpx.post(f"{BASE}/passport/v2/passport",
                   json={"productId": product_id},
                   headers=_headers(cookies, game_token(cookies)))
    if r.status_code == 401:
        raise SessionExpiredError("Passport 401")
    return r.json()["passport"]

def autologin_refresh(nxl_session: str, device_id: str) -> str | None:
    r = httpx.post(f"{BASE}/account/v1/no-auth/login/launcher/autologin",
                   json={"deviceId": device_id, "deviceType": "PC", "locale": "en"},
                   headers=_headers(f"NxLSession={nxl_session}"))
    if r.status_code != 200:
        return None
    return parse_set_cookie(r)
```

All endpoints: `fetch_access`, `check_playable`, `fetch_passport`, `fetch_game_config`,
`check_session_valid`, `login_email_password`, `login_otp`, `autologin_refresh` —
direct translations of `uNexonAPI.pas`.

---

## Launch Sequence

Stub and shim stay as Windows PE files. They run inside Proton's Wine instance.

```
launch/launcher.py:

1. cleanup_stub()           — kill previous wine stub process, delete deployed files
2. fetch_access(cookies)
3. check_playable(cookies, product_id)
4. passport = fetch_passport(cookies, product_id)
5. write_ticket_file(passport)
   → {wine_prefix}/drive_c/users/{user}/AppData/Local/Temp/nxl3p_ticket.txt
   (or $WINEPREFIX/drive_c/windows/temp/nxl3p_ticket.txt)
6. deploy stub:  copy nxl3p_stub.exe → {our_dir}/nexon_client.exe
7. spawn stub:   wine {our_dir}/nexon_client.exe  (no window)
8. deploy shim:  copy nxl3p_shim.dll → {our_dir}/bin/nexon_x64.dll
9. config = fetch_game_config(cookies, product_id)
10. build Proton command:
    env STEAM_COMPAT_DATA_PATH=... STEAM_COMPAT_CLIENT_INSTALL_PATH=...
    proton run Client.exe /P:{passport} /L:en ...
11. launch game subprocess (non-blocking)
12. background: wait game exit → cleanup stub/shim
```

### Proton Detection

```python
# launch/proton.py
def find_proton() -> Path:
    # 1. Setting in config
    # 2. Steam library: ~/.steam/root/steamapps/common/Proton*/proton
    # 3. Flatpak Steam: ~/.var/app/com.valvesoftware.Steam/...
    # 4. Ask user in settings dialog
```

### Wine Prefix / Temp Path

The ticket file must be written inside the Wine prefix so Proton-launched binaries can read it.

```python
def ticket_path(wine_prefix: Path) -> Path:
    return wine_prefix / "drive_c" / "windows" / "temp" / "nxl3p_ticket.txt"
```

Default Proton prefix for Mabinogi:
`~/.steam/root/steamapps/compatdata/<appid>/pfx/`

User configures this in Settings (or we auto-detect from Steam library).

---

## Named Pipe

The game's Nexon SDK connects to `\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}`.
Under Wine/Proton this maps to a Unix socket in the Wine prefix.

**Option A — pipe server in Python via Wine socket path** (complex)

**Option B — keep pipe server as a Windows helper exe** (simple)
- Build `nxl3p_pipe_server.exe` (stub, minimal Win32 — wraps current `uPipeServer.pas` logic)
- Launch it under `wine` with ticket + product_id as args
- It handles `getProductTicket`, `getSDKConfiguration`, etc.
- Python just starts it and waits

Option B is simpler and reuses tested code. Merge pipe server into the stub or keep separate.

---

## Credential Storage

```python
# profiles/creds.py
import secretstorage

COLLECTION = "default"
PREFIX     = "Rua"

def cred_save(profile_name: str, cookies: str):
    with secretstorage.dbus_init() as conn:
        col = secretstorage.get_default_collection(conn)
        col.create_item(f"{PREFIX}/{profile_name}",
                        {"application": PREFIX, "profile": profile_name},
                        cookies.encode(), replace=True)

def cred_load(profile_name: str) -> str:
    with secretstorage.dbus_init() as conn:
        col = secretstorage.get_default_collection(conn)
        items = col.search_items({"application": PREFIX, "profile": profile_name})
        item = next(items, None)
        return item.get_secret().decode() if item else ""
```

Falls back gracefully if no keyring daemon (e.g. headless): stores in
`~/.config/rua/creds.json` with a warning that cookies are unencrypted.

---

## Browser Cookie Extraction

Same logic as `uBrowserCookies.pas`:

- **Firefox**: `~/.mozilla/firefox/*.default/cookies.sqlite` — query `SELECT value FROM moz_cookies WHERE host LIKE '%.nexon.com%'`
- **Chrome/Chromium**: `~/.config/google-chrome/Default/Cookies` — encrypted with `libsecret` (v10/v11 key in keyring); use `pycookiecheat` or manual AES-CBC decrypt

---

## GUI (GTK4 / PyGObject)

### Main Window

```
┌─────────────────────────────────────────────────┐
│  [icon]  Rua                     [_][□][X]      │
├─────────┬───────────────────────────────────────┤
│ Profile │  [Launch]  [Check for Updates ▼]      │
│ ──────  │  [Pause]                              │
│ ● Main  │                                        │
│   Alt   │  Progress bar                          │
│         │  ─────────────────────────────────     │
│ [Add]   │  Log memo                              │
│ [Edit]  │                                        │
│ [Del]   │                                        │
└─────────┴───────────────────────────────────────┘
│  Status bar                                      │
└──────────────────────────────────────────────────┘
```

- `Gtk.ListBox` for profiles with icons (green/red/grey session state)
- `Gtk.MenuButton` for the split-button update dropdown
- `Gtk.ProgressBar` + `Gtk.TextView` (log, non-editable, monospace)
- Double-click profile → edit dialog
- Right-click profile → context menu: Edit / Delete / Refresh Login

### Login Dialog

Same two-path layout as Windows `frmLogin`:
- Email/Password section (top) with Sign In button, OTP flow
- Browser section (bottom) with Open nexon.com + Import Cookies + poll timer
- `Gtk.Dialog` subclass, modal

### Tray

```python
# ui/tray.py — AppIndicator3 or StatusIcon fallback
import gi
gi.require_version("AppIndicator3", "0.1")
from gi.repository import AppIndicator3, Gtk

indicator = AppIndicator3.Indicator.new("rua", icon_path, CATEGORY_APP_STATUS)
# Menu: Open / Launch Profile > [submenu] / Exit
```

---

## Patcher

Direct port of `uNxlPatcher.pas` using `threading.ThreadPoolExecutor`:

```python
MAX_DL = 8  # concurrent file downloads

with ThreadPoolExecutor(max_workers=MAX_DL) as pool:
    futures = [pool.submit(download_file, entry, callbacks) for entry in to_update]
    for f in as_completed(futures):
        f.result()  # raises on error
```

- zlib decompress: `zlib.decompress(data)`
- Base64 filename decode: same UTF-16LE → UTF-8 → skip 3-byte BOM
- Size-only change detection (mtime still unreliable)
- Temp files: `{path}.~nxlpatch`, cleaned on error/cancel
- Cancel via `threading.Event`; pause via `threading.Event.wait()`

---

## Config / Profiles

```
~/.config/rua/
  config.ini         — game_exe, theme, verbose, auto_check, auto_update, wine_prefix, proton_path
  profiles.json      — same schema as Windows version
```

No migration needed from Windows (different machine).

---

## Settings Dialog

Additional Linux-only fields:
- **Proton path** — file chooser for `proton` executable
- **Wine prefix** — directory chooser for compatdata pfx
- **Steam App ID** — integer, used to auto-locate prefix under Steam

---

## Phased Plan

### Phase 1 — Auth + CLI (no GUI)
- `auth/api.py` — all endpoints ported and tested
- `profiles/store.py` + `profiles/creds.py`
- `launch/proton.py` — Proton detection
- `launch/launcher.py` — full launch sequence (CLI args for profile)
- Verify game actually launches and plays

### Phase 2 — GTK4 Main Window
- Main window, profile list, launch button, log view
- Tray icon
- Settings dialog (game path, Proton path, Wine prefix)

### Phase 3 — Login Dialog
- Email/password flow
- Browser cookie import
- OTP flow

### Phase 4 — Patcher
- Manifest download + apply
- Progress UI

### Phase 5 — Polish
- Session validity icons
- Auto-check on start
- Lutris integration script / `.desktop` file
- Flatpak manifest

---

## Known Risks

| Risk | Mitigation |
|---|---|
| Proton version differences in Wine prefix layout | Make prefix path user-configurable |
| `nxl3p_shim.dll` scanning for `nexon_client.exe` process — Wine process names may differ | Test; may need stub renamed to exact `nexon_client.exe` inside Wine |
| Named pipe timing (shim must be loaded before game reads pipe) | Keep `Sleep(300)` / `ShimReady` event logic — run pipe server as Wine helper |
| libsecret not available (headless / minimal DE) | Plaintext fallback with warning |
| Nexon GeoIP blocking Linux User-Agent | Already spoofing NexonLauncher UA — should be fine |
| `FetchAccess` / `CheckPlayable` behaviour differences | Use debug dump files same as Windows to verify responses |
