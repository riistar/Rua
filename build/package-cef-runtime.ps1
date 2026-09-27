<#
  Builds the Chromium (CEF) runtime zip that Rua downloads on first use of the
  CEF login browser (used under Wine/Proton).

  Output: release\cef-runtime-<ver>-win64.zip + its SHA-256.
  Publish it as an asset of a GitHub release tagged  cef-<ver>  in riistar/Rua
  (the default download URL in uCefRuntime.pas), then optionally paste the SHA-256
  into CEF_RUNTIME_SHA256 in delphi/src/units/uCefRuntime.pas.

  The CEF version must match the vendored CEF4Delphi (uCEFVersion.inc /
  delphi/src/CEF4Delphi/update_CEF4Delphi.json).

  Usage (repo root):  powershell -File build/package-cef-runtime.ps1
#>
param(
  [string]$CefVersion  = '154.0.26',
  [string]$CefBuild    = '154.0.26+ge72305f+chromium-154.0.8037.58',
  [string]$OutDir      = 'release'
)

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$work    = Join-Path $env:TEMP "rua-cef-$CefVersion"
$archive = "cef_binary_${CefBuild}_windows64_minimal.tar.bz2"
$url     = 'https://cef-builds.spotifycdn.com/' + [Uri]::EscapeDataString($archive)

New-Item -ItemType Directory -Force $work | Out-Null
$tarPath = Join-Path $work $archive
if (-not (Test-Path $tarPath)) {
  Write-Host "Downloading $url"
  Invoke-WebRequest -Uri $url -OutFile "$tarPath.part" -UseBasicParsing
  Move-Item "$tarPath.part" $tarPath
}

$extract = Join-Path $work 'x'
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
New-Item -ItemType Directory -Force $extract | Out-Null
Write-Host 'Extracting...'
& "$env:SystemRoot\System32\tar.exe" -xjf $tarPath -C $extract
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }

$root = Get-ChildItem $extract -Directory | Select-Object -First 1
$stage = Join-Path $work 'stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

# Release\ = libcef.dll, chrome_elf.dll, v8 snapshots, GPU/ANGLE dlls. Skip import libs.
Get-ChildItem (Join-Path $root.FullName 'Release') -File |
  Where-Object { $_.Extension -ne '.lib' } |
  Copy-Item -Destination $stage
# Resources\ = icudtl.dat, *.pak, locales\
Copy-Item (Join-Path $root.FullName 'Resources\*') -Destination $stage -Recurse

if (-not (Test-Path (Join-Path $stage 'libcef.dll'))) { throw 'libcef.dll missing from staged runtime' }

$outPath = Join-Path $repo $OutDir
New-Item -ItemType Directory -Force $outPath | Out-Null
$zip = Join-Path $outPath "cef-runtime-$CefVersion-win64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Write-Host 'Zipping...'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ''
Write-Host "Runtime zip : $zip ($size MB)"
Write-Host "SHA-256     : $hash"
Write-Host "Publish as  : https://github.com/riistar/Rua/releases/download/cef-$CefVersion/cef-runtime-$CefVersion-win64.zip"
