<#
.SYNOPSIS
    Downloads the portable toolchain used by the local build/test scripts.

.DESCRIPTION
    Fetches a portable Lua 5.1 interpreter (LuaBinaries) and the selene linter
    into tools/. Both are gitignored. Run once, or with -Force to refresh.
#>
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$tools = $PSScriptRoot

$luaDir = Join-Path $tools "lua51"
$seleneDir = Join-Path $tools "selene"

function Get-File($url, $dest) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

if ($Force -or -not (Test-Path (Join-Path $luaDir "lua5.1.exe"))) {
    $zip = Join-Path $env:TEMP "lua51.zip"
    Get-File "https://sourceforge.net/projects/luabinaries/files/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip/download" $zip
    Remove-Item -Recurse -Force $luaDir -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $luaDir -Force
    Write-Host "Lua installed in $luaDir"
} else {
    Write-Host "Lua already present in $luaDir"
}

if ($Force -or -not (Test-Path (Join-Path $seleneDir "selene.exe"))) {
    $zip = Join-Path $env:TEMP "selene.zip"
    Get-File "https://github.com/Kampfkarren/selene/releases/download/0.31.0/selene-0.31.0-windows.zip" $zip
    Remove-Item -Recurse -Force $seleneDir -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $seleneDir -Force
    Write-Host "selene installed in $seleneDir"
} else {
    Write-Host "selene already present in $seleneDir"
}
