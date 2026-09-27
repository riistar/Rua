<#
  Builds the Wine/Linux bundle: release\Rua-<ver>-win64-wine.zip

    Rua/
      Rua.exe, sqlite3.dll, WebView2Loader.dll, nxl3p_shim.dll, nxl3p_stub.exe
      README-LINUX.md
      cef/   <- Chromium runtime (found by uCefRuntime.CefBundledDir, no download)

  The CEF runtime is taken from release\cef-runtime-<cefver>-win64.zip; run
  build/package-cef-runtime.ps1 first if it is missing. Build Rua.exe (Release/Win64) first.

  Usage (repo root):  powershell -File build/package-wine.ps1
#>
param(
  [string]$CefVersion = '154.0.26',
  [string]$OutDir     = 'release'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$rel  = Join-Path $repo $OutDir

$dproj = Get-Content (Join-Path $repo 'delphi\Rua.dproj') -Raw
$m = [regex]::Match($dproj, 'FileVersion=(\d+\.\d+\.\d+)')
$ver = if ($m.Success) { $m.Groups[1].Value } else { 'dev' }

$runtimeZip = Join-Path $rel "cef-runtime-$CefVersion-win64.zip"
if (-not (Test-Path $runtimeZip)) { throw "Missing $runtimeZip - run build/package-cef-runtime.ps1 first" }

$files = 'Rua.exe', 'sqlite3.dll', 'WebView2Loader.dll', 'nxl3p_shim.dll', 'nxl3p_stub.exe'
foreach ($f in $files) {
  if (-not (Test-Path (Join-Path $rel $f))) { throw "Missing $OutDir\$f" }
}

$stage = Join-Path $env:TEMP "rua-wine-$ver"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$root = Join-Path $stage 'Rua'
New-Item -ItemType Directory -Force $root | Out-Null

foreach ($f in $files) { Copy-Item (Join-Path $rel $f) $root }
Copy-Item (Join-Path $repo 'README-LINUX.md') $root

Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host 'Extracting CEF runtime...'
[IO.Compression.ZipFile]::ExtractToDirectory($runtimeZip, (Join-Path $root 'cef'))
if (-not (Test-Path (Join-Path $root 'cef\libcef.dll'))) { throw 'libcef.dll missing from cef\' }

$zip = Join-Path $rel "Rua-$ver-win64-wine.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Write-Host 'Zipping...'
[IO.Compression.ZipFile]::CreateFromDirectory($root, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Remove-Item -Recurse -Force $stage

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Write-Host ''
Write-Host "Wine bundle : $zip ($size MB)"
Write-Host "SHA-256     : $hash"
