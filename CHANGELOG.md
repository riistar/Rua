# Changelog

## v1.6.1 - 2026-09-29

### Changed
- **Hooks are now a shared system** — [Hooks] in config.ini is read and written
  by uHooks.pas directly, not cached on the GUI form. Hooks now fire in both
  GUI and CLI modes (update fires BeforePatch/AfterPatch; launch fires
  BeforeLaunch/AfterLaunch).

## v1.6.0 - 2026-09-28

### Added
- **Headless CLI mode** (`Rua.exe --cli <command>`). Commands: `login`, `login-otp`,
  `check-update`, `update`, `launch`. Exit codes: 0 = ok, 1 = error, 2 = update available.
  See `docs/CLI.md` for full reference.
- **DLL API** (`RuaAPI.dll`). C-compatible stdcall exports: `RuaLogin`, `RuaLoginOTP`,
  `RuaSessionCheck`, `RuaCheckUpdate`, `RuaRunPatcher`, `RuaLaunch`, `RuaGetLastError`.
  C header `RuaAPI.h` included. See `docs/DLL-API.md` for full reference.
- **Event hook commands** (Settings â†’ Event hook commands). Run arbitrary shell commands
  before/after patch and before/after game launch. `%PROFILE%` expands to the active
  profile name. Stored in `config.ini` under `[Hooks]`.

## v1.5.3 - 2026-09-28

### Added
- **Linux / Steam Deck support** (Wine, Proton, Lutris). Under Wine the login window uses an
  embedded Chromium (CEF) browser, downloaded once on first login (~180 MB). Override the
  engine with `config.ini` `[Browser] Engine = auto | webview2 | cef`. See `README-LINUX.md`.
- Under Wine: game install auto-detected (Nexon config, uninstall entries, Lutris / Steam /
  Bottles / `~/.wine` prefixes), and the system theme is used (custom styles render broken).
- **Log in again with a valid session.** Refresh Login on a still-valid session now asks
  whether to log in again instead of doing nothing. A forced re-login always shows the login
  method choice and never silently reuses the cached browser session.
- **Confirm before the login window closes.** After a successful login Rua asks before
  closing. Choose **No** to keep the page open (e.g. to capture Nexon's device verification
  page), then press **Done**; the session is kept.

## v1.5.2 - 2026-09-24

### Added
- **Pick exactly which files to update.** After scanning, Rua lists every new or changed file
  with its status (New / Size changed / Content changed), new size, local size and the size
  change. Choose **Update Selected**, **Update All**, or **Cancel**; **Select All / Select None**
  toggle the checkboxes. Files you leave unchecked are offered again on the next check.
- **Folder dialog shows every game folder**, marked "update available" or "up to date", and
  lets you update just one of several. Actions: **Update Selected**, **Update All**,
  **Repair Bad Files**, **Re-download All** (asks to confirm), with **All / None** selection.
- "Re-download All Files" option in the update button's dropdown.

### Changed
- Updates detect same-size content changes by comparing against the manifest of the installed
  version (cached after each update), so only new/changed files are downloaded.
- Device-trust rejection (`20027`) now tells you to complete device verification in the
  official Nexon Launcher, then log in again. Rua retries the same session a few times
  (up to 4, with growing delay) in case verification was just completed.

### Fixed
- Cancelling during the file scan no longer marks the game as up to date.
- Garbled characters (`Ã¢â‚¬"`) in login status text and patcher log messages.
- `nxl3p_shim.dll` is now built as Win64, fixing "Failed to Init NXALauncher".

## v1.5.1 - 2026-09-24

### Fixed
- Browser login gave a misleading "TpaSession expires in seconds, retry" error when Nexon
  actually rejected the session exchange for an unverified device (error code `20027`,
  "Trust device required"). Retrying never fixed it. Rua now reads Nexon's error code and
  tells you to check your email for Nexon's device-verification link instead.

## v1.5 - 2026-09-19

### Added
- **Update ignore list.** Files or wildcard patterns (`*`, `?`, case-insensitive) that the
  patcher never touches, so your local mods are not flagged, repaired or overwritten. Applies
  to every mode: normal update check, Repair Bad Files and Re-download All. Edit it in
  **Settings** or in the **Select Folders to Update** dialog; both share the same list.
- **Themed news feed.** Nexon news cards use a light "notification" style (tinted background,
  dark accent text) on light VCL styles and a tinted-dark scheme with light text on dark styles.
  Category and title colours are darkened on light themes so grey and blue items stay readable.
- **Re-login prompt on update check.** If the session has expired and the silent refresh fails,
  Rua now opens the WebView2 login instead of failing with `HTTP 401 fetching branch info`.
  This fixes Verify / Repair Files silently doing nothing.
- **Game availability check.** The launcher reads Nexon's `isPlayable` verdict before launching,
  so maintenance and region/IP blocks are reported clearly instead of failing at launch.
- Screenshots (light and dark) and a feature list in the README.

### Changed
- The saved theme is applied before the main window is created, so nothing flashes in the
  default style at startup.
- Patcher caps total simultaneous HTTP requests and reuses connections, instead of opening
  100+ at once and throttling itself against the CDN.
- Routine update checks use size-only change detection. Recompress-and-hash verification is
  reserved for Verify / Repair.
- Docs moved to `docs/`.

### Fixed
- Browser (TPA/SSO) login no longer discards a valid browser session when the token exchange is
  rejected. TpaSession is single-use and short-lived, so Rua keeps the browser NxLSession, or
  keeps the dialog open with a clear error, and retries on a fresh login.
- A launch with an expired session now reports "Session expired (401)" plainly.

### Notes
- The repository history was reset for this release. The previous `main` is preserved on the
  `archive/old-main` branch and the `1.0` tag.
