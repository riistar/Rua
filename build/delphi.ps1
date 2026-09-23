param(
    [ValidateSet('Debug', 'Release', 'All')]
    [string]$Config = 'Release',
    [string]$Project
)

$Root = Split-Path -LiteralPath $PSScriptRoot -Parent
$DelphiDir = Join-Path $Root 'delphi'
$ReleaseDir = Join-Path $Root 'release'

function Build-Project($ProjectFile, $Platform, $BuildConfig) {
    $ProjPath = Join-Path $DelphiDir $ProjectFile
    Write-Host "`n=== $ProjectFile ($Platform, $BuildConfig) ===" -ForegroundColor Cyan
    & msbuild /t:Build "/p:Config=$BuildConfig" "/p:Platform=$Platform" $ProjPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $ProjectFile ($Platform, $BuildConfig)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

function Build-All($BuildConfig) {
    Build-Project 'Rua.dproj' 'Win64' $BuildConfig
    Build-Project 'nxl3p_shim.dproj' 'Win64' $BuildConfig
    Build-Project 'nxl3p_stub.dproj' 'Win32' $BuildConfig
}

function Finalize-Release {
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
}

if ($Project) {
    switch ($Project) {
        'Rua'  { Build-Project 'Rua.dproj' 'Win64' $Config }
        'shim' { Build-Project 'nxl3p_shim.dproj' 'Win64' $Config }
        'stub' { Build-Project 'nxl3p_stub.dproj' 'Win32' $Config }
        default {
            Write-Host "Unknown project: $Project. Use Rua, shim, or stub." -ForegroundColor Red
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
