# Codex Wham Polling Fix

这个目录用于给 Codex Desktop 创建一个外置补丁版，绕过 API-key-only 使用模式下仍轮询 ChatGPT `wham/*` 接口导致的卡顿。

补丁版不会修改 `C:\Program Files\WindowsApps` 中的原始安装包，而是把最新版 Codex 复制到本目录的 `portable\` 后修补副本。

## 使用步骤

先完全退出 Codex，确认没有这些进程：

```text
ChatGPT.exe
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

这两个快捷方式都会出现在桌面和本目录。`Codex Patched.lnk` 会通过 `Start-CodexPatched.ps1` 在已安装 Codex 的 Windows 包身份中启动外置补丁副本，避免新版直接运行时报 `The process has no package identity`。`Codex Original.lnk` 使用 Windows AppsFolder 应用 ID 启动，所以 Codex 官方版本升级后，它仍会打开当前安装的最新版。

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

当前脚本只支持最新维护目标 Codex `26.915.4065.0`，不保留旧版 Codex 的补丁兼容代码。

该版本的 `app.asar` SHA-256（文件指纹）为：

- 原始：`B8AEB817CD1EE6EF50EFE8A97985D3BE41DE89688A5ADDFE0A444E1E52348096`
- 已修补：`B0937E89AC9248158F0CA8D89F21617B7A28561C0C8F344C604FC5A004F55D05`

Codex 每次更新后，都需要先检查新版 `app.asar` 里的 `/wham/tasks/list` 和 `/wham/usage` 片段，再把 `Repair-CodexWhamPolling.ps1` 更新为只匹配该最新版本；旧版本匹配应同时移除。

如果要重建同一个版本号的 portable 目录，使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\New-CodexPatchedCopy.ps1 -Force
```

如果要撤销某个补丁版，先关闭 Codex，然后直接删除对应的 `portable\OpenAI.Codex_<版本号>_x64__2p2nqsd0c76g0\` 目录。之后需要补丁版时，重新运行 `New-CodexPatchedCopy.ps1` 即可。

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
- `Start-CodexPatched.ps1`：借用已安装 Codex 的 Windows 包身份启动外置补丁副本。
- `Repair-CodexWhamPolling.ps1`：修补指定 `app.asar`。
- `portable\`、`backups\`、`*.asar`、`*.lnk` 都是本地生成内容，不提交 git。
