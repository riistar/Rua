# Nexon Launcher Auth API

Reverse-engineered from Nexon Launcher `nxl-release-18.14.10-220-fc7480c`.
All endpoints: `https://www.nexon.com/api`

---

## User-Agent

All requests must send:
```
User-Agent: NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0
```
Nexon's backend likely rejects or de-prioritises unknown UAs.

---

## Token overview

| Cookie / Token | Lifetime   | Notes |
|----------------|------------|-------|
| `TpaSession`   | Short       | Set by browser after nexon.com login. Used once for exchange. |
| `NxLSession`   | Months      | Long-lived launcher session. Refreshes AToken without re-login. |
| `AToken`       | ~2 hours    | Access token. Required as Bearer header on authenticated endpoints. |
| `g_AToken`     | ~2 hours    | Alternate access token variant. Returned alongside AToken. |
| `NexonUserID`  | Permanent   | Hashed user identifier. `base64(SHA256(raw_user_no))`. |
| `id_token`     | Session     | OIDC ID token. Not always present. |
| `NxGUN`        | Session     | Nexon game user number. Supplementary. |

Minimum set needed to make API calls: `NxLSession` + `AToken`.

---

## Login paths

Two ways to obtain `NxLSession` + `AToken`. Both produce the same usable session.

| Path | Works with | Autologin refresh |
|------|-----------|-------------------|
| Browser → TPA exchange | Google / social / all account types | No (returns error 20182) |
| Email / password API | Email+password accounts only | Yes |

Pick the path that matches the user's account type. Both produce identical downstream cookies.

---

## Path A — Browser login + TPA exchange

### Step A1 — Browser login

Direct the user to log into `https://www.nexon.com` in any browser. After successful
login the browser stores session cookies for `.nexon.com`.

Read those cookies and check:
- `NxLSession` already present → already have a valid session, skip exchange.
- `TpaSession` present → proceed to exchange (Step A2).
- Neither present → user hasn't logged in yet.

### Step A2 — TPA exchange

```
POST /api/account/v1/no-auth/login/tpa/launcher
Content-Type: application/json
Cookie: TpaSession=<value>

{
  "clientId":   "7853644408",
  "deviceId":   "<stable_machine_id>",
  "localTime":  <unix_epoch_milliseconds>,
  "timeOffset": <tz_bias_minutes>
}
```

`clientId` = `"7853644408"` — hardcoded Nexon Launcher application ID.  
`deviceId` — any stable per-machine identifier.  
`timeOffset` — minutes west of UTC (Windows `TIME_ZONE_INFORMATION.Bias`; positive = west).  
`TpaSession` expires in seconds — do the exchange immediately after detecting it.

**Success — HTTP 200**

Tokens returned via `Set-Cookie` response headers:
```
NxLSession=...; AToken=...; g_AToken=...; NxGUN=...
```

`NexonUserID` may be in cookies **or** in the JSON response body:
```json
{ "hashedUserNo": "<base64_sha256>" }
```

Collect all into a single cookie string for subsequent requests.

**Autologin limitation:** TPA/social-login accounts do NOT support the autologin refresh
endpoint — it returns error `20182`. When `NxLSession` expires or `AToken` can't be refreshed,
the user must re-login via browser.

---

## Path B — Email / password login

For accounts using email + password (not Google/social). Supports MFA (OTP) and detects
captcha requirements.

### Step B1 — Submit credentials

```
POST /api/account/v1/no-auth/login/launcher
Content-Type: application/json

{
  "id":         "<email_or_username>",
  "password":   "<password>",
  "deviceId":   "<stable_machine_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200 — success**

Same cookie response as TPA exchange. `NxLSession` + `AToken` in `Set-Cookie`. Done.

**HTTP 206 — MFA required**

One-time password required before session is granted:
```json
{
  "mfaKey":  "<opaque_key>",
  "mfaType": "email"
}
```

Store `mfaKey` and proceed to Step B2.

**Other status codes — error**

Response body contains a `code` field. Known codes:

| Code  | Meaning |
|-------|---------|
| 1013  | CAPTCHA required |
| 70018 | CAPTCHA required |
| 70019 | CAPTCHA required |
| other | Wrong credentials or account issue |

CAPTCHA cannot be completed programmatically. The user must log in via browser,
solve the CAPTCHA there, and either import browser cookies or retry credentials
after the CAPTCHA session is established.

### Step B2 — Submit OTP (if Step B1 returns 206)

```
POST /api/account/v1/no-auth/login/launcher/otp
Content-Type: application/json

{
  "mfaKey":     "<value_from_206_response>",
  "otp":        "<6_digit_code_from_email_or_app>",
  "deviceId":   "<stable_machine_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200 — success**: `NxLSession` + `AToken` in `Set-Cookie`. Same as direct login.  
**Other**: OTP wrong or expired — user must retry Step B1 to get a fresh `mfaKey`.

**Autologin support:** Email/password accounts CAN use the autologin refresh endpoint
(Step 3 below). `NxLSession` from this path is long-lived and auto-refreshes `AToken`.

---

## Step 3 — Refresh AToken (autologin)

`AToken` expires in ~2 hours. On HTTP 401, refresh using the stored `NxLSession`.

> **Important:** Only works for email/password accounts. TPA/social accounts return
> error `20182` — those must re-login via browser.

```
POST /api/account/v1/no-auth/login/launcher/autologin
Content-Type: application/json
Cookie: NxLSession=<value>

{
  "deviceId":   "<stable_machine_id>",
  "deviceType": "PC",
  "locale":     "en"
}
```

**HTTP 200 — success**: New `AToken` (and possibly refreshed `NxLSession`) in `Set-Cookie`.  
**Non-200**: `NxLSession` expired — user must re-login.

---

## Step 4 — Check playable (required before passport)

Must be called before `FetchPassport`. Sets a server-side session flag.

```
POST /api/game-auth2/v1/playable
Content-Type: application/json
Cookie: <session cookies>

{
  "productId": "10200"
}
```

| Status | Meaning |
|--------|---------|
| 400    | Product not playable for this account |
| other  | Playable (treat non-400 as success) |

---

## Step 5 — Fetch passport (launch token)

The passport is the opaque token the game uses to authenticate the launch session.
It goes into the named pipe response AND into the game's command-line `/P:` argument.

```
POST /api/passport/v2/passport
Authorization: Bearer <AToken>
Content-Type: application/json
Cookie: <session cookies>

{
  "productId": "10200"
}
```

**Success — HTTP 200**
```json
{ "passport": "<opaque_token_string>" }
```

**HTTP 401** → refresh AToken (Step 3) and retry once.

> **Note:** The older `/game-auth/v2/ticket` endpoint is dead — returns HTML 200 with no
> useful content. `passport/v2/passport` is the correct endpoint as of 2024.

---

## Step 6 — Fetch game configuration

Returns the executable path and launch parameters (with `${passport}` template).

```
GET /api/game-build/v1/configuration/games/10200
Authorization: Bearer <AToken>
Cookie: <session cookies>
```

**Response:**
```json
{
  "executablePath":   "client.exe",
  "workingDirectory": "",
  "directoryName":    "",
  "parameter": [
    "/P:${passport}",
    "/L:en",
    ...
  ]
}
```

Substitute `${passport}` with the value from Step 5 before constructing the command line.

---

## Update check (optional)

### Get branch info

```
GET /api/game-build/v1/branch/games/10200/public
Cookie: <session cookies>
```

**Response:**
```json
{
  "branchName":  "public",
  "manifestUrl": "http://download2.nexon.net/Game/nxl/games/10200/<hash>",
  "releaseDate": "...",
  "serviceId":   "..."
}
```

### Get current manifest hash

```
GET <manifestUrl>   (plain HTTP, no auth)
```

Response body is the raw manifest hash string (hex). Compare against the locally cached
hash. If different (or file missing), update is available.

### Download manifest

```
GET http://download2.nexon.net/Game/nxl/games/10200/<hash>
```

Response: zlib-compressed JSON. Decompress to get file list.

```json
{
  "files": {
    "<base64_filename>": {
      "fsize":        123456,
      "mtime":        1700000000,
      "objects":      ["<part_hash>", ...],
      "objects_fsize":[12345, ...]
    }
  }
}
```

**Filename decode:**
```
bytes  = base64_decode(key)           // result is UTF-16LE encoded string
utf8   = utf16le_to_utf8(bytes)
name   = utf8[3:].rstrip()            // skip 3-byte UTF-8 BOM (EF BB BF)
```

### Download file parts

```
GET https://download2.nexon.net/Game/nxl/games/10200/10200/{hash[0:2]}/{hash}
```

Each part is a compressed chunk. Parts within a file can be downloaded in parallel.
File paths in the manifest are relative to the game's install root directory.

**Change detection:** use `fsize` (file size) rather than `mtime` — mtime values are
unreliable and trigger false full-re-downloads.

---

## Full flow summary

### Email/password account
```
1. POST /api/account/v1/no-auth/login/launcher
   Body: { id, password, deviceId, deviceType:"PC", locale:"en" }
   → 200: NxLSession + AToken  (done)
   → 206: mfaKey + mfaType

   [if 206]
   POST /api/account/v1/no-auth/login/launcher/otp
   Body: { mfaKey, otp, deviceId, deviceType:"PC", locale:"en" }
   → 200: NxLSession + AToken  (done)

2. Store NxLSession + AToken securely.

3. Each launch:
   a. POST /api/game-auth2/v1/playable   { productId: "10200" }
   b. POST /api/passport/v2/passport     { productId: "10200" }  Bearer: AToken
      → passport token
   c. GET  /api/game-build/v1/configuration/games/10200  Bearer: AToken
      → launch parameters (substitute ${passport})
   d. Launch game executable.

4. AToken expired (HTTP 401 on any call):
   POST /api/account/v1/no-auth/login/launcher/autologin
   Body: { deviceId, deviceType:"PC", locale:"en" }
   Cookie: NxLSession=X
   → fresh AToken → retry failed call

5. NxLSession expired (autologin returns non-200):
   → re-prompt user for credentials (back to step 1)
```

### Browser (TPA/Google) account
```
1. User logs into nexon.com in browser

2. Read browser cookies → find TpaSession
   POST /api/account/v1/no-auth/login/tpa/launcher
   Body: { clientId:"7853644408", deviceId, localTime, timeOffset }
   Cookie: TpaSession=X
   → NxLSession + AToken

3. Store NxLSession + AToken securely.

4. Each launch: same as email/password steps 3a–3d above.

5. AToken expired (HTTP 401):
   Autologin DOES NOT work for TPA accounts (error 20182).
   → Re-detect TpaSession from browser (user must have active browser session)
   → Or prompt user to re-login via browser

6. NxLSession expired or browser session gone:
   → Re-open nexon.com in browser → user logs in → new TpaSession → exchange
```

---

## Cookie header format

All cookie values sent as a single `Cookie` header, semicolon-separated:
```
Cookie: NxLSession=abc123; AToken=xyz789; NexonUserID=hashed==
```

Cookies are scoped to `.nexon.com`.

---

## Product IDs

| Game          | Product ID |
|---------------|-----------|
| Mabinogi NA   | 10200     |

Other Nexon titles follow the same flow with their respective product IDs.

---

## DeviceId

Stable per-machine identifier sent in every auth request body.
Should be consistent across sessions for the same machine+profile.
Any deterministic hash of stable machine properties works (UUID + machine GUID, etc.).
Using a per-profile tag in the hash prevents two profiles from sharing a deviceId
(which causes session invalidation — "enableTagging" approach).
