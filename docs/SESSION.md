# Nexon Session / Login / Account Flow

---

## Overview

Nexon uses a layered token system. Two login paths exist depending on account type.
Both produce the same `NxLSession` + `AToken` session tokens used for all game API calls.

```
Path A — Browser (TPA/Google/social):
  nexon.com browser login
    → TpaSession cookie (short-lived, browser-side)
  Exchange  POST /api/account/v1/no-auth/login/tpa/launcher
    → NxLSession (months)  +  AToken (~2hr)  +  NexonUserID
  NOTE: autologin refresh does NOT work for TPA accounts (error 20182).

Path B — Email / Password:
  POST /api/account/v1/no-auth/login/launcher
    → 200: NxLSession + AToken  (done)
    → 206: mfaKey (OTP required)
  [if OTP]
  POST /api/account/v1/no-auth/login/launcher/otp
    → NxLSession + AToken  (done)
  Autologin refresh WORKS for email/password accounts.

Both paths → same downstream cookie string for API calls:
  NxLSession + AToken (+ NexonUserID + g_AToken + NxGUN)

AToken expires (~2hr)  POST /api/account/v1/no-auth/login/launcher/autologin
  → fresh AToken  (email/password only; TPA must re-login via browser)

AToken used as Bearer header on:
  - FetchPassport
  - FetchGameConfig
  - CheckPlayable
```

---

## Token reference

| Cookie        | Lifetime  | Purpose                                              |
|---------------|-----------|------------------------------------------------------|
| `TpaSession`  | Short     | Browser auth session; exchanged once for NxLSession  |
| `NxLSession`  | Months    | Long-lived launcher session; refreshes AToken        |
| `AToken`      | ~2 hours  | API access token; Bearer header on authenticated calls |
| `g_AToken`    | ~2 hours  | Secondary access token (game-specific variant)       |
| `NexonUserID` | Permanent | Hashed user number (`base64(SHA256(user_no))`)       |
| `id_token`    | Session   | OIDC ID token; may not always be present             |
| `NxGUN`       | Session   | Nexon game user number; supplementary                |

---

## Step 1A — Browser login (TPA / Google / social accounts)

User visits `https://www.nexon.com` and logs in via the system browser. After successful
login the browser stores cookies for `.nexon.com`. We read those cookies directly.

### Cookie extraction (priority order)

**Firefox** (plaintext SQLite):
```
%APPDATA%\Mozilla\Firefox\Profiles\<profile>\cookies.sqlite
Table: moz_cookies  WHERE host LIKE '%nexon.com'
```
Profile selection order:
1. `[Install*] Default=` entry in profiles.ini (active Firefox installation's profile)
2. `[Profile*] Default=1` flag
3. Any profile directory containing `cookies.sqlite`

WAL mode: multiple readers allowed concurrently with Firefox. No copy needed in most cases.
Fallback: copy snapshot to `%TEMP%\nlp_ff_cookies.sqlite` if live open fails.
Fallback 2: if SQLite has 0 rows (Firefox hasn't committed yet), scan live `firefox.exe`
process memory via `ReadProcessMemory`.

**Chrome / Edge / Brave** (encrypted SQLite):
```
Chrome: %LOCALAPPDATA%\Google\Chrome\User Data\Default\Network\Cookies
Edge:   %LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Network\Cookies
Brave:  %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Network\Cookies
```

Master key location (same base dir):
```
Local State  →  os_crypt.encrypted_key  (base64)
→ strip 5-byte "DPAPI" prefix → DPAPI decrypt → 32-byte AES-256 key
```

Cookie encryption format:
```
v10 prefix (bytes 0-2 = 'v','1','0') → AES-256-GCM
  Layout: "v10" + [12-byte IV] + [ciphertext] + [16-byte GCM tag]
  Decrypt with BCrypt AES-GCM using master key above.

v20 prefix (Chrome 127+ App-Bound Encryption) → cannot decrypt from outside Chrome.
  Chrome 127+ moves the master key into a privileged service. The key in Local State
  is no longer the actual decryption key.

Legacy (no version prefix) → raw DPAPI blob → CryptUnprotectData.
```

**Chrome 127+ fallback — process memory scan (RVM):**
When SQLite extraction yields no `NxLSession` or `TpaSession` (v20 blocks decrypt),
scan all PIDs named `chrome.exe` / `msedge.exe` / `brave.exe` via `ReadProcessMemory`.
After the user logs in, decrypted cookie strings exist in the browser's network service
process heap. Scan private committed pages (≤ 64 MB) for ASCII patterns `Name=Value`.

Cookies searched for (exit early when `NxLSession` or `TpaSession` found):
```
NxLSession, AToken, g_AToken, NexonUserID, id_token, TpaSession
```

---

## Step 2A — TPA exchange (TpaSession → NxLSession + AToken)

If browser login yields a `TpaSession`, exchange it immediately (it expires fast):

```
POST https://www.nexon.com/api/account/v1/no-auth/login/tpa/launcher
Cookie: TpaSession=<value>
Content-Type: application/json

{
  "clientId":   "7853644408",
  "deviceId":   "<machine_device_id>",
  "localTime":  <unix_ms>,
  "timeOffset": <tz_bias_minutes>
}
```

`clientId = "7853644408"` is the hardcoded Nexon Launcher client ID.  
`timeOffset` — Windows `TIME_ZONE_INFORMATION.Bias` (positive = west of UTC).

**Success (HTTP 200)**:
`Set-Cookie` returns `NxLSession`, `AToken`, `NxGUN`, `g_AToken`.
`NexonUserID` may come from `Set-Cookie` or from `hashedUserNo` in the JSON body.

The captured cookie string is stored in Windows Credential Manager and used for all
subsequent API calls without re-login.

**Autologin limitation for TPA accounts:**
The autologin refresh endpoint (`/launcher/autologin`) returns error `20182` for accounts
that logged in via TPA/Google. When `AToken` expires, re-detect browser cookies instead
(user may still have an active browser session and a fresh `TpaSession` will appear after
they visit nexon.com). If browser session is gone, prompt full re-login.

---

## Step 1B — Email / Password login

For accounts using email + password (not Google/social):

```
POST https://www.nexon.com/api/account/v1/no-auth/login/launcher
Content-Type: application/json

{
  "id":         "<email_or_username>",
  "password":   "<password>",
  "deviceId":   "<machine_device_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200 — success**: `NxLSession` + `AToken` in `Set-Cookie`. Done.

**HTTP 206 — MFA required**:
```json
{ "mfaKey": "<opaque>", "mfaType": "email" }
```

**Error codes (non-200/206)**:

| Code  | Meaning |
|-------|---------|
| 1013  | CAPTCHA required |
| 70018 | CAPTCHA required |
| 70019 | CAPTCHA required |

CAPTCHA can't be completed via API — user must complete it in a browser first.

### Step 2B — OTP submission (if 206)

```
POST https://www.nexon.com/api/account/v1/no-auth/login/launcher/otp
Content-Type: application/json

{
  "mfaKey":     "<value_from_206>",
  "otp":        "<6_digit_code>",
  "deviceId":   "<machine_device_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200**: `NxLSession` + `AToken` in `Set-Cookie`. Done.  
**Non-200**: Bad/expired OTP — re-start from Step 1B for a fresh `mfaKey`.

---

## Step 3 — AToken refresh (autologin)

`AToken` expires in approximately 2 hours. On HTTP 401, try autologin first:

```
POST https://www.nexon.com/api/account/v1/no-auth/login/launcher/autologin
Cookie: NxLSession=<value>
Content-Type: application/json

{
  "deviceId":   "<machine_device_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200**: New `AToken` (and possibly refreshed `NxLSession`) via `Set-Cookie`.  
**Non-200**: `NxLSession` expired **or** account is TPA/social (error 20182) — must re-login.

---

## Step 4 — API calls (authenticated)

All authenticated endpoints at `https://www.nexon.com/api`.
All require cookies + `Authorization: Bearer <AToken>` where applicable.
User-Agent: `NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0`

### CheckPlayable — must be called before FetchPassport

```
POST /api/game-auth2/v1/playable
Body: {"productId":"10200"}
Cookies: <session cookies>
```
Returns HTTP 400 if product not playable; other codes = playable.
**Must be called first** — sets a server-side flag that FetchPassport checks.

### FetchPassport — get the launch token

```
POST /api/passport/v2/passport
Authorization: Bearer <AToken>
Cookies: <session cookies>
Body: {"productId":"10200"}

Response: {"passport":"<opaque_token>"}
```

Passport token:
1. Served over named pipe as `getProductTicket` response
2. Substituted into `${passport}` in game launch parameters

The old `/game-auth/v2/ticket` endpoint (v1 API) is dead — returns HTML 200.

### FetchGameConfig — launch parameters

```
GET /api/game-build/v1/configuration/games/10200
Authorization: Bearer <AToken>

Response:
{
  "executablePath":   "client.exe",
  "workingDirectory": "",
  "directoryName":    "",
  "parameter":        ["/P:${passport}", "/L:...", ...]
}
```

### FetchBranchInfo / FetchManifestHash — update check

```
GET /api/game-build/v1/branch/games/10200/public
→ {manifestUrl: "http://download2.nexon.net/Game/nxl/games/10200/<current_hash>"}

GET <manifestUrl>
→ raw content = current manifest hash string
```

Compare against locally cached hash. Equal = up to date. Different = update needed.

---

## Storage

### Windows Credential Manager

Cookies stored encrypted by OS, per-user:
```
Target key:  <AppName>\{ProfileName}
Type:        CRED_TYPE_GENERIC
Persist:     CRED_PERSIST_LOCAL_MACHINE
Blob:        UTF-8 encoded "Name=Value; Name2=Value2; ..." cookie string
```

API: `CredWriteW` / `CredReadW` / `CredDeleteW` (advapi32.dll)

### DeviceId

Stable per-machine+profile identifier. Using profile name as a hash tag prevents
two profiles sharing the same deviceId (sharing deviceIds causes session invalidation —
Hyddwn's "enableTagging" approach).

---

## Session lifecycle diagram

```
Path A — TPA/Google first login:
  Browser login at nexon.com
    → browser cookies: TpaSession (+ maybe NxLSession/AToken)

  If TpaSession present → ExchangeTpaForNxLSession()
    POST /api/account/v1/no-auth/login/tpa/launcher
    → NxLSession (months) + AToken (~2hr) + NexonUserID

  Store in Credential Manager.

Path B — Email/password first login:
  LoginEmailPassword()
    POST /api/account/v1/no-auth/login/launcher
    → 200: NxLSession + AToken  (done)
    → 206: mfaKey  →  LoginOTP()
      POST /api/account/v1/no-auth/login/launcher/otp
      → 200: NxLSession + AToken  (done)

  Store in Credential Manager.

Each launch (both paths):
  LoadCookies(ProfileName) → cookie string
  CheckPlayable()           → sets server-side flag
  FetchPassport()           → passport token  (AToken Bearer required)
    401? →
      Path A: re-check browser cookies for fresh TpaSession → exchange → retry
      Path B: AutoLoginRefresh() → new AToken → retry FetchPassport()
    still 401? → ask user to re-login

  FetchGameConfig()         → launch parameters
  Launch game executable

AToken expires (~2hr):
  Path B: autologin refresh works
  Path A: must re-detect TpaSession from browser (or prompt re-login)

NxLSession / browser session expires:
  Both paths: full re-login required
```
