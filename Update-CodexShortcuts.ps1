#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ShortcutDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ShortcutDirectory)) {
    $ShortcutDirectory = $PSScriptRoot
}

$shell = New-Object -ComObject WScript.Shell
$explorer = Join-Path $env:WINDIR 'explorer.exe'
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Original.lnk'),
    (Join-Path $ShortcutDirectory 'Codex Original.lnk')
) | Select-Object -Unique

foreach ($path in $shortcuts) {
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $explorer
    $shortcut.Arguments = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
    $shortcut.Description = 'Codex original installed app'
    $shortcut.Save()
}

$shortcuts
