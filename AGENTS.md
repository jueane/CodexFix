# Codex Desktop 卡顿排查上下文

## 当前结论

用户使用的是 `base_url + API key` 模式，不走 ChatGPT 登录。模型请求本身能正常工作。

卡顿的根因不是模型 API 请求，而是 Codex Desktop 前端仍在后台轮询 ChatGPT `wham/*` 接口。这些接口需要 ChatGPT 后端 token，但 API-key-only 模式没有该 token，因此不断出现 `401 Unauthorized`。

关键失败特征：

```text
desktop_fetch_auth_401
hadToken=false
skipRetryReason=no_token_attached
status=401
GET https://chatgpt.com/backend-api/wham/tasks/list
GET https://chatgpt.com/backend-api/wham/usage
```

这些请求与 Windows 记录到的 `Codex.exe AppHangTransient` 在关键时间点同秒对齐。

## 已确认的关键事实

- Codex 自己上报的上下文里有 `authMethod: "apikey"`。
- `config.toml` 的模型配置不是这次卡顿的直接触发点；模型调用能正常说明 API key 路径已经生效。
- `/wham/tasks/list` 和 `/wham/usage` 不走用户的自定义 `base_url`，而是走 `chatgpt.com/backend-api/wham/*`。
- Codex 设置界面没有找到能彻底关闭这两个轮询的入口。
- 本地 feature flag 表 `local_app_server_feature_enablement` 为空，且目标轮询代码没有接入这个表。

## 代码定位

安装包：

```text
C:\Program Files\WindowsApps\OpenAI.Codex_26.623.5546.0_x64__2p2nqsd0c76g0\app\resources\app.asar
```

目标 1：侧边栏任务轮询

```text
webview/assets/sidebar-project-group-signals-B1b4ePo5.js
```

原始代码片段包含：

```js
enabled:!0
se.safeGet(`/wham/tasks/list`, { ... task_filter:`current` ... })
```

这里是硬编码启用，没有判断 `authMethod === "chatgpt"`。

补丁策略：

```text
enabled:!0 -> enabled:!1
```

目标 2：用量/限额轮询

```text
webview/assets/thread-context-inputs-BoCUYCfG.js
```

原始代码片段包含：

```js
return await on.safeGet(`/wham/usage`)
```

补丁策略：

```text
return await on.safeGet(`/wham/usage`) -> return await Promise.resolve(null)
```

脚本中为了原地替换，补丁字符串末尾保留了空格以保持字节长度一致。

## 测试验证

测试副本：

```text
D:\develop\CodexFix\test\app.asar
```

原始 SHA256：

```text
EADBBADB611619E31D352190042586268AD38EC1A180F821C48550072872F1CF
```

修复后 SHA256：

```text
41F067A25CA12ADCBE3FB2597B45D03444DD59A56086F6A7ADB9C46134EC20E7
```

修复脚本验证结果：

- `/wham/tasks/list` 原始片段不存在。
- `/wham/tasks/list` 补丁片段存在，偏移 `137799299`。
- `/wham/usage` 原始片段不存在。
- `/wham/usage` 补丁片段存在，偏移 `152293730`。

还原脚本验证结果：

- 还原后 SHA256 回到原始值。
- 原始片段存在。
- 补丁片段不存在。

## 脚本行为

修复脚本：

```text
D:\develop\CodexFix\Repair-CodexWhamPolling.ps1
```

还原脚本：

```text
D:\develop\CodexFix\Restore-CodexWhamPolling.ps1
```

默认备份位置：

```text
D:\develop\CodexFix\backups\app.asar.codexfix.bak
```

脚本默认会自动寻找最新的 Codex `app.asar`。也支持手动传入测试路径：

```powershell
-TargetAsar D:\develop\CodexFix\test\app.asar
```

如果 WindowsApps 权限不足，脚本会报错。只有显式加 `-TakeOwnership` 时，才会对目标文件执行：

```text
takeown.exe /F <app.asar> /A
icacls.exe <app.asar> /grant Administrators:F
```

## 后续会话注意

- 不要再把根因描述为“用户需要登录 ChatGPT”。
- 不要建议用户登录；用户明确只使用 API key。
- 不要再把模型 `base_url + API key` 配置当成主要问题。
- 重点围绕 `wham/*` 前端轮询、安装包补丁、补丁后日志验证继续。
- 回答时按最新状态说，不重复已经被用户修正过的旧判断。
