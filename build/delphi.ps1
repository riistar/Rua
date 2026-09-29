param(
    [ValidateSet('Debug', 'Release', 'All')]
    [string]$Config = 'Release',
    [string]$Project,
    [string]$Release
)

$Root = Split-Path $PSScriptRoot
$DelphiDir = Join-Path $Root 'delphi'
$ReleaseDir = Join-Path $Root 'release'
$RsVars = 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat'

function Build-Project($ProjectFile, $Platform, $BuildConfig) {
    $ProjPath = Join-Path $DelphiDir $ProjectFile
    Write-Host "`n=== $ProjectFile ($Platform, $BuildConfig) ===" -ForegroundColor Cyan
    $args = "/t:Build /p:Config=$BuildConfig /p:Platform=$Platform `"$ProjPath`""
    cmd /c "`"$RsVars`" && msbuild $args"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $ProjectFile ($Platform, $BuildConfig)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

function Build-All($BuildConfig) {
    Build-Project 'Rua.dproj' 'Win64' $BuildConfig
    Build-Project 'RuaAPI.dproj' 'Win64' $BuildConfig
    Build-Project 'nxl3p_shim.dproj' 'Win64' $BuildConfig
    Build-Project 'nxl3p_stub.dproj' 'Win32' $BuildConfig
}

function Finalize-Release {
    # Copy API header alongside the DLL
    $HeaderSrc = Join-Path $DelphiDir 'RuaAPI.h'
    $HeaderDst = Join-Path $ReleaseDir 'RuaAPI.h'
    if (Test-Path $HeaderSrc) {
        Copy-Item $HeaderSrc $HeaderDst -Force
        Write-Host "Copied RuaAPI.h -> release/" -ForegroundColor Gray
    }

    # Release builds go directly to release/ - just ensure runtime DLLs are there
    $RuntimeDlls = @('sqlite3.dll', 'WebView2Loader.dll')
    foreach ($dll in $RuntimeDlls) {
        $src = Join-Path $ReleaseDir $dll
        if (-not (Test-Path $src)) {
            Write-Host "WARNING: $dll not found in release/ - copy manually" -ForegroundColor Yellow
        }
    }
    Write-Host "`nRelease ready: $ReleaseDir" -ForegroundColor Green
    Get-ChildItem $ReleaseDir | ForEach-Object { Write-Host "  $($_.Name)" }

    if ($Release) {
        Create-Release $Release
    }
}

function Create-Release($Tag) {
    # Gather all non-zip files from release/
    $Assets = Get-ChildItem $ReleaseDir -File |
        Where-Object { $_.Extension -ne '.zip' } |
        ForEach-Object { $_.FullName }

    # Add doc files
    $DocsDir = Join-Path $Root 'docs'
    foreach ($doc in @('CLI.md', 'DLL-API.md')) {
        $p = Join-Path $DocsDir $doc
        if (Test-Path $p) { $Assets += $p }
    }

    Write-Host "`nCreating release $Tag with assets:" -ForegroundColor Cyan
    $Assets | ForEach-Object { Write-Host "  $_" }

    & gh release create $Tag --generate-notes @Assets
    if ($LASTEXITCODE -ne 0) {
        Write-Host "gh release create failed" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "Release $Tag created." -ForegroundColor Green
}

if ($Project) {
    switch ($Project) {
        'Rua'    { Build-Project 'Rua.dproj' 'Win64' $Config }
        'api'    { Build-Project 'RuaAPI.dproj' 'Win64' $Config }
        'shim'   { Build-Project 'nxl3p_shim.dproj' 'Win64' $Config }
        'stub'   { Build-Project 'nxl3p_stub.dproj' 'Win32' $Config }
        default {
            Write-Host "Unknown project: $Project. Use Rua, api, shim, or stub." -ForegroundColor Red
            exit 1
        }
    }
} else {
    switch ($Config) {
        'Debug'   { Build-All 'Debug' }
        'Release' { Build-All 'Release'; Finalize-Release }
        'All'     { Build-All 'Debug'; Build-All 'Release'; Finalize-Release }
    }
}

Write-Host "`nDone." -ForegroundColor Green
