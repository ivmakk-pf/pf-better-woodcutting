<#
.SYNOPSIS
Makes the install zip dist/BetterWoodcutting-<version>.zip.

.DESCRIPTION
The version comes from the VERSION constant in Scripts/main.lua. The zip holds the path from the game root
(Permafrost/Binaries/Win64/ue4ss/Mods/BetterWoodcutting/), so a player extracts it in the game folder. It holds
Scripts/ with its subfolders and an empty enabled.txt, never config.lua: the mod writes that file at the first start.

.EXAMPLE
./package.ps1
#>
$ErrorActionPreference = 'Stop'

$mod = 'BetterWoodcutting'
$main = Join-Path $PSScriptRoot 'Scripts/main.lua'
$match = Select-String -LiteralPath $main -Pattern '^local VERSION = "(\d+\.\d+\.\d+)"$'
if (-not $match) { throw "No VERSION constant in $main" }
$version = $match.Matches[0].Groups[1].Value

$stage = Join-Path ([System.IO.Path]::GetTempPath()) "$mod-package-$([guid]::NewGuid())"
$modDir = Join-Path $stage "Permafrost/Binaries/Win64/ue4ss/Mods/$mod"
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $modDir 'Scripts') | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'Scripts/*') -Destination (Join-Path $modDir 'Scripts') -Recurse
    New-Item -ItemType File -Path (Join-Path $modDir 'enabled.txt') | Out-Null

    $dist = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $zip = Join-Path $dist "$mod-$version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    Compress-Archive -Path (Join-Path $stage 'Permafrost') -DestinationPath $zip

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $archive.Entries | ForEach-Object { $_.FullName }
    } finally {
        $archive.Dispose()
    }
    Write-Host "Packaged $zip"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
