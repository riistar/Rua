# Rua - 3rd party (Mabinogi) Nexon Launcher

## Requirements

- Delphi 10.4.2+ (for TEdgeBrowser / WebView2 support)
- Microsoft Edge WebView2 Runtime installed (ships with Windows 11; installer at microsoft.com/edge/webview2)
- Windows 10 x64+

## Setup in Delphi IDE

1. File → Open → `NexonLauncher3P.dpr`
2. Delphi will prompt to create `NexonLauncher3P.dproj` — accept
3. Build → Build (F9)

No external packages or third-party components required.
All dependencies are RTL/VCL/Winapi units.

## Units

| Unit | Purpose |
|---|---|
| `uProtocol` | Pipe frame read/write + JSON request/response |
| `uPipeServer` | Named pipe server thread (serves game SDK) |
| `uCredStore` | Windows Credential Manager (CredWriteW/CredReadW) |
| `uProfiles` | Profile CRUD (index JSON + cred store) |
| `uNexonAPI` | FetchTicket, FetchManifestHash |
| `uDeviceId` | SHA256(WMIC UUID + MachineGuid) |
| `uGameLaunch` | Orchestrates ticket + pipe + ShellExecuteW |

## Forms

| Form | Purpose |
|---|---|
| `frmMain` | Profile list, game path, launch, update check |
| `frmLogin` | TEdgeBrowser at nexon.com, auto cookie capture |
| `frmProfile` | Profile name input dialog |

## Known PoC gaps

- `UserNo` field not yet populated from session (requires parsing nexon.com response)
- `getSDKConfiguration.hashedUserNo` sent empty — game may not need it for auth
- Cookie TTL unknown — re-login prompt on HTTP 401 from ticket endpoint

## Pipe served

`\\.\pipe\{79d303ac-af79-46c3-9ae0-6cd4ff4805ad}`

Handles: `getProductTicket`, `getSDKConfiguration`, `productActive`, `productClosed`, `getClientToken`
