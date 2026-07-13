# Codex Wham Polling Fix

这个目录用于给 Codex Desktop 创建一个外置补丁版，绕过 API-key-only 使用模式下仍轮询 ChatGPT `wham/*` 接口导致的卡顿。

补丁版不会修改 `C:\Program Files\WindowsApps` 中的原始安装包，而是把最新版 Codex 复制到本目录的 `portable\` 后修补副本。

## 使用步骤

先完全退出 Codex，确认没有这些进程：

```text
Codex.exe
codex.exe
```

然后在 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\New-CodexPatchedCopy.ps1
```

脚本会自动完成：

- 查找 C 盘已安装的最新版 Codex。
- 复制到 `D:\develop\CodexFix\portable\`。
- 修补复制出来的 `app\resources\app.asar`。
- 刷新桌面和本目录的快捷方式。

## 快捷方式

脚本会生成这些本地快捷方式：

- `Codex Patched.lnk`：启动补丁版。
- `Codex Original.lnk`：启动原版 Codex。

这两个快捷方式都会出现在桌面和本目录。`Codex Original.lnk` 使用 Windows AppsFolder 应用 ID 启动，所以 Codex 官方版本升级后，它仍会打开当前安装的最新版。

如果只想重新生成快捷方式，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Update-CodexShortcuts.ps1
```

## 更新补丁版

Codex 官方版本升级后，重新运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\New-CodexPatchedCopy.ps1
```

新版本会复制到新的 `portable\OpenAI.Codex_<版本号>_x64__2p2nqsd0c76g0\` 目录，并自动刷新 `Codex Patched.lnk` 指向新补丁版。

当前脚本已验证支持 Codex `26.623.5546.0` 和 `26.707.3748.0`。如果未来官方版本再次变更导致字节不匹配，需要先检查新版 `app.asar` 里的 `/wham/tasks/list` 和 `/wham/usage` 片段，再更新 `Repair-CodexWhamPolling.ps1`。

如果要重建同一个版本号的 portable 目录，使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\New-CodexPatchedCopy.ps1 -Force
```

## 验证

启动补丁版后，可以检查当天日志里是否还出现这些内容：

```text
desktop_fetch_auth_401
/wham/tasks/list
/wham/usage
```

示例命令，按实际日期调整路径：

```powershell
Select-String -Path "$env:LOCALAPPDATA\Codex\Logs\2026\07\01\*.log" -Pattern 'desktop_fetch_auth_401','/wham/tasks/list','/wham/usage'
```

## 文件说明

- `New-CodexPatchedCopy.ps1`：创建或刷新外置补丁版，并自动刷新快捷方式。
- `Update-CodexShortcuts.ps1`：创建或刷新补丁版和原版启动快捷方式。
- `Repair-CodexWhamPolling.ps1`：修补指定 `app.asar`。
- `Restore-CodexWhamPolling.ps1`：从备份还原指定 `app.asar`。
- `portable\`、`backups\`、`*.asar`、`*.lnk` 都是本地生成内容，不提交 git。
