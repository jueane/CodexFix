# Codex Wham Polling Fix

这个目录用于临时修复 Codex Desktop 在 `base_url + API key` 使用模式下仍轮询 ChatGPT `wham/*` 接口导致卡顿的问题。

## 问题背景

用户使用的是 `base_url + API key` 模式，不走 ChatGPT 登录；模型请求本身能正常工作。卡顿根因是 Codex Desktop 前端仍在后台轮询 ChatGPT `wham/*` 接口，这些接口需要 ChatGPT 后端 token，但 API-key-only 模式没有该 token，因此持续出现：

```text
desktop_fetch_auth_401
hadToken=false
skipRetryReason=no_token_attached
status=401
GET https://chatgpt.com/backend-api/wham/tasks/list
GET https://chatgpt.com/backend-api/wham/usage
```

补丁点：

- 侧边栏任务轮询：`webview/assets/sidebar-project-group-signals-B1b4ePo5.js` 中的 `/wham/tasks/list` 查询由 `enabled:!0` 改为 `enabled:!1`。
- 用量/限额轮询：`webview/assets/thread-context-inputs-BoCUYCfG.js` 中的 `/wham/usage` 调用改为 `Promise.resolve(null)`，并用空格保持字节长度一致。

## 已确认结论

当前结论比较稳定：主要卡顿触发源是 API-key-only 模式下仍持续轮询 ChatGPT `wham/*` 接口，而不是模型 API、`config.toml` 或必须登录 ChatGPT。

验证记录以补丁版运行日为准：

- 2026-06-30 使用外置补丁版 `D:\develop\CodexFix\portable\OpenAI.Codex_26.623.5546.0_x64__2p2nqsd0c76g0` 后，当天日志中 `desktop_fetch_auth_401`、`/wham/tasks/list`、`/wham/usage` 均为 `0`，且没有 Codex AppHang/crash/WER 事件。
- 日志中仍可能出现 `Received turn/... for unknown conversation`、git watcher、worker RPC、WSL 查询失败等噪声；目前没有证据表明它们与之前的系统级卡顿形成稳定关联。

## 文件

- `Repair-CodexWhamPolling.ps1`：修复脚本，禁用两个轮询点。
- `Restore-CodexWhamPolling.ps1`：还原脚本，用备份恢复原始 `app.asar`。
- `backups\app.asar.codexfix.bak`：修复脚本生成的原始备份。
- `test\app.asar`：测试用复制件，不是 Codex 正式安装文件。

## 修复前

先完全退出 Codex。确认任务管理器里没有这些进程：

```text
Codex.exe
codex.exe
```

## 执行修复

### 外置副本修复

如果 WindowsApps 拒绝直接写入，推荐使用外置副本。它不会修改正式安装目录，而是复制 Codex 包到 `D:\develop\CodexFix\portable` 后修补副本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\New-CodexPatchedCopy.ps1
```

启动修补后的副本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Start-CodexPatchedCopy.ps1
```

已创建副本后，也可以直接使用桌面快捷方式 `Codex Patched.lnk`。

### WindowsApps 原地修复

普通执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Repair-CodexWhamPolling.ps1
```

如果提示 WindowsApps 没写权限，用管理员 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Repair-CodexWhamPolling.ps1 -TakeOwnership
```

如果 `-TakeOwnership` 后仍然提示 `Access to the path ... is denied`，可以尝试一次 SYSTEM 兜底写入；如果仍返回 `0x80070005`，改用外置副本修复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Repair-CodexWhamPolling.ps1 -UseSystemTask
```

修复脚本会自动查找最新的 Codex `app.asar`，并备份到：

```text
D:\develop\CodexFix\backups\app.asar.codexfix.bak
```

## 执行还原

先完全退出 Codex，然后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Restore-CodexWhamPolling.ps1
```

如果提示 WindowsApps 没写权限，用管理员 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Restore-CodexWhamPolling.ps1 -TakeOwnership
```

如果 `-TakeOwnership` 后仍然被 WindowsApps 拒绝写入，用管理员 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\develop\CodexFix\Restore-CodexWhamPolling.ps1 -UseSystemTask
```

## 验证效果

修复后重新打开 Codex，观察是否还出现周期性界面锁死。

如需进一步确认，可查日志中是否还持续出现：

```text
desktop_fetch_auth_401
hadToken=false
/wham/tasks/list
/wham/usage
```

## 注意

- 这是本机临时补丁，不是官方修复。
- Codex 更新后可能覆盖 `app.asar`，需要重新执行修复脚本。
- `-TakeOwnership` 会修改 WindowsApps 中目标文件的所有权/ACL，只在普通管理员权限仍无法写入时使用。
- `-UseSystemTask` 会创建一次性 SYSTEM 计划任务执行最终文件覆盖，任务完成后脚本会自动注销并删除临时 helper；它用于 WindowsApps 在目标文件 ACL 已放开后仍拒绝管理员写入的情况。
- 当前机器上 WindowsApps 对正式安装目录的保护会连 SYSTEM 覆盖也拒绝，已改用外置补丁副本：`D:\develop\CodexFix\portable\OpenAI.Codex_26.623.5546.0_x64__2p2nqsd0c76g0`。
