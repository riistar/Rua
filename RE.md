# Nexon Launcher — RE Findings

Product: Mabinogi NA (product ID 10200)
Target binaries: `nexon_api_x64.dll` (game-side auth SDK), `nexon_client.exe` (official launcher stub)

---

## nexon_api_x64.dll — nxapi2_init

The game links `nexon_api_x64.dll` and calls `nxapi2_init` on startup. This function
establishes the connection between the game process and the launcher.

### Process discovery

1. `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)` — enumerate all processes
2. Search for process named `nexon_client.exe` (case-insensitive)
3. `K32GetModuleFileNameExW` on the found PID → full EXE path
4. Strip filename → `nexon_client_dir`
5. Derive DLL path: `nexon_client_dir + "\bin\nexon_x64.dll"`
6. `LoadLibraryW(DLL_path)` → `GetProcAddress("nxapi_get_func_addr")`

**Registry fallback** (if no running `nexon_client.exe` found):
```
HKCR\nxl\shell\open\command → default value
→ strip args → launcher directory
→ DLL path = {launcher_dir}\bin\nexon_client\nexon_client.exe (path to client within launcher)
```

### Function dispatch

`nxapi_get_func_addr` receives numeric codes and returns function pointers:

| Code         | Function         |
|--------------|-----------------|
| `0xbeef0001` | init             |
| `0xbeef0002` | close            |
| `0xbeef0003` | getProductId     |
| `0xbeef0004` | getProductTicket |
| `0xbeef0005` | (reserved)       |
| `0xbeef0006` | (reserved)       |

`getProductTicket` ultimately calls our shim, which returns the passport token
written to `%TEMP%\nxl3p_ticket.txt`.

### Game-running event

nexon_api_x64.dll creates a named event during init:
```
"928-92E6B-97AD4AD4-{PRODUCT_ID_HEX}-A43-CA66716-CD1625-56CA"
```
e.g. for product 10200 (0x27D8): `928-92E6B-97AD4AD4-27D8-A43-CA66716-CD1625-56CA`

The official Nexon Launcher polls `OpenEventW` for this event to detect whether
the game is running. Closing all handles to the event clears the "running" state.

---

## Named pipe protocol

Pipe name: `\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}`

Frame format:
```
[4-byte little-endian int32 = body length][UTF-8 JSON body]
```

The game sends requests; the launcher (pipe server) responds. One client at a time
(pipe created with `nMaxInstances = 1`). Pipe MUST be `FILE_FLAG_OVERLAPPED` —
`ConnectNamedPipe` with a non-NULL overlapped struct on a blocking pipe returns
`ERROR_OPERATION_ABORTED (995)` immediately.

### Request/response pairs

**getProductTicket** — primary auth token request
```json
// Request
{"reqType":"getProductTicket","productId":10200}

// Response
{"code":0,"reqType":"getProductTicket","res":{"productId":10200,"ticket":"<passport_token>"}}
```

**getSDKConfiguration** — CCU server config
```json
// Request
{"reqType":"getSDKConfiguration","productId":10200}

// Response
{"code":0,"res":{
  "ccuServerName":"ccu-edge.nexon.io",
  "ccuServerPort":8913,
  "hashedUserNo":"<base64_sha256_of_user_no>"
}}
```

**productActive** — game signals it is active
```json
// Request
{"reqType":"productActive"}
// Response
{"code":0}
```

**productClosed** — game signals exit; server closes after responding
```json
// Request
{"reqType":"productClosed"}
// Response
{"code":0}
```

**getClientToken** — treated as ack (not seen in wild but handled)

**Unknown reqType** → `{"code":-30000005}` (error sentinel)

---

## Bypass strategy (no official files touched)

nexon_api_x64.dll identifies the "launcher" by finding a running `nexon_client.exe`
and loading `{its_dir}\bin\nexon_x64.dll`. We satisfy both conditions without
touching any Nexon installation:

```
{our_dir}\
  NexonLauncher3P.exe      ← our launcher
  nxl3p_stub.exe           ← fake nexon_client.exe (no GUI, waits for exit event)
  nxl3p_shim.dll           ← fake nexon_x64.dll (serves getProductTicket etc.)
  bin\
    nexon_x64.dll          ← nxl3p_shim.dll deployed here at launch time (deleted after)
  nexon_client.exe         ← nxl3p_stub.exe copied here at launch time (deleted after)
```

### Launch sequence

1. Kill/clean any prior stub and shim
2. `CheckPlayable` + `FetchPassport` (get ticket)
3. Write ticket to `%TEMP%\nxl3p_ticket.txt` (shim reads this)
4. Copy `nxl3p_stub.exe` → `{our_dir}\nexon_client.exe`
5. Create named event `NXL3P_StubExit` (keep handle open; stub waits on this)
6. Spawn `nexon_client.exe` — stub appears in process list for the DLL scan
7. Wait 300 ms for process to appear in toolhelp snapshot
8. Create `{our_dir}\bin\` → copy `nxl3p_shim.dll` → `nexon_x64.dll`
9. `FetchGameConfig` — get launch parameters (exe, args with `${passport}` template)
10. Start named pipe server (TPipeServerThread)
11. `ShellExecuteEx` Client.exe with args (handles UAC elevation via manifest)
12. Open game-running event after 500 ms (nexon_api_x64.dll creates it during init)
13. Background thread: wait for shim `NXL3P_ShimReady` signal → kill stub → delete artifacts
14. Background thread: wait for Client.exe exit → close game-running event

### Cleanup

- Signal `NXL3P_StubExit` → stub exits gracefully (or `TerminateProcess` as fallback)
- Delete `{our_dir}\nexon_client.exe`
- Delete `{our_dir}\bin\nexon_x64.dll`
- Close game-running event handle (clears "game running" flag for official launcher)

---

## Shim (nxl3p_shim.dll)

Implements `nxapi_get_func_addr` export. On `0xbeef0001` (init):
1. Read ticket from `%TEMP%\nxl3p_ticket.txt`
2. Set the ticket value returned by `getProductTicket` dispatcher
3. Signal `NXL3P_ShimReady` event → launcher kills stub

On `0xbeef0002` (close): clean up.
On `0xbeef0004` (getProductTicket): return stored ticket string.

---

## Manifest / update system

```
Branch info:  GET  /api/game-build/v1/branch/games/10200/public
  → {manifestUrl: "http://download2.nexon.net/Game/nxl/games/10200/<hash>"}

Manifest hash: GET manifest URL → raw content = hash string (SHA1-based, hex)

Manifest file: GET http://download2.nexon.net/Game/nxl/games/10200/<hash>
  → zlib-compressed JSON

Manifest JSON:
  {"files": {
    "<base64_encoded_filename>": {
      "fsize": N,          // decompressed file size
      "mtime": N,          // unix timestamp (unreliable for change detection)
      "objects": ["hash"], // part hashes (SHA1 of compressed CDN part — unverified)
      "objects_fsize": [N] // compressed part sizes
    }
  }}

Part URL: https://download2.nexon.net/Game/nxl/games/10200/10200/{hash[0:2]}/{hash}
```

Filename decode (base64 → UTF-16LE → UTF-8 → skip 3-byte BOM → TrimRight):
```pascal
UniBytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
U8 := TEncoding.UTF8.GetBytes(TEncoding.Unicode.GetString(UniBytes));
// each byte cast to Char, skip first 3 (EF BB BF = UTF-8 BOM)
```

Install root = `TPath.GetDirectoryName(GameExe)` — paths in manifest are relative to this.

Hash file location: `{install_root}\patchdata\10200.manifest.hash`
Change detection: size-only (mtime was unreliable, caused full re-downloads).
Concurrency: 8 parallel file downloads (`MAX_DL = 8`), parallel parts within each file.
Temp files: `{dest}.~nxlpatch`, cleaned up on error.

---

## User-Agent

All Nexon API calls use:
```
NexonLauncher.nxl-release-18.14.10-220-fc7480c-coreapp-3.3.0
```

---

## Debug logs

| File                              | Content                           |
|-----------------------------------|-----------------------------------|
| `%TEMP%\nxl_launch_debug.txt`     | Launch sequence, stub/shim events |
| `%TEMP%\nxl_pipe_debug.txt`       | Named pipe request/response log   |
| `%TEMP%\nexon_tpa_debug.txt`      | TPA exchange response dump        |
| `%TEMP%\nexon_refresh_debug.txt`  | Autologin refresh response dump   |
