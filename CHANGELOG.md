# Changelog

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
- Garbled characters (`â€"`) in login status text and patcher log messages.
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
