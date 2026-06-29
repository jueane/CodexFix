# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository contains PowerShell tooling for a local workaround to Codex Desktop hangs caused by API-key-only sessions still polling ChatGPT `wham/*` endpoints. The model/API-key path is not the root issue; the targeted failures are repeated `401 Unauthorized` logs for:

- `GET https://chatgpt.com/backend-api/wham/tasks/list`
- `GET https://chatgpt.com/backend-api/wham/usage`

The current working approach is to create a writable external copy of the installed Codex package, patch that copy's `app.asar`, and launch the patched copy. Do not assume the installed WindowsApps package can be modified in place: on this machine, direct Administrator writes, `takeown`/`icacls`, and the SYSTEM scheduled-task copy fallback all failed with `0x80070005` against the installed `app.asar`.

## Common Commands

Run commands from `D:\develop\CodexFix` in PowerShell.

Create or refresh the patched external Codex copy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\New-CodexPatchedCopy.ps1
```

Start the patched copy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexPatchedCopy.ps1
```

Patch a specific `app.asar`, usually a test copy or portable copy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
```

Restore a specific `app.asar` from a backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
```

Validate PowerShell syntax after script edits:

```powershell
$files = @('.\Repair-CodexWhamPolling.ps1', '.\Restore-CodexWhamPolling.ps1', '.\New-CodexPatchedCopy.ps1', '.\Start-CodexPatchedCopy.ps1')
foreach ($file in $files) {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { $errors | ForEach-Object { "$file: $($_.Message)" } }
}
```

End-to-end validation with the local test `app.asar` copy, when present:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
```

Expected test hashes for Codex `26.623.5546.0`:

- Original: `EADBBADB611619E31D352190042586268AD38EC1A180F821C48550072872F1CF`
- Patched: `41F067A25CA12ADCBE3FB2597B45D03444DD59A56086F6A7ADB9C46134EC20E7`

Check whether the patched runtime is still producing the original failure signature:

```powershell
Select-String -Path "$env:LOCALAPPDATA\Codex\Logs\2026\06\29\*.log" -Pattern 'desktop_fetch_auth_401','/wham/tasks/list','/wham/usage'
```

Adjust the date path for the current log day.

## Architecture

`Repair-CodexWhamPolling.ps1` is the byte-level patcher. It locates a target `app.asar`, reads it as bytes, and applies two same-length UTF-8 replacements:

- Disables the sidebar task polling query by changing `enabled:!0` to `enabled:!1` in the `/wham/tasks/list` snippet.
- Replaces the `/wham/usage` call with `Promise.resolve(null)`, padded with spaces to preserve byte length.

The patcher refuses ambiguous or unsupported inputs: each original snippet must match exactly once, or the already-patched snippet must be present. It verifies after writing that original snippets are gone and patched snippets exist.

`Restore-CodexWhamPolling.ps1` restores a target `app.asar` from a backup and verifies SHA256 equality between backup and target after copying.

`New-CodexPatchedCopy.ps1` is the preferred workflow for this machine. It finds the newest installed `OpenAI.Codex_*_x64__2p2nqsd0c76g0` package under `C:\Program Files\WindowsApps`, copies the full package with `robocopy` into `portable\`, and then invokes `Repair-CodexWhamPolling.ps1` against the copied `app\resources\app.asar`. This avoids mutating WindowsApps.

`Start-CodexPatchedCopy.ps1` launches the latest package under `portable\` by running `app\Codex.exe` with its containing directory as the working directory.

Investigation context to preserve: the user uses `base_url + API key`, not ChatGPT login. Do not suggest logging into ChatGPT as the fix. The model request path works; the hang correlated with frontend `wham/*` polling failures, not `config.toml` or model API configuration. The relevant UI bundle locations in Codex `26.623.5546.0` were `webview/assets/sidebar-project-group-signals-B1b4ePo5.js` for `/wham/tasks/list` and `webview/assets/thread-context-inputs-BoCUYCfG.js` for `/wham/usage`.

## Repository State and Generated Files

The repository intentionally ignores generated or large artifacts:

- `portable/` contains full copied Codex app packages and should not be committed.
- `backups/` contains generated `app.asar` backups and should not be committed.
- `*.asar` and `*.asar.*` are ignored, including test and backup binaries.
- `.learnings/` is local diagnostic history and is ignored.

The tracked source should remain the PowerShell scripts, `README.md`, `CLAUDE.md`, `.gitignore`, and small metadata such as `test/original.sha256.txt`.

## Operational Notes

Before patching or recreating the portable copy, close running `Codex.exe` and `codex.exe` processes. `New-CodexPatchedCopy.ps1` enforces this.

Use the portable-copy workflow first. The in-place WindowsApps options in `Repair-CodexWhamPolling.ps1` and `Restore-CodexWhamPolling.ps1` are retained for machines where permissions allow them, but on this machine they have already failed even after `Administrators:F` and SYSTEM-copy attempts.

When Codex updates, rerun `New-CodexPatchedCopy.ps1`. If the script reports that patch bytes do not match original or patched bytes, inspect the new `app.asar` for updated `/wham/tasks/list` and `/wham/usage` snippets before changing patch strings.
