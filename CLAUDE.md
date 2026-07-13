# CLAUDE.md

这个文件给 Claude Code 在本仓库中工作时提供项目说明和约束。

## 目的

本仓库包含一组 PowerShell 工具，用于临时绕过 Codex Desktop 在 `base_url + API key` 使用模式下仍轮询 ChatGPT `wham/*` 接口导致的卡顿。模型/API-key 请求路径不是根因；需要处理的是日志中反复出现的这些 `401 Unauthorized`：

- `GET https://chatgpt.com/backend-api/wham/tasks/list`
- `GET https://chatgpt.com/backend-api/wham/usage`

当前有效方案是：创建一个可写的 Codex 已安装包外置副本，修补该副本中的 `app.asar`，然后启动这个补丁副本。不要假设可以直接修改 WindowsApps 中安装的包；在这台机器上，直接管理员写入、`takeown`/`icacls`、以及 SYSTEM 计划任务复制兜底都曾对已安装的 `app.asar` 返回 `0x80070005`。

## 已确认结论

主要卡顿触发源已确认是 API-key-only 模式下前端仍持续轮询 ChatGPT `wham/*` 接口，而不是模型 API、`config.toml` 或缺少 ChatGPT 登录。

保留证据时，应以补丁外置副本运行结果为基准：

- 2026-06-30，使用补丁 portable 副本运行后，当天检查到的 `desktop_fetch_auth_401`、`/wham/tasks/list`、`/wham/usage` 都是 0，且没有 Codex AppHang/crash/WER 事件。
- 其他日志噪声，例如 `Received turn/... for unknown conversation`、git watcher 警告、worker RPC 警告、WSL 状态失败等曾出现过，但目前没有和原始 AppHang 模式形成稳定关联。

## 常用命令

在 PowerShell 中从 `D:\develop\CodexFix` 执行命令。

创建或刷新补丁外置 Codex 副本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\New-CodexPatchedCopy.ps1
```

刷新桌面和仓库根目录快捷方式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-CodexShortcuts.ps1
```

修补指定的 `app.asar`，通常用于测试副本或 portable 副本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
```

撤销 portable 补丁版时，不再单独还原 `app.asar`；关闭 Codex 后直接删除对应的 `portable\OpenAI.Codex_<版本号>_x64__2p2nqsd0c76g0\` 目录，需要时重新运行 `New-CodexPatchedCopy.ps1` 生成新的补丁副本。

脚本编辑后验证 PowerShell 语法：

```powershell
$files = @('.\Repair-CodexWhamPolling.ps1', '.\New-CodexPatchedCopy.ps1', '.\Update-CodexShortcuts.ps1')
foreach ($file in $files) {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { $errors | ForEach-Object { "${file}: $($_.Message)" } }
}
```

本地测试 `app.asar` 副本存在时，可验证修补和重复运行的幂等性。需要回到原始状态时，重新复制测试用 `app.asar`，不要依赖还原脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
powershell -NoProfile -ExecutionPolicy Bypass -File .\Repair-CodexWhamPolling.ps1 -TargetAsar .\test\app.asar -BackupPath .\test\app.asar.codexfix.bak
```

已验证 Codex 版本的预期测试哈希：

Codex `26.623.5546.0`：

- 原始：`EADBBADB611619E31D352190042586268AD38EC1A180F821C48550072872F1CF`
- 已修补：`41F067A25CA12ADCBE3FB2597B45D03444DD59A56086F6A7ADB9C46134EC20E7`

Codex `26.707.3748.0`：

- 原始：`8569B806651BA64C7A0D2FB2E072D4616F37DFE9A057BE6EC829B6FA1C193B10`
- 已修补：`17765FFF1543F70C5EE4B9F20005FD5638CD33319A8309E7BFC1769BBDCF9F4B`

检查补丁运行时是否仍产生原始失败特征：

```powershell
Select-String -Path "$env:LOCALAPPDATA\Codex\Logs\2026\06\29\*.log" -Pattern 'desktop_fetch_auth_401','/wham/tasks/list','/wham/usage'
```

按当前日志日期调整路径。

## 架构

`Repair-CodexWhamPolling.ps1` 是字节级修补器。它定位目标 `app.asar`，按字节读取，并应用两个补丁组；每个补丁组可以包含多个 Codex 版本的等长 UTF-8 片段变体：

- 通过把 `/wham/tasks/list` 当前任务轮询片段中的 `enabled:!0` 改成 `enabled:!1`，禁用侧边栏任务轮询查询。
- 把 `/wham/usage` 速率限制状态调用替换成 `Promise.resolve(null)`；补丁字符串较短时自动用空格填充以保持字节长度不变。

修补器会拒绝模糊或不支持的输入：每个补丁组必须精确匹配一个原始变体，或者必须已经存在一个已修补变体。写入后它会验证所有原始变体已消失，且每个补丁组恰好存在一个已修补变体。

`New-CodexPatchedCopy.ps1` 是这台机器上的首选流程。它会在 `C:\Program Files\WindowsApps` 下找到最新的 `OpenAI.Codex_*_x64__2p2nqsd0c76g0` 安装包，用 `robocopy` 复制完整包到 `portable\`，调用 `Repair-CodexWhamPolling.ps1` 修补副本中的 `app\resources\app.asar`，然后刷新快捷方式。这样可以避免修改 WindowsApps。

`Update-CodexShortcuts.ps1` 会在用户桌面和仓库根目录创建或刷新 `Codex Patched.lnk` 与 `Codex Original.lnk`。默认情况下，补丁版快捷方式指向 `portable\` 下版本号最高的包，并从 `AppxManifest.xml` 读取实际启动程序；新版包可能是 `app\ChatGPT.exe`，旧版包可能是 `app\Codex.exe`。`New-CodexPatchedCopy.ps1` 会显式传入刚修补好的包。原版快捷方式通过 Explorer 启动 `shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App`，因此 Codex 升级后仍会打开当前安装的最新版。

需要保留的调查背景：用户使用 `base_url + API key`，不是 ChatGPT 登录。不要把登录 ChatGPT 建议为修复方案。模型请求路径可用；卡顿与前端 `wham/*` 轮询失败相关，而不是 `config.toml` 或模型 API 配置。Codex `26.623.5546.0` 中相关 UI bundle 位置曾是：`webview/assets/sidebar-project-group-signals-B1b4ePo5.js` 对应 `/wham/tasks/list`，`webview/assets/thread-context-inputs-BoCUYCfG.js` 对应 `/wham/usage`。Codex `26.707.3748.0` 中已验证的新片段是当前任务轮询里的 `Ae.safeGet('/wham/tasks/list', ...)`，以及带 `supports_rewardless_invites:!0` 查询参数的 `hi.safeGet('/wham/usage', ...)`。

## 仓库状态和生成文件

仓库有意忽略生成产物或大文件：

- `portable/` 包含完整复制出来的 Codex app 包，不应提交。
- `backups/` 包含生成的 `app.asar` 备份，不应提交。
- `*.asar` 和 `*.asar.*` 会被忽略，包括测试和备份二进制文件。
- `*.lnk` 快捷方式是本地生成文件，不应提交。
- `.learnings/` 是本地诊断历史，会被忽略。

跟踪源码应保持为 PowerShell 脚本、`README.md`、`CLAUDE.md`、`.gitignore`，以及少量元数据，例如 `test/original.sha256.txt`。

## 操作注意事项

修补或重新创建 portable 副本前，先关闭正在运行的 `ChatGPT.exe`、`Codex.exe` 和 `codex.exe` 进程。`New-CodexPatchedCopy.ps1` 会强制检查这一点。

优先使用 portable 外置副本流程。不要尝试修改 WindowsApps 中的已安装包；在这台机器上，即使尝试 `Administrators:F` 和 SYSTEM 复制也已经失败。撤销补丁版时直接删除对应的 portable 版本目录。

用户要求提交和推送时，默认直接提交到 `main` 并推送 `origin/main`；不要创建临时功能分支，除非用户明确要求分支或 PR。

Codex 更新后，重新运行 `New-CodexPatchedCopy.ps1`。如果脚本报告补丁字节不匹配原始或已修补字节，需要先检查新版 `app.asar` 中更新后的 `/wham/tasks/list` 和 `/wham/usage` 片段，再修改补丁字符串。
