#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PortableRoot,
    [string]$PortablePackageDir,
    [string]$ShortcutDirectory,
    [string]$ShortcutName = "Codex Patched.lnk",
    [string]$OriginalShortcutName = "Codex Original.lnk"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CodexPackageVersion {
    param([System.IO.DirectoryInfo]$Directory)

    if ($Directory.Name -match '^OpenAI\.Codex_(?<Version>\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$') {
        return [version]$Matches.Version
    }

    return [version]"0.0.0.0"
}

function Get-DefaultPortablePackageDir {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Portable directory not found. Run New-CodexPatchedCopy.ps1 first: $Root"
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "app\Codex.exe") } |
        Sort-Object @{ Expression = { Get-CodexPackageVersion -Directory $_ }; Descending = $true }, @{ Expression = { $_.LastWriteTime }; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No patched Codex copy was found under $Root. Run New-CodexPatchedCopy.ps1 first."
    }

    return $candidate.FullName
}

function New-CodexShortcut {
    param(
        [object]$Shell,
        [string]$ShortcutPath,
        [string]$Executable
    )

    $workingDirectory = Split-Path -Parent $Executable
    $shortcut = $Shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $Executable
    $shortcut.Arguments = ""
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.IconLocation = "$Executable,0"
    $shortcut.Description = "Codex patched portable copy"
    $shortcut.Save()

    return [pscustomobject]@{
        Kind = "Patched"
        Shortcut = $ShortcutPath
        Target = $Executable
        WorkingDirectory = $workingDirectory
    }
}

function Resolve-ShortcutName {
    param([string]$Name)

    if (-not $Name.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "$Name.lnk"
    }

    return $Name
}

function New-CodexOriginalShortcut {
    param(
        [object]$Shell,
        [string]$ShortcutPath
    )

    $explorer = Join-Path $env:WINDIR "explorer.exe"
    if (-not (Test-Path -LiteralPath $explorer)) {
        $explorer = "explorer.exe"
    }

    $arguments = "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
    $shortcut = $Shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $explorer
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = ""
    $shortcut.IconLocation = "$explorer,0"
    $shortcut.Description = "Codex original installed app"
    $shortcut.Save()

    return [pscustomobject]@{
        Kind = "Original"
        Shortcut = $ShortcutPath
        Target = $explorer
        Arguments = $arguments
        WorkingDirectory = ""
    }
}

if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $PSScriptRoot "portable"
}

if ([string]::IsNullOrWhiteSpace($PortablePackageDir)) {
    $PortablePackageDir = Get-DefaultPortablePackageDir -Root $PortableRoot
} else {
    $PortablePackageDir = (Resolve-Path -LiteralPath $PortablePackageDir).Path
}

if ([string]::IsNullOrWhiteSpace($ShortcutDirectory)) {
    $ShortcutDirectory = $PSScriptRoot
} else {
    $ShortcutDirectory = (Resolve-Path -LiteralPath $ShortcutDirectory).Path
}

$ShortcutName = Resolve-ShortcutName -Name $ShortcutName
$OriginalShortcutName = Resolve-ShortcutName -Name $OriginalShortcutName

$exe = Join-Path $PortablePackageDir "app\Codex.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Codex executable not found: $exe"
}

$desktop = [Environment]::GetFolderPath("Desktop")
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw "Desktop directory could not be resolved for the current user."
}

$patchedShortcutTargets = @(
    (Join-Path $desktop $ShortcutName),
    (Join-Path $ShortcutDirectory $ShortcutName)
) | Select-Object -Unique

$originalShortcutTargets = @(
    (Join-Path $desktop $OriginalShortcutName),
    (Join-Path $ShortcutDirectory $OriginalShortcutName)
) | Select-Object -Unique

$shell = New-Object -ComObject WScript.Shell
$shortcuts = @()
$shortcuts += @($patchedShortcutTargets | ForEach-Object {
    New-CodexShortcut -Shell $shell -ShortcutPath $_ -Executable $exe
})
$shortcuts += @($originalShortcutTargets | ForEach-Object {
    New-CodexOriginalShortcut -Shell $shell -ShortcutPath $_
})

[pscustomobject]@{
    PortablePackage = $PortablePackageDir
    Executable = $exe
    Shortcuts = $shortcuts
} | ConvertTo-Json -Depth 4
