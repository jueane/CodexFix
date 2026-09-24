#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$portableRoot = Join-Path $PSScriptRoot 'portable'
$copy = Get-ChildItem -LiteralPath $portableRoot -Directory -Filter 'OpenAI.Codex_*_x64__2p2nqsd0c76g0' -ErrorAction Stop |
    Where-Object { $_.Name -match '^OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_x64__2p2nqsd0c76g0$' -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'app\ChatGPT.exe')) } |
    Sort-Object { [version]($_.Name -replace '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$', '$1') } -Descending |
    Select-Object -First 1

if ($null -eq $copy) {
    throw "No portable Codex copy with app\ChatGPT.exe found in $portableRoot. Run New-CodexPatchedCopy.ps1 first."
}

$package = Get-AppxPackage -Name 'OpenAI.Codex' |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $package) {
    throw 'The installed OpenAI.Codex package was not found.'
}

Invoke-CommandInDesktopPackage `
    -PackageFamilyName $package.PackageFamilyName `
    -AppId 'App' `
    -Command (Join-Path $copy.FullName 'app\ChatGPT.exe') `
    -PreventBreakaway
