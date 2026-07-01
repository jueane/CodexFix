#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourcePackageDir,
    [string]$PortableRoot,
    [string]$PortablePackageDir,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DefaultCodexPackageDir {
    $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
    if (-not (Test-Path -LiteralPath $windowsApps)) {
        throw "WindowsApps directory not found: $windowsApps"
    }

    $candidate = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName "app\Codex.exe")) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName "app\resources\app.asar"))
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "Codex package directory was not found under $windowsApps"
    }

    return $candidate.FullName
}

function Resolve-PackageDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return Get-DefaultCodexPackageDir
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-CodexClosed {
    $running = @(Get-Process -Name "Codex","codex" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $ids = ($running | Select-Object -ExpandProperty Id) -join ", "
        throw "Close Codex before creating the patched copy. Running process IDs: $ids"
    }
}

$source = Resolve-PackageDir -Path $SourcePackageDir
Assert-CodexClosed

if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $PSScriptRoot "portable"
}

if ([string]::IsNullOrWhiteSpace($PortablePackageDir)) {
    $PortablePackageDir = Join-Path $PortableRoot (Split-Path -Leaf $source)
}

$target = $PortablePackageDir
$sourceFull = [System.IO.Path]::GetFullPath($source)
$targetFull = [System.IO.Path]::GetFullPath($target)
if ($sourceFull.TrimEnd('\') -ieq $targetFull.TrimEnd('\')) {
    throw "Portable package directory must not be the installed WindowsApps package directory."
}

if ((Test-Path -LiteralPath $target) -and $Force) {
    Remove-Item -LiteralPath $target -Recurse -Force
}

$targetParent = Split-Path -Parent $target
if (-not [string]::IsNullOrWhiteSpace($targetParent)) {
    New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
}

Write-Host "Copying Codex package to writable directory: $target"
& robocopy.exe $source $target /E /R:2 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NP | Out-Host
$robocopyExit = $LASTEXITCODE
if ($robocopyExit -ge 8) {
    throw "robocopy.exe failed with exit code $robocopyExit"
}

$portableAsar = Join-Path $target "app\resources\app.asar"
$portableBackup = Join-Path $target "app\resources\app.asar.codexfix.bak"
$repairScript = Join-Path $PSScriptRoot "Repair-CodexWhamPolling.ps1"

if (-not (Test-Path -LiteralPath $portableAsar)) {
    throw "Copied package does not contain app.asar: $portableAsar"
}

Write-Host "Patching writable copy: $portableAsar"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -TargetAsar $portableAsar -BackupPath $portableBackup
if ($LASTEXITCODE -ne 0) {
    throw "Repair script failed for portable copy with exit code $LASTEXITCODE"
}

$exe = Join-Path $target "app\Codex.exe"
$shortcutScript = Join-Path $PSScriptRoot "New-CodexPatchedShortcuts.ps1"

Write-Host "Creating shortcuts for patched copy: $exe"
$shortcutJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutScript -PortablePackageDir $target
if ($LASTEXITCODE -ne 0) {
    throw "Shortcut script failed for portable copy with exit code $LASTEXITCODE"
}
$shortcutResult = ($shortcutJson -join [Environment]::NewLine) | ConvertFrom-Json

[pscustomobject]@{
    SourcePackage = $source
    PortablePackage = $target
    PortableAsar = $portableAsar
    PortableBackup = $portableBackup
    ShortcutScript = $shortcutScript
    Shortcuts = $shortcutResult.Shortcuts
    Executable = $exe
} | ConvertTo-Json -Depth 3
