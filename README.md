# Rua

A lightweight 3rd-party launcher for Mabinogi NA that replaces the official Nexon Launcher entirely.

No heavy Electron wrapper, no CEF browser, no background services. Just a small native Windows app that logs you in and starts the game.

## What it does

- Manages multiple profiles/accounts
- Logs in via email/password or browser SSO through the Nexon site. Like the official launcher does.
- Stores login/session data securely in Windows Credential Manager
- Launches the game without Nexon's launcher running
- Game/client updater (manifest-based patcher with parallel downloads)
- Minimizes to tray while you play
- Login sessions do time out, minimum is usually 2 hours and then you need to refresh/re-login affected accounts (not a perfect solution, but Nexon server side limitation)

## What it is not

This isn't a wrapper or a mod. It's a full replacement for the official launcher. The game client connects to Nexon's servers exactly as it always has — Rua just handles the auth and launch part instead of Nexon's software.

## Building

Requires: https://github.com/salvadordf/WebView4Delphi

Open `delphi/rua/Rua.dproj` in Delphi 12.1+ and build (Win64 target).
Or run `powershell -File build/delphi.ps1` to build all projects.
Requires Windows 10 x64+ and the WebView2 Runtime (ships with Windows 11).

## Credits

- Rii / RiiStar

## Special thanks to past projects/code

- Sven — Hyddwn project
- Cursey
- Xcelled194
