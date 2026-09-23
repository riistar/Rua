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
