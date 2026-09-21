#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedExecutable = (Resolve-Path -LiteralPath $Executable).Path
$package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $package) {
    throw "The installed OpenAI.Codex package was not found. Install Codex before starting the patched copy."
}

$invokeCommand = Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue
if ($null -eq $invokeCommand) {
    throw "Invoke-CommandInDesktopPackage is unavailable on this Windows installation."
}

Invoke-CommandInDesktopPackage `
    -PackageFamilyName $package.PackageFamilyName `
    -AppId "App" `
    -Command $resolvedExecutable `
    -PreventBreakaway
