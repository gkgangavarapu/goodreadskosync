<#
.SYNOPSIS
    Local build/test/package entry point (Windows mirror of the Makefile).

.EXAMPLE
    tools\build.ps1 check
    tools\build.ps1 test
    tools\build.ps1 package
    tools\build.ps1 all
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "test", "package", "checksum", "clean", "all")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$plugin = Join-Path $root "goodreadskosync.koplugin"
$lua = Join-Path $PSScriptRoot "lua51\lua5.1.exe"
$luac = Join-Path $PSScriptRoot "lua51\luac5.1.exe"
$selene = Join-Path $PSScriptRoot "selene\selene.exe"
$dist = Join-Path $root "dist"

function Get-Version {
    $content = Get-Content (Join-Path $plugin "goodreadskosync\constants.lua") -Raw
    if ($content -match 'VERSION\s*=\s*"([^"]+)"') { return $Matches[1] }
    throw "Could not determine plugin version"
}

function Invoke-Check {
    if (-not (Test-Path $luac)) { throw "Run tools\setup.ps1 first (missing $luac)" }
    Write-Host "==> syntax check (luac -p)"
    $files = Get-ChildItem -Recurse -Filter *.lua -Path $plugin
    foreach ($file in $files) {
        & $luac -p $file.FullName
        if ($LASTEXITCODE -ne 0) { throw "Syntax error in $($file.FullName)" }
    }
    Write-Host "    $($files.Count) files OK"

    Write-Host "==> lint (selene)"
    if (Test-Path $selene) {
        Push-Location $root
        try {
            & $selene "goodreadskosync.koplugin" "tests"
            if ($LASTEXITCODE -ne 0) { throw "selene reported problems" }
        } finally {
            Pop-Location
        }
    } else {
        Write-Warning "selene not installed; skipping. Run tools\setup.ps1."
    }

    Write-Host "==> no accidental debug prints"
    $bad = Get-ChildItem -Recurse -Filter *.lua -Path $plugin |
        Select-String -Pattern '^\s*print\('
    if ($bad) {
        $bad | ForEach-Object { Write-Host "    $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
        throw "Found bare print() calls in plugin source"
    }
    Write-Host "    OK"
}

function Invoke-Test {
    if (-not (Test-Path $lua)) { throw "Run tools\setup.ps1 first (missing $lua)" }
    Write-Host "==> unit tests"
    Push-Location $root
    try {
        & $lua (Join-Path $root "tests\run.lua")
        if ($LASTEXITCODE -ne 0) { throw "Tests failed" }
    } finally {
        Pop-Location
    }
}

function Invoke-Package {
    Write-Host "==> package"
    $version = Get-Version
    if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
    $zip = Join-Path $dist "goodreadskosync-$version.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    Push-Location $root
    try {
        Compress-Archive -Path "goodreadskosync.koplugin" -DestinationPath $zip -Force
    } finally {
        Pop-Location
    }
    Write-Host "    built $zip"
    return $zip
}

function Invoke-Checksum {
    $zip = Invoke-Package
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    $sumFile = "$zip.sha256"
    "$hash  $(Split-Path $zip -Leaf)" | Set-Content $sumFile
    Write-Host "    $hash"
    return $zip
}

function Invoke-Clean {
    Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $root "tests\.tmp") -ErrorAction SilentlyContinue
    Write-Host "cleaned"
}

switch ($Target) {
    "check" { Invoke-Check }
    "test" { Invoke-Test }
    "package" { Invoke-Package | Out-Null }
    "checksum" { Invoke-Checksum | Out-Null }
    "clean" { Invoke-Clean }
    "all" { Invoke-Check; Invoke-Test; Invoke-Checksum | Out-Null }
}
