<#
.SYNOPSIS
    Collects the Goodreads plugin's login/session logs from a connected Kindle.

.DESCRIPTION
    Finds the Kindle drive, prints the plugin login trace and the relevant
    crash.log lines, and saves copies under Downloads\goodreadskosync-debug so they
    can be attached to a bug report. Contains no passwords, cookies, or tokens.
#>

param(
    [string]$Drive = ""
)

$ErrorActionPreference = "SilentlyContinue"

if ($Drive) {
    $root = "$Drive"
    if ($root -notmatch ":$") { $root = "${root}:" }
} else {
    # Prefer E: (common Kindle mount), otherwise auto-detect.
    $root = (Get-PSDrive -PSProvider FileSystem |
        Where-Object { Test-Path "$($_.Root)koreader" } |
        Sort-Object { if ($_.Root -eq "E:\") { 0 } else { 1 } } |
        Select-Object -First 1).Root
}

if (-not $root) {
    Write-Host "Kindle not found. Plug it in, unlock it, and try again." -ForegroundColor Red
    exit 1
}

$koreader = Join-Path $root "koreader"
$out = Join-Path $env:USERPROFILE "Downloads\goodreadskosync-debug"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$loginLog = Join-Path $koreader "settings\goodreadskosync\login.log"
$crashLog = Join-Path $koreader "crash.log"

Write-Host "Kindle: $root" -ForegroundColor Green

Write-Host ""
Write-Host "=== login.log ===" -ForegroundColor Cyan
if (Test-Path $loginLog) {
    Get-Content $loginLog
    Copy-Item $loginLog $out -Force
} else {
    Write-Host "(missing - the plugin did not reach the login flow, or KOReader was not restarted)"
}

Write-Host ""
Write-Host "=== crash.log (goodreads lines) ===" -ForegroundColor Cyan
if (Test-Path $crashLog) {
    $lines = Get-Content $crashLog |
        Select-String -Pattern "goodreads|login/|ap/signin|ap-handler" |
        Select-Object -Last 200
    if ($lines) {
        $lines | ForEach-Object { $_.Line }
        $lines | ForEach-Object { $_.Line } | Set-Content (Join-Path $out "crash-goodreads.txt")
    } else {
        Write-Host "(no goodreads lines found)"
    }
} else {
    Write-Host "(missing)"
}

Write-Host ""
Write-Host "Copies saved to: $out" -ForegroundColor Green
