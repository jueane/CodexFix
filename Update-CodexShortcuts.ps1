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

function Resolve-CodexPackageExecutable {
    param([string]$PackageDir)

    $manifest = Join-Path $PackageDir "AppxManifest.xml"
    if (Test-Path -LiteralPath $manifest) {
        try {
            [xml]$manifestXml = Get-Content -LiteralPath $manifest -Raw
            $application = $manifestXml.SelectSingleNode("//*[local-name()='Application' and @Executable]")
            if ($null -ne $application) {
                $relativeExecutable = $application.Executable.Replace('/', '\')
                $candidate = Join-Path $PackageDir $relativeExecutable
                if (Test-Path -LiteralPath $candidate) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        } catch {
            Write-Warning "Could not read app executable from manifest: $manifest"
        }
    }

    foreach ($relativeExecutable in @("app\ChatGPT.exe", "app\Codex.exe")) {
        $candidate = Join-Path $PackageDir $relativeExecutable
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Codex executable not found under package directory: $PackageDir"
}

function Get-DefaultPortablePackageDir {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Portable directory not found. Run New-CodexPatchedCopy.ps1 first: $Root"
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                Resolve-CodexPackageExecutable -PackageDir $_.FullName | Out-Null
                return $true
            } catch {
                return $false
            }
        } |
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
        [string]$Executable,
        [string]$LauncherScript
    )

    $powerShell = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShell)) {
        $powerShell = "powershell.exe"
    }

    $workingDirectory = Split-Path -Parent $Executable
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherScript`" -Executable `"$Executable`""
    $shortcut = $Shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $powerShell
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.IconLocation = "$Executable,0"
    $shortcut.Description = "Codex patched copy with Windows package identity"
    $shortcut.Save()

    return [pscustomobject]@{
        Kind = "Patched"
        Shortcut = $ShortcutPath
        Target = $powerShell
        Arguments = $arguments
        Executable = $Executable
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

$exe = Resolve-CodexPackageExecutable -PackageDir $PortablePackageDir
$launcherScript = Join-Path $PSScriptRoot "Start-CodexPatched.ps1"
if (-not (Test-Path -LiteralPath $launcherScript)) {
    throw "Patched Codex launcher script not found: $launcherScript"
}
$launcherScript = (Resolve-Path -LiteralPath $launcherScript).Path

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
    New-CodexShortcut -Shell $shell -ShortcutPath $_ -Executable $exe -LauncherScript $launcherScript
})
$shortcuts += @($originalShortcutTargets | ForEach-Object {
    New-CodexOriginalShortcut -Shell $shell -ShortcutPath $_
})

[pscustomobject]@{
    PortablePackage = $PortablePackageDir
    Executable = $exe
    Shortcuts = $shortcuts
} | ConvertTo-Json -Depth 4
