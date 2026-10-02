# 调研：去 Node 桥的原生 Swift 方案

状态：**评估中，未动工**。记录于 v3.3.0 发布后。

## 背景：为什么要重做

v3.3.0 用官方 `@anthropic-ai/claude-agent-sdk` 起常驻 node sidecar，实现了"后台任务跨微信消息存活"。功能达标，但部署代价偏重：

```
~/.config/ivox/bridge/        278 MB
  node_modules/               278 MB   ← 几乎全部体积
  bridge.messenger.mjs        8 KB     ← 实际逻辑
  state.json / package.json   可忽略
```

- 为 8 KB 的转发脚本背上整套 TS 依赖树（278 MB）。
- 额外要求用户安装 Node.js 18+，与"小而稳、零额外依赖"相悖。
- 多一层 node 二传手：Swift → node → claude。

## 关键事实：SDK 只是 claude 进程的封装

Agent SDK 本身不做推理，它做的事是：**spawn 原生 `claude` 二进制 + 通过 stdio 交换流式 JSON**。Node 不是必需品，只是官方目前只提供 TS/Python 的封装。

源码参考（本机 SDK）：

- `node_modules/@anthropic-ai/claude-agent-sdk/core.mjs` — spawn 参数、进程生命周期
- `node_modules/@anthropic-ai/claude-agent-sdk/agentSdkTypes.d.ts` — 消息类型定义
- `node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/` — 打包的原生 `claude` 二进制

## CLI 通信协议（据 SDK 源码，部分需实测核验）

启动 `claude` 时关键参数：

| 参数 | 作用 |
|---|---|
| `--input-format stream-json` | stdin 逐行 JSON |
| `--output-format stream-json` | stdout 逐行 JSON |
| `--verbose` | 输出含 session_id 等详细字段 |
| `--model <name>` | 指定模型 |
| `--session-id <sid>` / `--resume` | 恢复会话 |
| `--fork-session` | 基于现有会话分叉 |

- **帧边界**：stdin/stdout 都是 newline-delimited JSON（NDJSON），一行一条消息。
- **多轮常驻**：进程启动后 stdin 保持打开，逐行写入 user 消息即可连续对话；不在轮间关闭 stdin（这正是 v3.3.0 桥踩过的坑——prompt 被当单轮会导致 result 后 stdin 被关）。
- **stdout 消息类型**：`system`（含 init/session 信息）、`assistant`（文本/工具块）、`result`（一轮结束）等。
- **result 关键字段**：`subtype`（`success` / 错误类）、`is_error`、`num_turns`、`result`（最终文本）、`session_id`、`total_cost_usd` 等。
- **会话续接**：从 result 取 `session_id` 持久化；下次 spawn 带 `--resume --session-id <sid>` 恢复历史。
- **环境**：API key / base URL / model 走环境变量；`CLAUDE_CONFIG_DIR` 等可隔离配置目录。无独立握手包，首轮消息即开始。

> ⚠️ 待实测确认项（SDK 类型定义读得不完全确切，落码前需用裸进程验证）：
> 1. stdin user 消息的**确切** JSON 结构（`{role:"user", content:[{type:"text", text}]}` 还是 content 直接字符串）。
> 2. 一轮结束的界定：是收到 `result` 即可发下一条，还是需要显式 control/换行。
> 3. 工具权限（permission mode）如何在无 SDK 时表达——CLI flag（如 `--permission-mode acceptEdits` / `--dangerously-skip-permissions`）还是消息字段。
> 4. stdout `init` / `system` 消息里 session_id 与 result 里的是否一致、哪个为准。
> 5. SIGTERM 下 claude 是否优雅退出、有无子进程（工具进程）孤儿。

## 目标架构

```
Daemon (actor)
  └─ ClaudeAgent（Swift，新）：直接 Process spawn claude
        stdin  逐行写 user 消息
        stdout 逐行读，解析 system/assistant/result
        · 单常驻进程，session_id 落盘
        · 重启用 --resume 恢复
        · 闲置回收 + 信号清理
```

删除：node sidecar、`bridge.messenger.mjs`、`install-bridge-sdk.sh`、`~/.config/ivox/bridge/node_modules`（278 MB）、Node.js 依赖。

## 实施清单（立项时执行）

1. **裸进程协议探针** → 验证：手工 spawn `claude --input-format stream-json --output-format stream-json --verbose`，喂消息、抓 stdout，坐实上面 5 个待确认项。
2. **Swift 进程层**（替换 [ClaudeAskService.swift](../Sources/iVox/Network/ClaudeAskService.swift)）→ 验证：单轮问答文本与当前桥一致。
3. **NDJSON 编解码**（复用现有行缓冲解析模式）→ 验证：assistant 流式块 + result 收尾、错误分支。
4. **多轮常驻 + session resume** → 验证：真机两条消息，后台 `sleep 300 &` 后第二条查到"还在"，两轮 session_id 一致（沿用 v3.3.0 的验收标准）。
5. **生命周期**：Daemon cleanup 中关 stdin / 等退出 / 超时 terminate，无孤儿 claude。
6. **部署与文档**：改 Makefile 去掉 `install-bridge-sdk.sh`；README 删 Node 依赖；CHANGELOG 记录；旧 bridge 目录用 `trash` 挪走（不直接 rm）。

## 权衡

- **收益**：占用 278 MB → 0；去掉 Node 运行时依赖；链路少一跳、故障面更小。
- **成本/风险**：需自行维护与 claude 的 stream-json 协议，官方升级协议时要跟进（SDK 原本替我们吸收这部分）。建议把协议面收敛到最小（只发 user、只取 result/assistant 文本），降低耦合。
- **前置条件**：用户环境需有 `claude` CLI（当前微信链路本就依赖它，无新增）。Swift 需能定位该二进制路径。
- **决策建议**：协议探针（步骤 1）成本低、能先证伪；若裸进程稳定跑通多轮，则值得做这次减法。若协议在无 SDK 时存在无法表达的能力（如权限交互），则保留桥或退回 SDK。

## 备选方案（次优）

- **不常驻，任务外置**：agent 把长任务显式 `nohup` / `launchd submit` 出去、日志落盘，下轮读盘。绕开常驻进程，但交互形态弱、需改 agent 行为，不作为首选。
