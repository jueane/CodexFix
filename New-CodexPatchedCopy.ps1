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
            (Test-Path -LiteralPath (Join-Path $_.FullName 'app\resources\app.asar')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'app\ChatGPT.exe'))
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
    $running = @(Get-Process -Name "ChatGPT","Codex","codex" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $ids = ($running | Select-Object -ExpandProperty Id) -join ", "
        throw "Close Codex before creating the patched copy. Running process IDs: $ids"
    }
}

function New-PatchSpec {
    param([string]$Name, [string]$Original, [string]$Patched)
    $encoding = [System.Text.Encoding]::UTF8
    $originalBytes = $encoding.GetBytes($Original)
    $patchedBytes = $encoding.GetBytes($Patched.PadRight($Original.Length))
    if ($originalBytes.Length -ne $patchedBytes.Length) {
        throw "Patch '$Name' changes the byte length."
    }
    [pscustomobject]@{ Name = $Name; OriginalBytes = $originalBytes; PatchedBytes = $patchedBytes }
}

function Update-CodexAsar {
    param([string]$Path, [string]$Backup)

    if (-not ('CodexFix.ByteSearch' -as [type])) {
        Add-Type -TypeDefinition @'
namespace CodexFix {
    public static class ByteSearch {
        public static int IndexOf(byte[] haystack, byte[] needle, int start) {
            if (haystack == null || needle == null || needle.Length == 0) return -1;
            int limit = haystack.Length - needle.Length;
            for (int i = start; i <= limit; i++) {
                if (haystack[i] != needle[0]) continue;
                int j = 1;
                for (; j < needle.Length && haystack[i + j] == needle[j]; j++) {}
                if (j == needle.Length) return i;
            }
            return -1;
        }
    }
}
'@
    }

    $patches = @(
        (New-PatchSpec -Name 'Disable /wham/tasks/list polling' `
            -Original 'enabled:!0,placeholderData:Fr,queryFn:async()=>{try{return(await kg.safeGet(`/wham/tasks/list`,{parameters:{query:{limit:20,task_filter:`current`}}})).items}' `
            -Patched  'enabled:!1,placeholderData:Fr,queryFn:async()=>{try{return(await kg.safeGet(`/wham/tasks/list`,{parameters:{query:{limit:20,task_filter:`current`}}})).items}'),
        (New-PatchSpec -Name 'Disable /wham/usage polling' `
            -Original 'async function YOn({additionalHeaders:e,signal:t}){try{return NOn(await kg.safeGet(`/wham/usage`,{additionalHeaders:{"OAI-App-Brand":mg.toLowerCase(),...e},signal:t}))}catch(e){if(e instanceof xg&&[401,403,404].includes(e.status))return null;throw e}}' `
            -Patched  'async function YOn(){return null}')
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $writes = New-Object System.Collections.Generic.List[object]
    foreach ($patch in $patches) {
        $original = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.OriginalBytes, 0)
        $patched = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.PatchedBytes, 0)
        if ($original -ge 0 -and [CodexFix.ByteSearch]::IndexOf($bytes, $patch.OriginalBytes, $original + 1) -ge 0) {
            throw "Patch '$($patch.Name)' matched more than once."
        }
        if ($patched -ge 0 -and [CodexFix.ByteSearch]::IndexOf($bytes, $patch.PatchedBytes, $patched + 1) -ge 0) {
            throw "Patched bytes for '$($patch.Name)' matched more than once."
        }
        if ($original -ge 0 -and $patched -ge 0) { throw "Both original and patched bytes found for '$($patch.Name)'." }
        if ($original -lt 0 -and $patched -lt 0) { throw "Unsupported Codex version: '$($patch.Name)' not found." }
        if ($original -ge 0) {
            [Array]::Copy($patch.PatchedBytes, 0, $bytes, $original, $patch.PatchedBytes.Length)
            $writes.Add([pscustomobject]@{ Offset = $original; Bytes = $patch.PatchedBytes })
        }
    }

    if ($writes.Count -gt 0) {
        if (Test-Path -LiteralPath $Backup) {
            Write-Host "Backup already exists, keeping it: $Backup"
        } else {
            Copy-Item -LiteralPath $Path -Destination $Backup
            Write-Host "Backup written: $Backup"
        }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            foreach ($write in $writes) {
                $stream.Seek($write.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $stream.Write($write.Bytes, 0, $write.Bytes.Length)
            }
            $stream.Flush($true)
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    $verified = [System.IO.File]::ReadAllBytes($Path)
    foreach ($patch in $patches) {
        $original = [CodexFix.ByteSearch]::IndexOf($verified, $patch.OriginalBytes, 0)
        $patched = [CodexFix.ByteSearch]::IndexOf($verified, $patch.PatchedBytes, 0)
        if ($original -ge 0 -or $patched -lt 0 -or
            [CodexFix.ByteSearch]::IndexOf($verified, $patch.PatchedBytes, $patched + 1) -ge 0) {
            throw "Post-patch verification failed for '$($patch.Name)'."
        }
    }
}

function Update-OriginalShortcuts {
    $shell = New-Object -ComObject WScript.Shell
    $explorer = Join-Path $env:WINDIR 'explorer.exe'
    $paths = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Original.lnk'),
        (Join-Path $PSScriptRoot 'Codex Original.lnk')
    ) | Select-Object -Unique
    foreach ($path in $paths) {
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $explorer
        $shortcut.Arguments = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
        $shortcut.Description = 'Codex original installed app'
        $shortcut.Save()
    }
    $paths
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

if (-not (Test-Path -LiteralPath $portableAsar)) {
    throw "Copied package does not contain app.asar: $portableAsar"
}

Write-Host "Patching writable copy: $portableAsar"
Update-CodexAsar -Path $portableAsar -Backup $portableBackup

$exe = Join-Path $target 'app\ChatGPT.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Copied package does not contain app\ChatGPT.exe: $exe"
}

$originalShortcuts = Update-OriginalShortcuts

[pscustomobject]@{
    SourcePackage = $source
    PortablePackage = $target
    PortableAsar = $portableAsar
    PortableBackup = $portableBackup
    StartScript = (Join-Path $PSScriptRoot 'Start-CodexPatched.cmd')
    OriginalShortcuts = $originalShortcuts
    Executable = $exe
} | ConvertTo-Json -Depth 3
