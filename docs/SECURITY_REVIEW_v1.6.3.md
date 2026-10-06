# Rua Security Review Findings

2026-10-06

## Executive Summary

This review covers the full source of [riistar/Rua](https://github.com/riistar/Rua), a third-party Nexon Launcher replacement for Mabinogi. Five findings were identified: one HIGH, two MEDIUM, and two LOW. The HIGH finding allows a network-adjacent attacker to substitute game files during an update. No findings require remote code execution preconditions beyond a local network position.

| Severity | Count |
|----------|-------|
| HIGH     | 1     |
| MEDIUM   | 2     |
| LOW      | 2     |

---

## Finding 1 (HIGH) — HTTP Manifest with No Signature Verification

**File:** `units/uNxlPatcher.pas:50`

**Severity:** HIGH

**Category:** Cleartext protocol / supply-chain integrity

**Description:** The manifest hash URL and the manifest JSON itself are both fetched over plain HTTP (`http://download2.nexon.net/…`). There is no cryptographic signature on the manifest, so a network-adjacent attacker can replace the manifest in transit.

**Exploit scenario:** An attacker on the same network intercepts the HTTP request for `MANIFEST_BASE + ManifestHash` and returns a tampered manifest. The modified manifest's `objects[]` arrays contain SHA1 hashes of older or attacker-chosen game files that already exist on Nexon's HTTPS CDN. The patcher downloads and installs those files without detecting the substitution, silently downgrading the game client to a vulnerable version.

**Fix:** Change `MANIFEST_BASE` to `https://`. Additionally, verify a server-provided HMAC or signature over the manifest JSON before parsing it.

---

## Finding 2 (MEDIUM) — Downloaded Parts Not Hash-Verified

**File:** `units/uNxlPatcher.pas:402–507`

**Severity:** MEDIUM

**Category:** Missing integrity check

**Description:** `PatchFile` downloads each game file part over HTTPS, decompresses it with zlib, and writes it directly to disk. It never verifies the decompressed bytes against the corresponding SHA1 in `objects[]`. The verification functions `VerifyFileHash` and `VerifyFileByHash` exist but are only invoked during scan/repair mode, not during a normal download.

**Exploit scenario:** Compounded with Finding 1: once the manifest is replaced via HTTP MITM, the patcher fetches parts whose SHA1 names match the attacker's chosen files. Because no post-download hash check runs, corrupted or substituted content is written to disk silently. Even without manifest tampering, a CDN edge node returning wrong bytes goes undetected.

**Fix:** After decompressing each part in `PatchFile`, compute `THashSHA1` of the result and compare it to `E.Parts[I].Name` before writing. Abort and raise an exception on mismatch.

---

## Finding 3 (MEDIUM) — Password Exposed in Command-Line Arguments

**File:** N/A — this version uses browser-based login

**Severity:** MEDIUM

**Category:** Credential exposure

**Description:** The `--password` value for email/password login is read directly from `ParamStr`. On Windows, command-line arguments are accessible to any process running as the same user via `WMI Win32_Process.CommandLine`, Task Manager, or the Process Status API. The password is visible for the entire duration of the process.

**Exploit scenario:** A script or background process running as the same Windows user queries `Win32_Process` with a WMI call while `Rua.exe --cli login --email user@example.com --password secret` is in progress. The full command line, including the plaintext password, is returned in the `CommandLine` property.

**Fix:** Remove `--password` as a command-line switch. Instead, if no credentials are in the credential store, prompt for the password using `ReadConsoleW` with `ENABLE_ECHO_INPUT` disabled, or read from stdin via a piped secure input mechanism.

---

## Finding 4 (LOW) — Fixed Pipe GUID Enables Predictable Name Collision

**File:** `units/uPipeServer.pas:19`

**Severity:** LOW

**Category:** Defense-in-depth / pipe squatting

**Description:** The named pipe GUID `{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}` is a public constant embedded in the source code. Any unprivileged process running as the same user that knows this GUID could attempt to create the pipe before Rua does (pipe squatting), or could probe for the pipe's existence to detect when Rua is active.

`FILE_FLAG_FIRST_PIPE_INSTANCE` is used, which means Rua will fail to start if the pipe already exists — but it does not prevent a malicious same-user process from pre-creating it. The `AuthorizedClient` check (PID matching the game process) is strong mitigation: a squatter could accept the connection but could not impersonate the game to receive the ticket, because the game itself would connect and be rejected by Rua. However, a squatter could cause a denial-of-service by holding the pipe name before Rua opens it.

**Note:** `PIPE_REJECT_REMOTE_CLIENTS` and the `UserOnlyDescriptor` ACL (SDDL restricting to current user + SYSTEM) are correctly applied, eliminating remote-user and cross-user attacks.

**Fix:** Generate the pipe name at runtime from a per-session secret (e.g., a random UUID written to a process-local environment variable or shared via the existing `TPrivateTicket` memory-mapping mechanism), so it cannot be predicted or pre-squatted.

---

## Finding 5 (LOW) — Predictable Temp Filenames for Browser Cookie DB Copies

**File:** `units/uBrowserCookies.pas:746, 794, 901`

**Severity:** LOW

**Category:** Predictable temp-file paths / TOCTOU

**Description:** Browser cookie databases are copied to fixed temp paths before being opened via FireDAC:

- `%TEMP%\nlp_ff_cookies.sqlite` (Firefox)
- `%TEMP%\nlp_cr_cookies.sqlite` (Chrome/Edge/Brave)

Because these paths are predictable and user-writable, a same-user process could pre-create them as symlinks or replace them between the `TFile.Copy` and the subsequent `TFDConnection.Open` (TOCTOU). In practice the window is tiny and exploitation requires the attacker to already be running as the same user, limiting real-world impact.

**Fix:** Use `GetTempFileNameW` (or Delphi's `TPath.GetTempFileName`) to obtain a unique temp path per invocation, and delete the file immediately after use inside a `try/finally` block.

---

## Recommendations Summary

| # | Severity | Title                                       | File                                        | Fix effort                                        |
|---|----------|---------------------------------------------|---------------------------------------------|---------------------------------------------------|
| 1 | HIGH     | HTTP manifest download                      | `units/uNxlPatcher.pas:50`                 | Low — change URL scheme + add HMAC                |
| 2 | MEDIUM   | No hash verification on downloaded parts    | `units/uNxlPatcher.pas:402–507`            | Medium — call `VerifyFileByHash` in `PatchFile`   |
| 3 | MEDIUM   | Password visible in process command line    | N/A                                         | Low — replace `--password` with `ReadConsoleW` prompt |
| 4 | LOW      | Hardcoded pipe GUID enables squatting       | `units/uPipeServer.pas:19`                 | Medium — generate pipe name from per-session secret |
| 5 | LOW      | Predictable temp SQLite filenames (TOCTOU)  | `units/uBrowserCookies.pas:746, 794, 901`  | Low — use `GetTempFileNameW` per invocation       |

**Recommended priority:** Address finding 1 (manifest HTTPS) and finding 3 (password CLI) immediately — both are straightforward one-line changes with high security payoff. Finding 2 (hash verification) should follow in the next release. Findings 4 and 5 are defence-in-depth improvements and can be scheduled at lower priority.

---

## Remediation Status

**Status:** Resolved — shipped in v1.6.3

**Fix commit:** `d60616a` — *security: apply hardening fixes for v1.6.3*

Findings 1, 2, and 5 were applied to `units/uNxlPatcher.pas` and `units/uBrowserCookies.pas` in the original source tree.

Finding 3 (CLI password) was not applicable — this version uses browser-based login with no `--password` argument.

Finding 4 (pipe squatting) was assessed as not safely remediable without modifying the game's closed-source Nexon SDK, which hardcodes the pipe name client-side. Defence-in-depth mitigations (`FILE_FLAG_FIRST_PIPE_INSTANCE`, `UserOnlyDescriptor` ACL) remain in place and limit the practical impact to a same-user denial-of-service.
