/*
 * RuaAPI.h  —  C/C++ header for RuaAPI.dll
 *
 * All strings are UTF-16 (wchar_t on Windows).
 * All functions are __stdcall (safe from C, C++, Python ctypes, etc.).
 *
 * Link against RuaAPI.dll or use dynamic loading (LoadLibrary / GetProcAddress).
 */
#pragma once
#ifndef RUAAPI_H
#define RUAAPI_H

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -----------------------------------------------------------------------
 * Return codes
 * --------------------------------------------------------------------- */
#define RUA_OK       0  /* success / session valid / up-to-date              */
#define RUA_ERR      1  /* generic error  — call RuaGetLastError for details  */
#define RUA_MFA      2  /* MFA required  (RuaLogin only)                      */
#define RUA_CAPTCHA  3  /* CAPTCHA block — use the GUI browser login          */
#define RUA_UPDATE   4  /* update available  (RuaCheckUpdate only)            */
#define RUA_EXPIRED  5  /* session cookie expired  (RuaSessionCheck only)     */

/* -----------------------------------------------------------------------
 * Callback types
 * --------------------------------------------------------------------- */

/* Progress callback: invoked for each file during a patch run.
 * current  — 1-based index of the file being processed.
 * total    — total number of files in this run.
 * filename — relative path of the current file (e.g. L"Client.exe").
 */
typedef void (__stdcall *RuaProgressCb)(int current, int total, const wchar_t *filename);

/* Cancel callback: return non-zero to abort the patch.
 * Called before each file and before each part download. */
typedef int  (__stdcall *RuaCancelCb)(void);

/* -----------------------------------------------------------------------
 * Login
 * --------------------------------------------------------------------- */

/*
 * RuaLogin — Log in with email + password.
 *
 * email, password     : credentials.
 * device_id           : device identifier; pass NULL or L"" to auto-derive.
 * cookies_out         : buffer that receives the session cookie string on success.
 * cookies_size        : capacity of cookies_out in wchar_t (including NUL terminator).
 * mfa_key_out         : buffer for the MFA challenge key when RUA_MFA is returned.
 * mfa_key_size        : capacity of mfa_key_out.
 * mfa_type_out        : buffer for the MFA type string when RUA_MFA is returned.
 * mfa_type_size       : capacity of mfa_type_out.
 *
 * Returns: RUA_OK, RUA_MFA, RUA_CAPTCHA, or RUA_ERR.
 */
int __stdcall RuaLogin(
    const wchar_t *email,
    const wchar_t *password,
    const wchar_t *device_id,
    wchar_t       *cookies_out,
    int            cookies_size,
    wchar_t       *mfa_key_out,
    int            mfa_key_size,
    wchar_t       *mfa_type_out,
    int            mfa_type_size);

/*
 * RuaLoginOTP — Submit an OTP after RuaLogin returned RUA_MFA.
 *
 * mfa_key      : challenge key from the prior RuaLogin call.
 * otp          : one-time password from the authenticator app.
 * device_id    : same as the prior RuaLogin call.
 * cookies_out  : buffer for the session cookie string on success.
 * cookies_size : capacity of cookies_out.
 *
 * Returns: RUA_OK or RUA_ERR.
 */
int __stdcall RuaLoginOTP(
    const wchar_t *mfa_key,
    const wchar_t *otp,
    const wchar_t *device_id,
    wchar_t       *cookies_out,
    int            cookies_size);

/* -----------------------------------------------------------------------
 * Session
 * --------------------------------------------------------------------- */

/*
 * RuaSessionCheck — Verify a stored cookie string.
 *
 * cookies      : cookie string returned by RuaLogin / RuaLoginOTP.
 * http_status  : receives the HTTP response code; may be NULL.
 *
 * Returns: RUA_OK (valid) or RUA_EXPIRED.
 */
int __stdcall RuaSessionCheck(
    const wchar_t *cookies,
    int           *http_status);

/* -----------------------------------------------------------------------
 * Update check
 * --------------------------------------------------------------------- */

/*
 * RuaCheckUpdate — Check whether a game update is available.
 *
 * cookies               : session cookies (pass L"" if unauthenticated).
 * product_id            : Nexon product ID (10200 for Mabinogi).
 * install_root          : path containing the patchdata\ sub-folder.
 *                         Pass NULL to skip the local hash comparison.
 * manifest_hash_out     : buffer for the remote manifest hash string.
 * manifest_hash_size    : capacity of manifest_hash_out.
 *
 * Returns: RUA_OK (up-to-date), RUA_UPDATE (update available), or RUA_ERR.
 */
int __stdcall RuaCheckUpdate(
    const wchar_t *cookies,
    int            product_id,
    const wchar_t *install_root,
    wchar_t       *manifest_hash_out,
    int            manifest_hash_size);

/* -----------------------------------------------------------------------
 * Patch
 * --------------------------------------------------------------------- */

/*
 * RuaRunPatcher — Download and apply pending updates.
 *
 * manifest_hash : remote manifest hash from RuaCheckUpdate.
 * install_root  : path containing the patchdata\ sub-folder.
 * product_id    : Nexon product ID.
 * force_all     : 1 = re-download every file; 0 = changed files only.
 * progress_cb   : progress callback; may be NULL.
 * cancel_cb     : cancellation callback; may be NULL.
 *
 * Returns: RUA_OK or RUA_ERR.
 */
int __stdcall RuaRunPatcher(
    const wchar_t *manifest_hash,
    const wchar_t *install_root,
    int            product_id,
    int            force_all,
    RuaProgressCb  progress_cb,
    RuaCancelCb    cancel_cb);

/* -----------------------------------------------------------------------
 * Launch
 * --------------------------------------------------------------------- */

/*
 * RuaLaunch — Launch the game.  Synchronous: returns when the game exits.
 *
 * cookies    : session cookies.
 * product_id : Nexon product ID (10200).
 * game_exe   : full path to Client.exe.
 *
 * Returns: RUA_OK or RUA_ERR.
 */
int __stdcall RuaLaunch(
    const wchar_t *cookies,
    int            product_id,
    const wchar_t *game_exe);

/* -----------------------------------------------------------------------
 * Error retrieval
 * --------------------------------------------------------------------- */

/*
 * RuaGetLastError — Retrieve the last error message.
 *
 * buf      : output buffer.
 * buf_size : capacity in wchar_t (including NUL).
 */
void __stdcall RuaGetLastError(wchar_t *buf, int buf_size);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* RUAAPI_H */
