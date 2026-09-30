<#
.SYNOPSIS
    Builds (optionally) and installs the latest goodreadskosync.koplugin package onto
    a connected Kindle, and extracts it to Downloads.

.EXAMPLE
    tools\install-kindle.ps1
    tools\install-kindle.ps1 -Drive E
#>
param(
    [string]$Drive = "",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "build.ps1") package | Out-Null
}

$dist = Join-Path $repo "dist"
$zip = Get-ChildItem -Path $dist -Filter "goodreadskosync-*.zip" |
    Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $zip) { throw "No package found in $dist. Run tools\build.ps1 package first." }

$downloads = Join-Path $env:USERPROFILE "Downloads"
$src = Join-Path $downloads "goodreadskosync.koplugin"
Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
Expand-Archive -Path $zip.FullName -DestinationPath $downloads -Force

if ($Drive) {
    $root = "$Drive"
    if ($root -notmatch ":$") { $root = "${root}:" }
} else {
    $root = (Get-PSDrive -PSProvider FileSystem |
        Where-Object { Test-Path "$($_.Root)koreader" } |
        Sort-Object { if ($_.Root -eq "E:\") { 0 } else { 1 } } |
        Select-Object -First 1).Root
}
if (-not $root) { throw "Kindle not found. Plug it in and unlock it." }

$plugins = Join-Path $root "koreader\plugins"
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
$dst = Join-Path $plugins "goodreadskosync.koplugin"
Remove-Item -Recurse -Force $dst -ErrorAction SilentlyContinue
# Remove the legacy folder name so KOReader does not load two copies.
Remove-Item -Recurse -Force (Join-Path $plugins "goodreads.koplugin") -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $src $dst

Write-Host ""
Write-Host "Installed $($zip.Name)" -ForegroundColor Green
Write-Host "  to      $dst"
Write-Host "  copied  $src"
Write-Host ""
Write-Host "Safely eject the Kindle, then restart KOReader." -ForegroundColor Yellow
