# Rua CLI Reference

Rua includes a headless CLI mode for scripting, automation, and integration
with external tools (launchers, game managers, CI scripts).

```
Rua.exe --cli <command> [options]
```

## Requirements

- A profile must exist (created via the GUI) before using `launch` or session-
  dependent commands.
- Credentials are stored in Windows Credential Manager, same as the GUI.
- Config and profiles are shared with the GUI (`%APPDATA%\Rua\`).

---

## Commands

### `login`

Check or refresh the stored session for a profile, or log in with credentials.

```
Rua.exe --cli login [--profile NAME] [--email E --password P]
```

**Options**

| Option | Description |
|---|---|
| `--profile NAME` | Profile to use. Defaults to the first profile. |
| `--email E` | Email address (required with `--password`). |
| `--password P` | Password (required with `--email`). |

**Behaviour**

- With `--email` + `--password`: performs a direct login and saves the cookies
  to the named profile (creates the profile if it does not exist).
- Without credentials: checks the stored session; attempts an autologin refresh
  if it has expired (works only for email/password accounts, not Google/TPA).

**MFA / two-factor**

If the server requires an OTP, the command prints the MFA key and exits with
code 1. Submit the OTP with `login-otp`:

```
Rua.exe --cli login-otp --mfa-key KEY --otp 123456 [--profile NAME]
```

**CAPTCHA**

If a CAPTCHA is required, the command exits with an error. Use the GUI browser
login to authenticate, then switch back to CLI for other operations.

**Exit codes:** `0` = success, `1` = error.

---

### `login-otp`

Submit a one-time password after `login` returned an MFA challenge.

```
Rua.exe --cli login-otp --mfa-key KEY --otp CODE [--profile NAME]
```

| Option | Description |
|---|---|
| `--mfa-key KEY` | Key printed by `login`. |
| `--otp CODE` | 6-digit code from your authenticator app. |
| `--profile NAME` | Profile to save the session to. |

**Exit codes:** `0` = success, `1` = error.

---

### `check-update`

Check whether the remote game version differs from the local installation.

```
Rua.exe --cli check-update [--profile NAME] [--game-path PATH] [--product-id N]
```

| Option | Description |
|---|---|
| `--profile NAME` | Profile for session cookies. Defaults to first profile. |
| `--game-path PATH` | Path to the folder containing `patchdata\`. |
| `--product-id N` | Nexon product ID (default `10200` for Mabinogi). |

**Output**

Prints the remote manifest hash. If `--game-path` is given, also compares
against the locally stored hash.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Up to date. |
| `1` | Error. |
| `2` | Update available. |

**Example — shell scripting**

```powershell
Rua.exe --cli check-update --game-path "E:\mabinogi2\appdata"
if ($LASTEXITCODE -eq 2) {
    Rua.exe --cli update --game-path "E:\mabinogi2\appdata"
}
```

---

### `update`

Download and apply pending game updates.

```
Rua.exe --cli update --game-path PATH [--profile NAME] [--force-all] [--verify] [--product-id N]
```

| Option | Description |
|---|---|
| `--game-path PATH` | **Required.** Path to the folder containing `patchdata\`. |
| `--profile NAME` | Profile for session cookies (CDN downloads are unauthenticated). |
| `--force-all` | Re-download every file regardless of local state. |
| `--verify` | Repair mode: re-check every file and replace size-mismatched ones. |
| `--product-id N` | Nexon product ID (default `10200`). |

Progress is printed in-place on a single line during the download.

**Exit codes:** `0` = done, `1` = error.

---

### `launch`

Launch the game headlessly. The command blocks until the game process exits.

```
Rua.exe --cli launch [--profile NAME] [--game-path PATH] [--product-id N]
```

| Option | Description |
|---|---|
| `--profile NAME` | Profile to use. Defaults to first profile. |
| `--game-path PATH` | Full path to `Client.exe`. Falls back to the profile's saved path. |
| `--product-id N` | Nexon product ID (default `10200`). |

**Exit codes:** `0` = launched and exited normally, `1` = error.

---

## Common options

| Option | Description | Default |
|---|---|---|
| `--profile NAME` | Which profile to use | First profile |
| `--game-path PATH` | Path to `Client.exe` or its parent folder | Profile setting |
| `--product-id N` | Nexon product ID | `10200` (Mabinogi) |

---

## Examples

```powershell
# Log in and save credentials to profile "Alice"
Rua.exe --cli login --profile Alice --email alice@example.com --password hunter2

# Check for updates and patch if needed
Rua.exe --cli check-update --profile Alice --game-path "E:\mabinogi2\appdata"
Rua.exe --cli update  --profile Alice --game-path "E:\mabinogi2\appdata"

# Launch the game
Rua.exe --cli launch --profile Alice --game-path "E:\mabinogi2\appdata\Client.exe"

# Scripted check-and-patch-and-launch (PowerShell)
$path = "E:\mabinogi2\appdata"
Rua.exe --cli check-update --game-path $path
if ($LASTEXITCODE -eq 2) {
    Rua.exe --cli update --game-path $path
}
Rua.exe --cli launch --game-path "$path\Client.exe"
```

---

## Event hooks

Hook commands run before/after patch and before/after launch. They are
configured in **Settings → Event hook commands** or directly in
`%APPDATA%\Rua\config.ini` under the `[Hooks]` section:

```ini
[Hooks]
BeforePatch=C:\Scripts\before-patch.bat %PROFILE%
AfterPatch=C:\Scripts\after-patch.bat %PROFILE%
BeforeLaunch=C:\Scripts\before-launch.bat %PROFILE%
AfterLaunch=C:\Scripts\after-launch.bat %PROFILE%
```

`%PROFILE%` is replaced with the active profile name at runtime. Hooks run
fire-and-forget (the launcher does not wait for them to finish).
