# Nexon3PAPI.dll — Core API for Nexon Launcher Replacement

Win64 DLL exposing all core Nexon launcher functionality via C-compatible `stdcall` exports.
Consumable from any language: C, C++, C#, Python, Rust, etc.

## Quick Start

```c
#include <windows.h>

typedef int (__stdcall *NP_Init_t)(const char* configPath, void* logFn);
typedef int (__stdcall *NP_LoginEmailPw_t)(const wchar_t* email, const wchar_t* pw,
    const wchar_t* deviceId, wchar_t* outCookie, int outCookieLen);
typedef int (__stdcall *NP_LaunchGame_t)(const wchar_t* cookie, const wchar_t* passport,
    const wchar_t* gameExe, const wchar_t* userNo, int productId,
    void* logFn, void* exitFn);

HMODULE dll = LoadLibraryW(L"Nexon3PAPI.dll");
NP_Init_t NP_Init = (NP_Init_t)GetProcAddress(dll, "Nexon3PAPI_Init");
NP_LoginEmailPw_t NP_LoginEmailPw = (NP_LoginEmailPw_t)GetProcAddress(dll, "Nexon3PAPI_LoginEmailPw");
NP_LaunchGame_t NP_LaunchGame = (NP_LaunchGame_t)GetProcAddress(dll, "Nexon3PAPI_LaunchGame");

// Initialize
NP_Init("C:\\Users\\me\\AppData\\Roaming\\MyApp", NULL);

// Login
wchar_t cookie[4096];
int ret = NP_LoginEmailPw(L"user@example.com", L"password",
    L"sha256hexdeviceid", cookie, 4096);
// ret == 0: success, cookie contains "NxLSession=...; AToken=..."
// ret == 1: MFA required (cookie contains mfaKey)
// ret == 2: Captcha required

// Launch game
NP_LaunchGame(cookie, NULL, L"C:\\Mabinogi\\Client.exe",
    L"userNo", 10200, NULL, NULL);
```

## Return Codes

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `OK` | Success |
| 1 | `MFARequired` | OTP/MFA challenge (mfaKey in output buffer) |
| 2 | `CaptchaRequired` | CAPTCHA required — use browser login |
| -1 | `ErrGeneric` | Generic failure |
| -2 | `ErrNotInit` | `Nexon3PAPI_Init` not called |
| -3 | `ErrBadParam` | Invalid parameter |
| -4 | `ErrNetwork` | Network error |
| -5 | `ErrBufSmall` | Output buffer too small |
| -401 | `ErrSession` | Session expired (401) |

## String Conventions

- **PWideChar** (UTF-16) for all string inputs/outputs
- Caller provides output buffer + length in characters (including null terminator)
- Cookies format: `NxLSession=uuid; AToken=base64; NexonUserID=number`
- DeviceId format: 64-char lowercase hex SHA256

## Building a Launcher — Complete Flow

This section walks through everything your app needs to do, from first run
to game launch. The DLL handles the Nexon HTTP API calls; your app handles
UI, credential storage, and the browser login path.

### 1. Generate a Device ID

Call this once per account/profile and store the result. The `tag` should be
unique per profile (e.g., the profile name). This prevents Nexon from
invalidating sessions across profiles.

```
deviceId = Nexon3PAPI_GetDeviceId("MyProfileName")
// → "a1b2c3d4e5f6..." (64 hex chars)
```

Store: profile config alongside username.

### 2. Get a Session Cookie

You need a cookie string containing `NxLSession` + `AToken` + `NexonUserID`.
There are two paths:

#### Path A — Email/Password (simpler, full DLL)

```python
# Step 1: login
buf = create_unicode_buffer(4096)
ret = dll.Nexon3PAPI_LoginEmailPw(
    "user@nexon.com", "password", deviceId, buf, 4096)

if ret == 0:
    cookies = buf.value   # "NxLSession=...; AToken=...; NexonUserID=..."

elif ret == 1:
    # MFA required — buf.value contains mfaKey
    mfaKey = buf.value
    # prompt user for OTP code, then:
    ret2 = dll.Nexon3PAPI_LoginOTP(mfaKey, "123456", deviceId, buf, 4096)
    if ret2 == 0:
        cookies = buf.value

elif ret == 2:
    # Captcha required — must use browser login (Path B)
```

#### Path B — SSO / Browser Login (app provides browser)

The DLL cannot open a browser or capture cookies. Your app must:

**Option 1: Embedded WebView2 (recommended)**
1. Create a WebView2 control loading `https://www.nexon.com/account/en/login`
2. After login, capture cookies from `CoreWebView2.CookieManager`
3. Look for `NxLSession` or `TpaSession` cookies on `www.nexon.com`

**Option 2: System browser + cookie polling**
1. Open the system browser to the Nexon login URL
2. Periodically read Firefox/Chrome's cookie database (SQLite)
3. Look for `TpaSession` cookie set by nexon.com

After capturing the raw cookie string:

```python
# Fast path — NxLSession present, use directly:
if "NxLSession" in raw_cookies:
    cookies = raw_cookies

# TPA path — must exchange:
else:
    tpa = extract_cookie(raw_cookies, "TpaSession")
    buf = create_unicode_buffer(4096)
    ret = dll.Nexon3PAPI_ExchangeTpa(tpa, deviceId, buf, 4096)
    if ret == 0:
        cookies = buf.value
```

**After getting initial cookies via either path, upgrade the session scope:**

```python
# These merge Set-Cookie headers from Nexon's API into your cookie string.
# Without this, the passport endpoint may reject the session.

newBuf = create_unicode_buffer(8192)
dll.Nexon3PAPI_FetchAccount(cookies, newBuf, 8192)
if newBuf.value != cookies:
    cookies = newBuf.value  # merged with any refreshed tokens

dll.Nexon3PAPI_FetchAccess(cookies, 10200, newBuf, 8192)
if newBuf.value != cookies:
    cookies = newBuf.value

# Extract NexonUserID from cookies for later use
# (needed for launch, can be stored with profile)
userNo = extract_cookie(cookies, "NexonUserID")  # numeric string
```

### 3. Store the Credential

Store the cookie string securely. The cookie is your auth token — treat it like
a password.

```python
profile = {
    "name": "MyProfile",
    "email": email,
    "userNo": userNo,
    "deviceId": deviceId,
    "gameExe": "C:\\Mabinogi\\Client.exe",
    "lastUsed": now()
}

store_secure("Rua\\MyProfile", cookies)   # Windows Credential Manager
save_json("profiles.json", profiles_array)  # profile index
```

**Cookie format stored:**
```
NxLSession=uuid; AToken=base64token; NexonUserID=123456; id_token=jwt; arenaSid=hex
```

This single string is ALL you need for auth. It contains the session token,
refresh token, user ID, and any supplemental tokens.

### 4. On Subsequent Launches — Validate & Refresh

Before launching, check if the stored session is still valid:

```python
cookies = load_secure("Rua\\MyProfile")
deviceId = profile["deviceId"]

# Step 1: Check session
httpStatus = c_int(0)
nexonCode = c_int(0)
valid = dll.Nexon3PAPI_CheckSession(cookies, byref(httpStatus), byref(nexonCode))
if valid:
    print("Session OK")
    # proceed to launch

else:
    # Step 2: Try autologin refresh (works for email/pw accounts)
    buf = create_unicode_buffer(4096)
    ret = dll.Nexon3PAPI_AutoLogin(cookies, deviceId, buf, 4096)
    if ret == 0 and buf.value:
        cookies = buf.value
        store_secure("Rua\\MyProfile", cookies)   # save refreshed creds
        print("Session refreshed")
        # proceed to launch

    else:
        # Step 3: Need full re-login
        print("Session expired — re-login required")
        goto step 2  # prompt user to login again
```

### 5. Launch the Game

```python
exit_event = threading.Event()

def on_game_exit():
    exit_event.set()

exit_cb = CFUNCTYPE(None)(on_game_exit)

ret = dll.Nexon3PAPI_LaunchGame(
    cookies,          # NxLSession=...; AToken=...; NexonUserID=...
    None,             # passport (NULL = fetch automatically)
    "C:\\Mabinogi\\Client.exe",
    "123456",         # userNo from cookies
    10200,            # productId (Mabinogi NA)
    None,             # log callback
    exit_cb)

if ret == -401:
    # Session expired during launch (passport fetch returned 401)
    # Refresh and retry:
    buf = create_unicode_buffer(4096)
    if dll.Nexon3PAPI_AutoLogin(cookies, deviceId, buf, 4096) == 0:
        cookies = buf.value
        store_secure("Rua\\MyProfile", cookies)
        ret = dll.Nexon3PAPI_LaunchGame(
            cookies, None, "C:\\Mabinogi\\Client.exe",
            userNo, 10200, None, exit_cb)

elif ret != 0:
    raise Exception(f"Launch failed: {ret}")

# ret == 0 — game is running
# DLL handles stub/shim deployment, pipe server, and cleanup.
# exit_cb fires when the game process exits.
exit_event.wait()
```

### 6. SSO / WebView2 Login Details

If you're building a WebView2-based login (recommended for SSO), here's the
critical flow your app must implement:

```
1. Navigate WebView2 to:
   https://www.nexon.com/account/en/login?autologin=false&return_url=https%3A%2F%2Fnxl.nxfs.nexon.com%2F

2. User logs in with email/pw or Google/Facebook SSO.

3. After login, Nexon redirects to nxl.nxfs.nexon.com which sets cookies.

4. Capture cookies from WebView2's CookieManager for these domains:
   - www.nexon.com  → NxLSession, TpaSession, AToken, NexonUserID
   - nxl.nxfs.nexon.com → arenaSid

5. Extract the cookie values into a semicolon-delimited string:
   "NxLSession=uuid; AToken=base64; NexonUserID=123456"

6. If TpaSession is present, call Nexon3PAPI_ExchangeTpa() to convert it
   to a proper NxLSession + AToken (needed for launcher API scope).

7. Call Nexon3PAPI_FetchAccount() + Nexon3PAPI_FetchAccess() to merge
   Set-Cookie headers and upgrade the session for game-auth API use.

8. Store the final cookie string.
```

### Session Lifecycle Summary

```
                    ┌─────────────┐
                    │  First Run  │
                    └──────┬──────┘
                           │
               ┌───────────▼───────────┐
               │  Get device ID + tag  │
               └───────────┬───────────┘
                           │
               ┌───────────▼───────────┐
          ┌────│  Login (Path A or B)  │
          │    └───────────┬───────────┘
          │                │
          │    ┌───────────▼───────────┐
          │    │  Store cookie string  │
          │    │  + profile data       │
          │    └───────────┬───────────┘
          │                │
          │    ┌───────────▼───────────┐
          │    │Nexon3PAPI_CheckSession│──valid──┐
          │    └───────────┬───────────┘         │
          │        expired │                     │
          │    ┌───────────▼───────────┐         │
          │    │Nexon3PAPI_AutoLogin   │──ok─────┤
          │    └───────────┬───────────┘         │
          │        failed │                     │
          │    ┌───────────▼───────────┐         │
          └────│  Re-login prompt     │         │
               └───────────────────────┘         │
                                                 │
                    ┌─────────────┐              │
                    │  LaunchGame │◄─────────────┘
                    └──────┬──────┘
                           │
               ┌───────────▼───────────┐
               │  Returns -401? ──yes──┘ refresh + retry
               └───────────┬───────────┘
                           │
                    ┌──────▼──────┐
                    │ Game runs   │
                    │ exit_cb     │
                    └─────────────┘
```

## Functions

### Init / Shutdown

```c
int Nexon3PAPI_Init(const char* configPath,
    void (*logFn)(const char* msg));
void Nexon3PAPI_Shutdown();
```

Call `Init` once before any other function. `configPath` is a UTF-8 path for
the app's config directory (unused internally, stored for logging). `logFn` is
an optional callback for diagnostic messages (UTF-8). Call `Shutdown` on exit.

### Device ID

```c
int Nexon3PAPI_GetDeviceId(const wchar_t* tag,
    wchar_t* outBuf, int outBufLen);
```

Generates `SHA256(wmic_uuid + MachineGuid + tag).lowercase()`.

`tag` is typically the profile name for per-profile session isolation.
Output is always 64 hex chars.

### Login — Email/Password

```c
int Nexon3PAPI_LoginEmailPw(const wchar_t* email, const wchar_t* password,
    const wchar_t* deviceId, wchar_t* outCookie, int outCookieLen);
```

Returns cookie string on success. On MFA required (return 1), `outCookie`
contains the `mfaKey`. On CAPTCHA required (return 2), fall back to
WebView2/browser login flow.

### Login — OTP/MFA

```c
int Nexon3PAPI_LoginOTP(const wchar_t* mfaKey, const wchar_t* otpCode,
    const wchar_t* deviceId, wchar_t* outCookie, int outCookieLen);
```

Submit OTP code after receiving `MFARequired` from `LoginEmailPw`.

### Login — TPA Exchange (SSO/Browser)

```c
int Nexon3PAPI_ExchangeTpa(const wchar_t* tpaToken,
    const wchar_t* deviceId, wchar_t* outCookie, int outCookieLen);
```

Exchange a `TpaSession` cookie (from browser SSO login) for a launcher-scoped
`NxLSession` + `AToken` cookie string. Returns `ErrGeneric` if the token
expired or exchange failed.

### Session Refresh

```c
int Nexon3PAPI_AutoLogin(const wchar_t* inCookie,
    const wchar_t* deviceId, wchar_t* outCookie, int outCookieLen);
```

Refresh session via autologin (email/password accounts only). TPA accounts
return `ErrGeneric` (must re-detect browser cookies).

### Session Check

```c
int Nexon3PAPI_CheckSession(const wchar_t* inCookie,
    int* outHttpStatus, int* outNexonCode);
```

Returns non-zero if session is valid (HTTP 200), zero if expired.
`outHttpStatus` receives HTTP status code. `outNexonCode` receives the
`x-arena-web-errorcode` header.

### Passport

```c
int Nexon3PAPI_GetPassport(const wchar_t* inCookie, int productId,
    wchar_t* outPassport, int outPassportLen);
```

Fetch passport token from Nexon API. Used for game launch authentication.
Passport format: `NP12:us:0:userNo:base64token`.

### Game Config

```c
int Nexon3PAPI_FetchGameConfig(const wchar_t* inCookie, int productId,
    wchar_t* outJson, int outJsonLen);
```

Returns JSON with `executablePath`, `workingDirectory`, `parameters` array.

### Playable Check

```c
int Nexon3PAPI_CheckPlayable(const wchar_t* inCookie, int productId,
    int* outHttpStatus);
```

Returns non-zero if product is playable. Check `outHttpStatus` for 401
(session expired).

### Manifest Hash

```c
int Nexon3PAPI_FetchManifestHash(const wchar_t* inCookie, int productId,
    wchar_t* outHash, int outHashLen);
```

Fetch NXL manifest hash for patch checking.

### Access / Account

```c
int Nexon3PAPI_FetchAccess(const wchar_t* inCookie, int productId,
    wchar_t* outCookie, int outCookieLen);
int Nexon3PAPI_FetchAccount(const wchar_t* inCookie,
    wchar_t* outCookie, int outCookieLen);
```

`FetchAccess` calls `/game-auth2/v1/access` and merges Set-Cookie headers.
`FetchAccount` calls `/account/v1/account` and merges Set-Cookie headers.
Both return merged cookie string on success, or original input on failure.

### Launch Game

```c
int Nexon3PAPI_LaunchGame(const wchar_t* inCookie,
    const wchar_t* inPassport, const wchar_t* gameExe,
    const wchar_t* userNo, int productId,
    void (*logFn)(const char* msg),
    void (*exitFn)());
```

Full game launch sequence:
1. FetchAccount → FetchAccess → CheckPlayable → FetchPassport
2. Write passport ticket to `%TEMP%\nxl3p_ticket.txt`
3. Deploy `nxl3p_stub.exe` as `nexon_client.exe` (satisfies process scan)
4. Deploy `nxl3p_shim.dll` as `bin\nexon_x64.dll` (fake Nexon SDK)
5. Start named pipe server for game callbacks
6. `ShellExecuteEx` the game with platform-appropriate launch params

`inPassport` can be NULL (passport fetched automatically).
`exitFn` is called when the game process exits.
Returns `ErrSession` (-401) if session expired — caller should refresh
cookies and retry. Returns `ErrGeneric` (-1) on other failures.
Returns `OK` (0) on success.

### Launch Status

```c
int Nexon3PAPI_LaunchStatus();
```

Returns non-zero if a game was launched and is still running.

### Browser Cookies (EXE-side only)

Browser cookie extraction (`uBrowserCookies`) requires FireDAC/SQLite which
needs the VCL framework. It is NOT available in the DLL. The reference
implementation (Rua.exe) handles it in-app via `Nexon3PAPIImport` unit which
calls `uBrowserCookies` directly. External consumers should implement their
own browser cookie reading or use the Rua GUI.

### Patcher (EXE-side only)

The manifest patcher (`uNxlPatcher`) uses `TTask` which requires the VCL
framework. It is NOT available in the DLL. The reference implementation
handles patching in the EXE.

## File Dependencies

Place these in the same directory as the DLL:

| File | Required | Purpose |
|------|----------|---------|
| `Nexon3PAPI.dll` | Yes | Core API |
| `nxl3p_shim.dll` | Yes | Fake `nexon_x64.dll` deployed at game launch |
| `nxl3p_stub.exe` | Yes | Fake `nexon_client.exe` for process scan |
| `sqlite3.dll` | Only for browser cookie reading | Firefox/Chrome cookie DB |
| `WebView2Loader.dll` | Only for WebView2 browser login | Embedded browser |

## Example: Launch Game from Python

```python
import ctypes, ctypes.wintypes

dll = ctypes.WinDLL("Nexon3PAPI.dll")

dll.Nexon3PAPI_Init.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
dll.Nexon3PAPI_Init(b"C:\\MyApp\\config", None)

# Login
out = ctypes.create_unicode_buffer(4096)
ret = dll.Nexon3PAPI_LoginEmailPw(
    "user@example.com", "mypassword",
    "abcdef123456...deviceid...", out, 4096)
if ret != 0:
    raise Exception(f"Login failed: {ret}")
cookies = out.value

# Launch
EXIT_EVENT = threading.Event()
def on_exit():
    EXIT_EVENT.set()

EXIT_CB = ctypes.CFUNCTYPE(None)(on_exit)
ret = dll.Nexon3PAPI_LaunchGame(
    cookies, None,
    "C:\\Mabinogi\\Client.exe",
    "123456", 10200,
    None, EXIT_CB)
if ret == -401:  # session expired
    # refresh and retry
    pass
elif ret != 0:
    raise Exception(f"Launch failed: {ret}")

print("Game launched, waiting for exit...")
EXIT_EVENT.wait()
print("Game exited")
```

## Linux / Wine + Proton (Lutris)

The DLL uses only Win32 APIs that Wine implements maturely. If your game
runs in Proton, the DLL launcher will too.

### What Works

| API | Wine Status | Used For |
|-----|------------|----------|
| WinHTTP | ✅ Mature | All Nexon REST API calls |
| CreateProcessW / ShellExecuteEx | ✅ Mature | Spawning stub + game |
| Named pipes (`\\.\pipe\...`) | ✅ Mature | Game ←→ launcher IPC |
| Kernel events (`CreateEventW`) | ✅ Mature | ShimReady / StubExit sync |
| Windows Credential Manager | ⚠️ Partial | Falls back to plaintext under Wine |
| Registry (MachineGuid) | ✅ Mature | Device ID generation (per-prefix stable) |

### Lutris Setup

```
Lutris Wine prefix (e.g. ~/Games/mabinogi)
└── drive_c/
    ├── Nexon3PAPI.dll      ← place alongside your launcher
    ├── nxl3p_shim.dll       ← deployed as bin\nexon_x64.dll (Wine handles it)
    ├── nxl3p_stub.exe       ← deployed as nexon_client.exe (runs under Wine)
    └── Program Files (x86)/
        └── Mabinogi/
            └── Client.exe   ← launched via ShellExecuteEx → works in Proton
```

### Launching Your App

```python
#!/usr/bin/env python3
# Run this via Lutris → "Run EXE inside Wine prefix" or add as custom executable
import ctypes, os

# Wine maps the DLL from drive_c as normal
dll = ctypes.WinDLL("Nexon3PAPI.dll")
dll.Nexon3PAPI_Init(b"/home/me/.config/mylauncher", None)

# Everything else is identical to Windows usage
```

Or use a shell wrapper:
```bash
#!/bin/bash
# Add to Lutris as a custom executable
WINEPREFIX=~/Games/mabinogi wine python /path/to/launcher.py
```

### Device ID on Wine

`GetDeviceId` reads `MachineGuid` from the Wine prefix's registry. This value
is stable per prefix but differs from Windows. That's fine — per-prefix device
IDs prevent session conflicts. If you migrate prefixes, generate a new device
ID and re-login.

### Credential Storage

The DLL does not store credentials (app's responsibility). On Windows,
`uCredStore` uses `CredWriteW`/`CredReadW` (Windows Credential Manager).
Under Wine, CredManager falls back to plaintext storage in the prefix.
For production Linux use, implement your own secure store (libsecret,
encrypted file, etc.).

### Known Limitation

`GetDeviceId` calls `wmic csproduct get uuid` under the hood. Under Wine,
`wmic` may not be available. The function handles this gracefully — if the
UUID can't be read, it uses the MachineGuid + tag only (still a valid 64-char
SHA256 hash). Output is deterministic and stable for the same prefix + tag.

## Building External Consumers

- Link against `Nexon3PAPI.dll` as a dynamic library (`LoadLibrary`/`GetProcAddress`
  or your language's equivalent)
- No import library (.lib) needed — all functions are resolved at runtime
- Use the exported names exactly as listed in this doc
- Calling convention: `stdcall` on x86, `stdcall` on x64 (same on both platforms)
