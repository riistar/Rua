# RuaAPI.dll — DLL API Reference

`RuaAPI.dll` exposes Rua's core functionality (login, session check, manifest
check, patching, game launch) as a set of C-compatible `__stdcall` exports.

---

## Building

```powershell
powershell -File build/delphi.ps1 -Project delphi/RuaAPI.dpr
```

The DLL and its import library `RuaAPI.lib` land in the `bin\` folder next to
the project root.

---

## C Header

Copy `delphi/RuaAPI.h` into your project and link against `RuaAPI.dll`.

```c
#include "RuaAPI.h"
#pragma comment(lib, "RuaAPI.lib")
```

Or load dynamically:

```c
HMODULE dll = LoadLibraryW(L"RuaAPI.dll");
typedef int (__stdcall *FnRuaLogin)(...);
FnRuaLogin RuaLogin = (FnRuaLogin)GetProcAddress(dll, "RuaLogin");
```

---

## Return codes

| Constant | Value | Meaning |
|---|---|---|
| `RUA_OK` | 0 | Success / session valid / up-to-date |
| `RUA_ERR` | 1 | Generic error — call `RuaGetLastError` |
| `RUA_MFA` | 2 | MFA required (`RuaLogin` only) |
| `RUA_CAPTCHA` | 3 | CAPTCHA block — use GUI browser login |
| `RUA_UPDATE` | 4 | Update available (`RuaCheckUpdate` only) |
| `RUA_EXPIRED` | 5 | Session expired (`RuaSessionCheck` only) |

---

## API Reference

### `RuaLogin`

Log in with email + password.

```c
int __stdcall RuaLogin(
    const wchar_t *email,
    const wchar_t *password,
    const wchar_t *device_id,     /* NULL = auto-derive from machine hardware */
    wchar_t       *cookies_out,
    int            cookies_size,  /* wchar_t capacity, including NUL */
    wchar_t       *mfa_key_out,   /* filled when RUA_MFA returned; may be NULL */
    int            mfa_key_size,
    wchar_t       *mfa_type_out,  /* filled when RUA_MFA returned; may be NULL */
    int            mfa_type_size
);
```

**Returns** `RUA_OK`, `RUA_MFA`, `RUA_CAPTCHA`, or `RUA_ERR`.

When `RUA_MFA` is returned, pass `mfa_key_out` to `RuaLoginOTP` together with
the user's one-time password.

**Example**

```c
wchar_t cookies[2048] = {0};
wchar_t mfa_key[256]  = {0};
wchar_t mfa_type[64]  = {0};

int rc = RuaLogin(
    L"alice@example.com", L"hunter2", NULL,
    cookies, 2048,
    mfa_key, 256,
    mfa_type, 64);

if (rc == RUA_OK)   { /* use cookies */ }
if (rc == RUA_MFA)  { /* prompt user for OTP, then call RuaLoginOTP */ }
if (rc == RUA_ERR)  { wchar_t err[512]; RuaGetLastError(err, 512); /* log err */ }
```

---

### `RuaLoginOTP`

Submit a one-time password after `RuaLogin` returned `RUA_MFA`.

```c
int __stdcall RuaLoginOTP(
    const wchar_t *mfa_key,
    const wchar_t *otp,
    const wchar_t *device_id,
    wchar_t       *cookies_out,
    int            cookies_size
);
```

**Returns** `RUA_OK` or `RUA_ERR`.

---

### `RuaSessionCheck`

Verify that a stored cookie string is still accepted by the server.

```c
int __stdcall RuaSessionCheck(
    const wchar_t *cookies,
    int           *http_status   /* may be NULL */
);
```

**Returns** `RUA_OK` (valid) or `RUA_EXPIRED`.

---

### `RuaCheckUpdate`

Compare the remote manifest hash against the locally installed version.

```c
int __stdcall RuaCheckUpdate(
    const wchar_t *cookies,
    int            product_id,           /* 10200 = Mabinogi */
    const wchar_t *install_root,         /* path with patchdata\ sub-folder; NULL = skip local check */
    wchar_t       *manifest_hash_out,
    int            manifest_hash_size
);
```

**Returns** `RUA_OK` (up to date), `RUA_UPDATE` (update available), or `RUA_ERR`.

Cookies are used only for the initial API request; CDN downloads are
unauthenticated. Pass `L""` if you have no session.

---

### `RuaRunPatcher`

Download and apply pending updates.  Synchronous — returns when the patch
finishes (or is cancelled).

```c
typedef void (__stdcall *RuaProgressCb)(int current, int total, const wchar_t *filename);
typedef int  (__stdcall *RuaCancelCb)(void);  /* return non-zero to cancel */

int __stdcall RuaRunPatcher(
    const wchar_t *manifest_hash,  /* from RuaCheckUpdate */
    const wchar_t *install_root,
    int            product_id,
    int            force_all,       /* 1 = re-download everything */
    RuaProgressCb  progress_cb,     /* may be NULL */
    RuaCancelCb    cancel_cb        /* may be NULL */
);
```

**Returns** `RUA_OK` or `RUA_ERR`.

**Example**

```c
void __stdcall OnProgress(int cur, int total, const wchar_t *fname)
{
    wprintf(L"\r  [%d/%d] %s   ", cur, total, fname);
}

int rc = RuaRunPatcher(
    hash, L"E:\\mabinogi2\\appdata", 10200,
    0,           /* changed files only */
    OnProgress,
    NULL         /* no cancel */
);
```

---

### `RuaLaunch`

Launch the game.  **Synchronous** — this function blocks until the game
process exits.  The passport handshake and named-pipe server run internally.

```c
int __stdcall RuaLaunch(
    const wchar_t *cookies,
    int            product_id,
    const wchar_t *game_exe    /* full path to Client.exe */
);
```

**Returns** `RUA_OK` (game ran and exited normally) or `RUA_ERR`.

---

### `RuaGetLastError`

Retrieve a human-readable description of the last error.

```c
void __stdcall RuaGetLastError(wchar_t *buf, int buf_size);
```

Always safe to call; returns an empty string if no error has occurred.

---

## Python example

```python
import ctypes, ctypes.wintypes

rua = ctypes.WinDLL("RuaAPI.dll")
rua.RuaLogin.restype  = ctypes.c_int
rua.RuaLogin.argtypes = [
    ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p,
    ctypes.c_wchar_p, ctypes.c_int,
    ctypes.c_wchar_p, ctypes.c_int,
    ctypes.c_wchar_p, ctypes.c_int,
]

cookies  = ctypes.create_unicode_buffer(2048)
mfa_key  = ctypes.create_unicode_buffer(256)
mfa_type = ctypes.create_unicode_buffer(64)

rc = rua.RuaLogin(
    "alice@example.com", "hunter2", None,
    cookies, 2048,
    mfa_key, 256,
    mfa_type, 64,
)

if rc == 0:      # RUA_OK
    print("Cookies:", cookies.value)
elif rc == 2:    # RUA_MFA
    otp = input(f"OTP ({mfa_type.value}): ")
    # ... call RuaLoginOTP
```

---

## Thread safety

Each function is self-contained and synchronous.  You may call them from any
thread, but concurrent calls to the same function are not supported — serialize
if you need multiple simultaneous operations.
