#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TargetAsar,
    [string]$BackupPath,
    [switch]$TakeOwnership,
    [switch]$UseSystemTask,
    [switch]$ForceBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DefaultCodexAsarPath {
    $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
    if (-not (Test-Path -LiteralPath $windowsApps)) {
        throw "WindowsApps directory not found: $windowsApps"
    }

    $candidate = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $asar = Join-Path $_.FullName "app\resources\app.asar"
            if (Test-Path -LiteralPath $asar) { Get-Item -LiteralPath $asar }
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "Codex app.asar was not found under $windowsApps"
    }

    return $candidate.FullName
}

function Resolve-TargetAsar {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return Get-DefaultCodexAsarPath
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-CodexClosedIfInstalledTarget {
    param([string]$Path)
    $prefix = (Join-Path $env:ProgramFiles "WindowsApps\OpenAI.Codex_")
    if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $running = @(Get-Process -Name "ChatGPT","Codex","codex" -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            $ids = ($running | Select-Object -ExpandProperty Id) -join ", "
            throw "Close Codex before patching the installed app.asar. Running process IDs: $ids"
        }
    }
}

function Get-Sha256Hash {
    param([string]$Path)
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-ReadWriteAccess {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) { $stream.Close() }
    }
}

function Get-ReadWriteAccessError {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        return $null
    } catch {
        $errorRecord = $_.Exception
        while ($null -ne $errorRecord.InnerException) { $errorRecord = $errorRecord.InnerException }
        return "$($errorRecord.GetType().FullName): $($errorRecord.Message) (HResult=0x$('{0:X8}' -f $errorRecord.HResult))"
    } finally {
        if ($null -ne $stream) { $stream.Close() }
    }
}

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "-TakeOwnership requires an elevated PowerShell session."
    }
}

function Enable-WriteAccessForAdmins {
    param([string]$Path)
    Assert-Elevated
    Write-Host "Taking ownership of target file for Administrators: $Path"
    & takeown.exe /F $Path /A | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "takeown.exe failed with exit code $LASTEXITCODE" }
    & icacls.exe $Path /grant '*S-1-5-32-544:F' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "icacls.exe failed with exit code $LASTEXITCODE" }
}

function Copy-FileAsSystem {
    param(
        [string]$Source,
        [string]$Destination
    )

    Assert-Elevated

    $taskName = "CodexFix-SystemCopy-$([System.Guid]::NewGuid().ToString('N'))"
    $tempRoot = [System.IO.Path]::GetTempPath()
    $helperPath = Join-Path $tempRoot "$taskName.ps1"
    $resultPath = Join-Path $tempRoot "$taskName.json"

    $helper = @'
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = "Stop"

try {
    [System.IO.File]::Copy($Source, $Destination, $true)
    $stream = [System.IO.File]::OpenRead($Destination)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
    [pscustomobject]@{ Ok = $true; TargetSha256 = $hash } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 0
} catch {
    $errorRecord = $_.Exception
    while ($null -ne $errorRecord.InnerException) { $errorRecord = $errorRecord.InnerException }
    [pscustomobject]@{
        Ok = $false
        Exception = $errorRecord.GetType().FullName
        Message = $errorRecord.Message
        HResult = "0x$('{0:X8}' -f $errorRecord.HResult)"
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
'@

    Set-Content -LiteralPath $helperPath -Value $helper -Encoding UTF8

    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -Source `"$Source`" -Destination `"$Destination`" -ResultPath `"$resultPath`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $taskName
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        } while ($task.State -eq "Running" -and [DateTime]::UtcNow -lt $deadline)

        if ($task.State -eq "Running") {
            throw "SYSTEM copy task timed out after 60 seconds."
        }

        if (-not (Test-Path -LiteralPath $resultPath)) {
            throw "SYSTEM copy task did not write a result file. LastTaskResult=$($taskInfo.LastTaskResult)"
        }

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Ok) {
            throw "SYSTEM copy failed: $($result.Exception): $($result.Message) (HResult=$($result.HResult))"
        }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }
}

if (-not ("CodexFix.ByteSearch" -as [type])) {
    Add-Type -TypeDefinition @'
namespace CodexFix {
    public static class ByteSearch {
        public static int IndexOf(byte[] haystack, byte[] needle, int start) {
            if (haystack == null || needle == null || needle.Length == 0) return -1;
            if (start < 0) start = 0;
            int limit = haystack.Length - needle.Length;
            byte first = needle[0];
            for (int i = start; i <= limit; i++) {
                if (haystack[i] != first) continue;
                int j = 1;
                for (; j < needle.Length; j++) {
                    if (haystack[i + j] != needle[j]) break;
                }
                if (j == needle.Length) return i;
            }
            return -1;
        }
    }
}
'@
}

function New-PatchSpec {
    param(
        [string]$Name,
        [string]$Original,
        [string]$Patched
    )
    $encoding = [System.Text.Encoding]::UTF8
    $originalBytes = $encoding.GetBytes($Original)
    $patchedBytes = $encoding.GetBytes($Patched)
    if ($patchedBytes.Length -lt $originalBytes.Length) {
        $Patched = $Patched + (" " * ($originalBytes.Length - $patchedBytes.Length))
        $patchedBytes = $encoding.GetBytes($Patched)
    }
    if ($originalBytes.Length -ne $patchedBytes.Length) {
        throw "Patch '$Name' is invalid: original length $($originalBytes.Length), patched length $($patchedBytes.Length)"
    }
    [pscustomobject]@{
        Name = $Name
        Original = $Original
        Patched = $Patched
        OriginalBytes = $originalBytes
        PatchedBytes = $patchedBytes
    }
}

function New-PatchGroup {
    param(
        [string]$Name,
        [object[]]$Variants
    )

    [pscustomobject]@{
        Name = $Name
        Variants = $Variants
    }
}

$patchGroups = @(
    (New-PatchGroup `
        -Name "Disable sidebar /wham/tasks/list polling" `
        -Variants @(
            (New-PatchSpec `
                -Name "Disable sidebar /wham/tasks/list polling (26.915)" `
                -Original 'enabled:!0,placeholderData:Od,queryFn:async()=>{try{return(await oy.safeGet(`/wham/tasks/list`,{parameters:{query:{limit:20,task_filter:`current`}}})).items}' `
                -Patched  'enabled:!1,placeholderData:Od,queryFn:async()=>{try{return(await oy.safeGet(`/wham/tasks/list`,{parameters:{query:{limit:20,task_filter:`current`}}})).items}')
        )),
    (New-PatchGroup `
        -Name "Disable /wham/usage rate-limit polling" `
        -Variants @(
            (New-PatchSpec `
                -Name "Disable /wham/usage rate-limit polling (26.915)" `
                -Original 'async function EIa({additionalHeaders:e,signal:t}){try{let n=await oy.safeGet(`/wham/usage`,{additionalHeaders:{"OAI-App-Brand":Qv.toLowerCase(),...e},signal:t}),r=OIa.safeParse(n),i=NIa.safeParse(n),a=AIa.safeParse(n),o=MIa.safeParse(n);return{...n,ambient_usage:wIa.parse(n.ambient_usage),sidebar_usage_warnings:o.success?o.data.sidebar_usage_warnings:void 0,rate_limit_upsell:r.success?r.data.rate_limit_upsell:void 0,model_picker_upsell:i.success?i.data.model_picker_upsell:void 0,rate_limit_warning:a.success?a.data.rate_limit_warning:void 0}}catch(e){if(e instanceof Iv&&[401,403,404].includes(e.status))return null;throw e}}' `
                -Patched  'async function EIa(){return null}')
        ))
)

$target = Resolve-TargetAsar -Path $TargetAsar
Assert-CodexClosedIfInstalledTarget -Path $target

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $backupDir = Join-Path $PSScriptRoot "backups"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir "app.asar.codexfix.bak"
} else {
    $backup = $BackupPath
    $backupParent = Split-Path -Parent $backup
    if (-not [string]::IsNullOrWhiteSpace($backupParent)) {
        New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
    }
}

$workDir = Split-Path -Parent $backup
if ([string]::IsNullOrWhiteSpace($workDir)) { $workDir = $PSScriptRoot }

$bytes = [System.IO.File]::ReadAllBytes($target)
$changed = $false
$results = New-Object System.Collections.Generic.List[object]
$pendingWrites = New-Object System.Collections.Generic.List[object]

foreach ($patchGroup in $patchGroups) {
    $originalMatches = New-Object System.Collections.Generic.List[object]
    $patchedMatches = New-Object System.Collections.Generic.List[object]

    foreach ($patch in $patchGroup.Variants) {
        $originalIndex = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.OriginalBytes, 0)
        $patchedIndex = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.PatchedBytes, 0)

        if ($originalIndex -ge 0) {
            $secondOriginal = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.OriginalBytes, $originalIndex + 1)
            if ($secondOriginal -ge 0) {
                throw "Patch '$($patch.Name)' matched more than once. Refusing to patch this Codex version."
            }
            $originalMatches.Add([pscustomobject]@{ Patch = $patch; Offset = $originalIndex }) | Out-Null
        }

        if ($patchedIndex -ge 0) {
            $secondPatched = [CodexFix.ByteSearch]::IndexOf($bytes, $patch.PatchedBytes, $patchedIndex + 1)
            if ($secondPatched -ge 0) {
                throw "Patch '$($patch.Name)' matched patched bytes more than once. Refusing to patch this Codex version."
            }
            $patchedMatches.Add([pscustomobject]@{ Patch = $patch; Offset = $patchedIndex }) | Out-Null
        }
    }

    if ($originalMatches.Count -gt 0 -and $patchedMatches.Count -gt 0) {
        throw "Patch group '$($patchGroup.Name)' matched both original and patched variants. Refusing to patch this Codex version."
    }

    if ($originalMatches.Count -gt 1) {
        throw "Patch group '$($patchGroup.Name)' matched more than one original variant. Refusing to patch this Codex version."
    }

    if ($originalMatches.Count -eq 1) {
        $match = $originalMatches[0]
        $patch = $match.Patch
        [Array]::Copy($patch.PatchedBytes, 0, $bytes, $match.Offset, $patch.PatchedBytes.Length)
        $changed = $true
        $pendingWrites.Add([pscustomobject]@{ Offset = $match.Offset; Bytes = $patch.PatchedBytes }) | Out-Null
        $results.Add([pscustomobject]@{ Name = $patch.Name; Status = "patched"; Offset = $match.Offset }) | Out-Null
        continue
    }

    if ($patchedMatches.Count -gt 1) {
        throw "Patch group '$($patchGroup.Name)' matched more than one patched variant. Refusing to patch this Codex version."
    }

    if ($patchedMatches.Count -eq 1) {
        $match = $patchedMatches[0]
        $results.Add([pscustomobject]@{ Name = $match.Patch.Name; Status = "already_patched"; Offset = $match.Offset }) | Out-Null
        continue
    }

    throw "Patch group '$($patchGroup.Name)' did not match original or patched bytes. This Codex version is not supported by this script."
}

if ($changed) {
    $canWriteDirectly = Test-ReadWriteAccess -Path $target
    if (-not $canWriteDirectly -and $TakeOwnership) {
        Enable-WriteAccessForAdmins -Path $target
        $canWriteDirectly = Test-ReadWriteAccess -Path $target
    }

    if (-not $canWriteDirectly -and -not $UseSystemTask) {
        $accessError = Get-ReadWriteAccessError -Path $target
        if ($TakeOwnership) {
            throw "Write access is still denied after -TakeOwnership. Last File.Open error: $accessError. WindowsApps can still block Store package writes after file ACL changes. Try -UseSystemTask once; if that also returns 0x80070005, use New-CodexPatchedCopy.ps1 instead of patching WindowsApps in place."
        }
        throw "No write access to target. Last File.Open error: $accessError. Close Codex and run an elevated PowerShell session. If WindowsApps still denies access, rerun with -TakeOwnership, try -UseSystemTask once, or use New-CodexPatchedCopy.ps1."
    }

    if ($UseSystemTask) {
        Assert-Elevated
    }

    if ((Test-Path -LiteralPath $backup) -and -not $ForceBackup) {
        Write-Host "Backup already exists, keeping it: $backup"
    } else {
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Host "Backup written: $backup"
    }

    if ($canWriteDirectly -and -not $UseSystemTask) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            foreach ($write in $pendingWrites) {
                $stream.Seek($write.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $stream.Write($write.Bytes, 0, $write.Bytes.Length)
            }
            $stream.Flush($true)
        } finally {
            if ($null -ne $stream) { $stream.Close() }
        }
    } else {
        $patchedTemp = Join-Path $workDir "app.asar.codexfix.patched.tmp"
        try {
            [System.IO.File]::WriteAllBytes($patchedTemp, $bytes)
            Copy-FileAsSystem -Source $patchedTemp -Destination $target
        } finally {
            Remove-Item -LiteralPath $patchedTemp -Force -ErrorAction SilentlyContinue
        }
    }
}

$verifyBytes = [System.IO.File]::ReadAllBytes($target)
foreach ($patchGroup in $patchGroups) {
    $patchedCount = 0
    foreach ($patch in $patchGroup.Variants) {
        $originalIndex = [CodexFix.ByteSearch]::IndexOf($verifyBytes, $patch.OriginalBytes, 0)
        $patchedIndex = [CodexFix.ByteSearch]::IndexOf($verifyBytes, $patch.PatchedBytes, 0)
        if ($originalIndex -ge 0) {
            throw "Post-patch verification failed for '$($patch.Name)': original bytes are still present."
        }
        if ($patchedIndex -ge 0) {
            $patchedCount++
        }
    }
    if ($patchedCount -ne 1) {
        throw "Post-patch verification failed for '$($patchGroup.Name)': expected exactly one patched variant, found $patchedCount."
    }
}

[pscustomobject]@{
    Target = $target
    Backup = $backup
    Changed = $changed
    TargetSha256 = Get-Sha256Hash -Path $target
    Results = $results
} | ConvertTo-Json -Depth 5
