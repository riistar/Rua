# Rua on Linux (Wine / Proton / Lutris)

Rua is a Windows app, but it runs under Wine. On Windows the login window uses Edge WebView2, which barely works under Wine. So when Rua detects Wine, it switches to a built-in Chromium browser (CEF) for the login window instead.

## Download

Use the normal Windows release from the [releases page](https://github.com/riistar/Rua/releases). There is no separate Linux build.

Unzip it anywhere **inside the same Wine prefix as Mabinogi**:

```
Rua/
  Rua.exe
  sqlite3.dll
  WebView2Loader.dll
  nxl3p_shim.dll
  nxl3p_stub.exe
```

### Chromium runtime (automatic)

The first time you open the login window, Rua downloads the Chromium runtime (~180 MB) from the [`cef-154.0.26` release](https://github.com/riistar/Rua/releases/tag/cef-154.0.26). Progress shows in the login window. The file is checked against a SHA-256 hash, then unpacked into `%APPDATA%\Rua\cef\154.0.26\` inside the prefix. This only happens once per prefix.

For offline installs, download `cef-runtime-154.0.26-win64.zip` yourself and unzip it into a `cef/` folder next to `Rua.exe` (so `cef/libcef.dll` exists). Rua uses that folder and skips the download.

## Important: use one prefix

Rua and the game talk over a Windows named pipe, and log-in data is kept in Wine's copy of Windows Credential Manager. Both of those only exist **inside a prefix**. So:

- Run Rua in the **same prefix** where Mabinogi is installed.
- Launch the game **from Rua** so the game starts inside that prefix.

## Setup

### Plain Wine

```bash
WINEPREFIX=~/.wine-mabinogi wine ~/.wine-mabinogi/drive_c/Rua/Rua.exe
```

### Steam (Proton)

1. Steam → *Games* → *Add a Non-Steam Game* → pick `Rua.exe`.
2. Right-click it → *Properties* → *Compatibility* → turn on *Force the use of a specific Steam Play compatibility tool* and choose a Proton version.
3. Launch it once so Steam creates the prefix (`steamapps/compatdata/<id>/pfx`), then install or copy Mabinogi into that prefix.
4. Rua looks for `Client.exe` on its own (see [Game path](#game-path)). If it isn't found, set it in *Settings*.

### Lutris

1. *Add Game* → *Add locally installed game*, with Runner **Wine**.
2. Executable: `Rua.exe`. Wine prefix: the prefix that has Mabinogi.
3. Rua looks for `Client.exe` on its own (see [Game path](#game-path)). If it isn't found, set it in *Settings*.

## Game path

When no game path is set, Rua looks for `Client.exe` at startup and again when you add a profile. It checks:

- the official Nexon Launcher config, if one exists in the prefix
- the Windows uninstall entries in the prefix
- the usual install folders (`Nexon\Library\mabinogi`, `Nexon\Mabinogi` and the same under Program Files) on every drive except `Z:`
- the same folders inside other prefixes in your home dir: `~/.wine*`, `~/Games/*` (Lutris), Bottles and Steam `compatdata/*/pfx`

If nothing is found, Rua offers to open *Settings* so you can set it yourself.

## Theme

Under Wine, Rua always uses the plain *Windows* theme. The other themes don't draw correctly there (buttons go invisible), so the theme picker is locked.

## Logging in

Login works the same way as on Windows: pick *Nexon Account* (email/password) or *SSO* (Google, etc.) in the login window.

Rua finds out it's under Wine by checking for the `wine_get_version` export in Wine's `ntdll.dll`. This covers Wine, Proton, Lutris, Bottles and CrossOver. If detection fails, or you want to pick the browser yourself, set it in the config.

## Config

`%APPDATA%\Rua\config.ini`. Inside the prefix that is `drive_c/users/<you>/AppData/Roaming/Rua/config.ini` (under Proton, `<you>` is `steamuser`).

```ini
[Browser]
; auto = Chromium under Wine, WebView2 on Windows
Engine=auto            ; auto | cef | webview2
; Extra Chromium command-line switches, space separated
CefSwitches=
; 1 = write a Chromium debug log to %APPDATA%\Rua\CEF\debug.log
CefLog=0
; Download location for the runtime when it is not bundled
CefRuntimeUrl=
```

## Troubleshooting

| Problem | Try |
| --- | --- |
| Login window stays blank or black | `CefSwitches=--in-process-gpu`, or `CefSwitches=--single-process` as a last resort |
| "Chromium runtime download failed" | Check your internet connection, or do the offline install described under [Chromium runtime](#chromium-runtime-automatic) |
| "Chromium failed to start" | Delete `%APPDATA%\Rua\cef\154.0.26` so it downloads again (or check your `cef/` folder if you installed it by hand). Then set `CefLog=1` and check `debug.log` |
| Text is missing or looks like boxes | `winetricks corefonts` |
| WebView2 opens instead of Chromium | Set `Engine=cef` |
| Game starts but says it isn't logged in | Rua and the game are in different prefixes. See [Important: use one prefix](#important-use-one-prefix) |
| Login cookies or session look stale | Delete `%APPDATA%\Rua\CEF` inside the prefix (this is Chromium's browser profile) |

Only the launcher is covered here. Whether Mabinogi itself runs well depends on your Wine/Proton version, just like with the official launcher.
