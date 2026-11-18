# Concurrent client sessions

One Rua process, N game clients. No second Rua install, no per-session copies of
`nexon_client.exe` / `bin\nexon_x64.dll`.

## Session split (`uGameLaunch.pas`)

- `TGameLauncher` = container: list of running sessions + one `TDeployedFiles`.
  `Launch` never touches another session's resources.
- `TGameSession` = everything one client owns: stub process, stub-exit event,
  verified stub/shim handles, folder locks, pipe registration, `StubCreated` /
  `ShimCreated` flags. `StopPipe` and `Cleanup` act only on these fields.
  Events/mapping names are GUID-scoped (`Local\Rua.Stub.<guid>`,
  `Local\Rua.Ticket.<guid>`).
- A monitor thread per session waits for the game, then runs that session's
  `StopPipe` + `Cleanup`, removes it from the list and frees it.

## Reuse rule (`DeployVerified`)

Destination exists, is not a reparse point, and its SHA-256 equals the source →
open it read-only (denies write/delete), return the handle, do **not** delete or
copy. Otherwise (missing / link / different) replace as before; replacing a
different file that is in use fails closed. The result is a verified, per-session
handle on a shared file. Running images are never rewritten.

`TDeployedFiles` ref-counts sessions. `Cleanup` closes the session's own
handles, then `Detach`; only the last session out deletes the files, and only if
this process created them. Another process's verified handles deny the delete,
so it fails harmlessly.

## Ticket pipe (`uPipeServer.pas`)

The game hardcodes one pipe name and the old server allowed one instance
(`FILE_FLAG_FIRST_PIPE_INSTANCE`, max 1), so a second session could not even
create its pipe. Now one per-process acceptor owns the name (first instance keeps
`FIRST_PIPE_INSTANCE`, later instances unlimited), binds each connection to the
session whose game PID connected, and serves it on its own thread with that
session's ticket. `TPipeRegistration` (one per session) only ends that session's
connections when freed; the acceptor stops with the last registration.
Limit: a second Rua *process* cannot create the pipe while another owns the name
(fails closed). Use one process for several clients.

## Mutex (`Rua.dpr`)

Default unchanged, plus the second instance now activates the running window.
`--multi` (also `-multi`, `/multi`): the mutex check does not refuse the launch.
Sessions do not use the mutex.

## UI

With `--multi` the Launch button stays enabled while clients run. Playtime /
session timer in `frmMain` still tracks only the latest launch.

## Build / run

```powershell
powershell -File build/delphi.ps1 -Project Rua            # release
powershell -File build/delphi.ps1 -Project Rua -Config Debug
Rua.exe --multi
```
Launch a profile repeatedly from the same window; check
`%TEMP%\nxl_launch_debug.txt` (`[sN]` prefixes per session).

## Acceptance status

Built (Debug, 0 errors). Run on the devbox with two concurrent clients (log
`%TEMP%\nxl_launch_debug.txt`): both sessions reused the deployed stub and shim
(no rewrite, no error 32), had distinct ticket mappings, stub events and stub
PIDs, and registered on the shared pipe. The sessions exited and cleaned up
independently.

Not verified: a third concurrent launch, and that both clients stay connected
for a full play session.
