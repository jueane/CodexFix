#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TargetAsar,
    [string]$BackupPath,
    [switch]$TakeOwnership,
    [switch]$UseSystemTask
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
        $running = @(Get-Process -Name "Codex","codex" -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            $ids = ($running | Select-Object -ExpandProperty Id) -join ", "
            throw "Close Codex before restoring the installed app.asar. Running process IDs: $ids"
        }
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
    $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
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

$target = Resolve-TargetAsar -Path $TargetAsar
Assert-CodexClosedIfInstalledTarget -Path $target

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path (Join-Path $PSScriptRoot "backups") "app.asar.codexfix.bak"
}
$backup = (Resolve-Path -LiteralPath $BackupPath).Path

$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
$canWriteDirectly = Test-ReadWriteAccess -Path $target
if (-not $canWriteDirectly -and $TakeOwnership) {
    Enable-WriteAccessForAdmins -Path $target
    $canWriteDirectly = Test-ReadWriteAccess -Path $target
}

if (-not $canWriteDirectly -and -not $UseSystemTask) {
    $accessError = Get-ReadWriteAccessError -Path $target
    if ($TakeOwnership) {
        throw "Write access is still denied after -TakeOwnership. Last File.Open error: $accessError. WindowsApps can still block Store package writes after file ACL changes. Try -UseSystemTask once; if that also returns 0x80070005, restore is only needed for a previously modified external copy or for a WindowsApps write path with higher privileges."
    }
    throw "No write access to target. Last File.Open error: $accessError. Close Codex and run an elevated PowerShell session. If WindowsApps still denies access, rerun with -TakeOwnership or try -UseSystemTask once."
}

if ($UseSystemTask) {
    Assert-Elevated
}

if ($canWriteDirectly -and -not $UseSystemTask) {
    Copy-Item -LiteralPath $backup -Destination $target -Force
} else {
    Copy-FileAsSystem -Source $backup -Destination $target
}
$targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

if ($backupHash -ne $targetHash) {
    throw "Restore verification failed: target hash does not match backup hash."
}

[pscustomobject]@{
    Target = $target
    RestoredFrom = $backup
    TargetSha256 = $targetHash
} | ConvertTo-Json -Depth 3
