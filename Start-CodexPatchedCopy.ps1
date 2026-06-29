#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PortablePackageDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DefaultPortablePackageDir {
    $portableRoot = Join-Path $PSScriptRoot "portable"
    if (-not (Test-Path -LiteralPath $portableRoot)) {
        throw "Portable directory not found. Run New-CodexPatchedCopy.ps1 first."
    }

    $candidate = Get-ChildItem -LiteralPath $portableRoot -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "app\Codex.exe") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No patched Codex copy was found under $portableRoot. Run New-CodexPatchedCopy.ps1 first."
    }

    return $candidate.FullName
}

if ([string]::IsNullOrWhiteSpace($PortablePackageDir)) {
    $PortablePackageDir = Get-DefaultPortablePackageDir
} else {
    $PortablePackageDir = (Resolve-Path -LiteralPath $PortablePackageDir).Path
}

$exe = Join-Path $PortablePackageDir "app\Codex.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Codex executable not found: $exe"
}

$workingDirectory = Split-Path -Parent $exe
$process = Start-Process -FilePath $exe -WorkingDirectory $workingDirectory -PassThru

[pscustomobject]@{
    Started = $true
    ProcessId = $process.Id
    Executable = $exe
} | ConvertTo-Json -Depth 3
