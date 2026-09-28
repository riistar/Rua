# Rua CLI Reference

Rua includes a headless CLI mode for scripting, automation, and integration
with external tools (launchers, game managers, CI scripts).

```
Rua.exe --cli <command> [options]
```

## Requirements

**Email/password accounts** â€” no GUI setup needed. `login --email E --password P`
creates a profile on first run. All commands work entirely from the CLI.

**TPA / Google / browser accounts** â€” GUI required once to capture the initial
session cookie. After that, `check-update`, `update`, and `launch` work headlessly
until the session expires. No CLI path to re-authenticate TPA accounts (auto-refresh
works only for email/password; TPA returns error 20182).

- Credentials stored in Windows Credential Manager, same as GUI.
- Config and profiles shared with GUI (`%APPDATA%\Rua\`).
- Event hooks configured in `%APPDATA%Ruanfig.ini` fire in both GUI and CLI modes.

---

## Commands

### `login`

Check/refresh stored session or log in with credentials.

```
Rua.exe --cli login [--profile NAME] [--email E --password P]
```

| Option | Description |
|---|---|
| `--profile NAME` | Profile to use. Defaults to first profile. |
| `--email E` | Email (required with `--password`). |
| `--password P` | Password (required with `--email`). |

- With `--email` + `--password`: logs in, saves cookies, creates profile if needed.
- Without credentials: checks stored session; attempts autologin refresh if expired
  (email/password only â€” not TPA/Google).

**MFA:** server returns OTP challenge â†’ command prints MFA key and exits 1.
Submit with `login-otp`:
```
Rua.exe --cli login-otp --mfa-key KEY --otp 123456 [--profile NAME]
```

**CAPTCHA:** exits with error. Use GUI browser login, then return to CLI.

Exit codes: `0` success, `1` error.

---

### `login-otp`

Submit OTP after `login` returned an MFA challenge.

```
Rua.exe --cli login-otp --mfa-key KEY --otp CODE [--profile NAME]
```

Exit codes: `0` success, `1` error.

---

### `check-update`

Check whether remote game version differs from local install.

```
Rua.exe --cli check-update [--profile NAME] [--game-path PATH] [--product-id N]
```

| Option | Description |
|---|---|
| `--profile NAME` | Profile for session cookies. Defaults to first profile. |
| `--game-path PATH` | Path to folder containing `patchdata\`. |
| `--product-id N` | Nexon product ID (default `10200`). |

Exit codes: `0` up-to-date, `1` error, `2` update available.

```powershell
Rua.exe --cli check-update --game-path "E:\mabinogi2\appdata"
if ($LASTEXITCODE -eq 2) { Rua.exe --cli update --game-path "E:\mabinogi2\appdata" }
```

---

### `update`

Download and apply pending game updates.

```
Rua.exe --cli update --game-path PATH [--profile NAME] [--force-all] [--verify] [--product-id N]
```

| Option | Description |
|---|---|
| `--game-path PATH` | **Required.** Path containing `patchdata\`. |
| `--profile NAME` | Profile for session cookies. |
| `--force-all` | Re-download every file regardless of local state. |
| `--verify` | Repair: re-check all files, replace size-mismatched ones. |
| `--product-id N` | Nexon product ID (default `10200`). |

Exit codes: `0` done, `1` error.

---

### `launch`

Launch the game headlessly. Blocks until game exits.

```
Rua.exe --cli launch [--profile NAME] [--game-path PATH] [--product-id N]
```

| Option | Description |
|---|---|
| `--profile NAME` | Profile to use. Defaults to first profile. |
| `--game-path PATH` | Full path to `Client.exe`. Falls back to profile's saved path. |
| `--product-id N` | Nexon product ID (default `10200`). |

Exit codes: `0` launched and exited normally, `1` error.

---

## Examples

```powershell
# First-time setup â€” email/password, no GUI needed
Rua.exe --cli login --profile Alice --email alice@example.com --password hunter2

# Check and update
Rua.exe --cli check-update --profile Alice --game-path "E:\mabinogi2\appdata"
Rua.exe --cli update --profile Alice --game-path "E:\mabinogi2\appdata"

# Launch
Rua.exe --cli launch --profile Alice --game-path "E:\mabinogi2\appdata\Client.exe"

# Full scripted check-patch-launch
$path = "E:\mabinogi2\appdata"
Rua.exe --cli check-update --game-path $path
if ($LASTEXITCODE -eq 2) { Rua.exe --cli update --game-path $path }
Rua.exe --cli launch --game-path "$path\Client.exe"
```

---

## Event hooks

Hook commands run before/after patch and before/after launch. They fire in
**both GUI and CLI modes**. Configure in **Settings > Event hook commands**
or directly in `%APPDATA%\Rua\config.ini`:

```ini
[Hooks]
BeforePatch=C:\Scripts\before-patch.bat %PROFILE%
AfterPatch=C:\Scripts\after-patch.bat %PROFILE%
BeforeLaunch=C:\Scripts\before-launch.bat %PROFILE%
AfterLaunch=C:\Scripts\after-launch.bat %PROFILE%
```

`%PROFILE%` expands to the active profile name at runtime. Hooks run
fire-and-forget (the launcher does not wait for them to finish).

| Hook | Fires |
|---|---|
| `BeforePatch` | Before update download starts (`update` command / GUI check) |
| `AfterPatch` | After update completes successfully |
| `BeforeLaunch` | Just before the game process starts |
| `AfterLaunch` | After the game process exits |
