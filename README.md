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

然后在本目录的 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\New-CodexPatchedCopy.ps1
```

脚本会自动完成：

- 查找 C 盘已安装的最新版 Codex。
- 复制到 `D:\develop\CodexFix\portable\`。
- 修补复制出来的 `app\resources\app.asar`。
- 刷新桌面和本目录的 `Codex Original.lnk`。

## 启动

双击本目录的 `Start-CodexPatched.cmd` 启动补丁版。它调用同目录的 `Start-CodexPatched.ps1`；脚本会从自身位置的 `portable\` 中选择版本号最新、含有 `app\ChatGPT.exe` 的副本，并借用已安装 Codex 的 Windows 包身份启动，避免 `The process has no package identity`。

Windows 默认双击 `.ps1` 通常会打开编辑器；在 PowerShell 中也可直接执行 `& .\Start-CodexPatched.ps1`。桌面和本目录保留的 `Codex Original.lnk` 用于启动原版，升级后仍打开当前安装版本。

如果只想重新生成原版快捷方式，在本目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-CodexShortcuts.ps1
```

## 更新补丁版

Codex 官方版本升级后，重新运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\New-CodexPatchedCopy.ps1
```

新版本会复制到新的 `portable\OpenAI.Codex_<版本号>_x64__2p2nqsd0c76g0\` 目录；启动脚本下次运行时会自动选择它。

当前脚本只支持最新维护目标 Codex `26.917.8451.0`，不保留旧版 Codex 的补丁兼容代码。

该版本的 `app.asar` SHA-256（文件指纹）为：

- 原始：`18D9C47F7FCCED4124A6AC4C62AD3DD67AE107C22D7BCA62029FA81204B86240`
- 已修补：`3860E8508D1C044F3A52AFA256EC9ADEFDF708733A9D73D643B549852FB7D7DD`

Codex 每次更新后，都需要先检查新版 `app.asar` 里的 `/wham/tasks/list` 和 `/wham/usage` 片段，再把 `Repair-CodexWhamPolling.ps1` 更新为只匹配该最新版本；旧版本匹配应同时移除。

如果要重建同一个版本号的 portable 目录，使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\New-CodexPatchedCopy.ps1 -Force
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

- `New-CodexPatchedCopy.ps1`：创建或刷新外置补丁版，并刷新原版快捷方式。
- `Update-CodexShortcuts.ps1`：创建或刷新原版启动快捷方式。
- `Start-CodexPatched.cmd`：可双击的补丁版启动入口。
- `Start-CodexPatched.ps1`：选择最新外置副本并借用已安装 Codex 的 Windows 包身份启动。
- `Repair-CodexWhamPolling.ps1`：修补指定 `app.asar`。
- `portable\`、`backups\`、`*.asar`、`*.lnk` 都是本地生成内容，不提交 git。
